defmodule Slipdock.Meetings.ReviewTest do
  @moduledoc """
  What a reviewer does (#537): answer and take back answers, with the
  finding put back exactly; include, leave out, edit (marked as theirs), add
  what the transcript missed; and the capture's state following its open
  questions.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Meetings, Repo}
  alias Slipdock.Meetings.{Event, Finding, Question, Review}

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Pricing"}, owner: owner)
    sam = user_fixture("sam@example.com")
    {:ok, sam} = Slipdock.Accounts.update_profile(sam, %{"name" => "Sam Smith"})
    share_fixture(board, [sam], "write")
    %{owner: owner, board: board, sam: sam}
  end

  defp only_question(capture),
    do: Repo.one!(from(q in Question, where: q.capture_id == ^capture.id))

  defp only_finding(capture),
    do: Repo.one!(from(f in Finding, where: f.capture_id == ^capture.id))

  test "answering who is meant assigns them; the last answer makes it ready", %{
    board: board,
    owner: owner,
    sam: sam
  } do
    capture = reviewed_capture(board, owner, [action_finding("Sammy")])
    assert capture.state == "needs_review"

    {:ok, _} = Review.answer(only_question(capture), "user:#{sam.id}", owner)

    f = only_finding(capture)
    assert f.effect["assignee_id"] == sam.id
    assert Meetings.get_capture!(capture.id).state == "ready"

    q = only_question(capture)
    assert q.status == "answered" and q.answered_by_id == owner.id and q.via == "web"
    assert q.answer["label"] == "Sam Smith"
  end

  test "taking an answer back reopens it, puts the finding back and the state too", %{
    board: board,
    owner: owner,
    sam: sam
  } do
    capture = reviewed_capture(board, owner, [action_finding("Sammy")])
    before = only_finding(capture)
    {:ok, _} = Review.answer(only_question(capture), "user:#{sam.id}", owner)
    {:ok, _} = Review.unanswer(only_question(capture), owner)

    after_ = only_finding(capture)
    assert after_.effect == before.effect
    assert after_.signals == before.signals
    assert only_question(capture).status == "open"
    assert Meetings.get_capture!(capture.id).state == "needs_review"
  end

  test "an answer through an agent, after a replay, is recorded as such", %{
    board: board,
    owner: owner
  } do
    capture = reviewed_capture(board, owner, [action_finding("Sammy")])

    {:ok, _} =
      Review.answer(only_question(capture), "none", owner,
        via: "agent",
        context: %{replayed: "0:09–0:14"}
      )

    q = only_question(capture)
    assert q.via == "agent"
    assert q.context["replayed"] == "0:09–0:14"

    message =
      Repo.one!(
        from(e in Event,
          where: e.capture_id == ^capture.id and e.kind == "answered",
          select: e.message
        )
      )

    assert message =~ "Nobody yet (via agent), after replaying 0:09–0:14."
    refute Map.has_key?(only_finding(capture).effect, "assignee_id")
  end

  test "choosing the existing card turns the action into a change to it", %{
    board: board,
    owner: owner
  } do
    card = card_fixture(hd(board.columns), %{"title" => "Pricing page refresh"})

    candidate = %{
      "type" => "card",
      "id" => card.id,
      "ref" => "##{card.id}",
      "title" => card.title,
      "lines" => ["L3"],
      "strength" => "similarity",
      "version" => "v"
    }

    capture =
      reviewed_capture(board, owner, [action_finding(nil, %{"owner" => nil})], %{
        "candidates" => [candidate]
      })

    {:ok, _} = Review.answer(only_question(capture), "card:#{card.id}", owner)
    f = only_finding(capture)
    assert f.kind == "card_change"
    assert f.effect["card_id"] == card.id
    assert f.effect["changes"] == %{"due_date" => "2026-10-09"}
    assert [%{"id" => id, "strength" => "person"}] = f.links
    assert id == card.id
  end

  test "neither leaves it out; a new card keeps it as one", %{board: board, owner: owner} do
    card = card_fixture(hd(board.columns), %{"title" => "Pricing page refresh"})

    candidate = %{
      "type" => "card",
      "id" => card.id,
      "ref" => "##{card.id}",
      "title" => card.title,
      "lines" => ["L3"],
      "strength" => "name",
      "version" => "v"
    }

    capture =
      reviewed_capture(board, owner, [action_finding(nil, %{"owner" => nil})], %{
        "candidates" => [candidate]
      })

    {:ok, _} = Review.answer(only_question(capture), "none", owner)
    refute only_finding(capture).included

    {:ok, _} = Review.unanswer(only_question(capture), owner)
    {:ok, _} = Review.answer(only_question(capture), "new", owner)
    assert %{included: true, effect: %{"type" => "new_card"}} = only_finding(capture)
  end

  test "which reading takes the chosen reading's words", %{board: board, owner: owner} do
    capture = capture_fixture(board, owner)
    {:ok, capture} = Meetings.transition(capture, "reading")

    capture =
      capture
      |> Ecto.Changeset.change(
        readings: %{
          "1" => [decision_finding(%{"title" => "Annual plan at 15% off"})],
          "2" => [decision_finding(%{"title" => "Annual plan at 50% off"})]
        },
        context: %{"candidates" => []}
      )
      |> Repo.update!()

    {:ok, _} = Meetings.verify(capture)
    {:ok, capture} = Meetings.transition(capture, "needs_review")

    {:ok, _} = Review.answer(only_question(capture), "reading:2", owner)
    f = only_finding(capture)
    assert f.title == "Annual plan at 50% off"
    assert f.effect["text"] == "Annual plan at 50% off"
  end

  test "include, leave out, edit and add are each the reviewer's, on the record", %{
    board: board,
    owner: owner
  } do
    capture = reviewed_capture(board, owner, [decision_finding()])
    f = only_finding(capture)

    {:ok, _} = Review.include(f, false, owner)
    refute Repo.reload!(f).included
    {:ok, _} = Review.include(f, true, owner)

    {:ok, edited} =
      Review.edit(
        Repo.reload!(f),
        %{"title" => "Annual plan, 20% off", "topic" => "Plans"},
        owner
      )

    assert edited.edited_by_id == owner.id
    # The topic is a label (a heading on the meeting's page), not a page.
    assert edited.effect["topic"] == "Plans"
    refute Map.has_key?(edited.effect, "page")
    assert edited.effect["text"] == "Annual plan, 20% off"

    {:ok, added} =
      Review.add(
        capture,
        %{
          "kind" => "action",
          "title" => "Tell sales",
          "list" => "To Do",
          "assignee_id" => to_string(owner.id)
        },
        owner
      )

    assert added.origin == "person" and added.added_by_id == owner.id
    assert added.signals == ["added_by_person"]

    assert added.effect == %{
             "type" => "new_card",
             "title" => "Tell sales",
             "list" => "To Do",
             "assignee_id" => owner.id
           }

    kinds = Repo.all(from(e in Event, where: e.capture_id == ^capture.id, select: e.kind))
    assert Enum.count(kinds, &(&1 == "included")) == 2
    assert "edited" in kinds and "added" in kinds
  end

  test "an added finding needs a title", %{board: board, owner: owner} do
    capture = reviewed_capture(board, owner, [decision_finding()])
    assert {:error, %Ecto.Changeset{}} = Review.add(capture, %{"title" => " "}, owner)
  end

  test "a committed or discarded capture cannot be changed", %{board: board, owner: owner} do
    capture = reviewed_capture(board, owner, [decision_finding()])
    {:ok, _} = Meetings.transition(Meetings.get_capture!(capture.id), "discarded")

    assert {:error, "this capture is discarded: there is nothing left to review"} =
             Review.include(only_finding(capture), false, owner)
  end

  test "an answer that is not one of the options is refused", %{board: board, owner: owner} do
    capture = reviewed_capture(board, owner, [action_finding("Sammy")])

    assert {:error, "that is not one of the answers to this question"} =
             Review.answer(only_question(capture), "user:999999", owner)
  end

  test "a dropped finding cannot be included", %{board: board, owner: owner} do
    capture =
      reviewed_capture(board, owner, [
        decision_finding(%{"evidence" => [%{"line" => "L1", "quote" => "nobody said"}]})
      ])

    assert {:error, "a dropped finding cannot be included or edited"} =
             Review.include(only_finding(capture), true, owner)
  end
end

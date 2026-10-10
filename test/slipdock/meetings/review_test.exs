defmodule Slipdock.Meetings.ReviewTest do
  @moduledoc """
  What a reviewer does (#537): answer and take back answers, with the
  finding put back exactly; include, leave out, edit (marked as theirs), add
  what the transcript missed; and the capture's state following its open
  questions.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
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

  describe "the same name, asked about on several findings" do
    setup %{board: board, owner: owner} do
      capture =
        reviewed_capture(board, owner, [
          action_finding("Johnny", %{"title" => "Send the deck"}),
          action_finding("Johnny", %{"title" => "Book the room"}),
          action_finding("Sammy", %{"title" => "Draft the brief"})
        ])

      questions =
        Repo.all(
          from(q in Question,
            where: q.capture_id == ^capture.id and q.kind == "who_is_meant",
            order_by: q.id
          )
        )

      %{capture: capture, questions: questions}
    end

    test "one answer settles every open question about that name, and only that name", ctx do
      [johnny1, johnny2, sammy] = ctx.questions
      assert johnny1.context["name"] == "Johnny" and sammy.context["name"] == "Sammy"

      {:ok, _} = Review.answer(johnny1, "user:#{ctx.sam.id}", ctx.owner)

      assert Repo.reload!(johnny2).status == "answered"
      assert Repo.reload!(johnny2).answered_by_id == ctx.owner.id
      assert Repo.reload!(sammy).status == "open"

      findings =
        Repo.all(from(f in Finding, where: f.capture_id == ^ctx.capture.id, order_by: f.position))

      assert Enum.map(findings, & &1.effect["assignee_id"]) == [ctx.sam.id, ctx.sam.id, nil]

      [_, second] =
        Repo.all(
          from(e in Event,
            where: e.capture_id == ^ctx.capture.id and e.kind == "answered",
            order_by: e.id
          )
        )

      assert second.message =~ "the same name as question #{johnny1.id}"

      # Each can still be taken back on its own.
      {:ok, _} = Review.unanswer(Repo.reload!(johnny2), ctx.owner)
      assert Repo.reload!(johnny1).status == "answered"
      assert Repo.reload!(johnny2).status == "open"
    end

    test "someone not on the board keeps the name as said, with nobody assigned", ctx do
      [johnny1, johnny2, _] = ctx.questions

      assert %{"label" => "Keep “Johnny”"} =
               Enum.find(johnny1.options, &(&1["value"] == "name:Johnny"))

      {:ok, _} = Review.answer(johnny1, "name:Johnny", ctx.owner)
      assert Repo.reload!(johnny2).status == "answered"

      for f <-
            Repo.all(
              from(f in Finding,
                where: f.capture_id == ^ctx.capture.id and f.title != "Draft the brief"
              )
            ) do
        assert f.effect["assignee"] == "Johnny"
        refute Map.has_key?(f.effect, "assignee_id")
        refute "owner_unknown" in f.signals
      end
    end

    test "an answered one is left alone, and an answer it can't take is skipped", ctx do
      [johnny1, johnny2, _] = ctx.questions
      {:ok, _} = Review.answer(johnny2, "none", ctx.owner)

      # A question whose options don't include the answer is left open.
      johnny3 =
        question_fixture(ctx.capture, %{
          prompt: "Who is “Johnny”?",
          context: %{"name" => "Johnny"},
          options: [%{"value" => "none", "label" => "Nobody yet"}]
        })

      {:ok, _} = Review.answer(johnny1, "user:#{ctx.sam.id}", ctx.owner)
      assert Repo.reload!(johnny2).answer["value"] == "none"
      assert Repo.reload!(johnny3).status == "open"
    end
  end

  test "answering who is meant assigns them; the last answer makes it ready", %{
    board: board,
    owner: owner,
    sam: sam
  } do
    capture = reviewed_capture(board, owner, [action_finding("Sammy")], %{}, %{blocking: true})
    assert capture.state == "needs_review"

    {:ok, _} = Review.answer(only_question(capture), "user:#{sam.id}", owner)

    f = only_finding(capture)
    assert f.effect["assignee_id"] == sam.id
    assert Meetings.get_capture!(capture.id).state == "ready"

    q = only_question(capture)
    assert q.status == "answered" and q.answered_by_id == owner.id and q.via == "web"
    assert q.answer["label"] == "Sam Smith"
  end

  describe "leaving out a finding with an open question" do
    setup %{board: board, owner: owner} do
      capture =
        reviewed_capture(
          board,
          owner,
          [
            action_finding("Sammy", %{"title" => "Send the deck"}),
            action_finding("Johnny", %{"title" => "Book the room"})
          ],
          %{},
          %{blocking: true}
        )

      [sammy, johnny] =
        Repo.all(from(f in Finding, where: f.capture_id == ^capture.id, order_by: f.position))

      %{capture: capture, sammy: sammy, johnny: johnny}
    end

    test "sets its question aside, and the last one left out makes it ready", ctx do
      assert length(Meetings.open_questions(ctx.capture)) == 2

      {:ok, _} = Review.include(ctx.sammy, false, ctx.owner)
      assert [%{finding_id: id}] = Meetings.open_questions(ctx.capture)
      assert id == ctx.johnny.id
      assert Meetings.get_capture!(ctx.capture.id).state == "needs_review"

      {:ok, _} = Review.include(ctx.johnny, false, ctx.owner)
      assert Meetings.open_questions(ctx.capture) == []
      assert Meetings.get_capture!(ctx.capture.id).state == "ready"
      assert Meetings.counts([ctx.capture])[ctx.capture.id].open == 0

      # The questions themselves are untouched: still open, unanswered.
      assert Repo.all(from(q in Question, where: q.capture_id == ^ctx.capture.id))
             |> Enum.all?(&(&1.status == "open" and is_nil(&1.answer)))
    end

    test "including it again brings its question back, and the state with it", ctx do
      {:ok, _} = Review.include(ctx.sammy, false, ctx.owner)
      {:ok, _} = Review.include(ctx.johnny, false, ctx.owner)
      assert Meetings.get_capture!(ctx.capture.id).state == "ready"

      {:ok, _} = Review.include(Repo.reload!(ctx.johnny), true, ctx.owner)
      assert [%{finding_id: id}] = Meetings.open_questions(ctx.capture)
      assert id == ctx.johnny.id
      assert Meetings.get_capture!(ctx.capture.id).state == "needs_review"
      assert Meetings.counts([ctx.capture])[ctx.capture.id].open == 1
    end

    test "blocks? and set_aside? agree with the query", ctx do
      {:ok, _} = Review.include(ctx.sammy, false, ctx.owner)
      capture = Meetings.load(Meetings.get_capture!(ctx.capture.id))

      by_finding = Map.new(capture.questions, &{&1.finding_id, &1})
      assert Meetings.set_aside?(by_finding[ctx.sammy.id], capture.findings)
      refute Meetings.blocks?(by_finding[ctx.sammy.id], capture.findings)
      refute Meetings.set_aside?(by_finding[ctx.johnny.id], capture.findings)
      assert Meetings.blocks?(by_finding[ctx.johnny.id], capture.findings)

      # Answered, or not blocking, never blocks; about no finding, never set aside.
      q = by_finding[ctx.johnny.id]
      refute Meetings.blocks?(%{q | status: "answered"}, capture.findings)
      refute Meetings.blocks?(%{q | blocking: false}, capture.findings)
      assert Meetings.blocks?(%{q | finding_id: nil}, [])
      refute Meetings.set_aside?(%{q | finding_id: nil}, [])
    end
  end

  test "taking an answer back reopens it, puts the finding back and the state too", %{
    board: board,
    owner: owner,
    sam: sam
  } do
    capture = reviewed_capture(board, owner, [action_finding("Sammy")], %{}, %{blocking: true})
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
    capture = reviewed_capture(board, owner, [action_finding("Sammy")], %{}, %{blocking: true})

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
    capture = reviewed_capture(board, owner, [action_finding("Sammy")], %{}, %{blocking: true})

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

defmodule Slipdock.Meetings.HardeningTest do
  @moduledoc """
  What a review of meeting capture found (#549), each pinned: commits that
  race, follow-up commits judged against the right versions, side effects
  held until a commit lands, answers taken back without taking others with
  them, the speaker asked only if they can answer, no blank pages for
  decisions elsewhere, and edits checked before they are stored.
  """
  use Slipdock.DataCase, async: false

  import Swoosh.TestAssertions
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Meetings, Repo}
  alias Slipdock.Boards.Card
  alias Slipdock.Meetings.{Commit, Finding, Pipeline, Question, Review, Speakers, Undo, Version}
  alias Slipdock.Wiki.Page

  setup do
    owner = user_fixture("owner@example.com")
    {:ok, owner} = Slipdock.Accounts.update_profile(owner, %{"name" => "Priya Shah"})
    board = board_fixture(%{"name" => "Pricing"}, owner: owner)
    sam = user_fixture("sam@example.com")
    {:ok, sam} = Slipdock.Accounts.update_profile(sam, %{"name" => "Sam Smith"})
    share_fixture(board, [sam], "write")
    %{owner: owner, board: board, sam: sam}
  end

  defp findings(capture),
    do: Repo.all(from(f in Finding, where: f.capture_id == ^capture.id, order_by: f.position))

  defp questions(capture),
    do: Repo.all(from(q in Question, where: q.capture_id == ^capture.id, order_by: q.id))

  test "two commits at once: one writes, the other is refused, nothing doubles", ctx do
    capture =
      reviewed_capture(ctx.board, ctx.owner, [
        action_finding(nil, %{"owner" => nil, "title" => "Once only"})
      ])

    parent = self()

    results =
      for _ <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          Commit.commit(capture, ctx.owner)
        end)
      end
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :conflict, _}, &1)) == 1
    assert Repo.aggregate(from(c in Card, where: c.title == "Once only"), :count) == 1
  end

  describe "an item that waited for its speaker" do
    setup ctx do
      capture =
        capture_fixture(ctx.board, ctx.owner, %{transcript: "w#{System.unique_integer()}"},
          utterances: [
            %{speaker: "Priya Shah", text: "We keep the free tier.", start_ms: 0, end_ms: 3000},
            %{
              speaker: "Sam Smith",
              text: "And we go annual at 20% off.",
              start_ms: 3000,
              end_ms: 6000
            }
          ]
        )

      {:ok, _} = Speakers.diarise(capture)
      {:ok, _} = Speakers.attribute(capture)

      unsure =
        from(u in Slipdock.Meetings.Utterance,
          where: u.capture_id == ^capture.id and u.line_id == "L2"
        )

      Repo.update_all(unsure, set: [voice_unsure: true])

      capture =
        capture
        |> Ecto.Changeset.change(
          readings: %{
            "1" => [
              %{
                "kind" => "decision",
                "title" => "Free tier stays",
                "topic" => "Pricing",
                "decided_by" => "Priya",
                "evidence" => [%{"line" => "L1", "quote" => "We keep the free tier."}]
              },
              %{
                "kind" => "decision",
                "title" => "Annual at 20% off",
                "topic" => "Pricing",
                "evidence" => [%{"line" => "L2", "quote" => "we go annual at 20% off."}]
              }
            ]
          },
          context: %{"candidates" => [], "decisions" => []}
        )
        |> Repo.update!()

      {:ok, _} = Meetings.verify(capture)
      {:ok, capture} = Meetings.transition(Meetings.get_capture!(capture.id), "reading")
      {:ok, capture} = Meetings.transition(capture, "needs_review")
      [q] = questions(capture)
      {:ok, _} = Review.ask_speaker(q, ctx.owner)
      {:ok, first} = Commit.commit(Meetings.get_capture!(capture.id), ctx.owner)
      %{capture: first, question: Repo.reload!(q)}
    end

    test "is written to the page the first commit made, not refused as stale", ctx do
      [page_change] = ctx.capture.change_set["changes"]
      assert page_change["created_page"]

      {:ok, _} = Review.answer(ctx.question, "none", ctx.sam)
      assert Commit.stale(Commit.build(Meetings.get_capture!(ctx.capture.id))) == []
      {:ok, again} = Commit.commit(Meetings.get_capture!(ctx.capture.id), ctx.owner)

      page = Repo.get!(Page, page_change["page_id"])
      assert page.body =~ "Free tier stays"
      assert page.body =~ "Annual at 20% off"
      assert length(again.change_set["changes"]) == 2
    end

    test "and undo afterwards sees no edit of ours as somebody else's", ctx do
      {:ok, _} = Review.answer(ctx.question, "none", ctx.sam)
      {:ok, again} = Commit.commit(Meetings.get_capture!(ctx.capture.id), ctx.owner)

      assert Undo.conflicts(again) == []
      {:ok, _} = Undo.undo(again, ctx.owner)
      [first | _] = again.change_set["changes"]
      assert Repo.get!(Page, first["page_id"]).archived_at
    end
  end

  test "mention emails wait for the commit, and never go for one that rolled back", ctx do
    finding = fn title ->
      action_finding(nil, %{"owner" => nil, "title" => title, "body" => "Over to @sam for this."})
    end

    capture = reviewed_capture(ctx.board, ctx.owner, [finding.("First"), finding.("Second")])

    assert {:error, _} =
             Commit.commit(capture, ctx.owner,
               after_change: fn n, _ -> if n == 2, do: {:error, "boom"} end
             )

    assert_no_email_sent()

    {:ok, _} = Commit.commit(capture, ctx.owner)
    assert_email_sent(fn email -> assert email.subject =~ "mentioned you on “First”" end)
  end

  describe "answers on the same finding" do
    setup ctx do
      card =
        card_fixture(Enum.find(ctx.board.columns, &(&1.name == "To Do")), %{
          "title" => "Pricing page refresh"
        })

      candidate = %{
        "type" => "card",
        "id" => card.id,
        "ref" => "##{card.id}",
        "title" => card.title,
        "lines" => ["L3"],
        "strength" => "similarity",
        "version" => Version.of(card)
      }

      capture =
        reviewed_capture(ctx.board, ctx.owner, [action_finding("Sammy")], %{
          "candidates" => [candidate]
        })

      [who, existing] = Enum.sort_by(questions(capture), & &1.kind, :desc)
      assert who.kind == "who_is_meant" and existing.kind == "existing_or_new"
      %{capture: capture, card: card, who: who, existing: existing}
    end

    test "taking one back keeps the other", ctx do
      {:ok, _} = Review.answer(ctx.who, "user:#{ctx.sam.id}", ctx.owner)
      {:ok, _} = Review.answer(Repo.reload!(ctx.existing), "card:#{ctx.card.id}", ctx.owner)
      {:ok, _} = Review.unanswer(Repo.reload!(ctx.who), ctx.owner)

      [f] = findings(ctx.capture)
      assert f.kind == "card_change"
      assert f.effect["card_id"] == ctx.card.id
      refute Map.has_key?(f.effect["changes"], "assignee_id")
    end

    test "answering again replaces the first answer rather than stacking on it", ctx do
      {:ok, _} = Review.answer(ctx.who, "user:#{ctx.sam.id}", ctx.owner)
      {:ok, _} = Review.answer(Repo.reload!(ctx.who), "none", ctx.owner)
      [f] = findings(ctx.capture)
      refute Map.has_key?(f.effect, "assignee_id")

      {:ok, _} = Review.unanswer(Repo.reload!(ctx.who), ctx.owner)
      [f] = findings(ctx.capture)
      assert f.effect["assignee"] == "Sammy"
    end
  end

  test "the speaker is asked only if they could answer", ctx do
    reader = user_fixture("reader@example.com")
    {:ok, reader} = Slipdock.Accounts.update_profile(reader, %{"name" => "Rae Reader"})
    share_fixture(ctx.board, [reader], "read")

    capture =
      capture_fixture(ctx.board, ctx.owner, %{transcript: "r#{System.unique_integer()}"},
        utterances: [%{speaker: "Rae Reader", text: "I'll take it.", start_ms: 0, end_ms: 1000}]
      )

    {:ok, _} = Speakers.diarise(capture)
    {:ok, _} = Speakers.attribute(capture)

    capture =
      capture
      |> Ecto.Changeset.change(
        readings: %{
          "1" => [
            action_finding("Raymond", %{
              "evidence" => [%{"line" => "L1", "quote" => "I'll take it."}]
            })
          ]
        },
        context: %{"candidates" => [], "decisions" => []}
      )
      |> Repo.update!()

    {:ok, _} = Meetings.verify(capture)
    {:ok, capture} = Meetings.transition(Meetings.get_capture!(capture.id), "reading")
    {:ok, _} = Meetings.transition(capture, "needs_review")

    [q] = questions(capture)

    assert {:error, "Rae Reader can't edit this board, so couldn't answer" <> _} =
             Review.ask_speaker(q, ctx.owner)
  end

  test "a decision replacing one on another board's page makes no page here", ctx do
    other = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner)

    plans = %{"title" => "Decisions / Plans", "body" => "- Monthly plan only\n"}
    {:ok, theirs} = Slipdock.Wiki.create_page(other, plans, user: ctx.owner)

    decisions = [
      %{
        "page_id" => theirs.id,
        "board_id" => other.id,
        "title" => theirs.title,
        "ref" => theirs.code,
        "version" => Version.of(theirs),
        "entries" => [%{"text" => "Monthly plan only", "superseded" => false}]
      }
    ]

    capture =
      reviewed_capture(
        ctx.board,
        ctx.owner,
        [decision_finding(%{"supersedes" => "Monthly plan only"})],
        %{"decisions" => decisions}
      )

    {:ok, committed} = Commit.commit(capture, ctx.owner)

    assert Enum.map(committed.change_set["changes"], & &1["page_title"]) == [
             "Decisions / Pricing sync · 7 Oct 2026"
           ]

    refute Repo.exists?(
             from(p in Page,
               where: p.board_id == ^ctx.board.id and p.title == "Decisions / Plans"
             )
           )

    assert Repo.reload!(theirs).body == "- Monthly plan only\n"
  end

  describe "edits are checked before they are stored" do
    setup ctx do
      capture = reviewed_capture(ctx.board, ctx.owner, [action_finding(nil, %{"owner" => nil})])
      %{capture: capture, finding: hd(findings(capture))}
    end

    test "a list that isn't text, or isn't on the board; a date that isn't one; a topic that isn't text",
         ctx do
      assert {:error, "title, body, topic, list and due_date are text"} =
               Review.edit(ctx.finding, %{"list" => 3}, ctx.owner)

      assert {:error, "“Someday” is not a list on this board" <> _} =
               Review.edit(ctx.finding, %{"list" => "Someday"}, ctx.owner)

      assert {:error, "due_date should be a date like 2026-10-09"} =
               Review.edit(ctx.finding, %{"due_date" => "next week"}, ctx.owner)

      assert {:error, _} = Review.edit(ctx.finding, %{"topic" => %{"a" => 1}}, ctx.owner)

      assert {:ok, _} =
               Review.edit(
                 ctx.finding,
                 %{"list" => "Backlog", "due_date" => "2026-10-20"},
                 ctx.owner
               )

      assert {:error, "what the transcript missed is an action or a decision"} =
               Review.add(ctx.capture, %{"kind" => "idea", "title" => "x"}, ctx.owner)
    end
  end

  test "answers given as 0, a negative number or not text name no option", ctx do
    capture = reviewed_capture(ctx.board, ctx.owner, [action_finding("Sammy")])
    [q] = questions(capture)
    assert Review.option_value(q, "0") == nil
    assert Review.option_value(q, "-1") == nil
    assert Review.option_value(q, %{"a" => 1}) == nil
    assert Review.option_value(q, 1) == hd(q.options)["value"]
  end

  test "a voice can only be someone on the board, and not after the commit", ctx do
    stranger = user_fixture("stranger@example.com")

    capture =
      capture_fixture(ctx.board, ctx.owner, %{transcript: "v#{System.unique_integer()}"},
        utterances: [%{speaker: "Speaker 1", text: "Hi."}]
      )

    {:ok, _} = Speakers.diarise(capture)
    [voice] = Repo.all(from(v in Slipdock.Meetings.Voice, where: v.capture_id == ^capture.id))

    assert {:error, "that person isn't on this board"} =
             Speakers.reassign(voice, %{"user_id" => stranger.id}, ctx.owner)

    Repo.update_all(from(c in Slipdock.Meetings.Capture, where: c.id == ^capture.id),
      set: [state: "committed"]
    )

    assert {:error, "this capture is committed" <> _} =
             Speakers.reassign(voice, %{"user_id" => ctx.sam.id}, ctx.owner)
  end

  test "discarding while it is being read stops the reading", ctx do
    capture = capture_fixture(ctx.board, ctx.owner)
    capture = Pipeline.start(capture, mode: :manual)
    {:ok, _} = Meetings.discard(capture, ctx.owner)

    stopped = Pipeline.run(Meetings.get_capture!(capture.id))
    assert stopped.state == "discarded"
    refute_received {:ai_request, _}
    assert Meetings.get_capture!(capture.id).readings == nil
  end
end

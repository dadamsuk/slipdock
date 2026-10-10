defmodule Slipdock.Meetings.CommitTest do
  @moduledoc """
  The change set and the commit (#538): built from the reviewed findings,
  the same structure the preview shows (G6); written in one transaction
  (G8) after every target's version is checked (G7); once only (G10); by
  somebody who can write everywhere it lands; attributed via meeting capture.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Boards, Meetings, Repo, Settings, Wiki}
  alias Slipdock.Boards.{Activity, Card, Comment}
  alias Slipdock.Meetings.{Commit, Version}
  alias Slipdock.Wiki.Page

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Pricing", "code" => "PL"}, owner: owner)
    sam = user_fixture("sam@example.com")
    {:ok, sam} = Slipdock.Accounts.update_profile(sam, %{"name" => "Sam Smith"})
    share_fixture(board, [sam], "write")
    [todo | _] = board.columns

    card =
      card_fixture(Enum.find(board.columns, &(&1.name == "To Do")) || todo, %{
        "title" => "Pricing page refresh"
      })

    %{owner: owner, board: board, sam: sam, card: card}
  end

  # A capture whose findings make: a new card for Sam, a due date and a
  # comment on the existing card, and a decision.
  defp capture_with_everything(ctx) do
    candidate = %{
      "type" => "card",
      "id" => ctx.card.id,
      "ref" => "##{ctx.card.id}",
      "title" => ctx.card.title,
      "lines" => ["L3"],
      "strength" => "id",
      "version" => Version.of(ctx.card)
    }

    change = %{
      "kind" => "card_change",
      "title" => "Refresh due Friday",
      "card" => "##{ctx.card.id}",
      "change" => %{"field" => "due_date", "to" => "2026-10-09"},
      "comment" => "Agreed in the pricing sync: due Friday.",
      "evidence" => [%{"line" => "L3", "quote" => "update PL-14 by Friday"}]
    }

    reviewed_capture(
      ctx.board,
      ctx.owner,
      [
        decision_finding(),
        action_finding("Sam", %{
          "title" => "Write the launch email",
          "evidence" => [%{"line" => "L4", "quote" => "Yes, that's mine."}]
        }),
        change
      ],
      %{"candidates" => [candidate]}
    )
  end

  describe "the change set" do
    test "has every change, in plain structure, with before and after", ctx do
      capture = capture_with_everything(ctx)
      assert capture.state == "ready"
      set = Commit.build(capture)

      ops = Enum.map(set["changes"], & &1["op"])
      assert ops == ["create_card", "update_card", "comment", "decision_entry"]

      [create, update, comment, decision] = set["changes"]
      assert create["title"] == "Write the launch email"
      assert create["list"] == "To Do"
      assert create["assignee_ids"] == [ctx.sam.id]
      assert create["assignees"] == ["Sam Smith"]
      assert create["due_date"] == "2026-10-09"
      assert create["provenance"]["quote"] == "Yes, that's mine."

      assert update["fields"] == %{"due_date" => %{"from" => nil, "to" => "2026-10-09"}}
      assert update["base_version"] == Version.of(ctx.card)

      assert comment["body"] =~ "Agreed in the pricing sync: due Friday."
      assert comment["body"] =~ "> update PL-14 by Friday"

      assert decision["page_title"] == "Decisions / Pricing sync · 7 Oct 2026"
      assert decision["page_id"] == nil
      assert [line] = decision["lines_added"]
      assert line =~ "**Annual plan at 20% off**"
      assert line =~ "Sam: “We go with the annual plan at 20% off.”"

      assert set["notify"] == [
               %{"who" => "Sam Smith", "why" => "assigned “Write the launch email”"}
             ]

      assert set["digest"] == Commit.build(capture)["digest"]
    end

    test "two findings changing the same card are one change, with both fields", ctx do
      candidate = %{
        "type" => "card",
        "id" => ctx.card.id,
        "ref" => "##{ctx.card.id}",
        "title" => ctx.card.title,
        "lines" => ["L3"],
        "strength" => "id",
        "version" => Version.of(ctx.card)
      }

      change = fn field, to, title ->
        %{
          "kind" => "card_change",
          "title" => title,
          "card" => "##{ctx.card.id}",
          "change" => %{"field" => field, "to" => to},
          "evidence" => [%{"line" => "L3", "quote" => "update PL-14"}]
        }
      end

      capture =
        reviewed_capture(
          ctx.board,
          ctx.owner,
          [
            change.("due_date", "2026-10-09", "Due Friday"),
            change.("priority", "high", "Make it urgent")
          ],
          %{"candidates" => [candidate]}
        )

      assert [%{"op" => "update_card", "fields" => fields, "finding_ids" => [_, _]}] =
               Commit.build(capture)["changes"]

      assert fields == %{
               "due_date" => %{"from" => nil, "to" => "2026-10-09"},
               "priority" => %{"from" => "none", "to" => "high"}
             }
    end

    test "says what is left out, and why", ctx do
      capture =
        reviewed_capture(ctx.board, ctx.owner, [
          decision_finding(),
          %{
            "kind" => "idea",
            "title" => "Lifetime plan",
            "evidence" => [%{"line" => "L2", "quote" => "annual plan"}]
          }
        ])

      assert [%{"title" => "Lifetime plan", "why" => "left out in review"}] =
               Commit.build(capture)["left_out"]
    end

    test "a decision replacing an earlier one strikes it on the existing page", ctx do
      {:ok, page} =
        Wiki.create_page(
          ctx.board,
          %{
            "title" => "Decisions / Pricing",
            "body" => "- Monthly plan only\n- Free tier stays\n"
          },
          user: ctx.owner
        )

      capture =
        reviewed_capture(ctx.board, ctx.owner, [
          decision_finding(%{"supersedes" => "monthly plan only"})
        ])

      # The new decision on the meeting's page; the old one struck on the
      # older page per topic, where it is.
      [own, decision] = Commit.build(capture)["changes"]
      assert own["page_title"] == "Decisions / Pricing sync · 7 Oct 2026"
      assert own["lines_struck"] == []
      assert decision["page_id"] == page.id
      assert decision["base_hash"] == page.content_hash
      assert decision["finding_ids"] == []
      assert decision["lines_struck"] == ["- Monthly plan only"]

      assert decision["body_after"] =~
               "- ~~Monthly plan only~~ (replaced by “Annual plan at 20% off” on [[decisions-pricing-sync-7-oct-2026|Decisions / Pricing sync · 7 Oct 2026]])"

      assert decision["body_after"] =~ "- Free tier stays"
    end

    test "a new due date that leaves a dependent card due before it is a knock-on", ctx do
      waiting =
        card_fixture(hd(ctx.board.columns), %{"title" => "Launch", "due_date" => "2026-10-08"})

      {:ok, _} = Boards.add_dependency(waiting, Repo.reload!(ctx.card))
      set = Commit.build(capture_with_everything(%{ctx | card: Repo.reload!(ctx.card)}))
      assert [%{"title" => "Launch", "why" => why}] = set["knock_on"]
      assert why =~ "now due Fri 9 Oct, but is due Thu 8 Oct"
    end
  end

  test "a card for somebody not on the board says who it's for", ctx do
    capture = reviewed_capture(ctx.board, ctx.owner, [action_finding("Johnny")])
    [q] = Repo.all(from(q in Slipdock.Meetings.Question, where: q.capture_id == ^capture.id))
    {:ok, _} = Slipdock.Meetings.Review.answer(q, "name:Johnny", ctx.owner)

    set = Commit.build(Repo.reload!(capture))
    [card] = Enum.filter(set["changes"], &(&1["op"] == "create_card"))
    assert card["description"] == "For Johnny (not on this board)."
    assert card["assignee_ids"] == []

    # An assigned card says nothing of the kind.
    capture =
      reviewed_capture(ctx.board, ctx.owner, [action_finding("Sam")], %{}, %{transcript: "x"})

    set = Commit.build(capture)
    [card] = Enum.filter(set["changes"], &(&1["op"] == "create_card"))
    assert card["description"] == nil
  end

  describe "committing" do
    test "writes everything once, attributed, and the board matches the change set", ctx do
      capture = capture_with_everything(ctx)
      set = Commit.build(capture)

      {:ok, committed} = Commit.commit(capture, ctx.owner, digest: set["digest"], via: "web")
      assert committed.state == "committed"
      assert committed.committed_by_id == ctx.owner.id
      [create, update, comment, decision] = committed.change_set["changes"]

      # Preview and database agree, change by change.
      card = Repo.get!(Card, create["card_id"]) |> Repo.preload(:assignees)
      assert card.title == create["title"]
      assert card.column_id == create["column_id"]
      assert Enum.map(card.assignees, & &1.id) == create["assignee_ids"]
      assert Date.to_iso8601(card.due_date) == create["due_date"]

      changed = Repo.get!(Card, update["card_id"])
      assert Date.to_iso8601(changed.due_date) == update["fields"]["due_date"]["to"]

      assert Repo.get!(Comment, comment["comment_id"]).body == comment["body"]

      page = Repo.get!(Page, decision["page_id"])
      assert page.title == "Decisions / Pricing sync · 7 Oct 2026"
      assert page.body == decision["body_after"]
      assert [%{via: "meeting"}] = Wiki.list_revisions(page)

      lines = Repo.all(from(a in Activity, where: a.kind == "meeting", select: a.message))
      assert length(lines) == 4

      assert Enum.all?(
               lines,
               &(&1 =~ "via meeting capture “Pricing sync”, committed by #{ctx.owner.email}")
             )
    end

    test "a failure on the fourth of six changes leaves none of them written", ctx do
      findings =
        for n <- 1..6 do
          action_finding(nil, %{
            "owner" => nil,
            "title" => "Task #{n}",
            "evidence" => [%{"line" => "L#{rem(n, 4) + 1}", "quote" => "the"}]
          })
        end
        |> Enum.map(&Map.put(&1, "evidence", [%{"line" => "L1", "quote" => "Let's"}]))

      capture = reviewed_capture(ctx.board, ctx.owner, findings)
      before = Repo.aggregate(Card, :count)
      assert length(Commit.build(capture)["changes"]) == 6

      assert {:error, message} =
               Commit.commit(capture, ctx.owner,
                 after_change: fn n, _ -> if n == 4, do: {:error, "the disk filled up"} end
               )

      assert message =~
               "nothing was written: making the card “Task 4” failed (the disk filled up)"

      assert Repo.aggregate(Card, :count) == before
      assert Meetings.get_capture!(capture.id).state == "ready"
    end

    test "a real refusal part of the way through rolls back the rest too", ctx do
      findings =
        for n <- 1..3,
            do:
              action_finding(nil, %{
                "owner" => nil,
                "title" => "Task #{n}",
                "evidence" => [%{"line" => "L1", "quote" => "Let's"}]
              })

      capture = reviewed_capture(ctx.board, ctx.owner, findings)
      count = Slipdock.Quota.used(ctx.owner, :items)
      {:ok, _} = Settings.update(%{"item_limit" => count + 2, "item_limit_enabled" => true})

      assert {:error, message} = Commit.commit(capture, ctx.owner)
      assert message =~ "making the card “Task 3” failed"
      refute Repo.exists?(from(c in Card, where: c.title in ["Task 1", "Task 2"]))
    end

    test "a card edited after the review read it is named, and nothing is written", ctx do
      capture = capture_with_everything(ctx)
      {:ok, _} = Boards.update_card(ctx.card, %{"title" => "Pricing page refresh (v2)"})
      before = Repo.aggregate(Card, :count)

      assert {:error, :stale, [stale | _]} = Commit.commit(capture, ctx.owner)
      assert stale["ref"] == "##{ctx.card.id}"
      assert stale["why"] == "it was changed after the review read it"
      assert Repo.aggregate(Card, :count) == before

      refute Repo.exists?(
               from(p in Page, where: p.title == "Decisions / Pricing sync · 7 Oct 2026")
             )
    end

    test "a decisions page struck on and edited since the review read it is stale too", ctx do
      {:ok, page} =
        Wiki.create_page(ctx.board, %{"title" => "Decisions / Pricing", "body" => "- Old\n"},
          user: ctx.owner
        )

      capture =
        reviewed_capture(ctx.board, ctx.owner, [decision_finding(%{"supersedes" => "old"})])

      {:ok, _} = Wiki.update_page(page, %{"body" => "- Old\n- Someone else's\n"}, user: ctx.owner)

      assert {:error, :stale, [%{"why" => "it was edited after the review read it"}]} =
               Commit.commit(capture, ctx.owner)
    end

    test "a page made with the meeting's title since the review is not written over", ctx do
      capture = reviewed_capture(ctx.board, ctx.owner, [decision_finding()])
      preview = Commit.build(capture)

      {:ok, theirs} =
        Wiki.create_page(
          ctx.board,
          %{"title" => "Decisions / Pricing sync · 7 Oct 2026", "body" => "Somebody's notes.\n"},
          user: ctx.owner
        )

      # The preview named a page that is somebody else's now: committing
      # against it is refused, and the next preview names another.
      assert {:error, :conflict, _} = Commit.commit(capture, ctx.owner, digest: preview["digest"])
      {:ok, committed} = Commit.commit(capture, ctx.owner)

      assert [
               %{
                 "page_title" => "Decisions / Pricing sync · 7 Oct 2026 (2)",
                 "created_page" => true
               }
             ] =
               committed.change_set["changes"]

      assert Repo.reload!(theirs).body == "Somebody's notes.\n"
    end

    test "a second commit is refused and writes nothing (G10)", ctx do
      capture = reviewed_capture(ctx.board, ctx.owner, [decision_finding()])
      {:ok, _} = Commit.commit(capture, ctx.owner)
      revisions = Repo.aggregate(Slipdock.Wiki.Revision, :count)

      assert {:error, :conflict, "this capture was committed already; it is never written twice"} =
               Commit.commit(capture, ctx.owner)

      assert Repo.aggregate(Slipdock.Wiki.Revision, :count) == revisions
    end

    test "the review changing after the preview is refused", ctx do
      capture =
        reviewed_capture(ctx.board, ctx.owner, [
          decision_finding(),
          action_finding(nil, %{"owner" => nil})
        ])

      digest = Commit.build(capture)["digest"]

      [_, action] =
        Repo.all(
          from(f in Meetings.Finding, where: f.capture_id == ^capture.id, order_by: f.position)
        )

      {:ok, _} = Meetings.Review.include(action, false, ctx.owner)

      assert {:error, :conflict, "the review changed since that preview" <> _} =
               Commit.commit(capture, ctx.owner, digest: digest)
    end

    test "questions still open, or nothing included, are refused", ctx do
      capture = reviewed_capture(ctx.board, ctx.owner, [action_finding("Sammy")])

      assert {:error, :conflict, "questions are still open" <> _} =
               Commit.commit(capture, ctx.owner)

      capture =
        reviewed_capture(ctx.board, ctx.owner, [
          %{
            "kind" => "idea",
            "title" => "Maybe",
            "evidence" => [%{"line" => "L1", "quote" => "Let's"}]
          }
        ])

      assert {:error, :conflict, "nothing is included" <> _} = Commit.commit(capture, ctx.owner)
    end

    test "somebody who can only read the board cannot commit to it", ctx do
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, [reader], "read")
      capture = reviewed_capture(ctx.board, ctx.owner, [decision_finding()])

      assert {:error, :forbidden, "you can't write to Pricing, where this capture would write"} =
               Commit.commit(capture, reader)
    end

    test "a card that has gone since is stale, not a crash", ctx do
      capture = capture_with_everything(ctx)
      {:ok, _} = Boards.delete_card(ctx.card)

      assert {:error, :stale, [%{"why" => "it no longer exists"} | _]} =
               Commit.commit(capture, ctx.owner)
    end
  end

  describe "one decisions page per meeting (#550)" do
    test "decisions on two topics go on one page, each under its topic's heading", ctx do
      capture =
        reviewed_capture(
          ctx.board,
          ctx.owner,
          [
            decision_finding(),
            decision_finding(%{
              "title" => "Launch on Friday",
              "topic" => "Launch",
              "evidence" => [%{"line" => "L3", "quote" => "update PL-14 by Friday"}]
            }),
            decision_finding(%{
              "title" => "No discount codes",
              "evidence" => [%{"line" => "L1", "quote" => "Let's settle the pricing page."}]
            })
          ],
          %{},
          %{attendees: [%{"name" => "Priya"}, %{"email" => "sam@example.com"}]}
        )

      {:ok, committed} = Commit.commit(capture, ctx.owner)
      assert [change] = committed.change_set["changes"]
      assert change["page_title"] == "Decisions / Pricing sync · 7 Oct 2026"
      assert length(change["finding_ids"]) == 3

      page = Repo.get!(Page, change["page_id"])
      [header, pricing, launch] = String.split(page.body, ~r/\n(?=## )/)

      # The header: the meeting, its date, who was there, and the way back.
      assert header =~ "Notes from the meeting “Pricing sync” on 7 Oct 2026."
      assert header =~ "Attendees: Priya, sam@example.com."
      assert header =~ "(/boards/#{ctx.board.id}/meetings/#{capture.id})"
      refute header =~ ~r/^\s*[-*] /m

      # Both Pricing decisions under one heading, in order; Launch under its own.
      assert pricing =~
               ~r/\A## Pricing\n\n- \*\*Annual plan at 20% off\*\*.*\n- \*\*No discount codes\*\*/

      assert launch =~ ~r/\A## Launch\n\n- \*\*Launch on Friday\*\*/

      # The context step reads the three decisions, not the headings or header.
      [read] = Slipdock.Meetings.Context.decisions([page])

      assert Enum.map(read["entries"], & &1["text"]) |> Enum.map(&String.slice(&1, 0, 26)) == [
               "**Annual plan at 20% off**",
               "**No discount codes** — 7 ",
               "**Launch on Friday** — 7 O"
             ]
    end

    test "the page opens with the meeting's summary and key topics, then its decisions", ctx do
      notes = %{
        "summary" => "An interview for the CTO role.\n- Went well.",
        "topics" => [
          %{"title" => "The role.", "summary" => "Part-time to start."},
          %{"title" => "# Equity", "summary" => nil}
        ]
      }

      capture =
        reviewed_capture(ctx.board, ctx.owner, [decision_finding()], %{}, %{notes: notes})

      {:ok, committed} = Commit.commit(capture, ctx.owner)
      [change] = committed.change_set["changes"]
      body = Repo.get!(Page, change["page_id"]).body

      assert body =~ "**Summary.** An interview for the CTO role. Went well.\n"
      assert body =~ "**Key topics**\n\n**The role.** Part-time to start.\n\n**Equity.**\n"

      # In order: summary, topics, then the decisions.
      [summary, topics, decisions, entry] =
        Enum.map(["**Summary.**", "**Key topics**", "**Decisions**", "- **Annual plan"], fn s ->
          :binary.match(body, s) |> elem(0)
        end)

      assert summary < topics and topics < decisions and decisions < entry

      # The model's words can't make a list item or a heading: the context
      # step reads only the decision.
      [read] = Slipdock.Meetings.Context.decisions([Repo.get!(Page, change["page_id"])])
      assert [%{"text" => "**Annual plan at 20% off**" <> _}] = read["entries"]
      refute body =~ ~r/^\s*[-*] (?!\*\*Annual)/m
      refute body =~ ~r/^#+ /m
    end

    test "a meeting with a summary and no decisions still gets its page; undo archives it",
         ctx do
      capture =
        reviewed_capture(ctx.board, ctx.owner, [], %{}, %{
          notes: %{"summary" => "Nothing was decided.", "topics" => []}
        })

      set = Commit.build(capture)

      assert [%{"op" => "decision_entry", "lines_added" => [], "finding_ids" => []}] =
               set["changes"]

      {:ok, committed} = Commit.commit(capture, ctx.owner)
      [change] = committed.change_set["changes"]
      page = Repo.get!(Page, change["page_id"])
      assert page.body =~ "**Summary.** Nothing was decided."

      {:ok, _} = Slipdock.Meetings.Undo.undo(Meetings.get_capture!(capture.id), ctx.owner)
      assert Repo.get!(Page, page.id).archived_at
    end

    test "a meeting with neither summary nor decisions writes no page", ctx do
      capture = reviewed_capture(ctx.board, ctx.owner, [action_finding("Sam Smith")])
      set = Commit.build(capture)
      refute Enum.any?(set["changes"], &(&1["op"] == "decision_entry"))
    end

    test "decisions on one topic need no heading", ctx do
      {:ok, committed} =
        ctx.board
        |> reviewed_capture(ctx.owner, [decision_finding()])
        |> Commit.commit(ctx.owner)

      [change] = committed.change_set["changes"]
      body = Repo.get!(Page, change["page_id"]).body
      refute body =~ "## "
      assert body =~ ~r/struck through\.\n\n- \*\*Annual plan at 20% off\*\*/
    end

    test "two captures of the same meeting on the same day write two pages", ctx do
      {:ok, first} =
        ctx.board
        |> reviewed_capture(ctx.owner, [decision_finding()])
        |> Commit.commit(ctx.owner)

      {:ok, second} =
        ctx.board
        |> reviewed_capture(ctx.owner, [decision_finding(%{"title" => "Free tier stays"})])
        |> Commit.commit(ctx.owner)

      {:ok, third} =
        ctx.board
        |> reviewed_capture(ctx.owner, [decision_finding(%{"title" => "Trial is 14 days"})])
        |> Commit.commit(ctx.owner)

      [a] = first.change_set["changes"]
      [b] = second.change_set["changes"]
      [c] = third.change_set["changes"]
      assert a["page_title"] == "Decisions / Pricing sync · 7 Oct 2026"
      assert b["page_title"] == "Decisions / Pricing sync · 7 Oct 2026 (2)"
      assert c["page_title"] == "Decisions / Pricing sync · 7 Oct 2026 (3)"
      assert b["created_page"] and c["created_page"]
      assert length(Enum.uniq([a["page_id"], b["page_id"], c["page_id"]])) == 3

      # The first meeting's page is not appended to.
      refute Repo.get!(Page, a["page_id"]).body =~ "Free tier stays"
      assert Repo.get!(Page, b["page_id"]).body =~ "Free tier stays"

      # A different day is a different title.
      {:ok, next_day} =
        ctx.board
        |> reviewed_capture(ctx.owner, [decision_finding()], %{}, %{
          started_at: ~U[2026-10-08 10:00:00Z]
        })
        |> Commit.commit(ctx.owner)

      assert [%{"page_title" => "Decisions / Pricing sync · 8 Oct 2026"}] =
               next_day.change_set["changes"]
    end

    test "a long meeting title still makes a page title that fits", ctx do
      long = String.duplicate("Quarterly planning ", 10) |> String.trim()

      {:ok, committed} =
        ctx.board
        |> reviewed_capture(ctx.owner, [decision_finding()], %{}, %{title: long})
        |> Commit.commit(ctx.owner)

      [change] = committed.change_set["changes"]
      assert String.length(change["page_title"]) <= Page.title_length()
      assert change["page_title"] =~ ~r/^Decisions \/ Quarterly planning .* · 7 Oct 2026$/
    end

    test "replacing decisions strikes them on an earlier meeting's page and a legacy topic page, linking both ways",
         ctx do
      {:ok, legacy} =
        Wiki.create_page(
          ctx.board,
          %{"title" => "Decisions / Plans", "body" => "- Free tier stays\n"},
          user: ctx.owner
        )

      {:ok, earlier} =
        ctx.board
        |> reviewed_capture(
          ctx.owner,
          [decision_finding(%{"title" => "Monthly plan only"})],
          %{},
          %{title: "Kick-off", started_at: ~U[2026-10-01 10:00:00Z]}
        )
        |> Commit.commit(ctx.owner)

      [%{"page_id" => earlier_id, "page_title" => earlier_title}] =
        earlier.change_set["changes"]

      assert earlier_title == "Decisions / Kick-off · 1 Oct 2026"

      capture =
        reviewed_capture(ctx.board, ctx.owner, [
          decision_finding(%{"supersedes" => "monthly plan only"}),
          decision_finding(%{
            "title" => "Free tier goes",
            "topic" => "Plans",
            "supersedes" => "free tier stays",
            "evidence" => [%{"line" => "L1", "quote" => "Let's settle the pricing page."}]
          })
        ])

      {:ok, committed} = Commit.commit(capture, ctx.owner)
      [own | struck] = committed.change_set["changes"]
      assert own["page_title"] == "Decisions / Pricing sync · 7 Oct 2026"
      assert Enum.map(struck, & &1["page_title"]) == [earlier_title, "Decisions / Plans"]
      assert Enum.all?(struck, &(&1["finding_ids"] == [] and &1["lines_added"] == []))

      own_link = "[[decisions-pricing-sync-7-oct-2026|Decisions / Pricing sync · 7 Oct 2026]]"

      # Struck where they are, each saying what replaced it and where.
      assert Repo.get!(Page, earlier_id).body =~
               ~r/- ~~\*\*Monthly plan only\*\*.*~~ \(replaced by “Annual plan at 20% off” on \Q#{own_link}\E\)/

      assert Repo.reload!(legacy).body ==
               "- ~~Free tier stays~~ (replaced by “Free tier goes” on #{own_link})\n"

      # And the new page links back to each.
      body = Repo.get!(Page, own["page_id"]).body
      earlier_slug = Repo.get!(Page, earlier_id).slug

      assert body =~
               "Replaces “monthly plan only” on [[#{earlier_slug}|Decisions / Kick-off · 1 Oct 2026]]."

      assert body =~ "Replaces “free tier stays” on [[decisions-plans|Decisions / Plans]]."
    end

    test "a later commit of the same capture adds to its own page, headings and all", ctx do
      capture = reviewed_capture(ctx.board, ctx.owner, [decision_finding()])
      {:ok, committed} = Commit.commit(capture, ctx.owner)
      [first] = committed.change_set["changes"]

      # What waited for its speaker, answered since: on another topic.
      later =
        finding_fixture(committed, %{
          title: "Launch on Friday",
          position: 99,
          effect: %{"type" => "decision_entry", "topic" => "Launch", "text" => "Launch on Friday"}
        })

      assert Commit.pending?(committed)
      {:ok, again} = Commit.commit(committed, ctx.owner)

      [_, second] = again.change_set["changes"]

      assert second["page_id"] == first["page_id"]
      assert second["page_title"] == first["page_title"]
      assert second["finding_ids"] == [later.id]
      refute second["created_page"]

      # The page was one topic with no heading; now it is two, each headed.
      body = Repo.get!(Page, first["page_id"]).body
      assert body =~ ~r/struck through\.\n\n## Pricing\n\n- \*\*Annual plan at 20% off\*\*/
      assert body =~ ~r/\n\n## Launch\n\n- \*\*Launch on Friday\*\*/
      assert length(Regex.scan(~r/^## /m, body)) == 2
    end
  end
end

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

      assert decision["page_title"] == "Decisions / Pricing"
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

      [decision] = Commit.build(capture)["changes"]
      assert decision["page_id"] == page.id
      assert decision["base_hash"] == page.content_hash
      assert decision["lines_struck"] == ["- Monthly plan only"]

      assert decision["body_after"] =~
               "- ~~Monthly plan only~~ (replaced by “Annual plan at 20% off”)"

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
      assert page.title == "Decisions / Pricing"
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
      refute Repo.exists?(from(p in Page, where: p.title == "Decisions / Pricing"))
    end

    test "a decisions page edited, or made, since the review read it is stale too", ctx do
      {:ok, page} =
        Wiki.create_page(ctx.board, %{"title" => "Decisions / Pricing", "body" => "- Old\n"},
          user: ctx.owner
        )

      capture = reviewed_capture(ctx.board, ctx.owner, [decision_finding()])
      {:ok, _} = Wiki.update_page(page, %{"body" => "- Old\n- Someone else's\n"}, user: ctx.owner)

      assert {:error, :stale, [%{"why" => "it was edited after the review read it"}]} =
               Commit.commit(capture, ctx.owner)

      other = board_fixture(%{"name" => "Other"}, owner: ctx.owner)
      capture = reviewed_capture(other, ctx.owner, [decision_finding()])
      {:ok, _} = Wiki.create_page(other, %{"title" => "Decisions / Pricing"}, user: ctx.owner)

      assert {:error, :stale, [%{"why" => "it was made after the review read the wiki"}]} =
               Commit.commit(capture, ctx.owner)
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
end

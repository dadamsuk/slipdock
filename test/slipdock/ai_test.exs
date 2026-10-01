defmodule Slipdock.AITest do
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  alias Slipdock.{AI, Boards}
  alias Slipdock.AI.{Actions, Assistant, Context, Narrator}

  setup :share_stub

  defp share_stub(_), do: Slipdock.AIStub.share()

  describe "Slipdock.AI" do
    test "complete/2 posts the messages and returns the reply" do
      Slipdock.AIStub.reply_with("Hello there")
      assert {:ok, "Hello there"} = AI.complete([%{role: "user", content: "hi"}])

      assert_receive {:ai_request,
                      %{"model" => "test/model", "messages" => [%{"content" => "hi"}]}}
    end

    test "complete_json/2 decodes a JSON object, even inside code fences" do
      Slipdock.AIStub.reply_with("```json\n{\"reply\": \"ok\", \"actions\": []}\n```")

      assert {:ok, %{"reply" => "ok", "actions" => []}} =
               AI.complete_json([%{role: "user", content: "x"}])

      assert_receive {:ai_request, %{"response_format" => %{"type" => "json_object"}}}
    end

    test "decode_json/1 salvages an object surrounded by prose" do
      assert {:ok, %{"a" => 1}} = AI.decode_json("Sure! {\"a\": 1} Hope that helps.")
      assert {:error, _} = AI.decode_json("nothing here")
    end

    test "API errors become readable messages" do
      Slipdock.AIStub.fail_with(402, "Insufficient credits")

      assert {:error, "OpenRouter reports no credit left."} =
               AI.complete([%{role: "user", content: "x"}])

      Slipdock.AIStub.fail_with(400, "bad model")
      assert {:error, msg} = AI.complete([%{role: "user", content: "x"}])
      assert msg =~ "bad model"
    end
  end

  describe "Slipdock.AI.Context" do
    test "a board page lists its wiki separately from its cards" do
      user = user_fixture()
      board = board_fixture(%{"name" => "Launch"}, owner: user)
      [backlog | _] = board.columns

      # A card that sounds like a document is still listed as a card.
      decoy = card_fixture(backlog, %{"title" => "the wiki page for retries"})

      {:ok, page} =
        Slipdock.Wiki.create_page(
          board,
          %{"title" => "Retry policy", "summary" => "How retries work"},
          user: user
        )

      text =
        Context.build(%{
          kind: :board,
          board: reload(board),
          cards: [decoy],
          pages: [page],
          mode: :board,
          users: [user]
        })

      assert text =~ "## Wiki pages on this board (1)"
      assert text =~ "These are documents, not cards"
      assert text =~ "#{page.code} “Retry policy” — summary: How retries work"

      # The decoy is under Cards, and the page is not.
      [cards, wiki] = String.split(text, "## Wiki pages on this board", parts: 2)
      assert cards =~ "the wiki page for retries"
      refute cards =~ "Retry policy"
      refute wiki =~ "the wiki page for retries"
    end

    test "a board page lists the lists, tags, people and cards with their ids" do
      board = board_fixture(%{"name" => "Launch"})
      [backlog, doing | _] = board.columns
      tag = tag_fixture(board, "ops")
      user = user_fixture()

      card =
        card_fixture(backlog, %{
          "title" => "Write the plan",
          "priority" => "high",
          "due_date" => "2030-02-01",
          "assignee_id" => user.id,
          "description" => "All the details."
        })

      {:ok, _} = Boards.toggle_card_tag(card, tag)
      other = card_fixture(doing, %{"title" => "Ship it", "flags" => ["blocked"]})
      board = reload(board)
      cards = Enum.flat_map(board.columns, & &1.cards)

      text =
        Context.build(%{
          kind: :board,
          board: board,
          cards: cards,
          mode: :board,
          card: nil,
          users: [user]
        })

      assert text =~ "# Board: Launch"
      assert text =~ "“Backlog”"
      assert text =~ "Tags available: “ops”"
      assert text =~ "People who can be assigned: tester@example.com"

      assert text =~
               "##{card.id} “Write the plan” (list: Backlog; priority: high; assignee: tester@example.com; due: 2030-02-01; tags: ops)"

      assert text =~ "description: All the details."
      assert text =~ "##{other.id} “Ship it” (list: #{doing.name}; flags: blocked)"
    end

    test "an open card is rendered in full, with checklist and comments" do
      board = board_fixture()
      [backlog | _] = board.columns
      card = card_fixture(backlog, %{"title" => "Deep card", "description" => "Body text"})
      {:ok, _} = Boards.add_checklist_item(card, "First step")
      {:ok, _} = Boards.add_comment(card, "Looks good")
      card = Boards.get_card!(card.id)

      text = Context.build(%{kind: :card, board: reload(board), card: card})
      assert text =~ "Card ##{card.id}: “Deep card”"
      assert text =~ "Description:\nBody text"
      assert text =~ "- [ ] First step"
      assert text =~ "Looks good"
    end

    test "the narrative is rendered with its events" do
      board = board_fixture()
      [backlog, _, _, done] = board.columns
      card = card_fixture(backlog, %{"title" => "Shipped thing"})
      :ok = Boards.move_card(card.id, done.id)
      board = reload(board)
      config = Slipdock.Swimlanes.Config.defaults("narrative")
      narrative = Slipdock.Narrative.build(board, config)

      text = Context.narrative_text(%{board: board, narrative: narrative, view_name: nil})
      assert text =~ "Summary: 1 of 1 cards changed"
      assert text =~ "### ##{card.id} “Shipped thing”"
      assert text =~ "moved “Shipped thing” to Done"
    end
  end

  describe "Slipdock.AI.Actions" do
    setup do
      user = user_fixture()
      board = board_fixture(%{"name" => "Plan"})
      [backlog, doing | _] = board.columns
      tag = tag_fixture(board, "ops")
      card = card_fixture(backlog, %{"title" => "Alpha"})
      {:ok, _} = Boards.add_checklist_item(card, "Draft it")
      board = reload(board)
      card = Boards.get_card!(card.id)
      %{user: user, board: board, backlog: backlog, doing: doing, tag: tag, card: card}
    end

    defp scope(ctx),
      do: %{
        board: ctx.board,
        cards: [ctx.card],
        pages: ctx[:pages] || [],
        user: ctx.user,
        users: [ctx.user]
      }

    test "a wiki page is archived by code or title, and never by a card that sounds like one",
         ctx do
      {:ok, page} =
        Slipdock.Wiki.create_page(ctx.board, %{"title" => "Retry policy"}, user: ctx.user)

      # A card whose title contains the word is still only a card.
      decoy = card_fixture(ctx.backlog, %{"title" => "the wiki page for retries"})
      ctx = Map.merge(ctx, %{pages: [page], cards: [ctx.card, decoy]})
      scope = %{scope(ctx) | cards: [ctx.card, decoy]}

      steps = Actions.prepare([%{"type" => "archive_page", "page" => page.code}], scope)
      assert [%{label: label, error: nil}] = steps
      assert label == "Archive the page “Retry policy” (#{page.code})"

      assert [%{result: :ok}] = Actions.apply(steps)
      assert Slipdock.Wiki.get_page!(page.id).archived_at
      refute Boards.get_card!(decoy.id).archived_at

      # By title too, and a name that matches nothing is refused rather than
      # guessed at.
      {:ok, other} =
        Slipdock.Wiki.create_page(ctx.board, %{"title" => "Rollback"}, user: ctx.user)

      scope = %{scope | pages: [other]}

      assert [%{error: nil, label: label}] =
               Actions.prepare([%{"type" => "archive_page", "page" => "rollback"}], scope)

      assert label =~ "Rollback"

      assert [%{error: error}] =
               Actions.prepare([%{"type" => "archive_page", "page" => "wiki"}], scope)

      assert error =~ "no wiki page called"
    end

    test "a reader cannot archive a page", ctx do
      {:ok, page} = Slipdock.Wiki.create_page(ctx.board, %{"title" => "Spec"}, user: ctx.user)
      outsider = user_fixture("ai.page.outsider@example.com")
      scope = %{scope(ctx) | pages: [page], user: outsider}

      assert [%{error: error}] =
               Actions.prepare([%{"type" => "archive_page", "page" => "W-1"}], scope)

      assert error =~ "read-only" or error =~ "no wiki page"
    end

    test "an update becomes one labelled step per change and applies them", ctx do
      steps =
        Actions.prepare(
          [
            %{
              "type" => "update",
              "card_id" => ctx.card.id,
              "changes" => %{
                "due_date" => "2030-03-05",
                "priority" => "high",
                "column" => ctx.doing.name,
                "add_tags" => ["ops"],
                "assignee" => "tester@example.com",
                "add_flags" => ["blocked"]
              }
            }
          ],
          scope(ctx)
        )

      labels = Enum.map(steps, & &1.label)
      assert "Set the due date of “Alpha” to Tue 5 Mar 2030" in labels
      assert "Set priority of “Alpha” to high" in labels
      assert "Move “Alpha” to #{ctx.doing.name}" in labels
      assert "Add tag “ops” to “Alpha”" in labels
      assert "Assign “Alpha” to tester@example.com" in labels
      assert "Flag “Alpha”: blocked" in labels
      assert Enum.all?(steps, &is_nil(&1.error))

      applied = Actions.apply(steps)
      assert Enum.all?(applied, &(&1.result == :ok)), inspect(applied)

      card = Boards.get_card!(ctx.card.id)
      assert card.due_date == ~D[2030-03-05]
      assert card.priority == "high"
      assert card.column_id == ctx.doing.id
      assert Enum.map(card.tags, & &1.name) == ["ops"]
      assert card.assignee_id == ctx.user.id
      assert card.flags == ["blocked"]
    end

    test "unchanged values, unknown references and cards off the page are reported", ctx do
      steps =
        Actions.prepare(
          [
            %{"type" => "update", "card_id" => ctx.card.id, "changes" => %{"priority" => "none"}},
            %{
              "type" => "update",
              "card_id" => ctx.card.id,
              "changes" => %{"add_tags" => ["nope"]}
            },
            %{
              "type" => "update",
              "card_id" => ctx.card.id,
              "changes" => %{"due_date" => "next week"}
            },
            %{"type" => "update", "card_id" => 999_999, "changes" => %{"priority" => "high"}},
            %{"type" => "explode"}
          ],
          scope(ctx)
        )

      assert [tag, date, missing, unknown] = steps
      assert tag.error =~ "no tag called “nope”"
      assert date.error =~ "isn't a date"
      assert missing.error =~ "isn't on this page"
      assert unknown.error == "unknown action"
      refute Actions.runnable?(steps)
    end

    test "creating, commenting, checklists and archiving", ctx do
      steps =
        Actions.prepare(
          [
            %{
              "type" => "create",
              "title" => "Beta",
              "column" => String.downcase(ctx.doing.name),
              "priority" => "low",
              "tags" => ["ops"]
            },
            %{"type" => "comment", "card_id" => ctx.card.id, "body" => "Discussed with the team"},
            %{
              "type" => "checklist",
              "card_id" => ctx.card.id,
              "add" => ["Review it"],
              "check" => ["draft it"]
            },
            %{"type" => "archive", "card_id" => ctx.card.id}
          ],
          scope(ctx)
        )

      assert Enum.map(steps, & &1.label) == [
               "Create “Beta” in #{ctx.doing.name} (priority low, tags ops)",
               "Comment on “Alpha”: “Discussed with the team”",
               "Add 1 checklist item to “Alpha”: Review it",
               "Check “Draft it” on “Alpha”",
               "Archive “Alpha”"
             ]

      applied = Actions.apply(steps)
      assert Enum.all?(applied, &(&1.result == :ok)), inspect(applied)

      board = reload(ctx.board)
      beta = board.columns |> Enum.flat_map(& &1.cards) |> Enum.find(&(&1.title == "Beta"))
      assert beta.column_id == ctx.doing.id
      assert Enum.map(beta.tags, & &1.name) == ["ops"]

      alpha = Boards.get_card!(ctx.card.id)
      assert alpha.archived_at
      assert Enum.map(alpha.comments, & &1.body) == ["Discussed with the team"]

      assert Enum.map(alpha.checklist_items, &{&1.text, &1.done}) == [
               {"Draft it", true},
               {"Review it", false}
             ]
    end

    test "checklist items can be removed outright", ctx do
      steps =
        Actions.prepare(
          [%{"type" => "checklist", "card_id" => ctx.card.id, "remove" => ["draft it", "nope"]}],
          scope(ctx)
        )

      assert [ok, missing] = steps
      assert ok.label == "Remove “Draft it” from the checklist of “Alpha”"
      assert missing.error == "no such checklist item"
      assert [%{result: :ok}, _] = Actions.apply(steps)
      assert Boards.get_card!(ctx.card.id).checklist_items == []
    end

    test "subcards are added beneath a card, creating its sub-board when needed", ctx do
      steps =
        Actions.prepare(
          [
            %{
              "type" => "subcards",
              "card_id" => ctx.card.id,
              "titles" => ["Draft it", "Review it"]
            },
            %{"type" => "checklist", "card_id" => ctx.card.id, "remove" => ["Draft it"]}
          ],
          scope(ctx)
        )

      assert [sub, remove] = steps

      assert sub.label ==
               "Add 2 subcards to “Alpha” (creating its sub-board): Draft it; Review it"

      assert remove.error == nil
      assert Enum.all?(Actions.apply(steps), &(&1.result == :ok))

      card = Boards.get_card!(ctx.card.id)
      assert Enum.map(card.sub_board.cards, & &1.title) == ["Draft it", "Review it"]
      assert card.checklist_items == []

      # A second batch lands on the existing sub-board.
      [again] =
        Actions.prepare(
          [%{"type" => "subcards", "card_id" => card.id, "titles" => ["Ship it"]}],
          %{scope(ctx) | cards: [card]}
        )

      assert again.label == "Add 1 subcard to “Alpha”: Ship it"
      assert [%{result: :ok}] = Actions.apply([again])
      assert length(Boards.get_card!(card.id).sub_board.cards) == 3
    end

    test "a user without write access gets every step refused", ctx do
      stranger = user_fixture("stranger@example.com")

      steps =
        Actions.prepare(
          [%{"type" => "update", "card_id" => ctx.card.id, "changes" => %{"priority" => "high"}}],
          %{scope(ctx) | user: stranger}
        )

      assert [%{error: "you have read-only access to “Alpha”"}] = steps

      assert [%{error: _}] =
               Actions.prepare([%{"type" => "create", "title" => "X"}], %{
                 scope(ctx)
                 | user: stranger
               })
    end
  end

  describe "Slipdock.AI.Assistant and Narrator" do
    test "propose/3 asks for JSON and returns the reply with its actions" do
      Slipdock.AIStub.reply_with(%{
        "reply" => "Moving it.",
        "actions" => [%{"type" => "archive", "card_id" => 1}]
      })

      assert {:ok, %{reply: "Moving it.", actions: [%{"type" => "archive"}]}} =
               Assistant.propose("ctx", [], "archive it")

      assert_receive {:ai_request,
                      %{"messages" => [%{"role" => "system", "content" => system} | _]}}

      assert system =~ "ctx"
      assert system =~ "\"type\": \"update\""
    end

    test "chat/3 carries the recent history" do
      Slipdock.AIStub.reply_with("Two cards are overdue.")
      history = [%{role: "user", content: "hi"}, %{role: "assistant", content: "hello"}]
      assert {:ok, "Two cards are overdue."} = Assistant.chat("ctx", history, "what's overdue?")
      assert_receive {:ai_request, %{"messages" => messages}}
      assert Enum.map(messages, & &1["role"]) == ["system", "user", "assistant", "user"]
    end

    test "the narrator sends the account with the level's instructions" do
      board = board_fixture()
      config = Slipdock.Swimlanes.Config.defaults("narrative")
      narrative = Slipdock.Narrative.build(board, config)
      Slipdock.AIStub.reply_with("Nothing much happened.")

      assert {:ok, "Nothing much happened."} =
               Narrator.generate(
                 %{board: board, narrative: narrative, view_name: nil},
                 "one_liner"
               )

      assert_receive {:ai_request,
                      %{"max_tokens" => 150, "messages" => [_, %{"content" => user}]}}

      assert user =~ "exactly one sentence"
      assert user =~ "Period:"
      assert {:error, _} = Narrator.generate(%{board: board, narrative: narrative}, "bogus")
    end
  end
end

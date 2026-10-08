defmodule Slipdock.AITest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{AI, Boards}
  alias Slipdock.AI.{Actions, Assistant, Context, Narrator}

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

  # Two things real local model servers do that OpenRouter does not, both met
  # on an LM Studio box: no `response_format: json_object`, and a reasoning
  # model that thinks until the token budget is gone.
  describe "endpoints that are not OpenRouter" do
    test "JSON mode is dropped and asked again when the endpoint refuses it" do
      test = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Slipdock.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(body)
        send(test, {:ai_request, body})

        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{
              "error" => "'response_format.type' must be 'json_schema' or 'text'"
            })

          _ ->
            Req.Test.json(conn, %{
              "choices" => [%{"message" => %{"content" => "{\"ok\": true}"}}]
            })
        end
      end)

      assert {:ok, %{"ok" => true}} = AI.complete_json([%{role: "user", content: "x"}])

      assert_receive {:ai_request, %{"response_format" => _}}
      # The second ask leaves the flag off rather than giving up on the endpoint.
      assert_receive {:ai_request, second}
      refute Map.has_key?(second, "response_format")
    end

    test "a reasoning model that ran out of budget says so, rather than 'empty'" do
      Req.Test.stub(Slipdock.AI, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{"content" => "", "reasoning_content" => "Hmm, let me think…"},
              "finish_reason" => "length"
            }
          ]
        })
      end)

      assert {:error, message} = AI.complete([%{role: "user", content: "x"}])
      assert message =~ "token budget"
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
      assert text =~ "People who can be assigned: #{default_email()}"

      assert text =~
               "##{card.id} “Write the plan” (list: Backlog; priority: high; assignee: #{default_email()}; due: 2030-02-01; tags: ops)"

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
                "assignee" => "#{default_email()}",
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
      assert "Assign “Alpha” to #{default_email()}" in labels
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

    test "the assistant adding several checklist items is one line in the activity log", ctx do
      lines = fn ->
        ctx.card.board_id
        |> Boards.list_activities(50, ctx.card.id)
        |> Enum.filter(&(&1.kind == "checklist"))
        |> Enum.map(& &1.message)
      end

      before = lines.()

      [%{"type" => "checklist", "card_id" => ctx.card.id, "add" => ["One", "Two"]}]
      |> Actions.prepare(scope(ctx))
      |> Actions.apply()

      assert lines.() -- before == [~s(added 2 checklist items to “Alpha”)]
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
      # The preload has no order of its own; ids say which was made first.
      assert card.sub_board.cards |> Enum.sort_by(& &1.id) |> Enum.map(& &1.title) ==
               ["Draft it", "Review it"]

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

  describe "Slipdock.AI.Actions, change by change" do
    setup do
      user = user_fixture()
      board = board_fixture(%{"name" => "Plan"})
      [backlog, doing | _] = board.columns
      tag_fixture(board, "ops")
      tag_fixture(board, "ux")
      card = card_fixture(backlog, %{"title" => "Alpha"})
      {:ok, _} = Boards.add_checklist_item(card, "Draft it")
      board = reload(board)
      card = Boards.get_card!(card.id)
      %{user: user, board: board, backlog: backlog, doing: doing, card: card}
    end

    defp scope_for(ctx, card \\ nil),
      do: %{board: ctx.board, cards: [card || ctx.card], user: ctx.user, users: [ctx.user]}

    defp propose_change(ctx, changes, card \\ nil) do
      card = card || ctx.card

      Actions.prepare(
        [%{"type" => "update", "card_id" => card.id, "changes" => changes}],
        scope_for(ctx, card)
      )
    end

    defp run!(steps) do
      applied = Actions.apply(steps)
      assert Enum.all?(applied, &(&1.result == :ok)), inspect(applied)
      applied
    end

    test "anything that isn't a list of actions prepares nothing", ctx do
      assert Actions.prepare(%{"type" => "archive"}, scope_for(ctx)) == []
      assert Actions.prepare(nil, scope_for(ctx)) == []
    end

    test "an action without a type is malformed", ctx do
      assert [%{label: "(malformed action)", error: "no type given"}] =
               Actions.prepare([%{"card_id" => ctx.card.id}], scope_for(ctx))
    end

    test "a card id may come as \"#12\", and a scope without cards refuses every id", ctx do
      assert [%{error: nil, label: "Archive “Alpha”"}] =
               Actions.prepare(
                 [%{"type" => "archive", "card_id" => "##{ctx.card.id}"}],
                 scope_for(ctx)
               )

      assert [%{error: "card #? isn't on this page"}] =
               Actions.prepare([%{"type" => "archive", "card_id" => "alpha"}], scope_for(ctx))

      assert [%{error: "no cards on this page"}] =
               Actions.prepare([%{"type" => "archive", "card_id" => ctx.card.id}], %{
                 user: ctx.user
               })
    end

    test "changes may be given flat on the action, and a non-map is ignored", ctx do
      steps =
        Actions.prepare(
          [%{"type" => "update", "card_id" => ctx.card.id, "priority" => "low"}],
          scope_for(ctx)
        )

      assert [%{label: "Set priority of “Alpha” to low"}] = steps

      assert [] =
               Actions.prepare(
                 [%{"type" => "update", "card_id" => ctx.card.id, "changes" => "make it better"}],
                 scope_for(ctx)
               )
    end

    test "renaming: empty is refused, the same title is no change, a new one applies", ctx do
      assert [%{error: "the new title is empty"}] = propose_change(ctx, %{"title" => "  "})
      assert [] = propose_change(ctx, %{"title" => "Alpha"})

      assert [%{label: "Rename “Alpha” to “Alpha prime”"}] =
               steps = propose_change(ctx, %{"title" => "Alpha prime"})

      run!(steps)
      assert Boards.get_card!(ctx.card.id).title == "Alpha prime"
    end

    test "a description is set with an excerpt in the label, and cleared", ctx do
      long = String.duplicate("word ", 30)
      [step] = propose_change(ctx, %{"description" => long})
      assert step.label =~ "Update the description of “Alpha”: “word word"
      assert step.label =~ "…”"
      run!([step])
      assert Boards.get_card!(ctx.card.id).description =~ "word word"

      card = Boards.get_card!(ctx.card.id)

      assert [%{label: "Clear the description of “Alpha”"} = clear] =
               propose_change(ctx, %{"description" => nil}, card)

      run!([clear])
      assert Boards.get_card!(ctx.card.id).description in [nil, ""]
    end

    test "priority must be one of the priorities", ctx do
      assert [%{error: "“urgent!” isn't a priority"}] =
               propose_change(ctx, %{"priority" => "urgent!"})

      assert [%{label: "Set priority of “Alpha” to critical"}] =
               propose_change(ctx, %{"priority" => "CRITICAL"})
    end

    test "dates are set, left alone when unchanged, and cleared", ctx do
      [step] = propose_change(ctx, %{"start_date" => "2030-01-02"})

      assert step.label ==
               "Set the start date of “Alpha” to #{Slipdock.Dates.long(~D[2030-01-02])}"

      run!([step])

      card = Boards.get_card!(ctx.card.id)
      assert card.start_date == ~D[2030-01-02]
      assert [] = propose_change(ctx, %{"start_date" => " 2030-01-02 "}, card)
      assert [] = propose_change(ctx, %{"due_date" => "none"}, card)

      assert [%{label: "Clear the start date of “Alpha”"} = clear] =
               propose_change(ctx, %{"start_date" => "null"}, card)

      run!([clear])
      assert Boards.get_card!(ctx.card.id).start_date == nil
      assert [%{error: "“42” isn't a date" <> _}] = propose_change(ctx, %{"due_date" => 42})
    end

    test "completed is set and reopened, from the forms a model writes it in", ctx do
      assert [] = propose_change(ctx, %{"completed" => "no"})

      assert [%{label: "Mark “Alpha” complete"} = done] =
               propose_change(ctx, %{"completed" => "yes"})

      run!([done])

      card = Boards.get_card!(ctx.card.id)
      assert card.completed
      assert [] = propose_change(ctx, %{"completed" => 1}, card)

      assert [%{label: "Reopen “Alpha”"} = reopen] =
               propose_change(ctx, %{"completed" => false}, card)

      run!([reopen])
      refute Boards.get_card!(ctx.card.id).completed
    end

    test "percent complete takes whole numbers, \"40%\" and floats, and refuses the rest", ctx do
      assert [%{label: "Set “Alpha” to 40% complete"} = step] =
               propose_change(ctx, %{"percent_complete" => "40%"})

      run!([step])
      card = Boards.get_card!(ctx.card.id)
      assert card.percent_complete == 40

      assert [] = propose_change(ctx, %{"percent_complete" => 40.2}, card)

      assert [%{label: "Clear % complete on “Alpha”"}] =
               propose_change(ctx, %{"percent_complete" => nil}, card)

      for bad <- [101, -1, "lots", "40 percent", true] do
        assert [%{error: "“" <> rest}] = propose_change(ctx, %{"percent_complete" => bad}, card)
        assert rest =~ "isn't a whole number from 0 to 100"
      end
    end

    test "assigning: by name or address, to nobody, and never to a stranger", ctx do
      assert [] = propose_change(ctx, %{"assignee" => "nobody"})

      [step] = propose_change(ctx, %{"assignee" => "TESTER"})
      assert step.label =~ "Assign “Alpha” to"
      run!([step])
      card = Boards.get_card!(ctx.card.id)
      assert card.assignee_id == ctx.user.id
      assert [] = propose_change(ctx, %{"assignee" => ctx.user.email}, card)

      assert [%{label: "Unassign “Alpha”"} = unassign] =
               propose_change(ctx, %{"assignee" => ""}, card)

      run!([unassign])
      assert Boards.get_card!(ctx.card.id).assignee_id == nil

      assert [%{error: "nobody called “zed” can be assigned"}] =
               propose_change(ctx, %{"assignee" => "zed"})
    end

    test "with no people in scope, only those the asker can see may be assigned", ctx do
      {:ok, _} = Slipdock.Settings.update(%{"user_directory" => "shared_only"})

      owner = Slipdock.Repo.get!(Slipdock.Accounts.User, ctx.board.owner_id)
      user_fixture("unrelated.person@example.com")
      scope = %{scope_for(ctx) | users: [], user: owner}

      assert [%{error: "nobody called “unrelated.person” can be assigned"}] =
               Actions.prepare(
                 [
                   %{
                     "type" => "update",
                     "card_id" => ctx.card.id,
                     "changes" => %{"assignee" => "unrelated.person"}
                   }
                 ],
                 scope
               )
    end

    test "moving to the list it is already in is no change; an unknown list is refused", ctx do
      assert [] = propose_change(ctx, %{"list" => ctx.backlog.name})

      assert [%{error: "there is no list called “Nowhere”"}] =
               propose_change(ctx, %{"column" => "Nowhere"})
    end

    test "tags are added, removed, and replaced as a set", ctx do
      # A comma-separated string is a list too.
      assert [_, _] = propose_change(ctx, %{"add_tags" => "ops, ux"})

      [add] = propose_change(ctx, %{"add_tags" => "ops"})
      run!([add])
      card = Boards.get_card!(ctx.card.id)
      assert Enum.map(card.tags, & &1.name) == ["ops"]

      # Adding what is there, or removing what isn't, is no step at all.
      assert [] = propose_change(ctx, %{"add_tags" => ["OPS"], "remove_tags" => ["ux"]}, card)

      steps = propose_change(ctx, %{"tags" => ["ux"]}, card)

      assert Enum.map(steps, & &1.label) |> Enum.sort() ==
               ["Add tag “ux” to “Alpha”", "Remove tag “ops” from “Alpha”"]

      run!(steps)
      assert Enum.map(Boards.get_card!(ctx.card.id).tags, & &1.name) == ["ux"]
    end

    test "a tag step is idempotent if the card changed in between", ctx do
      [add] = propose_change(ctx, %{"add_tags" => ["ops"]})
      # Someone else tags it first; the step must not toggle it back off.
      {:ok, _} = Boards.toggle_card_tag(ctx.card, Enum.find(ctx.board.tags, &(&1.name == "ops")))
      run!([add])
      assert Enum.map(Boards.get_card!(ctx.card.id).tags, & &1.name) == ["ops"]
    end

    test "flags are added and removed, unknown ones refused alongside", ctx do
      steps = propose_change(ctx, %{"add_flags" => ["Blocked", "on-fire"]})
      assert [%{label: "Flag “Alpha”: blocked", error: nil}, %{error: "no such flag"}] = steps
      run!([hd(steps)])

      card = Boards.get_card!(ctx.card.id)
      assert card.flags == ["blocked"]
      assert [] = propose_change(ctx, %{"add_flags" => ["blocked"]}, card)

      assert [%{label: "Unflag “Alpha”: blocked"} = unflag] =
               propose_change(ctx, %{"remove_flags" => "blocked"}, card)

      run!([unflag])
      assert Boards.get_card!(ctx.card.id).flags == []
    end

    test "flags may be set outright, to a set or to none", ctx do
      [set] = propose_change(ctx, %{"flags" => ["review", "starred"]})
      assert set.label == "Set flags of “Alpha” to review, starred"
      run!([set])

      card = Boards.get_card!(ctx.card.id)
      assert Enum.sort(card.flags) == ["review", "starred"]
      assert [] = propose_change(ctx, %{"flags" => ["starred", "review"]}, card)

      assert [%{label: "Set flags of “Alpha” to none"}] =
               propose_change(ctx, %{"flags" => []}, card)

      assert [%{error: "unknown flag in " <> _}] =
               propose_change(ctx, %{"flags" => ["review", "hot"]}, card)
    end

    test "date precision must be a known one", ctx do
      assert [%{error: "unknown precision"}] =
               propose_change(ctx, %{"date_precision" => "fortnight"})

      [step] = propose_change(ctx, %{"date_precision" => "quarter"})
      assert step.label == "Schedule “Alpha” by quarter"
      run!([step])
      card = Boards.get_card!(ctx.card.id)
      assert card.date_precision == "quarter"
      assert [] = propose_change(ctx, %{"date_precision" => "quarter"}, card)
    end

    test "an unknown field is refused by name", ctx do
      assert [%{label: "Change colour of “Alpha”", error: "unknown field"}] =
               propose_change(ctx, %{"colour" => "red"})
    end

    test "creating: every detail in the label, and every one applied", ctx do
      [step] =
        Actions.prepare(
          [
            %{
              "type" => "create",
              "title" => "Gamma",
              "description" => "Details",
              "start_date" => "2030-01-01",
              "due_date" => "2030-02-01",
              "assignee" => ctx.user.email,
              "flags" => ["Starred"],
              "tags" => ["ops", "missing"]
            }
          ],
          scope_for(ctx)
        )

      assert step.label ==
               "Create “Gamma” in #{ctx.backlog.name} (starts 2030-01-01, due 2030-02-01, " <>
                 "assigned to #{Slipdock.Accounts.User.display_name(ctx.user)}, tags ops, flags starred)"

      run!([step])

      gamma =
        reload(ctx.board).columns
        |> Enum.flat_map(& &1.cards)
        |> Enum.find(&(&1.title == "Gamma"))

      assert gamma.column_id == ctx.backlog.id
      assert gamma.due_date == ~D[2030-02-01]
      assert gamma.assignee_id == ctx.user.id
      assert gamma.flags == ["starred"]
      assert Enum.map(gamma.tags, & &1.name) == ["ops"]
    end

    test "creating is refused without a title, a board, or valid details", ctx do
      prep = fn action -> Actions.prepare([Map.put(action, "type", "create")], scope_for(ctx)) end

      assert [%{error: "no title given"}] = prep.(%{"title" => "  "})

      assert [%{error: "there is no list called “Nowhere”"}] =
               prep.(%{"title" => "X", "column" => "Nowhere"})

      assert [%{error: "“asap” isn't a priority"}] =
               prep.(%{"title" => "X", "priority" => "ASAP"})

      assert [%{error: "unknown flag"}] = prep.(%{"title" => "X", "flags" => ["hot"]})

      assert [%{error: "a date isn't in YYYY-MM-DD form"}] =
               prep.(%{"title" => "X", "due_date" => "soon"})

      assert [%{error: "nobody called “zed” can be assigned"}] =
               prep.(%{"title" => "X", "assignee" => "zed"})

      assert [%{error: "cards can't be created from this page", label: "Create “X”"}] =
               Actions.prepare([%{"type" => "create", "title" => "X"}], %{
                 scope_for(ctx)
                 | board: nil
               })
    end

    test "an empty comment is refused", ctx do
      assert [%{error: "the comment is empty"}] =
               Actions.prepare(
                 [%{"type" => "comment", "card_id" => ctx.card.id, "body" => "   "}],
                 scope_for(ctx)
               )
    end

    test "checklist: checking what is checked, unchecking, and items that aren't there", ctx do
      item = hd(ctx.card.checklist_items)
      {:ok, _} = Boards.toggle_checklist_item(item.id)
      card = Boards.get_card!(ctx.card.id)

      steps =
        Actions.prepare(
          [
            %{
              "type" => "checklist",
              "card_id" => card.id,
              "add" => ["", "  "],
              "check" => ["Draft it", "Ghost"],
              "uncheck" => "draft it"
            }
          ],
          scope_for(ctx, card)
        )

      assert [checked, ghost, uncheck] = steps
      assert checked.error == "already checked"
      assert ghost.error == "no such checklist item"
      assert uncheck.label == "Uncheck “Draft it” on “Alpha”"
      run!([uncheck])
      refute hd(Boards.get_card!(card.id).checklist_items).done

      fresh = Boards.get_card!(card.id)

      assert [%{error: "already unchecked"}] =
               Actions.prepare(
                 [%{"type" => "checklist", "card_id" => card.id, "uncheck" => ["Draft it"]}],
                 scope_for(ctx, fresh)
               )

      assert [%{error: "you have read-only access" <> _}] =
               Actions.prepare(
                 [%{"type" => "checklist", "card_id" => card.id, "add" => ["x"]}],
                 Map.put(scope_for(ctx, fresh), :authorize, fn _ -> false end)
               )
    end

    test "subcards: none given is refused, and an unknown sub-board list fails when run", ctx do
      assert [%{error: "no subcard titles given"}] =
               Actions.prepare(
                 [%{"type" => "subcards", "card_id" => ctx.card.id, "titles" => [" "]}],
                 scope_for(ctx)
               )

      [step] =
        Actions.prepare(
          [
            %{
              "type" => "subcards",
              "card_id" => ctx.card.id,
              "titles" => "One, Two",
              "column" => "Nowhere"
            }
          ],
          scope_for(ctx)
        )

      assert step.label =~ "Add 2 subcards to “Alpha”"
      assert [%{result: {:error, "there is no list called “Nowhere”"}}] = Actions.apply([step])
    end

    test "archive_page refuses with no wiki in scope, and with no page named", ctx do
      assert [%{error: "this page has no wiki to change"}] =
               Actions.prepare([%{"type" => "archive_page", "page" => "W-1"}], scope_for(ctx))

      assert [%{error: "no page was named"}] =
               Actions.prepare([%{"type" => "archive_page"}], Map.put(scope_for(ctx), :pages, []))
    end

    test "a page deleted after the proposal is reported when run", ctx do
      {:ok, page} =
        Slipdock.Wiki.create_page(ctx.board, %{"title" => "Gone soon"}, user: ctx.user)

      [step] =
        Actions.prepare(
          [%{"type" => "archive_page", "code" => page.code}],
          Map.put(scope_for(ctx), :pages, [page])
        )

      Slipdock.Repo.delete!(page)
      assert [%{result: {:error, "the page no longer exists"}}] = Actions.apply([step])
    end

    test "a card archived or deleted after the proposal is not changed", ctx do
      [rename] = propose_change(ctx, %{"title" => "Too late"})

      [comment] =
        Actions.prepare(
          [%{"type" => "comment", "card_id" => ctx.card.id, "body" => "hi"}],
          scope_for(ctx)
        )

      {:ok, _} = Boards.archive_card(ctx.card)

      assert [
               %{result: {:error, "the card was archived"}},
               %{result: {:error, "the card was archived"}}
             ] =
               Actions.apply([rename, comment])

      assert Boards.get_card!(ctx.card.id).title == "Alpha"

      other = card_fixture(ctx.backlog, %{"title" => "Beta"})

      [archive] =
        Actions.prepare([%{"type" => "archive", "card_id" => other.id}], scope_for(ctx, other))

      {:ok, _} = Boards.delete_card(other)
      assert [%{result: {:error, "the card no longer exists"}}] = Actions.apply([archive])
    end

    test "permission is checked again when the step runs", ctx do
      # Write access is withdrawn between the proposal and the click.
      {:ok, allow} = Agent.start_link(fn -> true end)
      scope = Map.put(scope_for(ctx), :authorize, fn _ -> Agent.get(allow, & &1) end)

      [step] =
        Actions.prepare(
          [%{"type" => "update", "card_id" => ctx.card.id, "changes" => %{"title" => "Sneaky"}}],
          scope
        )

      assert step.error == nil
      Agent.update(allow, fn _ -> false end)
      assert [%{result: {:error, "you have read-only access to “Alpha”"}}] = Actions.apply([step])
      assert Boards.get_card!(ctx.card.id).title == "Alpha"
    end

    test "a step that fails validation or raises reports it rather than crashing", ctx do
      [rename] = propose_change(ctx, %{"title" => String.duplicate("x", 5000)})
      assert [%{result: {:error, "invalid: title " <> _}}] = Actions.apply([rename])

      boom = %{label: "Boom", error: nil, run: fn -> raise "kaboom" end, result: nil}
      refused = %{label: "No", error: nil, run: nil, result: nil}

      assert [%{result: {:error, "failed: kaboom"}}, %{result: {:error, "skipped"}}] =
               Actions.apply([boom, refused])

      assert Actions.runnable?([boom])
      refute Actions.runnable?([%{refused | error: "no"}])
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

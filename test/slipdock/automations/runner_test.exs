defmodule Slipdock.Automations.RunnerTest do
  # The runner on its own: which events a trigger answers, how each condition
  # reads a card, and what each action does — or says it could not do — when
  # it is handed an event directly rather than through a board change.
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Automations, Boards}
  alias Slipdock.Accounts.User
  alias Slipdock.Automations.{Rule, Runner}
  alias Slipdock.Boards.{Activity, Card}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Runner"}, owner: owner)
    [todo, doing, done | _] = board.columns
    %{owner: owner, board: board, todo: todo, doing: doing, done: done}
  end

  # A rule that only the clock would set off, so creating and changing cards
  # in a test never runs it behind the test's back; the test runs it itself.
  defp rule(board, actions, attrs \\ %{}) do
    rule_fixture(
      board,
      %{"trigger" => %{"type" => "schedule", "at" => "23:59"}, "actions" => actions},
      attrs
    )
  end

  defp run(rule, card, type \\ "card_updated"),
    do: Runner.run(rule, %{type: type, card: card, board_id: rule.board_id})

  defp trigger(spec), do: %Rule{spec: %{"trigger" => spec, "conditions" => []}}

  defp holds?(card, field, op, value),
    do: Runner.conditions_match?([%{"field" => field, "op" => op, "value" => value}], card)

  defp fresh(card), do: Boards.get_card!(card.id)

  describe "matches?/2 — triggers" do
    test "card_entered answers a card added to, or moved into, the list it names", ctx do
      rule =
        trigger(%{"type" => "card_entered", "column" => "  " <> String.upcase(ctx.doing.name)})

      assert Runner.matches?(rule, %{type: "card_created", column: ctx.doing})
      assert Runner.matches?(rule, %{type: "card_moved", from: ctx.todo, column: ctx.doing})
      refute Runner.matches?(rule, %{type: "card_moved", from: ctx.doing, column: ctx.done})
      refute Runner.matches?(rule, %{type: "card_created", column: nil})
      refute Runner.matches?(rule, %{type: "card_updated", column: ctx.doing})

      anywhere = trigger(%{"type" => "card_entered"})
      assert Runner.matches?(anywhere, %{type: "card_moved", column: ctx.done})
    end

    test "card_activity counts each change once, and only a change a rule can see" do
      rule = trigger(%{"type" => "card_activity"})

      for type <- ~w(card_created card_moved comment_added tag_added card_archived),
          do: assert(Runner.matches?(rule, %{type: type}), type)

      # These arrive alongside a card_updated of their own.
      for type <- ~w(card_completed card_assigned flag_added card_reopened),
          do: refute(Runner.matches?(rule, %{type: type}), type)

      assert Runner.matches?(rule, %{type: "card_updated", fields: [:title]})
      refute Runner.matches?(rule, %{type: "card_updated", fields: []})
      refute Runner.matches?(rule, %{type: "card_updated"})
    end

    test "card_moved checks both ends, by list or by name", ctx do
      to = String.downcase(ctx.done.name)
      rule = trigger(%{"type" => "card_moved", "from" => ctx.todo.name, "to" => to})

      assert Runner.matches?(rule, %{type: "card_moved", from: ctx.todo, to: ctx.done})
      assert Runner.matches?(rule, %{type: "card_moved", from: ctx.todo.name, to: ctx.done.name})
      refute Runner.matches?(rule, %{type: "card_moved", from: ctx.doing, to: ctx.done})
      refute Runner.matches?(rule, %{type: "card_moved", from: ctx.todo, to: nil})
    end

    test "card_updated with a field fires only when that field changed" do
      rule = trigger(%{"type" => "card_updated", "field" => "priority"})

      assert Runner.matches?(rule, %{type: "card_updated", fields: [:title, :priority]})
      assert Runner.matches?(rule, %{type: "card_updated", fields: ["priority"]})
      refute Runner.matches?(rule, %{type: "card_updated", fields: [:title]})
      refute Runner.matches?(rule, %{type: "card_updated"})
      assert Runner.matches?(trigger(%{"type" => "card_updated"}), %{type: "card_updated"})
    end

    test "card_assigned knows a person by email, name or display name" do
      user = %User{email: fixture_email("sam@example.com"), name: "Sam Smith"}

      for wanted <- [fixture_email("SAM@example.com"), "sam smith", User.display_name(user)] do
        rule = trigger(%{"type" => "card_assigned", "assignee" => wanted})
        assert Runner.matches?(rule, %{type: "card_assigned", assignee: user}), wanted
      end

      rule = trigger(%{"type" => "card_assigned", "assignee" => fixture_email("ada@example.com")})
      refute Runner.matches?(rule, %{type: "card_assigned", assignee: user})
      refute Runner.matches?(rule, %{type: "card_assigned", assignee: nil})

      refute Runner.matches?(rule, %{
               type: "card_assigned",
               assignee: fixture_email("ada@example.com")
             })

      anybody = trigger(%{"type" => "card_assigned"})
      assert Runner.matches?(anybody, %{type: "card_assigned", assignee: nil})
    end

    test "tag_added and flag_added match the name, ignoring case" do
      tag = trigger(%{"type" => "tag_added", "tag" => "Urgent"})
      assert Runner.matches?(tag, %{type: "tag_added", tag: "urgent"})
      refute Runner.matches?(tag, %{type: "tag_added", tag: "later"})
      refute Runner.matches?(tag, %{type: "tag_added", tag: nil})

      flag = trigger(%{"type" => "flag_added", "flag" => "blocked"})
      assert Runner.matches?(flag, %{type: "flag_added", flag: "Blocked"})
      refute Runner.matches?(flag, %{type: "flag_added", flag: "review"})
    end

    test "a trigger answers its own event type and nothing else" do
      refute Runner.matches?(trigger(%{"type" => "card_completed"}), %{type: "card_reopened"})
      assert Runner.matches?(trigger(%{"type" => "card_completed"}), %{type: "card_completed"})
      refute Runner.matches?(%Rule{spec: %{}}, %{type: "card_created"})
      refute Runner.matches?(trigger(%{"type" => "card_created"}), %{})
    end

    test "conditions are checked against the event's card, and a missing card fails them", ctx do
      card = card_fixture(ctx.todo, %{"priority" => "high"})
      high = [%{"field" => "priority", "op" => "is", "value" => "high"}]
      rule = %Rule{spec: %{"trigger" => %{"type" => "card_created"}, "conditions" => high}}

      assert Runner.matches?(rule, %{type: "card_created", card: card})
      refute Runner.matches?(rule, %{type: "card_created"})
      refute Runner.conditions_match?(high, %{priority: "high"})
      assert Runner.conditions_match?([], nil)
    end
  end

  describe "conditions_match?/2" do
    test "text fields compare without regard to case or surrounding space", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Fix the Login bug", "priority" => "high"})

      assert holds?(card, "title", "contains", "LOGIN")
      refute holds?(card, "title", "contains", "logout")
      assert holds?(card, "title", "not_contains", "logout")
      assert holds?(card, "priority", "is", " High ")
      assert holds?(card, "priority", "is_not", "low")
      assert holds?(card, "column", "is", ctx.doing.name)
      assert holds?(card, "card", "is", card.id)
      refute holds?(card, "card", "is", card.id + 1)
    end

    test "list fields hold when any member matches", ctx do
      card = card_fixture(ctx.todo, %{"flags" => ["blocked", "review"]})
      tag = tag_fixture(ctx.board, "Ops")
      {:ok, _} = Boards.toggle_card_tag(card, tag)
      card = fresh(card)

      assert holds?(card, "tag", "is", "ops")
      refute holds?(card, "tag", "is_not", "ops")
      assert holds?(card, "tag", "any_of", ["dev", "OPS"])
      assert holds?(card, "tag", "none_of", ["dev"])
      refute holds?(card, "tag", "none_of", ["dev", "ops"])
      assert holds?(card, "tag", "contains", "op")
      assert holds?(card, "flag", "is", "review")
      assert holds?(card, "flag", "any_of", "blocked")
      assert holds?(card, "priority", "any_of", ["none", "low"])
      refute holds?(card, "priority", "none_of", "none")
    end

    test "the assignee condition holds for anybody on the card", ctx do
      ada = user_fixture("ada@example.com")
      bob = user_fixture("bob@example.com")
      share_fixture(ctx.board, [ada, bob])

      card = card_fixture(ctx.todo, %{"assignee_id" => ada.id})
      {:ok, _} = Boards.update_card(card, %{"add_assignee_ids" => [bob.id]})
      card = fresh(card)

      assert holds?(card, "assignee", "is", fixture_email("bob@example.com"))
      assert holds?(card, "has_assignee", "is", true)
      refute holds?(card, "assignee", "is", fixture_email("carol@example.com"))

      unassigned = card_fixture(ctx.todo)
      assert holds?(unassigned, "has_assignee", "is", "false")
      assert holds?(unassigned, "assignee", "is_not_set", nil)
    end

    test "booleans accept true, yes and 1", ctx do
      card = card_fixture(ctx.todo)
      {:ok, card} = Boards.toggle_completed(card)

      for yes <- [true, "true", "Yes", "1"], do: assert(holds?(card, "completed", "is", yes))
      refute holds?(card, "completed", "is", "no")
      refute holds?(card, "archived", "is", true)
      refute holds?(card, "blocked", "is", true)
      assert holds?(card, "has_due_date", "is", false)

      {:ok, archived} = Boards.archive_card(fresh(card))
      assert holds?(archived, "archived", "is", "yes")
    end

    test "a card waiting on an unfinished card is blocked", ctx do
      blocker = card_fixture(ctx.todo)
      card = card_fixture(ctx.todo)
      {:ok, _} = Boards.add_dependency(card, blocker)

      assert holds?(fresh(card), "blocked", "is", true)
      {:ok, _} = Boards.toggle_completed(blocker)
      refute holds?(fresh(card), "blocked", "is", true)
    end

    test "dates compare against a date, today or tomorrow", ctx do
      today = Date.utc_today()
      card = card_fixture(ctx.todo, %{"due_date" => Date.to_iso8601(Date.add(today, 2))})

      assert holds?(card, "due_date", "after", "today")
      assert holds?(card, "due_date", "after", "tomorrow")
      assert holds?(card, "due_date", "before", Date.to_iso8601(Date.add(today, 3)))
      refute holds?(card, "due_date", "before", "today")
      assert holds?(card, "due_date", "is", Date.add(today, 2))
      assert holds?(card, "due_date", "within_days", 2)
      refute holds?(card, "due_date", "within_days", 1)
      refute holds?(card, "due_date", "older_than_days", 0)

      # A date that can't be read is never before, after or equal to anything.
      refute holds?(card, "due_date", "before", "next week")
      refute holds?(card, "due_date", "after", 7)
      refute holds?(card, "due_date", "is", "soon")

      past = card_fixture(ctx.todo, %{"due_date" => Date.to_iso8601(Date.add(today, -10))})
      assert holds?(past, "due_date", "older_than_days", 7)
      refute holds?(past, "due_date", "within_days", 30)
    end

    test "numbers compare as numbers, whatever they were written as", ctx do
      card = card_fixture(ctx.todo, %{"percent_complete" => 60})

      assert holds?(card, "percent_complete", "gt", 50)
      assert holds?(card, "percent_complete", "gt", "50.5")
      refute holds?(card, "percent_complete", "lt", "50")
      assert holds?(card, "percent_complete", "lt", 61)
      assert holds?(card, "percent_complete", "gt", "lots")
      refute holds?(card, "title", "gt", 3)
    end

    test "age_days is how long ago the card was made", ctx do
      card = card_fixture(ctx.todo)
      old = DateTime.add(DateTime.utc_now(), -40, :day) |> DateTime.truncate(:second)
      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [inserted_at: old])
      card = fresh(card)

      assert holds?(card, "age_days", "older_than_days", 30)
      refute holds?(card, "age_days", "older_than_days", 40)
      assert holds?(card, "age_days", "gt", 39)
      refute holds?(card_fixture(ctx.todo), "age_days", "older_than_days", 0)
    end

    test "health is whatever the last status update said", ctx do
      card = card_fixture(ctx.todo)
      refute holds?(card, "health", "is_set", nil)

      {:ok, _} =
        Boards.add_status_update(card, ctx.owner, %{"health" => "at_risk", "body" => "slipping"})

      assert holds?(fresh(card), "health", "is", "at_risk")
    end

    test "has_doc holds once a wiki page is pinned to the card", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Needs a spec"})
      assert holds?(card, "has_doc", "is", false)

      {:ok, _} = Slipdock.Wiki.create_page_from_card(card, [])
      assert holds?(fresh(card), "has_doc", "is", true)
    end

    test "an unset value is set by nobody, and is not anything in particular", ctx do
      card = card_fixture(ctx.todo)

      assert holds?(card, "description", "is_not_set", nil)
      refute holds?(card, "description", "is_set", nil)
      refute holds?(card, "description", "is", "x")
      refute holds?(card, "description", "contains", "x")
      refute holds?(card, "due_date", "before", "2099-01-01")
      refute holds?(card, "percent_complete", "lt", 50)

      # The negations hold: a card with no description doesn't contain "WIP".
      assert holds?(card, "description", "not_contains", "WIP")
      assert holds?(card, "description", "is_not", "x")
      assert holds?(card, "due_date", "is_not", "2030-01-01")
      assert holds?(card, "health", "none_of", ["red"])
    end

    test "a field or test it doesn't know holds for nothing", ctx do
      card = card_fixture(ctx.todo)
      refute holds?(card, "mood", "is", "calm")
      assert holds?(card, "mood", "is_not_set", nil)
      refute holds?(card, "title", "rhymes_with", "x")
      refute Runner.conditions_match?([%{"field" => "title"}], card)
    end
  end

  describe "run/3 — card actions" do
    test "each one says what it did", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Thing", "due_date" => "2030-01-01"})

      rule =
        rule(ctx.board, [
          %{"type" => "set_priority", "priority" => "high"},
          %{"type" => "complete_card"},
          %{"type" => "clear_due_date"},
          %{"type" => "set_due_date", "date" => "2031-02-03"},
          %{"type" => "reopen_card"},
          %{"type" => "move_card", "column" => ctx.done.name},
          %{"type" => "log", "message" => "touched {{card.title}}"}
        ])

      assert run(rule, card) == [
               {:ok, "set priority"},
               {:ok, "completed"},
               {:ok, "cleared the due date"},
               {:ok, "due 2031-02-03"},
               {:ok, "reopened"},
               {:ok, "moved to #{ctx.done.name}"},
               {:ok, "logged"}
             ]

      card = fresh(card)
      assert card.priority == "high"
      assert card.due_date == ~D[2031-02-03]
      refute card.completed
      assert card.column_id == ctx.done.id

      assert Repo.exists?(
               from(a in Activity,
                 where: a.card_id == ^card.id and a.message == "touched Thing"
               )
             )
    end

    test "each action sees the card as the one before it left it", ctx do
      card = card_fixture(ctx.todo, %{"flags" => ["review"]})

      rule =
        rule(ctx.board, [
          %{"type" => "add_flags", "flags" => ["blocked"]},
          %{"type" => "remove_flags", "flags" => ["review"]},
          %{"type" => "move_card", "column" => ctx.done.name},
          %{"type" => "comment", "body" => "now in {{card.column}}, flagged {{card.flags}}"}
        ])

      assert [_, {:ok, "flags now blocked"}, _, {:ok, "commented"}] = run(rule, card)

      card = fresh(card)
      assert card.flags == ["blocked"]
      assert [%{body: body}] = card.comments
      assert body == "now in #{ctx.done.name}, flagged blocked"
    end

    test "a move to the list it is already in is not a move", ctx do
      card = card_fixture(ctx.doing)
      rule = rule(ctx.board, [%{"type" => "move_card", "column" => ctx.doing.name}])
      assert run(rule, card) == [{:ok, "already in #{ctx.doing.name}"}]
    end

    test "a value the card won't take is reported, not swallowed", ctx do
      card = card_fixture(ctx.todo)

      rule =
        rule(ctx.board, [
          %{"type" => "set_priority", "priority" => "whenever"},
          %{"type" => "set_due_date", "date" => "someday"},
          %{"type" => "comment", "body" => "   "}
        ])

      assert [{:error, priority}, {:error, "no date given"}, {:error, comment}] = run(rule, card)
      assert priority =~ "priority"
      assert comment =~ "body"
      assert fresh(card).priority == "none"
    end

    test "flags go up and come down, and asking twice changes nothing", ctx do
      card = card_fixture(ctx.todo, %{"flags" => ["review"]})

      add = rule(ctx.board, [%{"type" => "add_flags", "flags" => ["blocked", "review"]}])
      assert run(add, card) == [{:ok, "flags now review, blocked"}]
      assert run(add, fresh(card)) == [{:ok, "flags unchanged"}]

      remove = rule(ctx.board, [%{"type" => "remove_flags", "flags" => ["review", "starred"]}])
      assert run(remove, fresh(card)) == [{:ok, "flags now blocked"}]
      assert fresh(card).flags == ["blocked"]
    end

    test "tags must exist on the board, and are taken off as easily as put on", ctx do
      tag_fixture(ctx.board, "ops")
      card = card_fixture(ctx.todo)

      assert run(rule(ctx.board, [%{"type" => "add_tags", "tags" => ["nope"]}]), card) ==
               [{:error, "no such tag: nope"}]

      add = rule(ctx.board, [%{"type" => "add_tags", "tags" => ["ops", "nope"]}])
      assert run(add, card) == [{:ok, "tags now ops"}]
      assert run(add, fresh(card)) == [{:ok, "tags unchanged"}]

      remove = rule(ctx.board, [%{"type" => "remove_tags", "tags" => ["ops"]}])
      assert run(remove, fresh(card)) == [{:ok, "tags now "}]
      assert Repo.preload(fresh(card), :tags, force: true).tags == []
    end

    test "assign finds people who can see the board, and nobody else", ctx do
      {:ok, _} = Slipdock.Settings.update(%{"user_directory" => "shared_only"})
      sam = user_fixture("sam@example.com")
      share_fixture(ctx.board, sam)
      user_fixture("stranger@example.com")
      card = card_fixture(ctx.todo)

      assert [{:ok, "assigned to " <> _}] =
               run(
                 rule(ctx.board, [
                   %{"type" => "assign", "assignee" => fixture_email("SAM@example.com")}
                 ]),
                 card
               )

      assert fresh(card).assignee_id == sam.id

      assert run(
               rule(ctx.board, [
                 %{"type" => "assign", "assignee" => fixture_email("stranger@example.com")}
               ]),
               card
             ) ==
               [{:error, "no such person: #{fixture_email("stranger@example.com")}"}]

      assert run(rule(ctx.board, [%{"type" => "unassign"}]), fresh(card)) == [{:ok, "unassigned"}]
      assert fresh(card).assignee_id == nil
    end

    test "comments and checklist items are filled in from the card", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Release"})

      rule =
        rule(ctx.board, [
          %{"type" => "comment", "body" => "{{card.title}} is in {{card.column}}"},
          %{"type" => "add_checklist_items", "items" => ["Tag {{card.title}}", "Announce"]}
        ])

      assert run(rule, card) == [{:ok, "commented"}, {:ok, "added 2 checklist items"}]

      card = fresh(card)
      assert [%{body: "Release is in " <> _}] = card.comments
      assert Enum.map(card.checklist_items, & &1.text) == ["Tag Release", "Announce"]

      assert [~s(added 2 checklist items to “Release”)] ==
               ctx.board.id
               |> Boards.list_activities(50, card.id)
               |> Enum.filter(&(&1.kind == "checklist"))
               |> Enum.map(& &1.message)
    end

    test "a checklist item the card won't take is reported", ctx do
      card = card_fixture(ctx.todo)
      rule = rule(ctx.board, [%{"type" => "add_checklist_items", "items" => ["Fine", ""]}])

      assert [{:error, message}] = run(rule, card)
      assert message =~ "added 1 of 2 checklist items"
      assert Enum.map(fresh(card).checklist_items, & &1.text) == ["Fine"]
    end

    test "archive_card archives", ctx do
      card = card_fixture(ctx.todo)
      assert run(rule(ctx.board, [%{"type" => "archive_card"}]), card) == [{:ok, "archived"}]
      assert Repo.get!(Card, card.id).archived_at
    end

    test "create_page starts a page pinned to the card", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Payments"})

      rule =
        rule(ctx.board, [
          %{"type" => "create_page", "title" => "{{card.title}} spec", "summary" => "Why"}
        ])

      assert [{:ok, "started " <> label}] = run(rule, card)
      assert label =~ "“Payments spec”"
      assert holds?(fresh(card), "has_doc", "is", true)
    end

    test "actions that need a card say so when the event has none", ctx do
      actions =
        for type <-
              ~w(move_card set_priority complete_card archive_card comment add_flags add_tags add_checklist_items unassign create_page notify_assignee) do
          %{
            "type" => type,
            "column" => "Done",
            "priority" => "low",
            "body" => "b",
            "flags" => ["review"],
            "tags" => ["x"],
            "items" => ["i"]
          }
        end

      rule = rule(ctx.board, actions)
      results = Runner.run(rule, %{type: "schedule", board_id: ctx.board.id})

      assert length(results) == length(actions)
      assert Enum.all?(results, &match?({:error, _}, &1))
      assert {:error, "there is no card to act on"} = hd(results)
      assert {:error, "there is no card to write up"} = Enum.at(results, -2)
      assert {:error, "nobody is assigned"} = List.last(results)
    end

    test "an action that raises fails alone, naming itself", ctx do
      card = card_fixture(ctx.todo)
      rule = rule(ctx.board, [%{"type" => "complete_card"}])

      # A stored spec that went round validation: a map where a list should be.
      rule =
        put_in(rule.spec["actions"], [
          %{"type" => "add_flags", "flags" => %{"oops" => 1}},
          %{"type" => "complete_card"},
          %{"type" => "teleport"}
        ])

      assert [
               {:error, "add_flags: " <> _},
               {:ok, "completed"},
               {:error, "unknown action “teleport”"}
             ] =
               run(rule, card)
    end
  end

  describe "run/3 — create_card" do
    test "fills in everything it is given, tags included", ctx do
      sam = user_fixture("sam@example.com")
      share_fixture(ctx.board, sam)
      tag_fixture(ctx.board, "follow-up")
      card = card_fixture(ctx.todo, %{"title" => "Launch"})

      rule =
        rule(ctx.board, [
          %{
            "type" => "create_card",
            "title" => "After {{card.title}}",
            "column" => String.upcase(ctx.doing.name),
            "description" => "From {{rule.name}}",
            "priority" => "high",
            "due_date" => "2030-05-01",
            "assignee" => fixture_email("sam@example.com"),
            "tags" => ["follow-up", "missing"]
          }
        ])

      assert run(rule, card) == [{:ok, "created “After Launch”"}]

      made = Repo.one!(from(c in Card, where: c.title == "After Launch")) |> Runner.decorate()
      assert made.column_id == ctx.doing.id
      assert made.description == "From #{rule.name}"
      assert made.priority == "high"
      assert made.due_date == ~D[2030-05-01]
      assert made.assignee_id == sam.id
      assert Enum.map(made.tags, & &1.name) == ["follow-up"]
    end

    test "a list it can't find means the first list; a bad value is reported", ctx do
      rule =
        rule(ctx.board, [%{"type" => "create_card", "title" => "Lost", "column" => "Nowhere"}])

      assert [{:ok, _}] = Runner.run(rule, %{type: "schedule", board_id: ctx.board.id})
      assert Repo.one!(from(c in Card, where: c.title == "Lost")).column_id == ctx.todo.id

      bad = rule(ctx.board, [%{"type" => "create_card", "title" => "Bad", "priority" => "asap"}])
      assert [{:error, message}] = Runner.run(bad, %{type: "schedule", board_id: ctx.board.id})
      assert message =~ "priority"
    end
  end

  describe "run/3 — email and alerts" do
    test "email to somebody who can't see the board is refused, the rest still sent", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Note"})
      rule = rule(ctx.board, [%{"type" => "email", "to" => ctx.owner.email}])

      # Saved with a recipient who could see it; that's no longer the case.
      rule =
        put_in(rule.spec["actions"], [
          %{"type" => "email", "to" => [ctx.owner.email, fixture_email("gone@example.com")]}
        ])

      assert [{:error, message}] = run(rule, card)
      assert message == "emailed #{ctx.owner.email}; refused #{fixture_email("gone@example.com")}"

      assert_email_sent(fn email ->
        assert email.subject == "Runner: Note"
        assert email.text_body =~ rule.name
        assert email.text_body =~ "/boards/#{ctx.board.id}/cards/#{card.id}"
      end)
    end

    test "an email with no card gets a subject and body of its own", ctx do
      rule = rule(ctx.board, [%{"type" => "email", "to" => ctx.owner.email}])

      assert [{:ok, "emailed " <> _}] =
               Runner.run(rule, %{type: "schedule", board_id: ctx.board.id})

      assert_email_sent(fn email ->
        assert email.subject == "Runner: automation"
        assert email.text_body == "#{rule.name} (Runner)"
      end)
    end

    test "an alert with no card belongs to the rule's board", ctx do
      rule = rule(ctx.board, [%{"type" => "alert", "title" => "Morning, {{board.name}}"}])

      assert [{:ok, "alerted: Morning, Runner"}] =
               Runner.run(rule, %{type: "schedule", board_id: ctx.board.id})

      assert [alert] = Automations.list_alerts(ctx.owner)
      assert alert.board_id == ctx.board.id
      assert alert.card_id == nil
      assert alert.severity == "info"
      assert alert.rule_id == rule.id
    end

    test "an alert that can't be raised says why", ctx do
      rule = rule(ctx.board, [%{"type" => "alert", "title" => "x", "severity" => "apocalyptic"}])
      assert [{:error, "alert failed: " <> why}] = Runner.run(rule, %{type: "schedule"})
      assert why =~ "severity"
    end
  end

  describe "render/2 and variables/1" do
    test "fills what it knows, leaves what it doesn't, and copes with non-text" do
      assert Runner.render(nil, %{}) == nil
      assert Runner.render(42, %{}) == "42"
      assert Runner.render("{{ a }}/{{b}}/{{c.d}}", %{"a" => 1, "b" => nil}) == "1//{{c.d}}"
    end

    test "every placeholder in the vocabulary is bound for a card event", ctx do
      tag = tag_fixture(ctx.board, "ops")

      card =
        card_fixture(ctx.todo, %{
          "title" => "T",
          "due_date" => "2030-01-02",
          "start_date" => "2030-01-01",
          "description" => "D",
          "flags" => ["review"]
        })

      {:ok, _} = Boards.toggle_card_tag(card, tag)
      rule = rule(ctx.board, [%{"type" => "log", "message" => "m"}])

      vars =
        Runner.variables(%{type: "card_moved", card: fresh(card), board: ctx.board, rule: rule})

      for "{{" <> rest <- Slipdock.Automations.Spec.placeholders() do
        key = String.trim_trailing(rest, "}}")
        assert Map.has_key?(vars, key), key
      end

      assert vars["card.tags"] == "ops"
      assert vars["card.flags"] == "review"
      assert vars["card.status"] == "open"
      assert vars["card.due_date"] == "2030-01-02"
      assert vars["event"] == "card_moved"
    end

    test "a card's empty fields render empty rather than as the placeholder", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Bare"})
      vars = Runner.variables(%{card: card, board: ctx.board})

      assert Runner.render(
               "[{{card.assignee}}|{{card.due_date}}|{{card.description}}|{{card.nope}}]",
               vars
             ) ==
               "[|||{{card.nope}}]"
    end

    test "with no card, board or rule there is only the clock" do
      vars = Runner.variables(%{})
      assert Map.keys(vars) |> Enum.sort() == ["event", "now", "today"]
      assert vars["event"] == ""
    end
  end

  describe "base_url/0" do
    setup do
      Slipdock.TestConfig.put(:base_url, nil)
    end

    defp endpoint(config), do: Slipdock.TestConfig.put(SlipdockWeb.Endpoint, config)

    test "the configured address wins" do
      Slipdock.TestConfig.put(:base_url, "https://kanban.example.com")
      assert Runner.base_url() == "https://kanban.example.com"
    end

    test "otherwise it is built from the endpoint, leaving out default ports" do
      endpoint(url: [scheme: "https", host: "k.example.com", port: 443])
      assert Runner.base_url() == "https://k.example.com"

      endpoint(url: [scheme: "http", host: "k.example.com", port: 80])
      assert Runner.base_url() == "http://k.example.com"

      endpoint(url: [host: "k.example.com"], http: [port: 4000])
      assert Runner.base_url() == "http://k.example.com:4000"

      endpoint(url: [scheme: "https", host: "k.example.com"])
      assert Runner.base_url() == "https://k.example.com"

      endpoint([])
      assert Runner.base_url() == "http://localhost"
    end
  end
end

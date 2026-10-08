defmodule Slipdock.Automations.SpecTest do
  # The rule vocabulary on its own: what a spec may say, what it is turned
  # into, and how it reads back. Nothing here touches the database.
  use ExUnit.Case, async: true

  alias Slipdock.Automations.Spec

  defp spec(trigger, actions \\ [%{"type" => "complete_card"}], conditions \\ []) do
    %{"trigger" => trigger, "conditions" => conditions, "actions" => actions}
  end

  defp error(spec) do
    assert {:error, message} = Spec.validate(spec)
    message
  end

  describe "validate/1 refuses" do
    test "anything that is not a map" do
      assert Spec.validate(nil) == {:error, "must be a JSON object"}
      assert Spec.validate("when a card moves, email me") == {:error, "must be a JSON object"}
      assert Spec.validate([]) == {:error, "must be a JSON object"}
    end

    test "a trigger with no type, or a type that is not a string" do
      assert error(%{"trigger" => %{}, "actions" => [%{"type" => "log"}]}) =~
               "needs a trigger with a type"

      assert error(spec(%{"type" => 7})) =~ "needs a trigger with a type"
      assert error(spec("card_created")) =~ "needs a trigger with a type"
    end

    test "a trigger missing a key it needs" do
      assert error(spec(%{"type" => "card_stale"})) == "trigger “card_stale” needs days"
      assert error(spec(%{"type" => "card_stale", "days" => ""})) =~ "needs days"
    end

    test "conditions that are not a list" do
      assert error(spec(%{"type" => "card_created"}, [%{"type" => "complete_card"}], %{})) ==
               "conditions must be a list"
    end

    test "a condition without a field and an op, or with an unknown op" do
      trigger = %{"type" => "card_created"}
      actions = [%{"type" => "complete_card"}]

      assert error(spec(trigger, actions, [%{"field" => "priority"}])) ==
               "each condition needs a field and an op"

      assert error(spec(trigger, actions, ["priority is high"])) ==
               "each condition needs a field and an op"

      assert error(spec(trigger, actions, [%{"field" => "priority", "op" => "resembles"}])) ==
               "unknown condition test “resembles”"
    end

    test "the first bad condition stops the check" do
      conditions = [
        %{"field" => "priority", "op" => "is", "value" => "high"},
        %{"field" => "mood", "op" => "is", "value" => "calm"},
        %{"field" => "tag", "op" => "sounds_like", "value" => "x"}
      ]

      assert error(
               spec(
                 %{"type" => "card_created"},
                 [%{"type" => "log", "message" => "m"}],
                 conditions
               )
             ) ==
               "unknown condition field “mood”"
    end

    test "an action with no type, an empty or missing action list" do
      trigger = %{"type" => "card_created"}
      assert error(spec(trigger, [%{"to" => "a@example.com"}])) == "each action needs a type"
      assert error(spec(trigger, [])) == "needs at least one action"
      assert error(spec(trigger, %{"type" => "log"})) == "needs at least one action"
    end

    test "an action missing several required keys names them all" do
      assert error(spec(%{"type" => "card_created"}, [%{"type" => "alert"}])) ==
               "action “alert” needs title"

      assert error(spec(%{"type" => "card_created"}, [%{"type" => "add_tags", "tags" => []}])) ==
               "action “add_tags” needs tags"
    end

    test "a later bad action even when the earlier ones are fine" do
      actions = [%{"type" => "complete_card"}, %{"type" => "webhook"}]
      assert error(spec(%{"type" => "card_created"}, actions)) == "action “webhook” needs url"
    end
  end

  describe "validate/1 on webhooks" do
    defp webhook(url),
      do: spec(%{"type" => "card_created"}, [%{"type" => "webhook", "url" => url}])

    test "placeholders may fill in the path and query" do
      assert {:ok, %{"actions" => [%{"url" => url}]}} =
               Spec.validate(webhook("https://example.com/cards/{{card.id}}?t={{ card.title }}"))

      assert url == "https://example.com/cards/{{card.id}}?t={{ card.title }}"
    end

    test "placeholders may not decide the host, however they are smuggled in" do
      for url <- [
            "https://{{board.name}}.example.com/h",
            "https://user@{{card.title}}/h",
            "{{card.url}}",
            "https://example.com:{{card.id}}/h"
          ] do
        assert error(webhook(url)) == "action “webhook” can't use placeholders in the URL's host",
               url
      end
    end

    test "a URL that is not http(s) or points inside is refused, with the reason" do
      assert error(webhook("ftp://example.com/h")) =~ "action “webhook” url"
      assert error(webhook("http://127.0.0.1/h")) =~ "action “webhook” url"
    end
  end

  describe "validate/1 normalises" do
    test "aliases for the webhook action" do
      for name <- ~w(callback http post) do
        assert {:ok, %{"actions" => [%{"type" => "webhook"}]}} =
                 Spec.validate(
                   spec(%{"type" => "card_created"}, [
                     %{"type" => name, "url" => "https://example.com/h"}
                   ])
                 )
      end
    end

    test "numbers written as strings, in lists too, but not text that merely starts with one" do
      assert {:ok, normalised} =
               Spec.validate(
                 spec(
                   %{"type" => "card_due_soon", "within_hours" => "48"},
                   [%{"type" => "add_tags", "tags" => ["2026", "q3 plan"]}],
                   [%{"field" => "percent_complete", "op" => "gt", "value" => "50"}]
                 )
               )

      assert normalised["trigger"] == %{"type" => "card_due_soon", "within_hours" => 48}
      assert normalised["actions"] == [%{"type" => "add_tags", "tags" => [2026, "q3 plan"]}]

      assert normalised["conditions"] == [
               %{"field" => "percent_complete", "op" => "gt", "value" => 50}
             ]

      assert {:ok, %{"actions" => [%{"title" => "3 things"}]}} =
               Spec.validate(
                 spec(%{"type" => "card_created"}, [
                   %{"type" => "create_card", "title" => "3 things"}
                 ])
               )
    end

    test "blank optional keys are dropped rather than kept empty" do
      assert {:ok, %{"trigger" => trigger, "actions" => [action]}} =
               Spec.validate(
                 spec(%{"type" => "card_moved", "from" => "", "to" => "Done"}, [
                   %{"type" => "alert", "title" => "Moved", "body" => nil, "severity" => ""}
                 ])
               )

      assert trigger == %{"type" => "card_moved", "to" => "Done"}
      assert action == %{"type" => "alert", "title" => "Moved"}
    end

    test "a condition always carries a value, nil when none was given" do
      assert {:ok, %{"conditions" => [condition]}} =
               Spec.validate(
                 spec(%{"type" => "card_created"}, [%{"type" => "complete_card"}], [
                   %{"field" => "due_date", "op" => "is_set", "extra" => "dropped"}
                 ])
               )

      assert condition == %{"field" => "due_date", "op" => "is_set", "value" => nil}
    end

    test "conditions may be left out altogether" do
      assert {:ok, %{"conditions" => []}} =
               Spec.validate(%{
                 "trigger" => %{"type" => "card_created"},
                 "actions" => [%{"type" => "log", "message" => "hi"}]
               })
    end

    test "every action in the vocabulary validates with only its required keys" do
      samples = %{
        "to" => "a@example.com",
        "title" => "T",
        "column" => "Done",
        "priority" => "high",
        "tags" => ["x"],
        "flags" => ["blocked"],
        "assignee" => "a@example.com",
        "body" => "B",
        "items" => ["one"],
        "url" => "https://example.com/h",
        "message" => "M",
        "pool" => "dev"
      }

      for %{type: type, required: required} <- Spec.vocabulary().actions do
        action = Map.new(required, &{&1, Map.fetch!(samples, &1)}) |> Map.put("type", type)

        assert {:ok, %{"actions" => [kept]}} =
                 Spec.validate(spec(%{"type" => "card_created"}, [action])),
               type

        assert kept["type"] == type
      end
    end

    test "every trigger in the vocabulary validates with only its required keys" do
      for %{type: type, required: required} <- Spec.vocabulary().triggers do
        trigger = Map.new(required, &{&1, 3}) |> Map.put("type", type)
        assert {:ok, %{"trigger" => %{"type" => ^type}}} = Spec.validate(spec(trigger)), type
      end
    end
  end

  describe "accessors" do
    test "read a spec, and anything that is not one, without raising" do
      {:ok, rule} =
        Spec.validate(
          spec(%{"type" => "card_overdue"}, [%{"type" => "log", "message" => "late"}], [
            %{"field" => "completed", "op" => "is", "value" => false}
          ])
        )

      assert Spec.trigger_type(rule) == "card_overdue"
      assert Spec.scheduled?(rule)
      assert [%{"type" => "log"}] = Spec.actions(rule)
      assert [%{"field" => "completed"}] = Spec.conditions(rule)

      for junk <- [nil, %{}, %{"trigger" => "x", "actions" => "y", "conditions" => "z"}] do
        assert Spec.trigger_type(junk) == nil
        refute Spec.scheduled?(junk)
        assert Spec.actions(junk) == []
        assert Spec.conditions(junk) == []
      end
    end

    test "the clock-driven triggers are exactly the scheduled ones" do
      assert Enum.sort(Spec.scheduled_types()) ==
               ~w(card_due_soon card_overdue card_stale card_starts_soon schedule)

      refute Spec.scheduled?(%{"trigger" => %{"type" => "card_created"}})
      assert Enum.all?(Spec.scheduled_types(), &(&1 in Spec.trigger_types()))
      assert "webhook" in Spec.action_types()
      assert "has_doc" in Spec.condition_fields()
      assert "older_than_days" in Spec.condition_ops()
    end
  end

  describe "summary/1" do
    defp says(trigger, actions \\ [%{"type" => "complete_card"}], conditions \\ []) do
      {:ok, rule} = Spec.validate(spec(trigger, actions, conditions))
      Spec.summary(rule)
    end

    test "each trigger reads as a clause" do
      cases = [
        {%{"type" => "card_created"}, "a card is added"},
        {%{"type" => "card_entered", "column" => "Ready"}, "a card arrives in Ready"},
        {%{"type" => "card_activity"}, "anything happens to a card"},
        {%{"type" => "card_moved", "from" => "Doing", "to" => "Done"},
         "a card moves out of Doing into Done"},
        {%{"type" => "card_moved"}, "a card moves"},
        {%{"type" => "card_updated", "field" => "priority"}, "a card's priority changes"},
        {%{"type" => "card_completed"}, "a card is completed"},
        {%{"type" => "card_reopened"}, "a card is reopened"},
        {%{"type" => "card_archived"}, "a card is archived"},
        {%{"type" => "card_assigned", "assignee" => "Sam"}, "a card is assigned to Sam"},
        {%{"type" => "comment_added"}, "a card gets a comment"},
        {%{"type" => "tag_added", "tag" => "urgent"}, "a card is tagged urgent"},
        {%{"type" => "flag_added", "flag" => "blocked"}, "a card is flagged as blocked"},
        {%{"type" => "card_stale", "days" => 7, "column" => "Doing"},
         "a card goes 7 days untouched in Doing"},
        {%{"type" => "card_due_soon"}, "a card is due within 24 hours"},
        {%{"type" => "card_due_soon", "within_hours" => 6}, "a card is due within 6 hours"},
        {%{"type" => "card_due_soon", "within_days" => 3}, "a card is due within 3 days"},
        {%{"type" => "card_overdue"}, "a card is overdue"},
        {%{"type" => "card_overdue", "by_days" => 2}, "a card is overdue by 2 days"},
        {%{"type" => "card_overdue", "by_days" => 0}, "a card is overdue"},
        {%{"type" => "card_starts_soon"}, "a card starts within 1 days"},
        {%{"type" => "card_starts_soon", "within_days" => 5}, "a card starts within 5 days"},
        {%{"type" => "schedule"}, "the clock reaches 09:00"},
        {%{"type" => "schedule", "at" => "17:30", "weekday" => 5},
         "the clock reaches 17:30 on Friday"},
        {%{"type" => "schedule", "at" => "08:00", "weekday" => 9}, "the clock reaches 08:00"}
      ]

      for {trigger, clause} <- cases do
        assert says(trigger) == "When #{clause}, complete it.", inspect(trigger)
      end
    end

    test "each condition reads as a clause" do
      cases = [
        {"priority", "is", "high", "priority is high"},
        {"tag", "is_not", ["a", "b"], "tag is not a, b"},
        {"title", "contains", "bug", "title contains “bug”"},
        {"title", "not_contains", "wip", "title does not contain “wip”"},
        {"priority", "any_of", ["high", "critical"], "priority is one of high, critical"},
        {"flag", "none_of", ["blocked"], "flag is none of blocked"},
        {"due_date", "is_set", nil, "due date is set"},
        {"has_assignee", "is_not_set", nil, "has assignee is not set"},
        {"due_date", "before", "2030-01-01", "due date is before 2030-01-01"},
        {"start_date", "after", "today", "start date is after today"},
        {"due_date", "within_days", 3, "due date is within 3 days"},
        {"age_days", "older_than_days", 30, "age days is more than 30 days old"},
        {"percent_complete", "gt", 50, "percent complete is more than 50"},
        {"percent_complete", "lt", 10, "percent complete is less than 10"}
      ]

      for {field, op, value, clause} <- cases do
        condition = %{"field" => field, "op" => op, "value" => value}

        assert says(%{"type" => "card_created"}, [%{"type" => "complete_card"}], [condition]) ==
                 "When a card is added and #{clause}, complete it.",
               op
      end
    end

    test "each action reads as a clause" do
      cases = [
        {%{"type" => "email", "to" => ["a@example.com", "b@example.com"]},
         "email a@example.com, b@example.com"},
        {%{"type" => "notify_assignee"}, "email the assignee"},
        {%{"type" => "alert", "title" => "T"}, "raise an info alert"},
        {%{"type" => "alert", "title" => "T", "severity" => "warning"}, "raise a warning alert"},
        {%{"type" => "alert", "title" => "T", "severity" => "urgent"}, "raise an urgent alert"},
        {%{"type" => "move_card", "column" => "Done"}, "move it to Done"},
        {%{"type" => "set_priority", "priority" => "low"}, "set its priority to low"},
        {%{"type" => "add_tags", "tags" => ["a", "b"]}, "tag it a, b"},
        {%{"type" => "remove_tags", "tags" => ["a"]}, "untag a"},
        {%{"type" => "add_flags", "flags" => ["review"]}, "flag it review"},
        {%{"type" => "remove_flags", "flags" => ["review"]}, "clear the review flag"},
        {%{"type" => "assign", "assignee" => "Sam"}, "assign it to Sam"},
        {%{"type" => "unassign"}, "unassign it"},
        {%{"type" => "comment", "body" => "hi"}, "comment on it"},
        {%{"type" => "set_due_date", "date" => "2030-01-01"}, "set its due date to 2030-01-01"},
        {%{"type" => "set_due_date", "in_days" => 3}, "set its due date to 3 days from now"},
        {%{"type" => "set_due_date"}, "set its due date to today"},
        {%{"type" => "clear_due_date"}, "clear its due date"},
        {%{"type" => "complete_card"}, "complete it"},
        {%{"type" => "reopen_card"}, "reopen it"},
        {%{"type" => "archive_card"}, "archive it"},
        {%{"type" => "add_checklist_items", "items" => ["a", "b", "c"]}, "add 3 checklist items"},
        {%{"type" => "create_card", "title" => "Next", "column" => "To Do"},
         "create “Next” in To Do"},
        {%{"type" => "create_page", "title" => "Notes"}, "start a wiki page “Notes” for it"},
        {%{"type" => "create_page"}, "start a wiki page for it"},
        {%{"type" => "webhook", "url" => "https://example.com/h"}, "POST https://example.com/h"},
        {%{"type" => "log", "message" => "m"}, "note it in the activity log"}
      ]

      for {action, clause} <- cases do
        assert says(%{"type" => "card_created"}, [action]) == "When a card is added, #{clause}.",
               action["type"]
      end
    end

    test "copes with a spec that never went through validate/1" do
      assert Spec.summary(%{"trigger" => %{"type" => "eclipse"}, "actions" => []}) ==
               "When eclipse, ."

      assert Spec.summary(%{}) == "When something happens, ."

      assert Spec.summary(%{
               "trigger" => %{"type" => "card_created"},
               "conditions" => [%{"field" => "tag", "op" => "rhymes_with", "value" => ["x"]}],
               "actions" => [%{"type" => "teleport"}]
             }) == "When a card is added and tag rhymes_with x, teleport."
    end
  end

  describe "vocabulary/0 and catalogue/0" do
    test "the vocabulary lists every trigger and action once, marking the scheduled ones" do
      vocabulary = Spec.vocabulary()

      assert Enum.map(vocabulary.triggers, & &1.type) == Spec.trigger_types()
      assert Enum.map(vocabulary.actions, & &1.type) == Spec.action_types()

      scheduled = for t <- vocabulary.triggers, t.scheduled, do: t.type
      assert scheduled == Spec.scheduled_types()

      refute Enum.any?(vocabulary.actions, &Map.has_key?(&1, :scheduled))

      assert %{type: "card_stale", required: ["days"]} =
               Enum.find(vocabulary.triggers, &(&1.type == "card_stale"))

      assert vocabulary.placeholders == Spec.placeholders()
      assert "{{card.url}}" in Spec.placeholders()
      assert vocabulary.severities == ["info", "warning", "urgent"]
    end

    test "the catalogue names everything the validator accepts, required keys marked" do
      catalogue = Spec.catalogue()

      for type <- Spec.trigger_types() ++ Spec.action_types(),
          do: assert(catalogue =~ "  - #{type}: ", type)

      for name <- Spec.condition_fields() ++ Spec.condition_ops(), do: assert(catalogue =~ name)

      assert catalogue =~ "  - email: send an email — keys: to (required), subject, body"
      assert catalogue =~ "  - card_completed: a card is ticked off\n"
    end
  end
end

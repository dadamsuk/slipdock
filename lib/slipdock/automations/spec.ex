defmodule Slipdock.Automations.Spec do
  @moduledoc """
  The shape of an automation rule, and the one place that knows it.

  A spec is a map with three keys:

      %{
        "trigger"    => %{"type" => "card_created", "column" => "Doing"},
        "conditions" => [%{"field" => "priority", "op" => "is", "value" => "high"}],
        "actions"    => [%{"type" => "email", "to" => "ops@example.com", ...}]
      }

  `validate/1` checks and normalises one (dropping unknown keys, coercing
  numbers, defaulting what can be defaulted); `summary/1` turns it back into
  a sentence for the UI; `catalogue/0` renders the whole vocabulary as text
  for the model that writes specs from plain language. Keeping all three
  next to the definitions means the prompt can never drift from the runner.
  """

  # {type, required keys, optional keys, blurb}
  @event_triggers [
    {"card_created", [], ["column"], "a card is added (optionally to one list)"},
    {"card_entered", [], ["column"],
     "a card arrives in a list, either added there or moved there from another"},
    {"card_moved", [], ["from", "to"], "a card moves between lists"},
    {"card_updated", [], ["field"],
     "a card changes (field: title, description, priority, due_date, start_date, percent_complete, assignee, flags, color)"},
    {"card_completed", [], [], "a card is ticked off"},
    {"card_reopened", [], [], "a completed card is reopened"},
    {"card_archived", [], [], "a card is archived"},
    {"card_assigned", [], ["assignee"], "a card is assigned to someone"},
    {"comment_added", [], [], "someone comments on a card"},
    {"tag_added", [], ["tag"], "a tag is put on a card"},
    {"flag_added", [], ["flag"],
     "a flag is put on a card (flagged, blocked, review, waiting, starred)"},
    {"card_activity", [], [],
     "anything happens to a card — added, moved, changed, commented on, tagged or archived; once per change"}
  ]

  @scheduled_triggers [
    {"card_stale", ["days"], ["column"], "a card has not been touched for N days"},
    {"card_due_soon", [], ["within_hours", "within_days"],
     "a card's due date is closer than the given window (default 24 hours)"},
    {"card_overdue", [], ["by_days"], "a card's due date has passed"},
    {"card_starts_soon", [], ["within_days"], "a card's start date is coming up"},
    {"schedule", [], ["at", "weekday"],
     "the clock, once a day at \"HH:MM\" (optionally only on one weekday, 1 = Monday)"}
  ]

  # Neither an event nor the clock: the rule keeps one job open for a runner
  # pool, refilled from the top of a list whenever the last one ends (see
  # `Slipdock.Automations.feed/1`). It has to queue a job, or there is
  # nothing to say when it is busy.
  @feed_triggers [
    {"list_top", ["column"], ["unassigned"],
     "keeps a runner busy with a list, in its order: whenever nothing this rule queued is " <>
       "still open, the top open card of the list is sent (skipping completed, archived, " <>
       "dependency-blocked and blocked or waiting flagged cards; unassigned: true skips " <>
       "assigned ones too). Needs a runner action"}
  ]

  @condition_fields ~w(card column priority tag assignee flag title description completed
                       archived blocked has_due_date has_assignee due_date start_date
                       percent_complete health age_days has_doc)

  @condition_ops ~w(is is_not contains not_contains any_of none_of is_set is_not_set
                    before after within_days older_than_days gt lt)

  # {type, required keys, optional keys, blurb}
  @actions [
    {"email", ["to"], ["subject", "body"], "send an email"},
    {"notify_assignee", [], ["subject", "body"], "email everybody the card is assigned to"},
    {"alert", ["title"], ["body", "severity"],
     "raise a dismissable alert in the header bar (severity: info, warning, urgent)"},
    {"move_card", ["column"], [], "move the card to another list"},
    {"set_priority", ["priority"], [], "set the priority (none, low, medium, high, critical)"},
    {"add_tags", ["tags"], [], "put existing tags on the card"},
    {"remove_tags", ["tags"], [], "take tags off the card"},
    {"add_flags", ["flags"], [], "raise flags (flagged, blocked, review, waiting, starred)"},
    {"remove_flags", ["flags"], [], "lower flags"},
    {"assign", ["assignee"], [],
     "assign the card to a person (name or email), in place of whoever had it"},
    {"unassign", [], [], "leave the card unassigned"},
    {"comment", ["body"], [], "add a comment to the card"},
    {"set_due_date", [], ["date", "in_days"],
     "set the due date, either a YYYY-MM-DD date or in_days from today"},
    {"clear_due_date", [], [], "remove the due date"},
    {"complete_card", [], [], "tick the card off"},
    {"reopen_card", [], [], "un-tick the card"},
    {"archive_card", [], [], "archive the card"},
    {"add_checklist_items", ["items"], [], "add checklist items to the card"},
    {"create_card", ["title"],
     ["column", "description", "priority", "due_date", "assignee", "tags"],
     "add a new card to a list"},
    {"create_page", [], ["title", "template", "parent", "body", "summary"],
     "start a wiki page for the card, pinned to it (from a template page if named)"},
    {"webhook", ["url"], ["method"],
     "call a URL back with the card — its title, a link to it, its dates, flags and status. " <>
       "method: post (the default), put or patch send JSON; get puts the same fields in the " <>
       "query string. The URL may itself use placeholders"},
    {"log", ["message"], [], "write a line into the board's activity log"},
    {"runner", ["pool"], ["kind", "prompt", "wait_while_doing", "requeue_stuck"],
     "send the card to a coding agent on one of the user's own machines: queue a job for the " <>
       "runners of that pool, which run the kind of job named (claude by default) with the " <>
       "prompt (the card's title, link and description by default). The runner's own config " <>
       "decides what each kind runs. At most one open job per card per rule. " <>
       "wait_while_doing: true keeps the job queued while any other open card is in an " <>
       "in-progress list on the card's board. requeue_stuck: N (list_top rules only, 0-10) " <>
       "puts a card its job left in an in-progress list back on top of the rule's list, " <>
       "with a comment, up to N times, then flags it blocked and leaves it"}
  ]

  # Names people (and models) reach for that mean an action we already have.
  @action_aliases %{
    "callback" => "webhook",
    "http" => "webhook",
    "post" => "webhook",
    "send_to_runner" => "runner",
    "send to runner" => "runner"
  }

  # What text in an action (a subject, a comment, an alert body) may refer to.
  @placeholders ~w({{card.title}} {{card.id}} {{card.url}} {{card.description}} {{card.priority}}
                   {{card.column}} {{card.assignee}} {{card.due_date}} {{card.start_date}}
                   {{card.tags}} {{card.flags}} {{card.status}} {{board.name}} {{board.url}}
                   {{today}} {{now}} {{event}} {{rule.name}})

  @triggers @event_triggers ++ @scheduled_triggers ++ @feed_triggers

  # A rule is a handful of things to do, not a mailing list: these bound how
  # much one save can make the server send.
  @max_actions 20
  @max_recipients 10

  @scheduled_types Enum.map(@scheduled_triggers, &elem(&1, 0))
  @feed_types Enum.map(@feed_triggers, &elem(&1, 0))
  @trigger_types Enum.map(@triggers, &elem(&1, 0))
  @action_types Enum.map(@actions, &elem(&1, 0))

  def trigger_types, do: @trigger_types
  def action_types, do: @action_types
  def scheduled_types, do: @scheduled_types
  def feed_types, do: @feed_types
  def max_actions, do: @max_actions
  def max_recipients, do: @max_recipients
  def condition_fields, do: @condition_fields
  def condition_ops, do: @condition_ops

  @doc "Whether the spec's trigger is driven by the clock rather than an event."
  def scheduled?(spec), do: Enum.member?(@scheduled_types, trigger_type(spec))

  @doc "Whether the spec keeps a runner fed from the top of a list (`list_top`)."
  def feed?(spec), do: Enum.member?(@feed_types, trigger_type(spec))

  @doc "The spec's trigger type, or nil."
  def trigger_type(%{"trigger" => %{"type" => type}}) when is_binary(type), do: type
  def trigger_type(_), do: nil

  @doc "The spec's actions, or an empty list."
  def actions(%{"actions" => actions}) when is_list(actions), do: actions
  def actions(_), do: []

  @doc "The spec's conditions, or an empty list."
  def conditions(%{"conditions" => conditions}) when is_list(conditions), do: conditions
  def conditions(_), do: []

  ## Validation ---------------------------------------------------------------

  @doc """
  Checks a spec and returns `{:ok, normalised}` or `{:error, message}`.
  Unknown keys are dropped, so a chatty model can't smuggle anything past
  the runner; numbers arriving as strings are coerced.
  """
  @spec validate(map) :: {:ok, map} | {:error, String.t()}
  def validate(%{} = spec) do
    with {:ok, trigger} <- validate_trigger(spec["trigger"]),
         {:ok, conditions} <- validate_conditions(spec["conditions"] || []),
         {:ok, actions} <- validate_actions(spec["actions"]),
         {:ok, trigger} <- check_feed(trigger, actions) do
      {:ok, %{"trigger" => trigger, "conditions" => conditions, "actions" => actions}}
    end
  end

  def validate(_), do: {:error, "must be a JSON object"}

  defp validate_trigger(%{"type" => type} = trigger) when is_binary(type) do
    case List.keyfind(@triggers, type, 0) do
      nil ->
        {:error, "unknown trigger “#{type}”"}

      {_, required, optional, _} ->
        keep(trigger, required, optional, "trigger “#{type}”")
    end
  end

  defp validate_trigger(_), do: {:error, "needs a trigger with a type"}

  defp check_feed(%{"type" => type} = trigger, actions) when type in @feed_types do
    unassigned =
      Map.get(%{"true" => true, "false" => false}, trigger["unassigned"], trigger["unassigned"])

    cond do
      not Enum.any?(actions, &(&1["type"] == "runner")) ->
        {:error, "trigger “#{type}” needs a runner action: it keeps a runner pool busy"}

      not (is_nil(unassigned) or is_boolean(unassigned)) ->
        {:error, "trigger “#{type}” unassigned must be true or false"}

      is_nil(unassigned) ->
        {:ok, trigger}

      true ->
        {:ok, Map.put(trigger, "unassigned", unassigned)}
    end
  end

  # Putting a card back on the rule's list only means something to a rule
  # that works the list top first: one that sends cards as they arrive would
  # send it again at once.
  defp check_feed(trigger, actions) do
    if Enum.any?(actions, &(is_integer(&1["requeue_stuck"]) and &1["requeue_stuck"] > 0)),
      do: {:error, "requeue_stuck is only for a list_top rule"},
      else: {:ok, trigger}
  end

  defp validate_conditions(conditions) when is_list(conditions) do
    Enum.reduce_while(conditions, {:ok, []}, fn condition, {:ok, acc} ->
      case validate_condition(condition) do
        {:ok, c} -> {:cont, {:ok, acc ++ [c]}}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_conditions(_), do: {:error, "conditions must be a list"}

  defp validate_condition(%{"field" => field, "op" => op} = condition)
       when is_binary(field) and is_binary(op) do
    cond do
      not Enum.member?(@condition_fields, field) -> {:error, "unknown condition field “#{field}”"}
      not Enum.member?(@condition_ops, op) -> {:error, "unknown condition test “#{op}”"}
      true -> {:ok, %{"field" => field, "op" => op, "value" => coerce(condition["value"])}}
    end
  end

  defp validate_condition(_), do: {:error, "each condition needs a field and an op"}

  defp validate_actions(actions) when is_list(actions) and length(actions) > @max_actions,
    do: {:error, "a rule can have at most #{@max_actions} actions"}

  defp validate_actions(actions) when is_list(actions) and actions != [] do
    Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, acc} ->
      case validate_action(action) do
        {:ok, a} -> {:cont, {:ok, acc ++ [a]}}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_actions(_), do: {:error, "needs at least one action"}

  defp validate_action(%{"type" => type} = action) when is_binary(type) do
    type = Map.get(@action_aliases, type, type)
    action = Map.put(action, "type", type)

    case List.keyfind(@actions, type, 0) do
      nil ->
        {:error, "unknown action “#{type}”"}

      {_, required, optional, _} ->
        with {:ok, kept} <- keep(action, required, optional, "action “#{type}”"),
             do: check_action(kept)
    end
  end

  defp validate_action(_), do: {:error, "each action needs a type"}

  # A webhook's scheme and host are fixed when the rule is saved: placeholders
  # may fill in the path and query, never decide where the call goes. The
  # full check (DNS and all) happens again on every call.
  defp check_action(%{"type" => "webhook", "url" => url} = action) do
    url = to_string(url)
    sample = Regex.replace(~r/\{\{\s*[\w.]+\s*\}\}/, url, "x")

    authority =
      case String.split(url, "://", parts: 2) do
        [_scheme, rest] -> rest |> String.split(["/", "?", "#"], parts: 2) |> hd()
        [_] -> url
      end

    if String.contains?(authority, "{{") do
      {:error, "action “webhook” can't use placeholders in the URL's host"}
    else
      case Slipdock.Egress.check_static(sample) do
        :ok -> {:ok, action}
        {:error, reason} -> {:error, "action “webhook” url #{reason}"}
      end
    end
  end

  defp check_action(%{"type" => "email", "to" => to} = action) do
    if length(List.wrap(to)) > @max_recipients do
      {:error, "action “email” can go to at most #{@max_recipients} addresses"}
    else
      {:ok, action}
    end
  end

  defp check_action(%{"type" => "runner"} = action) do
    format = Slipdock.Runners.Runner.name_format()
    action = Map.update!(action, "pool", &(&1 |> to_string() |> String.downcase()))
    action = Map.update(action, "kind", "claude", &(&1 |> to_string() |> String.downcase()))

    wait =
      Map.get(
        %{"true" => true, "false" => false},
        action["wait_while_doing"],
        action["wait_while_doing"]
      )

    action = if is_boolean(wait), do: Map.put(action, "wait_while_doing", wait), else: action
    requeue = requeue_stuck(action["requeue_stuck"])
    action = if is_integer(requeue), do: Map.put(action, "requeue_stuck", requeue), else: action
    max_requeue = Slipdock.Runners.Recovery.max_requeues()

    cond do
      not (is_nil(wait) or is_boolean(wait)) ->
        {:error, "action “runner” wait_while_doing must be true or false"}

      not (is_nil(requeue) or (is_integer(requeue) and requeue in 0..max_requeue)) ->
        {:error, "action “runner” requeue_stuck must be a whole number from 0 to #{max_requeue}"}

      not Regex.match?(format, action["pool"]) ->
        {:error, "action “runner” pool must be lower case letters, digits, - or _"}

      not Regex.match?(format, action["kind"]) ->
        {:error, "action “runner” kind must be lower case letters, digits, - or _"}

      byte_size(to_string(action["prompt"])) > Slipdock.Runners.limits().max_prompt ->
        {:error, "action “runner” prompt is too long"}

      true ->
        {:ok, action}
    end
  end

  defp check_action(action), do: {:ok, action}

  defp requeue_stuck(nil), do: nil
  defp requeue_stuck(n) when is_integer(n), do: n

  defp requeue_stuck(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} -> n
      _ -> text
    end
  end

  defp requeue_stuck(other), do: other

  # Keeps the known keys of a trigger or action, checking the required ones
  # are there and not blank.
  defp keep(map, required, optional, what) do
    missing = Enum.filter(required, &blank?(map[&1]))

    if missing == [] do
      kept =
        for key <- required ++ optional, not blank?(map[key]), into: %{} do
          {key, coerce(map[key])}
        end

      {:ok, Map.put(kept, "type", map["type"])}
    else
      {:error, "#{what} needs #{Enum.join(missing, ", ")}"}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(_), do: false

  # Numbers the model wrote as strings are far commoner than strings that
  # happen to look like numbers, so "7" becomes 7.
  defp coerce(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> value
    end
  end

  defp coerce(value) when is_list(value), do: Enum.map(value, &coerce/1)
  defp coerce(value), do: value

  ## Summary ------------------------------------------------------------------

  @doc "A sentence describing the rule, for the rules list."
  def summary(spec) do
    "When " <>
      trigger_summary(spec["trigger"]) <>
      condition_summary(conditions(spec)) <>
      ", " <> action_summary(actions(spec)) <> "."
  end

  defp trigger_summary(%{"type" => type} = t) do
    case type do
      "card_created" ->
        "a card is added" <> where(t["column"], "to")

      "card_entered" ->
        "a card arrives" <> where(t["column"], "in")

      "card_activity" ->
        "anything happens to a card"

      "card_moved" ->
        "a card moves" <> where(t["from"], "out of") <> where(t["to"], "into")

      "card_updated" ->
        "a card's " <> to_string(t["field"] || "details") <> " changes"

      "card_completed" ->
        "a card is completed"

      "card_reopened" ->
        "a card is reopened"

      "card_archived" ->
        "a card is archived"

      "card_assigned" ->
        "a card is assigned" <> where(t["assignee"], "to")

      "comment_added" ->
        "a card gets a comment"

      "tag_added" ->
        "a card is tagged" <> where(t["tag"], "")

      "flag_added" ->
        "a card is flagged" <> where(t["flag"], "as")

      "card_stale" ->
        "a card goes #{t["days"]} days untouched" <> where(t["column"], "in")

      "card_due_soon" ->
        "a card is due within #{due_window(t)}"

      "card_overdue" ->
        "a card is overdue" <> by_days(t["by_days"])

      "card_starts_soon" ->
        "a card starts within #{t["within_days"] || 1} days"

      "schedule" ->
        "the clock reaches #{t["at"] || "09:00"}" <> weekday(t["weekday"])

      "list_top" ->
        "nothing it sent is still open, take the top #{unassigned(t)}card of #{t["column"]}"

      other ->
        other
    end
  end

  defp trigger_summary(_), do: "something happens"

  defp unassigned(%{"unassigned" => true}), do: "unassigned "
  defp unassigned(_), do: ""

  defp due_window(%{"within_hours" => h}) when is_integer(h), do: "#{h} hours"
  defp due_window(%{"within_days" => d}) when is_integer(d), do: "#{d} days"
  defp due_window(_), do: "24 hours"

  defp by_days(n) when is_integer(n) and n > 0, do: " by #{n} days"
  defp by_days(_), do: ""

  defp weekday(n) when is_integer(n) and n in 1..7,
    do: " on #{Enum.at(~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday), n - 1)}"

  defp weekday(_), do: ""

  defp where(nil, _), do: ""
  defp where(value, ""), do: " #{value}"
  defp where(value, preposition), do: " #{preposition} #{value}"

  defp condition_summary([]), do: ""

  defp condition_summary(conditions),
    do: " and " <> Enum.map_join(conditions, " and ", &one_condition/1)

  defp one_condition(%{"field" => field, "op" => op, "value" => value}) do
    field = String.replace(field, "_", " ")

    case op do
      "is" -> "#{field} is #{list(value)}"
      "is_not" -> "#{field} is not #{list(value)}"
      "contains" -> "#{field} contains “#{value}”"
      "not_contains" -> "#{field} does not contain “#{value}”"
      "any_of" -> "#{field} is one of #{list(value)}"
      "none_of" -> "#{field} is none of #{list(value)}"
      "is_set" -> "#{field} is set"
      "is_not_set" -> "#{field} is not set"
      "before" -> "#{field} is before #{value}"
      "after" -> "#{field} is after #{value}"
      "within_days" -> "#{field} is within #{value} days"
      "older_than_days" -> "#{field} is more than #{value} days old"
      "gt" -> "#{field} is more than #{value}"
      "lt" -> "#{field} is less than #{value}"
      other -> "#{field} #{other} #{list(value)}"
    end
  end

  defp action_summary(actions), do: Enum.map_join(actions, ", then ", &one_action/1)

  defp one_action(%{"type" => type} = a) do
    case type do
      "email" ->
        "email #{list(a["to"])}"

      "notify_assignee" ->
        "email the assignee"

      "alert" ->
        "raise #{article(a["severity"] || "info")} alert"

      "move_card" ->
        "move it to #{a["column"]}"

      "set_priority" ->
        "set its priority to #{a["priority"]}"

      "add_tags" ->
        "tag it #{list(a["tags"])}"

      "remove_tags" ->
        "untag #{list(a["tags"])}"

      "add_flags" ->
        "flag it #{list(a["flags"])}"

      "remove_flags" ->
        "clear the #{list(a["flags"])} flag"

      "assign" ->
        "assign it to #{a["assignee"]}"

      "unassign" ->
        "unassign it"

      "comment" ->
        "comment on it"

      "set_due_date" ->
        "set its due date #{due_target(a)}"

      "clear_due_date" ->
        "clear its due date"

      "complete_card" ->
        "complete it"

      "reopen_card" ->
        "reopen it"

      "archive_card" ->
        "archive it"

      "add_checklist_items" ->
        "add #{length(List.wrap(a["items"]))} checklist items"

      "create_card" ->
        "create “#{a["title"]}”" <> where(a["column"], "in")

      "create_page" ->
        "start a wiki page" <> page_title(a["title"])

      "webhook" ->
        "#{String.upcase(to_string(a["method"] || "post"))} #{a["url"]}"

      "log" ->
        "note it in the activity log"

      "runner" ->
        "send it to the #{a["pool"]} runners (#{a["kind"] || "claude"})" <>
          if(a["wait_while_doing"] == true, do: " once nothing is in progress", else: "") <>
          requeue_summary(a["requeue_stuck"])

      other ->
        other
    end
  end

  defp requeue_summary(1), do: ", putting back a card its job leaves in progress once"

  defp requeue_summary(n) when is_integer(n) and n > 1,
    do: ", putting back a card its job leaves in progress up to #{n} times"

  defp requeue_summary(_), do: ""

  defp page_title(nil), do: " for it"
  defp page_title(title), do: " “#{title}” for it"

  defp article(severity) when severity in ["info", "urgent"], do: "an #{severity}"
  defp article(severity), do: "a #{severity}"

  defp due_target(%{"date" => date}) when is_binary(date), do: "to #{date}"
  defp due_target(%{"in_days" => n}) when is_integer(n), do: "to #{n} days from now"
  defp due_target(_), do: "to today"

  defp list(value) when is_list(value), do: Enum.map_join(value, ", ", &to_string/1)
  defp list(value), do: to_string(value)

  ## Catalogue ----------------------------------------------------------------

  @doc """
  The whole vocabulary as data: what the API serves, what the agent guide
  lists, and what `catalogue/0` renders. One source, so a rule written
  against the documentation is a rule the runner can run.
  """
  def vocabulary do
    %{
      triggers:
        Enum.map(@event_triggers, &entry(&1, false)) ++
          Enum.map(@scheduled_triggers, &entry(&1, true)) ++
          Enum.map(@feed_triggers, &(&1 |> entry(false) |> Map.put(:feed, true))),
      condition_fields: @condition_fields,
      condition_ops: @condition_ops,
      actions: Enum.map(@actions, &entry(&1, nil)),
      placeholders: @placeholders,
      scopes: ["board", "tree"],
      severities: ["info", "warning", "urgent"]
    }
  end

  defp entry({type, required, optional, blurb}, scheduled) do
    %{type: type, required: required, optional: optional, description: blurb}
    |> then(&if(is_nil(scheduled), do: &1, else: Map.put(&1, :scheduled, scheduled)))
  end

  @doc "The placeholders action text may use."
  def placeholders, do: @placeholders

  @doc """
  The vocabulary as text, for the prompt that turns plain language into a
  spec and for the help shown beside the composer.
  """
  def catalogue do
    """
    TRIGGERS (exactly one, as "trigger": {"type": …, …}) — events:
    #{describe(@event_triggers)}

    TRIGGERS — driven by the clock, checked every few minutes:
    #{describe(@scheduled_triggers)}

    TRIGGERS — keeping a runner pool busy, one card at a time:
    #{describe(@feed_triggers)}

    CONDITIONS (optional, "conditions": [{"field": …, "op": …, "value": …}], all must hold):
      fields: #{Enum.join(@condition_fields, ", ")}
      ops: #{Enum.join(@condition_ops, ", ")}

    ACTIONS (one or more, "actions": [{"type": …, …}]):
    #{describe(@actions)}
    """
  end

  defp describe(entries) do
    Enum.map_join(entries, "\n", fn {type, required, optional, blurb} ->
      keys = Enum.map(required, &"#{&1} (required)") ++ optional
      keys = if keys == [], do: "", else: " — keys: " <> Enum.join(keys, ", ")
      "  - #{type}: #{blurb}#{keys}"
    end)
  end
end

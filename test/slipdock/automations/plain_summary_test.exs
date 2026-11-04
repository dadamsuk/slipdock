defmodule Slipdock.Automations.PlainSummaryTest do
  @moduledoc """
  A rule's summary is plain English (#1699): no "completed is false", no
  "flag it flagged", and no internal rule kind (`card_stale`) in it. Checked
  across every ready-made rule, with each of its flag choices, and across
  every yes/no condition field both ways.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Accounts.User
  alias Slipdock.Automations.{Presets, Spec}

  @user %User{id: 1, email: "me@example.com"}

  # A value for each kind of form field, the way someone would fill it in.
  defp value(%{name: "at"}), do: "09:00"
  defp value(%{name: "weekday"}), do: "1"
  defp value(%{name: "kind"}), do: "claude"
  defp value(%{name: "pool"}), do: "default"
  defp value(%{name: "folder"}), do: "Inbox"

  defp value(%{type: type}) do
    case type do
      "column" -> "Doing"
      "tag" -> "bug"
      "flag" -> "blocked"
      "field" -> "priority"
      "priority" -> "high"
      "person" -> "me@example.com"
      "email" -> "me@example.com"
      "number" -> "3"
      "url" -> "https://example.com/hook"
      "card" -> "12"
      "notify" -> "alert"
      "yesno" -> "yes"
      _ -> "Words"
    end
  end

  defp filled(preset, overrides \\ %{}) do
    preset.fields |> Map.new(&{&1.name, value(&1)}) |> Map.merge(overrides)
  end

  defp summary(key, params) do
    {:ok, %{"spec" => spec}} = Presets.build(key, params, user: @user)
    Spec.summary(spec)
  end

  # Every preset, and every preset with a flag field once per flag choice.
  defp every_summary do
    for preset <- Presets.all(),
        params <- variants(preset) do
      {preset.key, summary(preset.key, params)}
    end
  end

  defp variants(preset) do
    case Enum.find(preset.fields, &(&1.type == "flag")) do
      nil -> [filled(preset)]
      field -> for flag <- Presets.flags(), do: filled(preset, %{field.name => flag})
    end
  end

  # "<field> is <value>": a condition field's name read out beside its value.
  @field_value ~r/\b(#{Enum.join(Enum.map(Spec.condition_fields(), &String.replace(&1, "_", "[ _]")), "|")}) (is|is not) (true|false|yes|no)\b/

  test "every ready-made rule reads without field = value phrasing" do
    summaries = every_summary()
    assert length(summaries) > length(Presets.all())

    for {key, text} <- summaries do
      refute text =~ @field_value, "#{key}: #{text}"
      refute text =~ "completed is", "#{key}: #{text}"
      refute text =~ ~r/flag(ged)? (it |as )?flagged/, "#{key}: #{text}"
    end
  end

  test "no ready-made rule's summary names its internal kind" do
    for {key, text} <- every_summary(), kind <- Spec.trigger_types() do
      refute text =~ kind, "#{key} says #{kind}: #{text}"
    end
  end

  test "the open-cards check reads as “still open”" do
    assert summary("stale", filled(Presets.get("stale"))) =~
             "and it is still open, raise an info alert."
  end

  test "the plain flag is “flag it”, and a named one “flag it as …”" do
    preset = Presets.get("review_emailed_cards")
    field = Enum.find(preset.fields, &(&1.type == "flag")).name

    assert summary(preset.key, filled(preset, %{field => "flagged"})) =~ ", flag it."
    assert summary(preset.key, filled(preset, %{field => "waiting"})) =~ ", flag it as waiting."

    flagged = Presets.get("flagged")
    field = Enum.find(flagged.fields, &(&1.type == "flag")).name

    assert summary("flagged", filled(flagged, %{field => "flagged"})) =~
             "When a card is flagged, "

    assert summary("flagged", filled(flagged, %{field => "review"})) =~ "flagged as review"
  end

  defp says(conditions, actions \\ [%{"type" => "complete_card"}]) do
    Spec.summary(%{
      "trigger" => %{"type" => "card_created"},
      "conditions" => conditions,
      "actions" => actions
    })
  end

  test "every yes/no field reads as words, both ways, however the value is written" do
    cases = [
      {"completed", "it is completed", "it is still open"},
      {"archived", "it is archived", "it isn't archived"},
      {"blocked", "it is blocked", "it isn't blocked"},
      {"has_due_date", "it has a due date", "it has no due date"},
      {"has_assignee", "it is assigned to someone", "nobody is assigned to it"},
      {"has_doc", "it has a wiki page", "it has no wiki page"}
    ]

    for {field, yes, no} <- cases, {truthy, falsy} <- [{true, false}, {"true", "false"}] do
      is = &says([%{"field" => field, "op" => &1, "value" => &2}])
      assert is.("is", truthy) =~ "and #{yes},"
      assert is.("is", falsy) =~ "and #{no},"
      assert is.("is_not", truthy) =~ "and #{no},"
      assert is.("is_not", falsy) =~ "and #{yes},"
      assert is.("is_set", nil) =~ "and #{yes},"
      assert is.("is_not_set", nil) =~ "and #{no},"
    end
  end

  test "lists, tags, flags, people and cards read as “it is …”" do
    one = &says([%{"field" => &1, "op" => &2, "value" => &3}])

    assert one.("column", "is", "Doing") =~ "and it is in Doing,"

    assert one.("column", "any_of", ["To Do", "Doing", "Review"]) =~
             "it is in To Do, Doing or Review"

    assert one.("tag", "none_of", ["a", "b"]) =~ "it isn't tagged a or b"
    assert one.("tag", "is_set", nil) =~ "it has a tag"
    assert one.("tag", "is_not_set", nil) =~ "it has no tags"
    assert one.("flag", "is", "waiting") =~ "it is flagged waiting"
    assert one.("flag", "is_not_set", nil) =~ "it has no flags"
    assert one.("assignee", "is", "me@example.com") =~ "it is assigned to me@example.com"
    assert one.("assignee", "is_not_set", nil) =~ "nobody is assigned to it"
    assert one.("card", "any_of", [12, 13]) =~ "it is card #12 or #13"
    assert one.("tag", "contains", "ug") =~ "its tag contains “ug”"
  end

  test "progress and age read as amounts" do
    one = &says([%{"field" => &1, "op" => &2, "value" => &3}])

    assert one.("percent_complete", "gt", 80) =~ "it is more than 80% done"
    assert one.("age_days", "lt", 2) =~ "it is less than 2 days old"
    assert one.("age_days", "gt", 9) =~ "it is more than 9 days old"
    assert one.("health", "is", "late") =~ "its health is late"
    assert one.("start_date", "older_than_days", 4) =~ "its start date is more than 4 days ago"
  end

  test "clearing flags names them plainly" do
    clear = &says([], [%{"type" => "remove_flags", "flags" => &1}])

    assert clear.(["flagged"]) =~ ", clear its flag."
    assert clear.(["blocked"]) =~ ", clear its blocked flag."
    assert clear.(["blocked", "waiting"]) =~ ", clear its blocked and waiting flags."

    assert says([], [%{"type" => "add_flags", "flags" => ["blocked", "waiting"]}]) =~
             ", flag it as blocked and waiting."
  end
end

defmodule Slipdock.Meetings.Describe do
  @moduledoc """
  A finding's effect in plain words — the *becomes →* line of the review,
  and the lines of the commit preview: what committing it would write, and
  where. Never a number standing for confidence.
  """

  alias Slipdock.Meetings.Finding

  @doc "What committing this finding would do, in a sentence."
  def becomes(%Finding{included: false}), do: "nothing — left out"
  def becomes(%Finding{effect: effect}), do: effect_words(effect)

  @doc "An effect map in words."
  def effect_words(%{"type" => "new_card"} = e) do
    [
      "a new card “#{e["title"]}”",
      e["list"] && "in #{e["list"]}",
      e["assignee"] && "for #{e["assignee"]}",
      e["due_date"] && "due #{date(e["due_date"])}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" ")
  end

  def effect_words(%{"type" => "card_change"} = e) do
    changes =
      (e["changes"] || %{})
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Enum.map(fn {field, to} -> "#{field_words(field)} → #{value_words(field, to)}" end)

    parts =
      changes ++
        if(e["comment"], do: ["a comment"], else: []) ++
        if(e["reopen"], do: ["reopened"], else: [])

    "a change to #{e["ref"]} “#{e["card_title"]}”" <>
      if(parts == [], do: "", else: ": " <> Enum.join(parts, "; "))
  end

  def effect_words(%{"type" => "decision_entry"} = e) do
    "an entry on #{e["page"]}" <>
      if(e["supersedes"], do: ", replacing “#{e["supersedes"]}”", else: "")
  end

  def effect_words(_), do: "nothing"

  defp field_words("due_date"), do: "due"
  defp field_words("start_date"), do: "starts"
  defp field_words("assignee_id"), do: "assigned"
  defp field_words("assignee"), do: "assigned"
  defp field_words("list"), do: "list"
  defp field_words("completed"), do: "done"
  defp field_words(other), do: String.replace(other, "_", " ")

  defp value_words(field, to) when field in ["due_date", "start_date"], do: date(to)

  defp value_words("assignee_id", id) when is_integer(id) do
    case Slipdock.Repo.get(Slipdock.Accounts.User, id) do
      nil -> "somebody no longer here"
      user -> user.name || user.email
    end
  end

  defp value_words(_field, true), do: "yes"
  defp value_words(_field, false), do: "no"
  defp value_words(_field, to), do: to_string(to)

  @doc "An ISO date as a person reads it: Fri 9 Oct."
  def date(nil), do: nil

  def date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, d} -> Calendar.strftime(d, "%a %-d %b")
      _ -> iso
    end
  end
end

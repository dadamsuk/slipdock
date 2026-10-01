defmodule Slipdock.QuickAdd.Model do
  @moduledoc """
  Reads one quick add line with a cheap, low-latency model: the header box
  takes plain English ("call the printers about the banners friday, urgent,
  marketing board") and this turns it into the fields of a card.

  `parse/2` is given the line and a catalogue (see
  `Slipdock.QuickAdd.Capture.catalogue/1`) of the boards, lists, tags and
  people the user may pick from, and answers with those names — never ids.
  Matching the names back to rows, and everything that touches the
  database, is `Slipdock.QuickAdd.Capture`'s job.

  Dates come back as the phrase the line used ("friday", "eow", "in 2
  weeks"), not as a date: a cheap model counts days unreliably, and
  `Slipdock.QuickAdd.parse_date/2` already does it exactly.
  """

  alias Slipdock.AI
  alias Slipdock.Boards.Card

  @prompt """
  You turn one line typed into a kanban app's quick add box into a single card. Answer with ONE JSON object and nothing else:

  {"title": "…", "board": "…", "column": "…", "priority": "none|low|medium|high|critical", "flags": ["…"], "tags": ["…"], "assignee": "…", "start": "…", "due": "…"}

  Rules:
  - "title" is required and is the only key you must always return: the line with the parts you lifted out taken away, tidied into a short title in the user's own words. Never invent detail, never pad it out, and keep names, numbers and jargon exactly as typed.
  - Include another key only when the line actually says it. Omit it rather than guess; there is no harm in a card that only has a title.
  - Dates: do NOT work them out — the app does that. Copy the phrase the line uses into "due" (a deadline: "by Friday", "due tomorrow", "for the 3rd") or "start" (when the work begins: "start Monday", "from next week"), rewritten as one of these forms and nothing else: today, tomorrow, yesterday, mon…sun, next mon…next sun, next week, next month, eow, eom, "in 3 days", "in 2 weeks", "in 2 months", "1 oct", "2026-10-01". A line with one date and no word about starting means "due".
  - "board" and "column" must be copied character for character from the BOARDS catalogue below, and the column must be one of that board's own lists. Use them only when the line names one ("on the Marketing board", "straight into Doing"); otherwise leave both out and the default is used.
  - "tags" must come from the chosen board's tags. Leave out anything not listed: tags are never created here.
  - "assignee" only when the line names one of the PEOPLE below, by their name or email ("ask dan to…", "for sam"). A pronoun or a group — "waiting on them", "chase him", "with the team" — names nobody: leave it out.
  - "priority" is how urgent the work is: "urgent", "asap", "!!" are critical; "important" is high; "sometime", "nice to have" are low.
  - "flags" come only from: flagged, blocked, review, waiting, starred. "blocked on X" is blocked; "waiting on X" is waiting; "needs review" is review.
  - Keep leading words like "add", "card", "todo", "remind me to" out of the title only when they are plainly the user addressing the box, not part of the task.
  - The box also takes a typed shorthand, which means exactly the same things: `due: friday` / `by: 1 oct` (due), `start: mon` / `from: next week` (start), `#high` (priority), `#blocked` (flag), `#docs` (a tag), `#to-do` (a list), `@dan` (assignee). Read it the same way and keep it out of the title.
  """

  @doc """
  Turns `text` into `{:ok, map}` with string keys (the shape above), or
  `{:error, message}`. Options are passed to `Slipdock.AI.complete_json/2`.
  """
  def parse(text, catalogue, opts \\ []) do
    messages = [
      %{role: "system", content: @prompt <> "\n\n---\n\n" <> render(catalogue)},
      %{role: "user", content: text}
    ]

    opts =
      [max_tokens: 400, temperature: 0, model: AI.quick_model()]
      |> Keyword.merge(opts)

    with {:ok, json} <- AI.complete_json(messages, opts) do
      case clean(json) do
        %{"title" => title} = card when is_binary(title) -> {:ok, card}
        _ -> {:error, "The model didn't come back with a card."}
      end
    end
  end

  @doc "The catalogue as the few lines of text the model is shown."
  def render(catalogue) do
    """
    TODAY: #{Date.to_iso8601(catalogue.today)} (#{Calendar.strftime(catalogue.today, "%A")})
    DEFAULT: #{default_line(catalogue)}

    BOARDS:
    #{Enum.map_join(catalogue.boards, "\n", &board_line/1)}

    PEOPLE: #{people_line(catalogue.people)}
    """
  end

  defp default_line(%{default_board: nil}), do: "none set"

  defp default_line(%{default_board: board, default_column: column}),
    do: ~s(board "#{board.name}", list "#{column && column.name}")

  defp board_line(%{board: board, columns: columns, tags: tags}) do
    line = ~s(- "#{board.name}" — lists: #{Enum.map_join(columns, ", ", & &1.name)})
    if tags == [], do: line, else: line <> "; tags: " <> Enum.map_join(tags, ", ", & &1.name)
  end

  defp people_line([]), do: "nobody else"

  defp people_line(people) do
    Enum.map_join(people, ", ", fn user ->
      name = Slipdock.Accounts.User.display_name(user)
      if name == user.email, do: user.email, else: "#{name} (#{user.email})"
    end)
  end

  # Cheap models are loose with the schema: drop empty strings, coerce the
  # lists, and keep only keys that could mean something.
  defp clean(json) when is_map(json) do
    %{
      "title" => trimmed(json["title"]),
      "board" => trimmed(json["board"]),
      "column" => trimmed(json["column"] || json["list"]),
      "priority" => priority(trimmed(json["priority"])),
      "assignee" => trimmed(json["assignee"]),
      "start" => trimmed(json["start"] || json["start_date"]),
      "due" => trimmed(json["due"] || json["due_date"]),
      "flags" => json["flags"] |> list() |> Enum.filter(&(&1 in Card.flags())),
      "tags" => list(json["tags"])
    }
    |> Enum.reject(fn {_k, v} -> v in [nil, []] end)
    |> Map.new()
  end

  defp clean(_), do: %{}

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_), do: nil

  defp priority(p) when is_binary(p) do
    p = String.downcase(p)
    if p in Card.priorities(), do: p
  end

  defp priority(_), do: nil

  defp list(values) when is_list(values),
    do: values |> Enum.filter(&is_binary/1) |> Enum.map(&String.downcase(String.trim(&1)))

  defp list(value) when is_binary(value), do: list(String.split(value, ","))
  defp list(_), do: []
end

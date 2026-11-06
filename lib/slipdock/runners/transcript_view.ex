defmodule Slipdock.Runners.TranscriptView do
  @moduledoc """
  A job's live log (#1870) as a person reads it (#1871): one entry per
  message, tool call or tool result, with its time, from the raw Claude Code
  transcript lines `Slipdock.Runners.Transcript.read/2` gives back.

  The card's job panel, the Runners panel, `GET /api/jobs/:id/log` (and so
  `slipdock job-log` and `slipdock job --follow`) and the MCP tool `job_log` all show the
  same entries, so a line reads the same wherever it is watched:

      12:13:07  💬 Reading the card first.
      12:13:09  ▶ Bash: slipdock card 1871
      12:13:10     ↳ #1871 Job logs 2: watch a running job  (+40 lines)

  Each entry keeps the whole of what its line shortens (`detail`): a tool
  call's input, a result's full text, a message's whole text. Lines that are
  neither (hook output, file snapshots, thinking) are left out, and the
  notes the server writes into a log (`slipdock_cut`, `slipdock_capped`)
  read as notes.
  """

  @summary 160

  @typedoc "One line of the log, as shown."
  @type entry :: %{
          id: String.t(),
          line: non_neg_integer(),
          at: DateTime.t() | nil,
          kind: :prompt | :message | :tool | :result | :error | :note,
          text: String.t(),
          detail: String.t() | nil
        }

  @doc """
  The entries in `text` (JSON Lines), the first of its lines being line
  `first` of the log. Each entry's `id` is unique within the log, so a page
  can append them as they come.
  """
  @spec entries(String.t(), non_neg_integer()) :: [entry()]
  def entries(text, first \\ 0) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index(first)
    |> Enum.flat_map(fn {raw, n} ->
      case Jason.decode(raw) do
        {:ok, %{} = line} -> line |> from_line() |> number(n, at(line))
        _ -> []
      end
    end)
  end

  @doc "An entry as one line of text: its time (UTC), a mark for its kind, and what it says."
  @spec format(entry()) :: String.t()
  def format(%{at: at, kind: kind, text: text}) do
    time = if at, do: at |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_string()
    String.pad_trailing(time || "", 8) <> "  " <> mark(kind) <> text
  end

  @doc "The mark that starts an entry of `kind`, as `format/1` writes it."
  def mark(:prompt), do: "▸ "
  def mark(:message), do: "💬 "
  def mark(:tool), do: "▶ "
  def mark(:result), do: "   ↳ "
  def mark(:error), do: "   ✗ "
  def mark(:note), do: "… "

  defp number(entries, n, at) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, i} -> Map.merge(entry, %{id: "#{n}-#{i}", line: n, at: at}) end)
  end

  defp at(%{"timestamp" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp at(_), do: nil

  defp from_line(%{"type" => "slipdock_cut"} = l),
    do: [note("a line of #{l["bytes"]} bytes was left out (over #{l["limit"]})")]

  defp from_line(%{"type" => "slipdock_capped"} = l),
    do: [note("the log reached its limit (#{l["limit"]} bytes): nothing after this is kept")]

  defp from_line(%{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content),
       do: Enum.flat_map(content, &assistant/1)

  defp from_line(%{"type" => "user", "isMeta" => true}), do: []

  defp from_line(%{"type" => "user", "message" => %{"content" => content}})
       when is_binary(content) and content != "",
       do: [entry(:prompt, one(content), content)]

  defp from_line(%{"type" => "user", "message" => %{"content" => content}})
       when is_list(content),
       do: Enum.flat_map(content, &result/1)

  defp from_line(_), do: []

  defp assistant(%{"type" => "text", "text" => text}) when is_binary(text) do
    if String.trim(text) == "", do: [], else: [entry(:message, one(text), text)]
  end

  defp assistant(%{"type" => "tool_use", "name" => name} = use) do
    input = use["input"] || %{}
    [entry(:tool, "#{name}: " <> one(gist(input)), pretty(input))]
  end

  defp assistant(_), do: []

  defp result(%{"type" => "tool_result"} = r) do
    text = result_text(r["content"])
    lines = text |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))
    more = if length(lines) > 1, do: "  (+#{length(lines) - 1} lines)", else: ""
    kind = if r["is_error"] == true, do: :error, else: :result
    [entry(kind, one(List.first(lines) || "") <> more, text)]
  end

  defp result(_), do: []

  defp result_text(text) when is_binary(text), do: text

  defp result_text(parts) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => type} -> "[#{type}]"
      other -> to_string(Jason.encode!(other))
    end)
  end

  defp result_text(nil), do: ""
  defp result_text(other), do: Jason.encode!(other)

  # What a tool call is about, in the words a person would use: the command,
  # the file, the pattern, else its whole input.
  defp gist(input) when is_map(input) do
    Enum.find_value(
      ~w(command description file_path pattern url query prompt skill),
      input,
      &(is_binary(input[&1]) && input[&1])
    )
  end

  defp gist(input), do: input

  # `summary` is already one line; `detail` is kept only when it says more.
  defp entry(kind, summary, detail) do
    %{
      kind: kind,
      text: summary,
      detail: if(is_nil(detail) or detail == summary, do: nil, else: detail)
    }
  end

  defp note(text), do: %{kind: :note, text: text, detail: nil}

  defp one(text) when is_binary(text) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()
    if String.length(text) > @summary, do: String.slice(text, 0, @summary - 1) <> "…", else: text
  end

  defp one(other), do: other |> Jason.encode!() |> one()

  defp pretty(input) when input == %{}, do: nil
  defp pretty(input), do: Jason.encode!(input, pretty: true)
end

defmodule Slipdock.Runners.TranscriptSummary do
  @moduledoc """
  A job's log, summed up (#1877): what the card chat reads first, because a
  log is far too long to hand to a model whole.

  From the raw Claude Code transcript lines (`Slipdock.Runners.Transcript`):

    * `messages` — what the agent said, in order, each with its time and
      its line in the log;
    * where its time went, from the first timestamped line to the last.
      Each stretch between two lines goes to the tool call that was waiting
      for its result, the earliest if several were (`tools`, by kind), or,
      when none was, to the model (`model_seconds`);
    * `longest` — the longest tool calls, each with its line, so the chat
      can fetch that stretch of the log in full;
    * `failed` — the calls that failed, with the first of what they said;
    * `tokens` — the token usage its lines carried (#1954): `input`,
      `output`, `cache_read` and `cache_write`, summed once per assistant
      message (Claude Code repeats a message's `usage` on each of its
      content lines, so the last line of each message counts), or nil when
      no line carried any. Nothing is guessed for a log without it.

  A tool call's kind comes from what it was: a shell command by what it
  runs (`tests`, `checks` for compile, format and lint, `ci` for watching a
  build, `git`, `slipdock`, `reading` for looking at files), and the other
  tools by name (`reading`, `editing`, `subagents`, `other`).
  """

  alias Slipdock.Runners.TranscriptView

  @kinds ~w(tests checks ci git slipdock reading editing subagents shell other)a

  @error_cap 400

  @type t :: %{
          lines: non_neg_integer(),
          from: DateTime.t() | nil,
          to: DateTime.t() | nil,
          seconds: non_neg_integer(),
          model_seconds: non_neg_integer(),
          tool_seconds: non_neg_integer(),
          tools: %{atom() => %{seconds: non_neg_integer(), calls: non_neg_integer()}},
          messages: [map()],
          longest: [map()],
          failed: [map()],
          tokens: tokens() | nil
        }

  @type tokens :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer()
        }

  @doc "The kinds a tool call is put under, in the order they are shown."
  def kinds, do: @kinds

  @doc """
  The summary of `text` (JSON Lines, the log from its first line).
  `:longest` sets how many of the longest calls to keep (5).
  """
  @spec summarise(String.t(), keyword()) :: t()
  def summarise(text, opts \\ []) when is_binary(text) do
    lines = parse(text)
    calls = calls(lines)
    {model_ms, by_call} = split_time(lines, calls)
    time = time(lines, model_ms)

    tools =
      Map.new(@kinds, fn kind ->
        mine = Enum.filter(calls, &(&1.kind == kind))
        ms = mine |> Enum.map(&Map.get(by_call, &1.id, 0)) |> Enum.sum()
        {kind, %{calls: length(mine), seconds: round(ms / 1000)}}
      end)

    Map.merge(time, %{
      lines: length(lines),
      tools: tools,
      tokens: tokens(lines),
      messages: messages(text),
      longest:
        calls
        |> Enum.filter(& &1.seconds)
        |> Enum.sort_by(&(-&1.seconds))
        |> Enum.take(Keyword.get(opts, :longest, 5)),
      failed: Enum.filter(calls, & &1.error)
    })
  end

  @doc """
  What `text` says it spent (#1954), without the rest of the summary:
  `lines`, `model_seconds`, `tool_seconds` (as in `summarise/2`) and
  `tokens` (nil when no line carried `usage`).
  """
  @spec cost(String.t()) :: %{
          lines: non_neg_integer(),
          model_seconds: non_neg_integer(),
          tool_seconds: non_neg_integer(),
          tokens: tokens() | nil
        }
  def cost(text) when is_binary(text) do
    lines = parse(text)
    {model_ms, _by_call} = split_time(lines, calls(lines))
    time = time(lines, model_ms)

    %{
      lines: length(lines),
      model_seconds: time.model_seconds,
      tool_seconds: time.tool_seconds,
      tokens: tokens(lines)
    }
  end

  # From the first timestamped line to the last, split between the model
  # and the tools. The two parts make up the whole: rounding goes to the
  # tools.
  defp time(lines, model_ms) do
    stamps = lines |> Enum.map(& &1.at) |> Enum.reject(&is_nil/1)
    from = List.first(stamps)
    to = List.last(stamps)
    seconds = if from && to, do: round(DateTime.diff(to, from, :millisecond) / 1000), else: 0
    model = min(round(model_ms / 1000), seconds)

    %{from: from, to: to, seconds: seconds, model_seconds: model, tool_seconds: seconds - model}
  end

  ## The lines -------------------------------------------------------------------

  # Each line with its number, time, the tool calls it makes and the
  # results it carries.
  defp parse(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index()
    |> Enum.flat_map(fn {raw, n} ->
      case Jason.decode(raw) do
        {:ok, %{} = line} ->
          [%{n: n, at: at(line), uses: uses(line), results: results(line), usage: usage(line, n)}]

        _ ->
          []
      end
    end)
  end

  defp at(%{"timestamp" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, at, _} -> DateTime.truncate(at, :millisecond)
      _ -> nil
    end
  end

  defp at(_), do: nil

  # The usage an assistant line carries, keyed by its message (or, with no
  # message id, by the line).
  defp usage(%{"type" => "assistant", "message" => %{"usage" => %{} = u} = message}, n) do
    counts = %{
      input: count(u["input_tokens"]),
      output: count(u["output_tokens"]),
      cache_read: count(u["cache_read_input_tokens"]),
      cache_write: count(u["cache_creation_input_tokens"])
    }

    if Enum.any?(Map.values(counts), &(&1 > 0)), do: {message["id"] || {:line, n}, counts}
  end

  defp usage(_line, _n), do: nil

  defp count(n) when is_integer(n) and n > 0, do: n
  defp count(_), do: 0

  # The last usage of each message, summed; nil when no line had any.
  defp tokens(lines) do
    by_message = for %{usage: {id, counts}} <- lines, into: %{}, do: {id, counts}

    if by_message == %{} do
      nil
    else
      Enum.reduce(
        Map.values(by_message),
        %{input: 0, output: 0, cache_read: 0, cache_write: 0},
        &Map.merge(&2, &1, fn _k, a, b -> a + b end)
      )
    end
  end

  defp uses(%{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    for %{"type" => "tool_use", "id" => id, "name" => name} = use <- content,
        do: %{id: id, name: name, input: use["input"] || %{}}
  end

  defp uses(_), do: []

  defp results(%{"type" => "user", "message" => %{"content" => content}})
       when is_list(content) do
    for %{"type" => "tool_result", "tool_use_id" => id} = r <- content,
        do: %{id: id, error: r["is_error"] == true, text: result_text(r["content"])}
  end

  defp results(_), do: []

  defp result_text(text) when is_binary(text), do: text

  defp result_text(parts) when is_list(parts),
    do: Enum.map_join(parts, "\n", &((is_map(&1) && is_binary(&1["text"]) && &1["text"]) || ""))

  defp result_text(_), do: ""

  ## Tool calls ------------------------------------------------------------------

  # Every tool call: where it was made, when it answered, how long that took,
  # its kind and, if it failed, what it said.
  defp calls(lines) do
    answered =
      for line <- lines, r <- line.results, into: %{}, do: {r.id, Map.put(r, :line, line)}

    for line <- lines, use <- line.uses do
      result = answered[use.id]
      ended = result && result.line.at
      seconds = if line.at && ended, do: max(DateTime.diff(ended, line.at), 0)

      %{
        id: use.id,
        name: use.name,
        what: gist(use.input),
        kind: kind(use.name, use.input),
        line: line.n,
        at: line.at,
        result_line: result && result.line.n,
        seconds: seconds,
        error: result && failure(result)
      }
    end
  end

  defp failure(%{error: true, text: text}), do: first_lines(text)

  defp failure(%{text: text}) do
    if Regex.match?(~r/\AExit code [1-9]\d*/, text), do: first_lines(text)
  end

  defp first_lines(text) do
    text = text |> String.trim() |> String.replace(~r/\n{2,}/, "\n")
    if String.length(text) > @error_cap, do: String.slice(text, 0, @error_cap) <> "…", else: text
  end

  defp gist(input) when is_map(input) do
    Enum.find_value(
      ~w(command description file_path pattern url query prompt skill),
      fn key -> is_binary(input[key]) && one(input[key]) end
    ) || one(Jason.encode!(input))
  end

  defp gist(input), do: one(inspect(input))

  defp one(text) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()
    if String.length(text) > 160, do: String.slice(text, 0, 159) <> "…", else: text
  end

  @doc """
  The kind of a tool call named `name` with `input`: one of `kinds/0`.
  """
  def kind(name, input) when name in ["Bash", "BashOutput"],
    do: command_kind(input["command"] || "")

  def kind(name, _input) when name in ["Read", "Grep", "Glob", "LS", "NotebookRead"],
    do: :reading

  def kind(name, _input) when name in ["Edit", "Write", "MultiEdit", "NotebookEdit"],
    do: :editing

  def kind(name, _input) when name in ["Agent", "Task"], do: :subagents
  def kind(_name, _input), do: :other

  # Each step of a command is known by how it starts; a command of several
  # steps is the first of these kinds any step is. Reporting progress
  # (`slipdock job-progress`) and `cd` say nothing about what it was.
  @command_kinds [
    {:tests, ~r/^(mix test|npm (run )?test|npx playwright|pytest|go test|cargo test)\b/},
    {:checks,
     ~r/^(mix (compile|format|credo|pre_push|sobelow|dialyzer|hex\.audit|deps\.audit)|npx (eslint|tsc))\b/},
    {:ci, ~r/^gh (pr checks|run (watch|view|list))\b/},
    {:git, ~r/^(git|gh)\b/},
    {:slipdock, ~r/^slipdock\b/},
    {:reading, ~r/^(cat|sed -n|grep|rg|ls|find|head|tail|wc|less|tree|awk)\b/}
  ]

  defp command_kind(command) do
    steps =
      command
      |> String.replace(~r/"(?:[^"\\]|\\.)*"|'[^']*'/s, "''")
      |> String.split(~r/&&|\|\||;|\||\n|\$\(|`/)
      |> Enum.map(&step_head/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["cd ", "slipdock job-progress"])))

    Enum.find_value(@command_kinds, :shell, fn {kind, re} ->
      Enum.any?(steps, &Regex.match?(re, &1)) && kind
    end)
  end

  # A step without its leading env assignments, `time` or `timeout N`.
  defp step_head(step) do
    step
    |> String.trim()
    |> String.replace(~r/^\(+\s*/, "")
    |> String.replace(~r/^(([A-Z_][A-Z0-9_]*=\S*|time|timeout \d+\w?)\s+)+/, "")
  end

  ## Where the time went ---------------------------------------------------------

  # Walks the timestamped lines in order: each stretch since the line before
  # goes to the earliest tool call still waiting for its answer, else to the
  # model. Answers {model ms, %{call id => ms}}.
  defp split_time(lines, calls) do
    lines = Enum.filter(lines, & &1.at)
    order = calls |> Enum.with_index() |> Map.new(fn {c, i} -> {c.id, i} end)

    {_open, _prev, model, by_call} =
      Enum.reduce(lines, {[], nil, 0, %{}}, &step(&1, &2, order))

    {model, by_call}
  end

  defp step(line, {open, prev, model, by_call}, order) do
    gap = if prev, do: max(DateTime.diff(line.at, prev, :millisecond), 0), else: 0
    {model, by_call} = charge(Enum.min_by(open, &order[&1], fn -> nil end), gap, model, by_call)
    answered = Enum.map(line.results, & &1.id)
    {(open -- answered) ++ Enum.map(line.uses, & &1.id), line.at, model, by_call}
  end

  defp charge(nil, gap, model, by_call), do: {model + gap, by_call}
  defp charge(id, gap, model, by_call), do: {model, Map.update(by_call, id, gap, &(&1 + gap))}

  ## What it said ----------------------------------------------------------------

  defp messages(text) do
    text
    |> TranscriptView.entries()
    |> Enum.filter(&(&1.kind == :message))
    |> Enum.map(&%{line: &1.line, at: &1.at, text: &1.detail || &1.text})
  end
end

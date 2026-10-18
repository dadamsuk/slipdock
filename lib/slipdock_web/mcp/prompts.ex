defmodule SlipdockWeb.MCP.Prompts do
  @moduledoc """
  The prompts `/mcp` offers (`prompts/list`, `prompts/get`), and rendering
  one for a token (W-1805).

  Every rendered prompt has the same frame, so a workflow started from a
  client's menu behaves the way the skills do: the board's conventions
  first, a read-only notice when the token cannot write, the prompt's own
  body with its live context, and the tools to use last. The whole is held
  to about 6k tokens.
  """

  alias SlipdockWeb.MCP.Prompts

  @prompts [
    Prompts.PlanMyDay,
    Prompts.WeeklyReview,
    Prompts.Triage,
    Prompts.Resume,
    Prompts.LeaveHandoff,
    Prompts.CaptureThisChat,
    Prompts.TidyBoard
  ]

  # About 6k tokens, at the usual four characters to one.
  @max_chars 24_000

  @doc "The size cap on a rendered prompt, in characters."
  def max_chars, do: @max_chars

  @doc "Every prompt module offered right now, in the order `prompts/list` gives them."
  def all, do: Enum.filter(@prompts, &available?/1)

  @doc "Every prompt this server has, whether its feature is on or not: what the docs describe."
  def every, do: @prompts

  @doc "The prompt called `name`, or nil — nil too for one not offered right now."
  def find(name), do: Enum.find(all(), &(&1.name() == name))

  defp available?(prompt) do
    Code.ensure_loaded(prompt)
    not function_exported?(prompt, :available?, 0) or prompt.available?()
  end

  @doc "A prompt as `prompts/list` describes it."
  def describe(prompt) do
    %{
      name: prompt.name(),
      title: prompt.title(),
      description: prompt.description(),
      arguments: prompt.arguments()
    }
  end

  @doc """
  Renders `prompt` for the context's token: `{:ok, result}` in the shape
  `prompts/get` answers, or `{:error, message}` for arguments that are
  missing, unknown or not strings, and for whatever `render/2` refuses.
  """
  def get(prompt, args, context) when is_map(args) do
    with :ok <- check_arguments(prompt, args),
         {:ok, body} <- prompt.render(clean(args), context) do
      text = frame(prompt, body, context)

      {:ok,
       %{
         description: prompt.description(),
         messages: [%{role: "user", content: %{type: "text", text: text}}]
       }}
    end
  end

  def get(_prompt, _args, _context), do: {:error, "arguments must be an object"}

  defp check_arguments(prompt, args) do
    declared = prompt.arguments()
    known = Enum.map(declared, & &1.name)

    cond do
      unknown = Enum.find(Map.keys(args), &(&1 not in known)) ->
        takes = if known == [], do: "no arguments", else: "only " <> Enum.join(known, ", ")
        {:error, "#{prompt.name()} has no argument #{inspect(unknown)}; it takes #{takes}"}

      bad = Enum.find(Map.keys(args), &(not is_binary(args[&1]))) ->
        {:error, "argument #{bad} must be a string"}

      missing = Enum.find(declared, &(&1.required and blank?(args[&1.name]))) ->
        {:error, "#{prompt.name()} needs the #{missing.name} argument: #{missing.description}"}

      true ->
        :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""

  # Blank optional arguments are as good as absent; the rest trimmed.
  defp clean(args) do
    for {key, value} <- args, not blank?(value), into: %{}, do: {key, String.trim(value)}
  end

  # The body is what gets cut, so the conventions and the tools to use are
  # always there however long the live context runs.
  defp frame(prompt, body, context) do
    head =
      [
        Prompts.Context.conventions(),
        if(prompt.writes?() and read_only?(context.token),
          do: Prompts.Context.read_only_notice()
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    foot = "Tools to use: " <> Enum.join(prompt.tools(), ", ") <> "."
    room = @max_chars - String.length(head) - String.length(foot) - 4

    Enum.join([head, cap(String.trim(body), room), foot], "\n\n")
  end

  @doc "Whether the token behind a context may only read."
  def read_only?(%{scope: "read"}), do: true
  def read_only?(_), do: false

  @doc """
  `text` held to `room` characters. A prompt cuts its own long lists with
  `Prompts.Context.list/3` first; this is the backstop, and says so.
  """
  def cap(text, room \\ @max_chars) do
    if String.length(text) <= room do
      text
    else
      note = "\n\n…cut at the size cap: use the tools for the rest."
      String.slice(text, 0, max(room - String.length(note), 0)) <> note
    end
  end
end

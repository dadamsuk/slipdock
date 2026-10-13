defmodule SlipdockWeb.MCP.Tools.Ask do
  @moduledoc """
  A question in prose, answered from the boards: `POST /api/ask` as a tool.
  The board assistant searches and reads for itself, on the user's own AI key
  and provider, and the answer comes back with what it read.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "ask"

  @impl true
  def title, do: "Ask"

  @impl true
  def description,
    do:
      "Ask a question in prose and get an answer written from the boards, with the cards and " <>
        "pages it read. Costs a model call on your AI key and can take a while; use search " <>
        "when matches are enough."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        question: %{type: "string", description: "The question, in words."},
        board: %{type: "string", description: "Keep to this board (id, code or name)."}
      },
      required: ["question"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, %{user: user, token: token} = context) do
    with :ok <- whole_account(token),
         {:ok, question} <- Args.required(args, "question"),
         {:ok, board} <- board(args, context),
         {:ok, answer} <- Slipdock.AI.Researcher.ask(user, [], question, board: board) do
      {:ok,
       %{
         question: question,
         answer: answer.reply,
         sources: Enum.map(answer.sources, &source(&1, context.base_url))
       }}
    end
  end

  # As /api/ask: the assistant reads with tools scoped to the user, not the
  # token, so a token confined to some boards would get an answer drawn from
  # the rest. Refused rather than half-kept (#338).
  defp whole_account(%{scope_boards: [_ | _]}),
    do:
      {:error,
       "this API token's scope doesn't allow it: ask reads across every board, " <>
         "and this token is confined to some (use search, or an unscoped token)"}

  defp whole_account(_token), do: :ok

  defp board(args, context) do
    with {:ok, ref} when is_binary(ref) <- Args.optional(args, "board") do
      Args.refusal(SlipdockWeb.API.Authorize.fetch_board(Args.auth(context), ref, :read))
    end
  end

  defp source(%{page: page}, base),
    do: %{
      kind: "page",
      id: page.id,
      code: page.code,
      title: page.title,
      url: base <> "/boards/#{page.board_id}/wiki/#{page.slug}"
    }

  defp source(%{card: card}, base),
    do: %{
      kind: "card",
      id: card.id,
      title: card.title,
      url: base <> "/boards/#{card.board_id}/cards/#{card.id}"
    }
end

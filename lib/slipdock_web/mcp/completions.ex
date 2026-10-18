defmodule SlipdockWeb.MCP.Completions do
  @moduledoc """
  `completion/complete` for prompt arguments (W-1805): what a client offers
  while the person types one. A `board` argument completes the codes of the
  boards the token can see; a `card` argument completes `#id title`, on the
  board already chosen for the prompt when there is one, else on every board
  the token sees. Other arguments, and resource templates, have nothing to
  offer.

  The same access checks as the tools, so nothing the token can't read is
  ever suggested.
  """

  import Ecto.Query

  alias Slipdock.{Access, Repo}
  alias Slipdock.Boards.{Board, Card}
  alias SlipdockWeb.MCP.Prompts
  alias SlipdockWeb.MCP.Prompts.Context

  # The protocol's cap on values in one answer.
  @max 100

  @doc """
  The completion for `params` (the request's), or `{:error, message}` for a
  reference to a prompt that isn't there.
  """
  def complete(%{"ref" => %{"type" => "ref/prompt", "name" => name}} = params, context)
      when is_binary(name) do
    with prompt when not is_nil(prompt) <- Prompts.find(name),
         %{"name" => arg} <- params["argument"],
         true <- Enum.any?(prompt.arguments(), &(&1.name == arg)) do
      value = params["argument"]["value"]
      value = if is_binary(value), do: String.trim(value), else: ""
      chosen = get_in(params, ["context", "arguments"]) || %{}
      {:ok, answer(suggest(arg, value, chosen, context))}
    else
      nil -> {:error, "unknown prompt: #{name}"}
      _ -> {:ok, answer([])}
    end
  end

  def complete(%{"ref" => %{"type" => "ref/resource"}}, _context), do: {:ok, answer([])}
  def complete(_params, _context), do: {:error, "completion/complete needs a ref and an argument"}

  defp answer(values) do
    shown = Enum.take(values, @max)
    %{completion: %{values: shown, total: length(values), hasMore: length(values) > @max}}
  end

  @doc """
  What to suggest for the argument `arg` as typed so far (`value`), given the
  arguments already `chosen`: board codes for `board`, `#id title` for
  `card`, nothing for the rest.
  """
  def suggest(arg, value, chosen, context)

  def suggest("board", value, _chosen, context) do
    prefix = String.downcase(value)

    context
    |> Context.boards()
    |> Enum.filter(fn b ->
      String.starts_with?(String.downcase(b.code || ""), prefix) or
        String.starts_with?(String.downcase(b.name), prefix)
    end)
    |> Enum.map(& &1.code)
  end

  def suggest("card", value, chosen, context) do
    roots =
      case chosen["board"] do
        ref when is_binary(ref) and ref != "" ->
          case Context.board(context, ref) do
            {:ok, board} -> {:board, board.id}
            _ -> {:roots, []}
          end

        _ ->
          {:roots, context |> Context.boards() |> Enum.map(& &1.id)}
      end

    roots
    |> card_query(String.trim_leading(value, "#"))
    |> Repo.all()
    |> then(&Access.filter_readable_cards(context.user, &1))
    |> Enum.map(&"##{&1.id} #{&1.title}")
  end

  def suggest(_arg, _value, _chosen, _context), do: []

  defp card_query(where, typed) do
    base =
      from(c in Card,
        join: b in Board,
        on: b.id == c.board_id,
        where: is_nil(c.archived_at) and not c.completed,
        order_by: [desc: c.updated_at, desc: c.id],
        limit: ^(@max + 1),
        preload: [board: b]
      )

    base =
      case where do
        # The board and, for a top-level one, its sub-boards.
        {:board, id} -> where(base, [c, b], b.id == ^id or b.root_id == ^id)
        {:roots, ids} -> where(base, [c, b], coalesce(b.root_id, b.id) in ^ids)
      end

    case Integer.parse(typed) do
      {_, ""} -> where(base, [c], like(fragment("CAST(? AS text)", c.id), ^(typed <> "%")))
      _ when typed == "" -> base
      _ -> where(base, [c], ilike(c.title, ^("%" <> escape(typed) <> "%")))
    end
  end

  defp escape(text), do: String.replace(text, ~r/([\\%_])/, "\\\\\\1")
end

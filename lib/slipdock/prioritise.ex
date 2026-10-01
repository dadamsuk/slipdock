defmodule Slipdock.Prioritise do
  @moduledoc """
  The prioritise view: the cards a view selects, ranked, with everything
  that feeds a ranking editable in place — priority, votes and the board's
  scoring fields (RICE, ICE, value ÷ effort or custom formulas).

  Filtering comes from the shared view config (through `Slipdock.Table.rows/3`);
  the ranking follows the config's sort, except that the default "board
  order" means *auto*: by the first formula's score, else by votes, highest
  first.
  """

  alias Slipdock.{Fields, Table, Votes}
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Swimlanes.Config

  @doc """
  Builds the view for `user`. Returns a map with:

    * `:entries` – `%{card, rank, score, mine}` in ranked order
    * `:inputs` / `:formulas` – the board's fields split by kind
    * `:rank` – `%{key, label, dir, auto?}` describing the ranking
    * `:votes` – `%{budget, max, spent, left}` for `user`
    * `:shown` / `:hidden` – filter counts
  """
  def build(board, %Config{} = config, user, today \\ Date.utc_today()) do
    rows = Table.rows(board, %{config | rows: "none"}, today)
    cards = Enum.flat_map(rows.groups, & &1.cards)
    fields = Map.get(board, :fields) || []
    {inputs, formulas} = Enum.split_with(fields, &(&1.kind != "formula"))

    rank = rank(config, board, formulas)
    score = scorer(rank, board)

    cards =
      if rank.auto?,
        do: sort_desc(cards, score),
        else: cards

    entries =
      cards
      |> Enum.with_index(1)
      |> Enum.map(fn {card, i} ->
        %{card: card, rank: i, score: score.(card), mine: Votes.mine(card, user)}
      end)

    {budget, max} = Votes.budget(board)
    spent = if user, do: Votes.spent(user, Board.root_id(board)), else: 0

    %{
      entries: entries,
      inputs: inputs,
      formulas: formulas,
      rank: rank,
      votes: %{budget: budget, max: max, spent: spent, left: max(budget - spent, 0)},
      shown: rows.shown,
      hidden: rows.hidden
    }
  end

  # What the list is ranked by.
  defp rank(%Config{sort: "position"}, _board, [formula | _]),
    do: %{key: "f:#{formula.id}", label: formula.name, dir: "desc", auto?: true}

  defp rank(%Config{sort: "position"}, _board, []),
    do: %{key: "votes", label: "Votes", dir: "desc", auto?: true}

  defp rank(%Config{sort: sort, dir: dir}, board, _formulas) do
    label =
      case Config.custom_field(sort, board) do
        nil -> Config.sorts(board) |> List.keyfind(sort, 0, {sort, sort}) |> elem(1)
        field -> field.name
      end

    %{key: sort, label: label, dir: dir, auto?: false}
  end

  # The number a card is ranked by under `rank` (nil when it has none).
  defp scorer(%{key: "votes"}, _board), do: &Card.vote_total/1

  defp scorer(%{key: key}, board) do
    case Config.custom_field(key, board) do
      nil -> fn _ -> nil end
      field -> &Fields.numeric(&1, field)
    end
  end

  # Highest first, cards without a score last, ties in board order.
  defp sort_desc(cards, score) do
    cards
    |> Enum.with_index()
    |> Enum.sort_by(fn {card, i} ->
      case score.(card) do
        nil -> {1, 0, i}
        n -> {0, -n, i}
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end
end

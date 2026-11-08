defmodule Slipdock.Work.Tree do
  @moduledoc """
  What in a board's tree is waiting on one person (#2095), for the places
  they look from the top: an epic's tile and glance line, the board's
  header, `slipdock card` / `slipdock board`, and `waiting_on_me` in the
  REST API and MCP.

  One source: the items are `Slipdock.Work.waiting/2`'s, worked out once
  for the board's tree, so My work, the tile and every door agree. Each is
  put under the card on this board it sits beneath (`by_card`): an epic
  counts what is in its sub-board's tree, never itself, since a wait on the
  epic already shows on its own tile.

  Beside them, `others`: the open waits in the tree addressed to someone
  else by name. They show in the glance line only (`and 1 on someone
  else`), never in the count, so the count means "you, now".
  """

  import Ecto.Query

  alias Slipdock.{Access, Boards, Repo, Work}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Wait}

  defstruct count: 0, items: [], others: [], by_card: %{}

  @type t :: %__MODULE__{
          count: non_neg_integer(),
          items: [map()],
          others: [Wait.t()],
          by_card: %{optional(integer()) => %{mine: [map()], others: [Wait.t()]}}
        }

  @doc """
  The tree under `board` for `user`: `count` and `items` are everything in
  it on them (the board's own cards too, for the header); `others` the
  waits on other people; `by_card` both, under each card on `board` whose
  sub-board holds them. Options pass on to `Work.waiting/2` (`:now`).
  """
  def for_board(user, board, opts \\ [])
  def for_board(nil, _board, _opts), do: %__MODULE__{}

  def for_board(%User{} = user, %Board{} = board, opts) do
    items =
      Work.waiting(
        user,
        Keyword.merge(opts, board_id: board.id, roots: [Board.root_id(board)], paths: false)
      ).items

    others = others(user, board)

    by_card =
      Enum.reduce(items, %{}, &file(&2, top(&1.card, board), :mine, &1))
      |> then(fn acc -> Enum.reduce(others, acc, &file(&2, top(&1.card, board), :others, &1)) end)
      |> Map.new(fn {id, m} ->
        {id, %{mine: Enum.reverse(m.mine), others: Enum.reverse(m.others)}}
      end)

    %__MODULE__{count: length(items), items: items, others: others, by_card: by_card}
  end

  @doc """
  An epic's own tree: what `for_board/3` finds on `card`'s sub-board, or
  nothing for a card without one.
  """
  def for_card(user, card, opts \\ [])

  def for_card(%User{} = user, %Card{} = card, opts) do
    case Repo.get_by(Board, parent_card_id: card.id) do
      nil -> %__MODULE__{}
      sub -> for_board(user, sub, opts)
    end
  end

  def for_card(_user, _card, _opts), do: %__MODULE__{}

  @doc "`by_card`'s entry for one card: `%{mine: [], others: []}` when it has none."
  def of(%__MODULE__{by_card: by_card}, card_id),
    do: Map.get(by_card, card_id, %{mine: [], others: []})

  @doc """
  The card ids on the board a filter on "waiting on me" keeps: each card
  with an item on me under it, and the board's own cards with one.
  """
  def card_ids(%__MODULE__{items: items, by_card: by_card}, %Board{id: board_id}) do
    own = for %{card: %{board_id: ^board_id, id: id}} <- items, do: id
    under = for {id, %{mine: [_ | _]}} <- by_card, do: id
    MapSet.new(own ++ under)
  end

  @doc """
  An item's reason in a few words, for the glance line: `a question`,
  `3 rejections`, `a failed job`.
  """
  def short(%{reason: "circling", card: card}), do: rejections(card)

  def short(%{reason: "wait", wait: %Wait{purpose: "verify_limit"}, card: card}),
    do: rejections(card)

  def short(%{reason: "wait"}), do: "a question"
  def short(%{reason: "wait_anyone"}), do: "a question for anyone"
  def short(%{reason: "overseer"}), do: "the overseer"
  def short(%{reason: "verify"}), do: "to verify"
  def short(%{reason: "review"}), do: "flagged review"
  def short(%{reason: "waiting"}), do: "flagged waiting"
  def short(%{reason: "gave_up"}), do: "the runner gave up"
  def short(%{reason: "failed", job: %{status: "timeout"}}), do: "a job timed out"
  def short(%{reason: "failed"}), do: "a failed job"
  def short(%{reason: "needs_owner"}), do: "nobody on it"
  def short(%{reason: reason}), do: reason

  defp rejections(%Card{verify_rejections: n}) when is_integer(n) and n > 0,
    do: "#{n} #{if n == 1, do: "rejection", else: "rejections"}"

  defp rejections(_card), do: "past the rejection limit"

  @doc """
  The glance line for one card's entry (`of/2`), or nil when nothing waits:
  `Waiting on you: #2063 (a question), #2075 (3 rejections) and 1 on
  someone else`. With nothing on me, `Waiting on someone else: 1`.
  """
  def glance(%{mine: [], others: []}), do: nil

  def glance(%{mine: [], others: others}), do: "Waiting on someone else: #{length(others)}"

  def glance(%{mine: mine, others: others}) do
    named = Enum.map_join(mine, ", ", &"##{&1.card.id} (#{short(&1)})")

    case others do
      [] -> "Waiting on you: " <> named
      _ -> "Waiting on you: #{named} and #{length(others)} on someone else"
    end
  end

  # Open waits in the tree addressed by name to anyone but `user`, on live
  # cards `user` may read, each with its card (and the card's board).
  defp others(user, board) do
    root = Board.root_id(board)

    waits =
      from(w in Wait,
        join: c in Card,
        on: c.id == w.card_id,
        join: b in Board,
        on: b.id == c.board_id,
        where: b.id == ^root or b.root_id == ^root,
        where: is_nil(w.closed_at) and not is_nil(w.on_user_id) and w.on_user_id != ^user.id,
        where: is_nil(c.archived_at) and not c.completed and is_nil(b.archived_at),
        preload: [:on_user, card: :board]
      )
      |> Repo.all()

    readable =
      user
      |> Access.filter_readable_cards(Enum.map(waits, & &1.card))
      |> MapSet.new(& &1.id)

    Enum.filter(waits, &(MapSet.member?(readable, &1.card_id) and under?(&1.card, board)))
  end

  defp under?(%Card{board_id: id}, %Board{id: id}), do: true
  defp under?(card, board), do: top(card, board) != nil

  # The card on `board` that `card` sits beneath, the card itself when it
  # is on `board`, or nil when it is elsewhere.
  defp top(%Card{board_id: id} = card, %Board{id: id}), do: {:self, card.id}

  defp top(%Card{board: %Board{} = cb}, board) do
    case Enum.find(Boards.ancestry(cb), &(&1.board.id == board.id)) do
      %{card: c} -> c.id
      nil -> nil
    end
  end

  defp file(acc, nil, _key, _x), do: acc
  # A card's own items count on the header, not on its tile.
  defp file(acc, {:self, _id}, _key, _x), do: acc

  defp file(acc, id, key, x) do
    acc
    |> Map.put_new(id, %{mine: [], others: []})
    |> update_in([id, key], &[x | &1])
  end
end

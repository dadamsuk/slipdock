defmodule Slipdock.Boards.Links do
  @moduledoc """
  Links between cards (relates, duplicates and the like), and finding a card
  by its reference or title, on one board or across a person's boards.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.CardLink
  alias Slipdock.Repo

  @card_link ~r"^(?:https?://[^/\s]+)?/boards/\d+/(?:[a-z]+/)?cards/(\d{1,18})(?:[/?#]\S*)?$"

  ## Links

  @doc """
  Links `from` to `to` with `kind` (see `Slipdock.Boards.CardLink`). Cards may
  be on any boards. A "relates" link is symmetric, so one in either
  direction is enough.
  """
  def add_link(%Card{} = from, %Card{} = to, kind) when is_binary(kind) do
    cond do
      from.id == to.id ->
        {:error, "A card can't link to itself."}

      not Enum.member?(CardLink.kind_keys(), kind) ->
        {:error, "Unknown link kind."}

      kind == "relates" and link_exists?(to.id, from.id, kind) ->
        {:error, "Those cards are already related."}

      link_exists?(from.id, to.id, kind) ->
        {:error, "That link already exists."}

      true ->
        insert_link(from, to, kind)
    end
  end

  defp insert_link(from, to, kind) do
    %CardLink{from_id: from.id, to_id: to.id}
    |> CardLink.changeset(%{"kind" => kind})
    |> Repo.insert()
    |> case do
      {:ok, link} ->
        Boards.ActivityLog.log(
          Repo,
          from.board_id,
          from.id,
          "link",
          "linked “#{from.title}” — #{String.downcase(CardLink.label(kind, :out))} “#{to.title}”"
        )

        Boards.PubSub.broadcast(from.board_id)
        if to.board_id != from.board_id, do: Boards.PubSub.broadcast(to.board_id)
        {:ok, link}

      {:error, _} ->
        {:error, "Couldn't add that link."}
    end
  end

  defp link_exists?(from_id, to_id, kind) do
    Repo.exists?(
      from(l in CardLink, where: l.from_id == ^from_id and l.to_id == ^to_id and l.kind == ^kind)
    )
  end

  def get_link!(id), do: CardLink |> Repo.get!(id) |> Repo.preload([:from, :to])

  def remove_link(%CardLink{} = link) do
    link = Repo.preload(link, [:from, :to])

    Repo.delete(link)
    |> Boards.Shared.tap_ok(fn _ ->
      Boards.ActivityLog.log(
        Repo,
        link.from.board_id,
        link.from_id,
        "link",
        "unlinked “#{link.from.title}” from “#{link.to.title}”"
      )

      Boards.PubSub.broadcast(link.from.board_id)
      if link.to.board_id != link.from.board_id, do: Boards.PubSub.broadcast(link.to.board_id)
    end)
  end

  @doc """
  Active cards whose title matches `q` on any board of the trees rooted at
  `root_ids`, excluding `except` ids, with their board.
  """
  def search_cards_across(root_ids, q, except \\ [], limit \\ 8) when is_list(root_ids) do
    like = "%#{String.replace(q, ["%", "_"], &"\\#{&1}")}%"

    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where: (b.id in ^root_ids or b.root_id in ^root_ids) and is_nil(c.archived_at),
      where: is_nil(c.stand_in_for_id),
      where: ilike(c.title, ^like) and c.id not in ^except,
      order_by: [asc: c.title],
      limit: ^limit,
      preload: [board: b]
    )
    |> Repo.all()
  end

  @doc """
  The card id a typed reference names, or nil: an id (`123`, `#123`) or a
  card's link, whole or just its path, in any of the board's views
  (`https://…/boards/3/cards/123`, `/boards/3/table/cards/123?at=…`).
  """
  def card_ref(q) when is_binary(q) do
    q = String.trim(q)

    case Regex.run(~r/^#?\s*(\d{1,18})$/, q) ||
           Regex.run(@card_link, q) do
      [_, digits] -> String.to_integer(digits)
      _ -> nil
    end
  end

  def card_ref(_q), do: nil

  @doc """
  The live card a typed reference names (`card_ref/1`) in `board`'s tree but
  not on `board` itself, if `user` may read it, or nil: what a board's search
  box offers under the toolbar (#2097), since the filter already shows a card
  on the board.
  """
  def card_elsewhere_in_tree(user, %Board{} = board, q) when is_binary(q) do
    with %Card{} = card <- card_by_ref_across([Board.root_id(board)], q),
         false <- card.board_id == board.id,
         true <- Slipdock.Access.can_read?(Slipdock.Access.card_permission(user, card)) do
      card
    else
      _ -> nil
    end
  end

  def card_elsewhere_in_tree(_user, _board, _q), do: nil

  @doc """
  The card a typed reference names (see `card_ref/1`), if it is a card on one
  of the board trees rooted at `root_ids` — what the card finder (`Ctrl-O`)
  offers ahead of title matches. Naming a card is asking for it, so an
  archived card is found too with `archived: true`. Anything else typed, a
  stand-in and a card outside those boards all give `nil`.
  """
  def card_by_ref_across(root_ids, q, opts \\ []) when is_list(root_ids) and is_binary(q) do
    case card_ref(q) do
      nil ->
        nil

      id ->
        from(c in Card,
          join: b in Board,
          on: b.id == c.board_id,
          where: c.id == ^id,
          where: b.id in ^root_ids or b.root_id in ^root_ids,
          where: is_nil(c.stand_in_for_id),
          preload: [board: b]
        )
        |> then(&if(opts[:archived], do: &1, else: where(&1, [c], is_nil(c.archived_at))))
        |> Repo.one()
    end
  end

  @doc "Active cards on the board whose title matches `q`, excluding `except` ids."
  def search_cards(board_id, q, except \\ [], limit \\ 8) do
    like = "%" <> String.downcase(String.trim(q)) <> "%"

    from(c in Card,
      where: c.board_id == ^board_id and is_nil(c.archived_at) and c.id not in ^except,
      where: is_nil(c.stand_in_for_id),
      where: like(fragment("lower(?)", c.title), ^like),
      order_by: [asc: c.completed, asc: c.title],
      limit: ^limit,
      select: [:id, :title, :completed, :column_id]
    )
    |> Repo.all()
  end
end

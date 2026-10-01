defmodule Slipdock.Votes do
  @moduledoc """
  Budget voting: every person has `vote_budget` votes to spend across a
  board tree, at most `vote_max` on any one card (both set on the root
  board). A card's vote total is a prioritisation signal on its own, a
  table column, a sort, and `{votes}` in formulas.

  A wiki page can be voted on too, out of the same budget — "which of these
  specs should we write first" is the same question as "which of these cards
  should we do first", and a page on the board is competing with the cards
  for the same attention.
  """

  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, Owned, Vote}
  alias Slipdock.Repo
  alias Slipdock.Wiki.Page

  @doc "The tree's `{budget, max_per_card}`, read from its root board."
  def budget(%Board{} = board) do
    root =
      if Board.root_id(board) == board.id, do: board, else: Repo.get!(Board, Board.root_id(board))

    {root.vote_budget, root.vote_max}
  end

  @doc """
  The votes `user` has spent across the tree rooted at `root_id` — on its
  cards and on its pages, which come out of the one budget.
  """
  def spent(%User{id: user_id}, root_id) do
    on_cards =
      Repo.one(
        from(v in Vote,
          join: c in Card,
          on: c.id == v.card_id,
          join: b in Board,
          on: b.id == c.board_id,
          where: v.user_id == ^user_id and (b.id == ^root_id or b.root_id == ^root_id),
          select: coalesce(sum(v.count), 0)
        )
      )

    on_pages =
      Repo.one(
        from(v in Vote,
          join: p in Page,
          on: p.id == v.page_id,
          join: b in Board,
          on: b.id == p.board_id,
          where: v.user_id == ^user_id and (b.id == ^root_id or b.root_id == ^root_id),
          select: coalesce(sum(v.count), 0)
        )
      )

    on_cards + on_pages
  end

  @doc "How many votes `user` has on a card or a page (0 when none)."
  def mine(%{votes: votes}, %User{id: user_id}) when is_list(votes) do
    case Enum.find(votes, &(&1.user_id == user_id)) do
      nil -> 0
      v -> v.count
    end
  end

  def mine(_, _), do: 0

  @doc """
  Sets `user`'s votes on a card or a page to `count` (0 removes them), within
  the tree's budget rules. Returns `{:ok, reloaded}`, `{:error, message}`.
  """
  def set(owner, %User{} = user, count, comment \\ nil) when is_integer(count) do
    root_id = Boards.root_of_board(owner.board_id)
    root = Repo.get!(Board, root_id)
    current = mine(Repo.preload(owner, :votes, force: true), user)
    spent = spent(user, root_id) - current

    cond do
      count < 0 ->
        {:error, "Votes can't be negative."}

      count > root.vote_max ->
        {:error, "At most #{root.vote_max} #{plural(root.vote_max)} per card."}

      spent + count > root.vote_budget ->
        left = max(root.vote_budget - spent, 0)
        {:error, "You have #{left} #{plural(left)} left on this board."}

      count == 0 ->
        Vote
        |> where(^owner_clause(owner))
        |> where([v], v.user_id == ^user.id)
        |> Repo.delete_all()

        done(owner, user, count)

      true ->
        %Vote{user_id: user.id}
        |> struct!(Owned.owner_key(owner))
        |> Vote.changeset(%{"count" => count, "comment" => comment})
        |> Repo.insert(
          on_conflict: {:replace, [:count, :comment, :updated_at]},
          conflict_target: conflict_target(owner)
        )
        |> case do
          {:ok, _} -> done(owner, user, count)
          {:error, _} -> {:error, "Couldn't save your vote."}
        end
    end
  end

  defp owner_clause(%Page{id: id}), do: dynamic([v], v.page_id == ^id)
  defp owner_clause(%{id: id}), do: dynamic([v], v.card_id == ^id)

  defp conflict_target(%Page{}), do: [:page_id, :user_id]
  defp conflict_target(_), do: [:card_id, :user_id]

  defp done(owner, user, count) do
    message = "#{User.display_name(user)} put #{count} #{plural(count)} on “#{owner.title}”"
    Boards.log_activity_for(owner, "vote", message)
    Boards.broadcast_tree(Boards.root_of_board(owner.board_id))
    reload(owner)
  end

  defp reload(%Page{id: id}), do: {:ok, Slipdock.Wiki.get_page!(id)}
  defp reload(%Card{id: id}), do: {:ok, Boards.get_card!(id)}

  defp plural(1), do: "vote"
  defp plural(_), do: "votes"
end

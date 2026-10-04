defmodule SlipdockWeb.BoardLive.Items do
  @moduledoc """
  Finding the things a board's panels act on, and the gate on who a form may
  put on one. Shared by the board LiveView and its card and page panels, so
  each can check for itself that what it was handed belongs to the board.
  """

  alias Slipdock.{Access, Boards, Swimlanes, Wiki}

  @doc "The live (unarchived) card `card_id`, if it is on `board`."
  def load_card(board, card_id) do
    card = Boards.get_card!(card_id)
    if card.board_id == board.id and is_nil(card.archived_at), do: {:ok, card}, else: :error
  rescue
    Ecto.NoResultsError -> :error
  end

  @doc "The wiki page `page_id`, if it is placed on `board`, ready to draw."
  def load_placed_page(board, page_id) do
    case Wiki.find_page(page_id) do
      {:ok, %Slipdock.Wiki.Page{board_id: board_id, archived_at: nil} = page}
      when board_id == board.id ->
        {:ok, Slipdock.Wiki.Page.for_board(Slipdock.Repo.preload(page, Wiki.board_preloads()))}

      _ ->
        :error
    end
  end

  @doc """
  The ids a form posts are the browser's to choose, so whoever they name
  goes through the same gate as the API (`Boards.resolve_assignees/3`):
  somebody this user can see, who can open `target`.
  """
  def scope_assignees(params, target, user) do
    Enum.reduce_while(~w(assignee_id add_assignee_ids), {:ok, params}, fn key, {:ok, acc} ->
      refs = acc |> Map.get(key) |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))

      case refs != [] && Boards.resolve_assignees(target, user, refs) do
        false -> {:cont, {:ok, acc}}
        {:ok, ids} when key == "assignee_id" -> {:cont, {:ok, Map.put(acc, key, hd(ids))}}
        {:ok, ids} -> {:cont, {:ok, Map.put(acc, key, ids)}}
        {:error, _} -> {:halt, :error}
      end
    end)
  end

  @doc """
  Whether `user` may read and write `card`, as `{readable, writable}`. With
  view-only access to the board (`view_only`), only cards the saved view
  `view` shows are there at all, and the view's own grant says whether they
  can be changed; `config` is that view's configuration as on screen.
  """
  def card_access(card, user, view_only, config, view) do
    if view_only do
      matches = Swimlanes.matches?(card, config)
      level = if view, do: Access.view_permission(user, view), else: :none
      {matches, matches and Access.can_write?(level)}
    else
      perm = Access.card_permission(user, card)
      {Access.can_read?(perm), Access.can_write?(perm)}
    end
  end
end

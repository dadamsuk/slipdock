defmodule SlipdockWeb.API.Authorize do
  @moduledoc """
  Permission checks for API actions; results feed the fallback controller.

  Two things decide the answer: what the user may do (`Slipdock.Access`), and
  what the API token they presented is scoped to. The token can only ever
  narrow the user's own permission — never widen it — and when it is the token
  that refused, the message says so. A scoped token that reported "you don't
  edit this card" would send somebody hunting a permission problem that is not
  there.
  """
  alias Slipdock.Access

  @doc """
  The board `ref` names, if the user can at least read it, and if they — and
  their token — have `need` on it. A board they cannot read is a 404 like one
  that does not exist (see `Slipdock.Access.find_board/2`); one they can read
  but not `need` is a 403 that says why.
  """
  def fetch_board(conn, ref, need) do
    case Access.find_board(conn.assigns.current_user, to_string(ref || "")) do
      {:ok, board} -> with :ok <- board(conn, board, need), do: {:ok, board}
      {:error, :not_found} -> {:error, :not_found, "board"}
    end
  end

  def board(conn, board, need) do
    conn
    |> level(Access.board_permission(conn.assigns.current_user, board), board.id)
    |> check(need, "board")
  end

  @doc """
  The root of `board`'s tree, if this request has `need` on it as well as on
  `board` (#2068). For what a sub-board answers with its root's (the
  overseer): reading the sub-board is not reading the root, whose cards and
  sibling sub-boards it names.
  """
  def tree_root(_conn, %Slipdock.Boards.Board{root_id: nil} = board, _need), do: {:ok, board}

  def tree_root(conn, %Slipdock.Boards.Board{root_id: id}, need) do
    root = Slipdock.Repo.get!(Slipdock.Boards.Board, id)

    case board(conn, root, need) do
      :ok ->
        {:ok, root}

      {:error, :forbidden, _} ->
        {:error, :forbidden,
         "this board's overseer is its tree's root board's, which you can't #{verb(need)}"}
    end
  end

  defp verb(:read), do: "read"
  defp verb(:comment), do: "comment on"
  defp verb(:write), do: "edit"
  defp verb(:owner), do: "own"

  def card(conn, card, need) do
    conn
    |> level(Access.card_permission(conn.assigns.current_user, card), card.board_id)
    |> check(need, "card")
  end

  def page(conn, page, need) do
    conn
    |> level(Access.page_permission(conn.assigns.current_user, page), page.board_id)
    |> check(need, "page")
  end

  def folder(conn, folder, need) do
    conn
    |> level(Access.folder_permission(conn.assigns.current_user, folder), folder.board_id)
    |> check(need, "folder")
  end

  @doc """
  `subject` (a card, a list of cards, or a board) with the cards at the far
  end of its dependencies that this request can't read hidden — see
  `Slipdock.Access.hide_unreadable_dependencies/3`. Pass anything rendered
  with dependencies through it.
  """
  def visible(conn, subject),
    do:
      Access.hide_unreadable_dependencies(
        conn.assigns.current_user,
        subject,
        conn.assigns[:api_token]
      )

  defp level(conn, level, board_id),
    do: Access.narrow(level, conn.assigns[:api_token], board_id)

  defp check({level, why}, :read, what),
    do: if(Access.can_read?(level), do: :ok, else: forbidden(what, "read", why))

  # A commenter (#863) joins the discussion without editing the thing itself.
  defp check({level, why}, :comment, what),
    do: if(Access.can_comment?(level), do: :ok, else: forbidden(what, "comment on", why))

  defp check({level, why}, :write, what),
    do: if(Access.can_write?(level), do: :ok, else: forbidden(what, "edit", why))

  defp check({level, why}, :owner, what),
    do: if(Access.owner?(level), do: :ok, else: forbidden(what, "own", why))

  defp forbidden(what, verb, :scope),
    do:
      {:error, :forbidden,
       "this API token's scope doesn't allow it to #{verb} this #{what} " <>
         "(see Account → API tokens)"}

  defp forbidden(what, verb, _), do: {:error, :forbidden, "you don't #{verb} this #{what}"}
end

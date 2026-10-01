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

  def board(conn, board, need) do
    conn
    |> level(Access.board_permission(conn.assigns.current_user, board), board.id)
    |> check(need, "board")
  end

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

  defp level(conn, level, board_id),
    do: Access.narrow(level, conn.assigns[:api_token], board_id)

  defp check({level, why}, :read, what),
    do: if(Access.can_read?(level), do: :ok, else: forbidden(what, "read", why))

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

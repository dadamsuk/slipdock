defmodule SlipdockWeb.API.Authorize do
  @moduledoc "Permission checks for API actions; results feed the fallback controller."
  alias Slipdock.Access

  def board(conn, board, need) do
    check(Access.board_permission(conn.assigns.current_user, board), need, "board")
  end

  def card(conn, card, need) do
    check(Access.card_permission(conn.assigns.current_user, card), need, "card")
  end

  def page(conn, page, need) do
    check(Access.page_permission(conn.assigns.current_user, page), need, "page")
  end

  defp check(level, :read, what),
    do: if(Access.can_read?(level), do: :ok, else: forbidden(what, "read"))

  defp check(level, :write, what),
    do: if(Access.can_write?(level), do: :ok, else: forbidden(what, "edit"))

  defp check(level, :owner, what),
    do: if(Access.owner?(level), do: :ok, else: forbidden(what, "own"))

  defp forbidden(what, verb), do: {:error, :forbidden, "you don't #{verb} this #{what}"}
end

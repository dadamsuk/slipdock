defmodule SlipdockWeb.Ops.Shared do
  @moduledoc """
  What several operations' `run/2` share: the card as every surface answers
  it, the page a `page` (and `board`) param names, and who is acting and how
  they came in, from either kind of caller (a conn, or the MCP context's
  `auth` map).
  """

  alias Slipdock.{Access, Boards, Wiki}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V

  @doc "`{card}` as REST has always answered a card write: the card, fresh."
  def card_json(auth, card),
    do: V.card(Authorize.visible(auth, Boards.Cards.get_card!(card.id)))

  @doc "The actor: a conn's from `Actor.from_conn/1`, the MCP auth map's from its assigns."
  def actor(%Plug.Conn{} = conn), do: Slipdock.Actor.from_conn(conn)
  def actor(%{assigns: %{actor: actor}}), do: actor

  @doc """
  The way the call came in, as a page revision or a handoff records it:
  `cli` or `mcp` from the actor, else `api`.
  """
  def via(auth) do
    case actor(auth).via do
      via when via in ["cli", "mcp"] -> via
      _ -> "api"
    end
  end

  @doc """
  The page `ref` names (a code, an id, `board/slug`; with `board_ref`, a
  slug or title on that board) if the caller has `need` on it. A page they
  can't read at all, or a draft that isn't theirs, is not there (404), as
  REST's `PageController` has always answered.
  """
  def fetch_page(auth, ref, board_ref, need) do
    user = auth.assigns.current_user

    with {:ok, page} <- find_page(auth, ref, board_ref) do
      level = Access.page_permission(user, page)

      cond do
        not Access.can_read?(level) -> {:error, :not_found, "page #{inspect(ref)}"}
        (refused = Authorize.page(auth, page, need)) != :ok -> refused
        not Wiki.visible?(page, level) -> {:error, :not_found, "page #{inspect(ref)}"}
        true -> {:ok, page}
      end
    end
  end

  defp find_page(auth, ref, nil), do: Wiki.find_page(ref, as: auth.assigns.current_user)

  defp find_page(auth, ref, board_ref) do
    with {:ok, board} <- Authorize.fetch_board(auth, board_ref, :read),
         do: Wiki.find_page(board, ref)
  end

  @doc "The address the caller reached the server on: links in an answer start with it."
  def base_url(%Plug.Conn{} = conn), do: SlipdockWeb.BaseURL.from_conn(conn)
  def base_url(%{assigns: %{base_url: base_url}}), do: base_url
end

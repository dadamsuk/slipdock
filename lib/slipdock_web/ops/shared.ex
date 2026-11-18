defmodule SlipdockWeb.Ops.Shared do
  @moduledoc """
  What several operations' `run/2` share: the card as every surface answers
  it, and who is acting and how they came in, from either kind of caller (a
  conn, or the MCP context's `auth` map).
  """

  alias Slipdock.Boards
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
end

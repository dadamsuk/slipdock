defmodule SlipdockWeb.BoardNotices do
  @moduledoc """
  `{:boards_changed}` for the pages that list boards across trees: the board
  index, My work and Favourites. They hear about the boards the signed-in
  person can reach and nobody else's (see `Slipdock.Boards.subscribe_all/1`),
  and since what they can reach changes, each reload resubscribes.
  """
  import Phoenix.Component, only: [assign: 3]
  alias Slipdock.Boards

  @doc "Subscribes a connected page; a static render has nothing to listen with."
  def subscribe(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: assign(socket, :notice_roots, Boards.subscribe_all(socket.assigns.current_user)),
      else: socket
  end

  @doc "Call on `{:boards_changed}`, before reloading."
  def resubscribe(%{assigns: %{notice_roots: roots, current_user: user}} = socket),
    do: assign(socket, :notice_roots, Boards.resubscribe_all(user, roots))

  def resubscribe(socket), do: socket
end

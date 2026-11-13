defmodule SlipdockWeb.LiveAccess do
  @moduledoc """
  What an open page's reader may do, read again before each event (#2998).

  A LiveView works its reader's level out at mount and gates its events on
  the assigns that left. A level lowered since changes none of them: a
  page that isn't the board hears of no grant at all, and even a board
  told of one can be sent an event first. So a page attaches
  `refresh_on_event/3` at mount, and every event reads the level from the
  database before the page's own `handle_event/3` and its guards see it. A
  reader with no access left is sent away, as mount would have sent them.

  A board's LiveComponents can't attach a hook; theirs is
  `refresh_owner/1`, called at the top of `handle_event/3`.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, push_navigate: 2, put_flash: 3]

  alias Slipdock.Access

  @doc """
  Attaches the re-read to `socket`, at mount. `assign_fun` takes the socket
  and the level just read, and answers the socket with the page's gates
  (`can_write`, `can_manage`) set from it. `level_fun` reads the level; left
  out, it is the reader's on `socket.assigns.board`.
  """
  def refresh_on_event(socket, assign_fun, level_fun \\ &board_level/1)
      when is_function(assign_fun, 2) and is_function(level_fun, 1) do
    attach_hook(socket, :refresh_access, :handle_event, fn _event, _params, socket ->
      level = level_fun.(socket)

      if Access.can_read?(level),
        do: {:cont, assign_fun.(socket, level)},
        else: {:halt, send_away(socket)}
    end)
  end

  @doc "The reader's level on the page's board, as the database has it now."
  def board_level(%{assigns: %{board: board, current_user: user}}),
    do: Access.board_permission_now(user, board)

  @doc """
  For a board's owner-only component: `can_manage` read again from the
  database. One that finds its reader no longer the owner tells the board
  to read itself again, which stops drawing the panel.
  """
  def refresh_owner(%{assigns: %{can_manage: was}} = socket) do
    can_manage = board_level(socket) == :owner
    if was and not can_manage, do: send(self(), :reload_board)
    assign(socket, can_manage: can_manage)
  end

  defp send_away(socket) do
    socket
    |> put_flash(:error, "You don't have access to that board.")
    |> push_navigate(to: "/")
  end
end

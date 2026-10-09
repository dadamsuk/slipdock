defmodule SlipdockWeb.MeetingLive.Access do
  @moduledoc """
  The meeting pages' way in: the board from the route, and whether the
  signed-in person may read it (to see captures) or write to it (to send or
  commit one). A board they cannot read sends them home, as the board page
  does.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2]

  alias Slipdock.{Access, Boards, Meetings}

  @doc "`{:ok, socket}` with the board assigned, or the redirect home."
  def mount_board(socket, id, need \\ :read) do
    user = socket.assigns.current_user

    with %Slipdock.Boards.Board{} = board <- Boards.get_board(id),
         perm = Access.board_permission(user, board),
         true <- allowed?(perm, need) do
      {:ok,
       assign(socket,
         board: board,
         perm: perm,
         can_write: Access.can_write?(perm),
         meetings: tab(Meetings.presence(user, board)),
         marks: Slipdock.Favourites.marks(user),
         page_jumps: []
       )}
    else
      _ ->
        {:error,
         socket
         |> put_flash(:error, "You don't have access to that board.")
         |> push_navigate(to: "/")}
    end
  end

  # Somebody on a meeting page sees the tab, whatever the visibility, unless
  # they hid it — in which case the page still works for the link they followed.
  defp tab(:none), do: :none
  defp tab(_), do: :tab

  defp allowed?(perm, :read), do: Access.can_read?(perm)
  defp allowed?(perm, :write), do: Access.can_write?(perm)
end

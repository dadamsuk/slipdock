defmodule SlipdockWeb.NotifyHook do
  @moduledoc """
  Desktop toasts on every signed-in page (#2101).

  Mounted into the signed-in live sessions, this subscribes the LiveView to
  its reader's own topic (`Slipdock.Notify.topic/1`) and passes each
  `{:notify, event}` on to the page as `desktop-notify`, before the LiveView
  sees it, so no page has to know about it. The `DesktopNotify` hook
  (`assets/js/desktop_notify.js`, on a hidden element in the app layout)
  decides whether to show it: only with this browser's toggle on and
  permission given, never for the reader's own doing, and not when this tab
  is in front and already showing that card.
  """

  import Phoenix.LiveView

  alias Slipdock.Accounts.User
  alias Slipdock.Notify

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: subscribe(socket.assigns[:current_user])
    {:cont, attach_hook(socket, :desktop_notify, :handle_info, &handle_info/2)}
  end

  defp subscribe(%User{} = user), do: Notify.subscribe(user)
  defp subscribe(_), do: :ok

  defp handle_info({:notify, event}, socket) do
    case socket.assigns[:current_user] do
      %User{id: id} when id == event.user_id and id != event.by_id ->
        {:halt, push_event(socket, "desktop-notify", event)}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_info(_message, socket), do: {:cont, socket}
end

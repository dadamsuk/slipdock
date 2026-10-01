defmodule SlipdockWeb.AlertsHook do
  @moduledoc """
  Puts the alerts raised by automation rules on every authenticated page.

  Mounted into the `:authenticated` live session, this assigns `:alerts` and
  `:alerts_open`, keeps them up to date over PubSub, and answers the header
  bar's own events (`toggle_alerts`, `dismiss_alert`, `dismiss_all_alerts`)
  before the LiveView sees them — so no page has to know alerts exist.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias Slipdock.Automations

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) and socket.assigns[:current_user], do: Automations.subscribe_alerts()

    socket =
      socket
      |> assign(alerts_open: false)
      |> assign_alerts()
      |> attach_hook(:alerts_events, :handle_event, &handle_event/3)
      |> attach_hook(:alerts_messages, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp handle_event("toggle_alerts", _params, socket),
    do: {:halt, assign(socket, alerts_open: !socket.assigns.alerts_open)}

  defp handle_event("dismiss_alert", %{"id" => id}, socket) do
    Automations.dismiss_alert(socket.assigns.current_user, id)
    socket = assign_alerts(socket)
    # Closing the panel as the last alert goes avoids leaving an empty one open.
    {:halt,
     assign(socket, alerts_open: socket.assigns.alerts != [] and socket.assigns.alerts_open)}
  end

  defp handle_event("dismiss_all_alerts", _params, socket) do
    Automations.dismiss_all_alerts(socket.assigns.current_user)
    {:halt, socket |> assign_alerts() |> assign(alerts_open: false)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:alerts_changed}, socket), do: {:halt, assign_alerts(socket)}
  defp handle_info(_message, socket), do: {:cont, socket}

  defp assign_alerts(socket) do
    case socket.assigns[:current_user] do
      nil -> assign(socket, alerts: [])
      user -> assign(socket, alerts: Automations.list_alerts(user))
    end
  end
end

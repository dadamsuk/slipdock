defmodule SlipdockWeb.ViewportHook do
  @moduledoc """
  Tells every LiveView how wide the browser window is.

  A phone is not a narrow desktop. A seven-column month grid, a swimlane
  matrix or a Gantt chart cannot be squeezed into 390 points and still be
  read, so on a phone those views render *something else* rather than
  something smaller. That choice is made on the server, which means the
  server has to know the width.

  The width arrives twice over. The socket's connect params carry it into
  the first connected render, so a phone never paints the desktop layout
  first and then jumps; the `Viewport` JS hook pushes it again whenever the
  window is resized or the device is turned.

  Assigns:

    * `:narrow?` — the window is under 640px: a phone held upright, or a
      very small window. The one flag the views branch on.
    * `:viewport` — the width in CSS pixels, or `nil` until the socket
      connects (the dead render, and any test that never connects).

  Before the socket connects `:narrow?` is false, so the static render is
  the desktop one. That render is never shown for long enough to matter,
  and treating "unknown" as desktop keeps every existing test honest.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  # Tailwind's `sm` breakpoint. Under it we are on a phone in portrait.
  @narrow 640

  @doc "The width, in CSS pixels, below which `narrow?` is true."
  def narrow_width, do: @narrow

  def on_mount(:default, _params, _session, socket) do
    width = width_from_connect_params(socket)

    socket =
      socket
      |> assign(viewport: width, narrow?: narrow?(width))
      |> attach_hook(:viewport_events, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp handle_event("viewport", %{"width" => width}, socket) when is_number(width) do
    width = trunc(width)

    if width == socket.assigns[:viewport] do
      {:halt, socket}
    else
      {:halt, assign(socket, viewport: width, narrow?: narrow?(width))}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp width_from_connect_params(socket) do
    case get_connect_params(socket) do
      %{"viewport_width" => width} when is_number(width) and width > 0 -> trunc(width)
      _ -> nil
    end
  end

  defp narrow?(nil), do: false
  defp narrow?(width), do: width < @narrow
end

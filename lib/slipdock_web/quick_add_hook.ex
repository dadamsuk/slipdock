defmodule SlipdockWeb.QuickAddHook do
  @moduledoc """
  Puts the header's quick add box on every authenticated page.

  Mounted into the `:authenticated` live session, this assigns `:quick_add`
  and answers the box's own events (`toggle_quick_add`, `quick_add_submit`,
  `quick_add_dismiss`) before the LiveView sees them — so no page has to
  know quick add exists, the same arrangement `SlipdockWeb.AlertsHook` uses.

  The line itself is read and written by `Slipdock.QuickAdd.Capture`, in a
  task, so the model's half-second never holds the page up.

  The links a person pinned to the header (#1205, `Slipdock.HeaderLinks`)
  sit just left of the box and travel in the same assign, as `:links`, since
  every page already hands `:quick_add` to the layout. Anything that changes
  them sends `:header_links_changed` to the page, and this redraws them.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias Slipdock.HeaderLinks
  alias Slipdock.QuickAdd.Capture

  @empty %{
    open?: false,
    busy?: false,
    form_key: 0,
    text: "",
    result: nil,
    error: nil,
    destination: nil,
    ai?: false,
    links: []
  }

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(quick_add: %{@empty | links: HeaderLinks.list(socket.assigns[:current_user])})
      |> attach_hook(:quick_add_events, :handle_event, &handle_event/3)
      |> attach_hook(:quick_add_async, :handle_async, &handle_async/3)
      |> attach_hook(:header_links, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp handle_event("toggle_quick_add", _params, socket) do
    quick_add = socket.assigns.quick_add

    if quick_add.open? do
      {:halt, put(socket, %{@empty | form_key: quick_add.form_key, links: quick_add.links})}
    else
      {:halt, put(socket, %{quick_add | open?: true, error: nil} |> Map.merge(where_to(socket)))}
    end
  end

  defp handle_event("quick_add_submit", %{"text" => text}, socket) do
    user = socket.assigns.current_user

    cond do
      String.trim(text) == "" ->
        {:halt, socket}

      socket.assigns.quick_add.busy? ->
        {:halt, socket}

      true ->
        {:halt,
         socket
         |> put(%{socket.assigns.quick_add | busy?: true, text: text, error: nil, result: nil})
         |> start_async(:quick_add, fn -> Capture.capture(user, text) end)}
    end
  end

  defp handle_event("quick_add_dismiss", _params, socket),
    do: {:halt, put(socket, %{socket.assigns.quick_add | result: nil, error: nil})}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_async(:quick_add, {:ok, {:ok, capture}}, socket) do
    quick_add = socket.assigns.quick_add

    {:halt,
     put(socket, %{
       quick_add
       | busy?: false,
         text: "",
         result: capture,
         error: nil,
         form_key: quick_add.form_key + 1
     })}
  end

  defp handle_async(:quick_add, {:ok, {:error, message}}, socket),
    do: {:halt, put(socket, %{socket.assigns.quick_add | busy?: false, error: message})}

  defp handle_async(:quick_add, {:exit, reason}, socket) do
    require Logger
    Logger.warning("Quick add crashed: #{inspect(reason)}")

    {:halt,
     put(socket, %{socket.assigns.quick_add | busy?: false, error: "Couldn't add that card."})}
  end

  defp handle_async(_name, _result, socket), do: {:cont, socket}

  defp handle_info(:header_links_changed, socket) do
    links = HeaderLinks.list(socket.assigns[:current_user])
    {:halt, put(socket, %{socket.assigns.quick_add | links: links})}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  # Where the next card would land, for the box's own placeholder.
  defp where_to(socket) do
    case socket.assigns[:current_user] do
      nil ->
        %{destination: nil, ai?: false}

      user ->
        catalogue = Capture.catalogue(user)

        %{
          destination:
            if(Capture.available?(catalogue),
              do: {catalogue.default_board.name, catalogue.default_column.name}
            ),
          ai?: user.quick_add_ai and Slipdock.AI.configured?(user)
        }
    end
  end

  defp put(socket, quick_add), do: assign(socket, quick_add: quick_add)
end

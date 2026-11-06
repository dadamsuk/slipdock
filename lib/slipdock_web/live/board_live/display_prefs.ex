defmodule SlipdockWeb.BoardLive.DisplayPrefs do
  @moduledoc """
  Remembers a board's Display options in the reader's browser (#1879).

  The display options (card size, list width, what a card's front shows,
  table columns, …) live in the URL, so leaving the board and coming back
  to its bare address used to drop them. Each `handle_params` pushes
  `display-prefs` to the `DisplayPrefs` hook (`assets/js/display_prefs.js`)
  with the board and mode's key and the current display query. The hook
  keeps it in `localStorage`, one entry per board and mode, so another
  browser starts from the defaults.

  On the first visit to a mode since the page mounted, when the URL names
  no display options, the push says `restore: true`, and the hook sends
  back what it remembers (`display_restore`), which is patched into the URL
  in place. A URL that names display options wins, and so does a saved
  view, whose own options are left alone and never remembered. Filters are
  never remembered: only the Display menu's part (`Config.display_query/2`).
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3, push_patch: 2]
  import SlipdockWeb.BoardLive.Paths, only: [mode_path: 2]
  import SlipdockWeb.BoardLive.State, only: [swim_query: 3]

  alias Slipdock.Swimlanes.Config

  @doc "The `localStorage` key (after the hook's prefix) for a board's mode."
  def key(board_id, mode), do: "display:#{board_id}:#{mode}"

  @doc """
  Tells the browser the display options now in use, after `handle_params`.
  Not on a saved view, a view-only or card-only page, or before the socket
  is connected.
  """
  def sync(%{assigns: assigns} = socket) do
    if remembers?(socket) do
      key = key(assigns.board.id, assigns.mode)
      synced = Map.get(assigns, :display_synced, MapSet.new())
      query = Config.display_query(assigns.swim, assigns.swim_base)
      restore? = not MapSet.member?(synced, key) and query == %{}

      socket
      |> assign(:display_synced, MapSet.put(synced, key))
      |> push_event("display-prefs", %{key: key, query: query, restore: restore?})
    else
      socket
    end
  end

  @doc """
  Puts what the browser remembered on the current config and patches the
  URL in place (`replace: true`, so Back doesn't land on the bare URL).
  """
  def restore(%{assigns: assigns} = socket, %{"query" => remembered}) when is_map(remembered) do
    current = assigns.swim
    config = current |> Config.put_display(remembered) |> Config.sanitize(assigns.board)

    if remembers?(socket) and config != current do
      to = mode_path(assigns, swim_query(nil, config, assigns.swim_base))
      push_patch(socket, to: to, replace: true)
    else
      socket
    end
  end

  def restore(socket, _params), do: socket

  defp remembers?(%{assigns: assigns} = socket) do
    connected?(socket) and is_nil(socket.redirected) and is_nil(assigns[:swim_view]) and
      not Map.get(assigns, :view_only, false) and
      not Map.get(assigns, :card_only, false)
  end
end

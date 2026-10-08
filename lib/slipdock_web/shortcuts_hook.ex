defmodule SlipdockWeb.ShortcutsHook do
  @moduledoc """
  Answers the keyboard shortcuts that work on every authenticated page.

  Mounted into the `:authenticated` live session, this assigns `:shortcuts`
  and handles the palettes the `Keys` hook opens — the help sheet (`?`), the
  board switcher (`b`), the view switcher (`v`), the command palette
  (`Ctrl-P`) and the card finder (`Ctrl-O`) — before the LiveView sees them,
  the same arrangement `SlipdockWeb.AlertsHook` uses. Pages that have somewhere
  to jump to assign `:page_jumps`; the view switcher is theirs.

  The first three palettes are picked from by key: each row carries its own
  and the `Keys` hook narrows them as you type. The last two are picked from
  by typing what you are after, which is the server's work — `:query` is what
  was typed, `:results` what matched, and `:cursor` which row Enter would
  follow. The catalogue behind the command palette is `SlipdockWeb.Commands`.

  The keys themselves live in the hooks in `assets/js/app.js`, and are written
  down for people in `SlipdockWeb.Shortcuts`.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias Slipdock.Access
  alias Slipdock.Boards
  alias Slipdock.Wiki
  alias SlipdockWeb.Commands

  @closed %{panel: nil, boards: [], pool: [], query: "", results: [], cursor: 0}

  # How many cards the finder offers at once.
  @found 12

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(shortcuts: @closed)
      |> assign_new(:page_jumps, fn -> [] end)
      |> attach_hook(:shortcut_events, :handle_event, &handle_event/3)
      |> attach_hook(:shortcut_params, :handle_params, &handle_params/3)

    {:cont, socket}
  end

  defp handle_event("shortcut_panel", %{"panel" => panel}, socket)
       when panel in ~w(help boards views command find) do
    panel = String.to_existing_atom(panel)
    open = socket.assigns.shortcuts.panel

    cond do
      # The same key again closes the panel it opened.
      open == panel ->
        {:halt, assign(socket, shortcuts: @closed)}

      panel == :boards ->
        {:halt, assign(socket, shortcuts: %{@closed | panel: panel, boards: boards(socket)})}

      panel in [:command, :find] ->
        {:halt,
         assign(socket,
           shortcuts:
             search(
               %{@closed | panel: panel, pool: pool(socket, panel)},
               socket.assigns[:current_user]
             )
         )}

      true ->
        {:halt, assign(socket, shortcuts: %{@closed | panel: panel})}
    end
  end

  # Typing in the command palette or the card finder: what matched, and back
  # to the top of it.
  defp handle_event("palette_filter", %{"q" => q}, socket) do
    {:halt,
     assign(socket,
       shortcuts: search(%{socket.assigns.shortcuts | query: q}, socket.assigns[:current_user])
     )}
  end

  defp handle_event("palette_move", %{"dir" => dir}, socket) do
    %{results: results, cursor: cursor} = socket.assigns.shortcuts
    step = if dir == "up", do: -1, else: 1
    count = length(results)

    cursor =
      case count do
        0 -> 0
        n -> Integer.mod(cursor + step, n)
      end

    {:halt, assign(socket, shortcuts: %{socket.assigns.shortcuts | cursor: cursor})}
  end

  defp handle_event("close_shortcuts", _params, socket),
    do: {:halt, assign(socket, shortcuts: @closed)}

  defp handle_event("go_home", _params, socket),
    do: {:halt, socket |> assign(shortcuts: @closed) |> push_navigate(to: "/")}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # Following a row closes the palette it came from. A row that navigates does
  # that by remounting; one that only patches — the view switcher — needs this.
  defp handle_params(_params, _uri, socket) do
    {:cont, assign(socket, shortcuts: %{socket.assigns.shortcuts | panel: nil})}
  end

  # What an open palette works from, gathered once when it opens rather than
  # on every keystroke: the commands themselves, or the boards to search.
  defp pool(socket, :command) do
    Commands.build(boards(socket), socket.assigns[:page_jumps] || [], socket.assigns[:board])
  end

  defp pool(socket, :find), do: Enum.map(boards(socket), & &1.id)

  # What the open palette should be showing for what has been typed into it.
  defp search(%{panel: :command, query: q, pool: commands} = shortcuts, _user) do
    %{shortcuts | results: Commands.search(commands, q), cursor: 0}
  end

  # A page's code (`W-31`) finds that page, first, ahead of any card whose
  # title happens to contain it.
  defp search(%{panel: :find, query: q, pool: board_ids} = shortcuts, user) do
    results =
      case String.trim(q) do
        "" ->
          []

        q ->
          page = Wiki.page_by_code_for(user, q)
          List.wrap(page) ++ Boards.search_cards_across(board_ids, q, [], @found)
      end

    %{shortcuts | results: results, cursor: 0}
  end

  defp search(shortcuts, _user), do: shortcuts

  # The boards the switcher offers: the ones this user can open, each with the
  # key set in its board settings. A board with no key yet is still listed —
  # it can be clicked, it just cannot be typed.
  defp boards(socket) do
    case socket.assigns[:current_user] do
      nil -> []
      user -> Access.list_boards(user)
    end
  end
end

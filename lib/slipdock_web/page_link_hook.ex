defmodule SlipdockWeb.PageLinkHook do
  @moduledoc """
  The page picker that opens when somebody types `[[` in a Markdown editor: a
  wiki page, a card's description, a comment (#1302).

  The `PageLink` hook in `assets/js/page_link.js` sends what has been typed
  after the brackets as `page_link_suggest`, and this answers it, before the
  LiveView sees it, with the pages that match: by title, alias, folder path
  or code (`W-31`), the most recently changed first when nothing is typed
  yet. The matching is the quick switcher's (`Slipdock.Wiki.Switcher`), over
  the pages of the board's vault (or the board, outside one) first, then
  those of every other vault the reader has (#1303), and only what the
  reader may open.

  Each match carries the link to write: `[[Title]]` when the title alone
  finds that page from the board being written on, else `[[W-31]]`, which
  always does.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Slipdock.{Access, Boards}
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki.Switcher

  # How many pages the picker offers at once.
  @offered 8

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :page_link_events, :handle_event, &handle_event/3)}
  end

  # `fresh` comes with the first keystroke after a `[[`: the pool is gathered
  # then, and the rest of the word is scored against it in memory.
  defp handle_event("page_link_suggest", params, socket) do
    case board(socket, params["board"]) do
      %Board{} = board ->
        socket = ensure_pool(socket, board, params["fresh"] in [true, "true"])
        pool = socket.assigns.page_link_pool.pool

        pages =
          pool |> Switcher.search(params["q"] || "", @offered) |> Enum.map(&row(&1, board, pool))

        {:halt, %{pages: pages}, socket}

      nil ->
        {:halt, %{pages: []}, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  @doc """
  What `pages` (switcher entries) look like to the picker: title, code, where
  the page sits, and the link to write for it from `board`.
  """
  def row(entry, %Board{} = board, pool) do
    %{
      id: entry.id,
      title: entry.title,
      code: entry.code,
      path: where(entry, board),
      insert: link_for(entry, board, pool)
    }
  end

  @doc """
  The link to write for `entry` on `board`: `[[Title]]` when the title alone
  finds it there — the page is on that board, no other page on it shares the
  title, and the title holds nothing a link would read as syntax — else
  `[[W-31]]`.
  """
  def link_for(entry, %Board{id: board_id}, pool) do
    if entry.board_id == board_id and plain_title?(entry.title) and
         unique_title?(entry, pool),
       do: "[[#{entry.title}]]",
       else: "[[#{entry.code}]]"
  end

  # `/` names another board, `|` starts the label, `#` and `^` an anchor, and
  # a code-shaped title would be read as that code.
  defp plain_title?(title) do
    title != "" and not String.contains?(title, ["/", "|", "#", "^", "[", "]", "\n"]) and
      not Slipdock.Wiki.Page.code?(title)
  end

  defp unique_title?(entry, pool) do
    title = String.downcase(entry.title)

    not Enum.any?(
      pool,
      &(&1.id != entry.id and &1.board_id == entry.board_id and
          (String.downcase(&1.title) == title or String.downcase(&1.slug || "") == title))
    )
  end

  # The folder path the page sits under, its board when that is another, and
  # its vault when that is another too.
  defp where(entry, %Board{id: board_id}) do
    dir =
      case String.split(entry.path, "/") do
        [_only] -> nil
        parts -> parts |> Enum.drop(-1) |> Enum.join("/")
      end

    [entry[:elsewhere], if(entry.board_id != board_id, do: entry.board), dir]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # The board the editor is on: the one the hook names, when the reader may
  # open it, else the view's own.
  defp board(socket, id) do
    user = socket.assigns[:current_user]

    with true <- not is_nil(user) and id not in [nil, ""],
         {id, ""} <- Integer.parse(to_string(id)),
         %Board{} = board <- Boards.get_board(id),
         true <- Access.can_read?(Access.board_permission(user, board)) do
      board
    else
      _ -> own_board(socket)
    end
  end

  defp own_board(socket) do
    case {socket.assigns[:current_user], socket.assigns[:board]} do
      {nil, _} -> nil
      {_user, %Board{} = board} -> board
      _ -> nil
    end
  end

  defp ensure_pool(socket, board, fresh) do
    case socket.assigns[:page_link_pool] do
      %{board_id: id} when id == board.id and not fresh ->
        socket

      _ ->
        assign(socket, :page_link_pool, %{
          board_id: board.id,
          pool: Switcher.linkable_pool(socket.assigns.current_user, board)
        })
    end
  end
end

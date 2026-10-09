defmodule SlipdockWeb.ExportController do
  @moduledoc """
  Downloads: the table view as CSV, and a board's wiki as a zip of Markdown.

  The wiki export is the escape hatch — a wiki you cannot get your writing
  out of is one to think twice about putting writing into.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Boards, Table}
  alias Slipdock.Swimlanes.Config
  alias Slipdock.Wiki.Archive

  @doc "A board's whole wiki as a zip of Markdown files, front matter and all."
  def wiki(conn, %{"id" => id} = params) do
    board = Boards.get_board!(id)

    if Access.can_read?(Access.board_permission(conn.assigns.current_user, board)) do
      # A reader gets what a reader can see: drafts are for writers.
      opts =
        if Access.can_write?(Access.board_permission(conn.assigns.current_user, board)),
          do: [archived: archived(params)],
          else: [archived: archived(params), status: "published"]

      {filename, binary} = Archive.zip(board, opts)

      conn
      |> put_resp_content_type("application/zip")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, binary)
    else
      conn |> put_status(:forbidden) |> text("You don't have access to that board.")
    end
  end

  @doc """
  One page as a Markdown file, the same bytes the zip would hold for it.

  A page you can take away one at a time, rather than only by the boardful:
  the usual reason to want it is to paste it somewhere else today.
  """
  def page(conn, %{"id" => id, "slug" => slug}) do
    board = Boards.get_board!(id)
    user = conn.assigns.current_user

    with true <- Access.can_read?(Access.board_permission(user, board)),
         {:ok, page} <- Slipdock.Wiki.find_page(board, slug),
         true <- Slipdock.Wiki.visible?(page, Access.page_permission(user, page)) do
      conn
      |> put_resp_content_type("text/markdown")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{page.slug}.md"))
      |> send_resp(200, Archive.file(page))
    else
      _ -> conn |> put_status(:not_found) |> text("No such page.")
    end
  end

  defp archived(%{"archived" => "all"}), do: :all
  defp archived(%{"archived" => "true"}), do: true
  defp archived(_), do: false

  @doc """
  Everything one person has, as a zip — their own account, nobody else's.

  Not admin-only on purpose: being able to leave with your work is a thing you
  should not have to ask anybody for.
  """
  def account(conn, params) do
    # `?audio=1` takes the meeting recordings too.
    audio = params["audio"] in ["1", "true"]
    {filename, binary} = Slipdock.AccountExport.zip(conn.assigns.current_user, audio: audio)

    conn
    |> put_resp_content_type("application/zip")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, binary)
  end

  @doc """
  The caller's board trees as one portable JSON document — the file
  `Slipdock.Portable` reads back.

  Only boards they **own**: a board shared with you is somebody else's to hand
  on. `boards` narrows it to a comma-separated list of ids, codes or names, and
  anything the caller does not own is simply left out rather than refused —
  this is a download link rather than an API, and a broken link is a worse
  answer than a smaller file.
  """
  def portable(conn, params) do
    user = conn.assigns.current_user
    opts = portable_opts(user, params)
    {filename, iodata} = Slipdock.Portable.to_json(user, opts)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, iodata)
  end

  defp portable_opts(user, params) do
    Slipdock.Portable.archived_opts(params["archived"]) ++
      portable_boards(user, params["boards"])
  end

  defp portable_boards(_user, blank) when blank in [nil, ""], do: []

  defp portable_boards(user, refs) do
    boards =
      refs
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.flat_map(fn ref ->
        # Whoever owns the root owns what gets exported, which a sub-board's
        # own owner need not be.
        with {:ok, board} <- Access.find_board(user, ref),
             root = Slipdock.Portable.root_of(board),
             true <- owns?(user, root) do
          [root]
        else
          _ -> []
        end
      end)

    # Every board asked for turned out to be somebody else's, which is not the
    # same request as "all of mine" — answer with an empty document instead.
    if boards == [], do: [boards: []], else: [boards: boards]
  end

  defp owns?(user, board) do
    Access.owner?(Access.board_permission(user, board))
  end

  def table(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    board = Boards.get_board!(id)

    view =
      case params["view"] && Boards.find_saved_view(board, params["view"]) do
        {:ok, view} -> view
        _ -> nil
      end

    permitted? =
      Access.can_read?(Access.board_permission(user, board)) or
        (view != nil and Access.can_read?(Access.view_permission(user, view)))

    if permitted? do
      base = if view, do: Config.from_map(view.config), else: Config.defaults("table")

      config =
        params
        |> Config.from_query(base)
        |> Config.sanitize(board)
        |> Map.put(:mode, "table")

      filename = board.name |> String.replace(~r/[^\w\- ]+/u, "") |> String.trim()
      filename = if filename == "", do: "board", else: filename

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}.csv"))
      |> send_resp(200, Table.csv(board, config))
    else
      conn |> put_status(:forbidden) |> text("You don't have access to that board.")
    end
  end
end

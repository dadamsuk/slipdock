defmodule SlipdockWeb.MCP.Resources do
  @moduledoc """
  The resources `/mcp` offers (`resources/list`, `resources/templates/list`,
  `resources/read`): a board, card, wiki page, saved view or My work, as
  Markdown, that the *person* attaches to a conversation (W-1808). Tools are
  the model's choice; resources are the person's.

  `resources/list` is not everything they can read: a picker of every page
  in a 5,000-note vault is no use to anybody. It is what they have said
  matters: My work, their favourites (boards, cards, views and pages), and
  the pages pinned to their favourite boards. Anything else is reached
  through the URI templates.

  Every read goes through the tools' access checks with the token's scope
  (`SlipdockWeb.API.Authorize`), and anything the token cannot read reads
  exactly like something that is not there.

  The renderers are in `SlipdockWeb.MCP.Resources.Render`.
  """

  import Ecto.Query

  alias Slipdock.{Access, Boards, Favourites, Repo, Wiki}
  alias Slipdock.Boards.{Board, Card, SavedView}
  alias Slipdock.Wiki.{Link, Page}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.Args
  alias SlipdockWeb.MCP.Resources.Render
  alias SlipdockWeb.MCP.Tools.ReadPage

  @scheme "slipdock://"
  @mime "text/markdown"
  @per_page 50

  @doc "How many resources one page of `resources/list` holds."
  def per_page, do: @per_page

  @doc "The URI templates, as `resources/templates/list` gives them."
  def templates do
    [
      template(
        "board/{code}",
        "board",
        "Board",
        "A board as Markdown: its lists in order, the open cards on each with their " <>
          "ids, flags, due dates and assignees, and how many are done."
      ),
      template(
        "card/{id}",
        "card",
        "Card",
        "A card in full as Markdown: handoff, description, checklist, subcards, recent " <>
          "comments and the wiki pages about it."
      ),
      template(
        "page/{code}",
        "page",
        "Wiki page",
        "A wiki page's Markdown source, front matter included. Code like W-31."
      ),
      template(
        "view/{board}/{view}",
        "view",
        "Saved view",
        "A saved view's rows on a board, as Markdown. View is its id or name."
      ),
      template(
        "work",
        "work",
        "My work",
        "The cards assigned to me on every board, by when they are due."
      )
    ]
  end

  defp template(path, name, title, description),
    do: %{
      uriTemplate: @scheme <> path,
      name: name,
      title: title,
      description: description,
      mimeType: @mime
    }

  @doc """
  One page of `resources/list` for the context's token: `{:ok, result}`, or
  `{:error, message}` for a cursor this server did not hand out.
  """
  def list(context, cursor, per_page \\ @per_page) do
    with {:ok, offset} <- decode_cursor(cursor) do
      all = listed(context)
      {page, rest} = all |> Enum.drop(offset) |> Enum.split(per_page)
      result = %{resources: page}

      {:ok,
       if(rest == [], do: result, else: Map.put(result, :nextCursor, cursor(offset + per_page)))}
    end
  end

  defp cursor(offset), do: Base.url_encode64("offset:#{offset}", padding: false)

  defp decode_cursor(nil), do: {:ok, 0}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, "offset:" <> n} <- Base.url_decode64(cursor, padding: false),
         {offset, ""} when offset >= 0 <- Integer.parse(n) do
      {:ok, offset}
    else
      _ -> {:error, "invalid cursor"}
    end
  end

  defp decode_cursor(_), do: {:error, "invalid cursor"}

  # My work first, then favourites in the order they were marked, then the
  # pins on favourite boards; the same thing twice is listed once.
  defp listed(%{user: user} = context) do
    auth = Args.auth(context)
    favourites = Favourites.list(user)

    fav_resources =
      favourites
      |> Enum.filter(&(&1.kind in [:board, :card, :view, :page]))
      |> Enum.filter(&readable?(auth, &1.kind, &1.resource))
      |> Enum.map(&resource(&1.kind, &1.resource, "Favourite"))

    fav_board_ids = for %{kind: :board, resource: b} <- favourites, do: b.id

    pins =
      fav_board_ids
      |> pinned_pages()
      |> Enum.filter(fn {page, _board} -> readable?(auth, :page, page) end)
      |> Enum.map(fn {page, board} ->
        resource(:page, page, "Pinned to #{board.name}")
      end)

    [work_resource() | fav_resources ++ pins]
    |> Enum.uniq_by(& &1.uri)
  end

  defp pinned_pages([]), do: []

  defp pinned_pages(board_ids) do
    from(l in Link,
      join: p in Page,
      on: p.id == l.page_id,
      join: b in Board,
      on: b.id == l.target_board_id,
      where: l.pinned and l.target_board_id in ^board_ids and is_nil(p.archived_at),
      where: not p.template,
      order_by: [asc: b.id, asc: p.id],
      select: {p, b}
    )
    |> Repo.all()
  end

  defp readable?(auth, :board, %Board{} = board), do: Authorize.board(auth, board, :read) == :ok
  defp readable?(auth, :card, %Card{} = card), do: Authorize.card(auth, card, :read) == :ok
  defp readable?(auth, :page, %Page{} = page), do: ReadPage.check(page, auth, :read) == :ok
  defp readable?(auth, :view, %SavedView{} = view), do: view_readable?(auth, view)
  defp readable?(_auth, _kind, _resource), do: false

  defp view_readable?(auth, view) do
    user = auth.assigns.current_user
    level = Access.view_permission(user, view)
    {level, _} = Access.narrow(level, auth.assigns.api_token, view.board_id)
    Access.can_read?(level)
  end

  defp work_resource,
    do: %{
      uri: @scheme <> "work",
      name: "My work",
      title: "My work",
      description: "The cards assigned to me on every board, by when they are due.",
      mimeType: @mime
    }

  @doc "The URI a board, card, page or view is read at."
  def uri(:board, %Board{} = board), do: @scheme <> "board/" <> (board.code || "#{board.id}")
  def uri(:card, %Card{id: id}), do: @scheme <> "card/#{id}"
  def uri(:page, %Page{code: code}), do: @scheme <> "page/" <> code

  def uri(:view, %SavedView{} = view) do
    board = Repo.get!(Board, view.board_id)
    @scheme <> "view/" <> (board.code || "#{board.id}") <> "/#{view.id}"
  end

  defp resource(kind, thing, why) do
    %{
      uri: uri(kind, thing),
      name: name(kind, thing),
      title: name(kind, thing),
      description: "#{why}: #{kind_label(kind)}",
      mimeType: @mime
    }
  end

  defp name(:board, board), do: board.name
  defp name(:card, card), do: "##{card.id} #{card.title}"
  defp name(:page, page), do: "#{page.code} #{page.title}"
  defp name(:view, view), do: view.name

  defp kind_label(:board), do: "a board"
  defp kind_label(:card), do: "a card"
  defp kind_label(:page), do: "a wiki page"
  defp kind_label(:view), do: "a saved view"

  @doc """
  `resources/read`: `{:ok, result}` with the resource as Markdown, or
  `:not_found` for a URI that names nothing this token may read. The two are
  the same answer on purpose: which of them it was would say whether the
  thing exists.
  """
  def read(uri, context) when is_binary(uri) do
    with {:ok, target} <- parse(uri),
         {:ok, found} <- resolve(target, context) do
      {:ok, %{contents: [%{uri: uri, mimeType: @mime, text: Render.render(found, context)}]}}
    else
      _ -> :not_found
    end
  end

  def read(_uri, _context), do: :not_found

  @doc "What a URI names: `{:board, ref}`, `{:card, id}`, …, or `:error`."
  def parse(@scheme <> rest) do
    case rest |> String.split("/") |> Enum.map(&URI.decode/1) do
      ["board", ref] when ref != "" -> {:ok, {:board, ref}}
      ["card", id] -> card_id(id)
      ["page", ref] when ref != "" -> {:ok, {:page, ref}}
      ["view", board, view] when board != "" and view != "" -> {:ok, {:view, board, view}}
      ["work"] -> {:ok, :work}
      _ -> :error
    end
  end

  def parse(_), do: :error

  defp card_id(id) do
    case Integer.parse(String.trim_leading(id, "#")) do
      {n, ""} when n > 0 -> {:ok, {:card, n}}
      _ -> :error
    end
  end

  defp resolve({:board, ref}, context) do
    auth = Args.auth(context)

    with {:ok, board} <- Authorize.fetch_board(auth, ref, :read) do
      {:ok, {:board, Authorize.visible(auth, Boards.get_board!(board.id))}}
    end
  end

  # An archived card is not listed, but it is readable by its number.
  defp resolve({:card, id}, context) do
    auth = Args.auth(context)

    with %Card{} = card <- Boards.get_card(id),
         :ok <- Authorize.card(auth, card, :read) do
      {:ok, {:card, Authorize.visible(auth, Repo.preload(card, :board))}}
    end
  end

  defp resolve({:page, ref}, context) do
    auth = Args.auth(context)

    with {:ok, %Page{} = page} <- Wiki.find_page(ref, as: context.user),
         :ok <- ReadPage.check(page, auth, :read) do
      {:ok, {:page, page}}
    end
  end

  # A view can be shared on its own, without its board, so it is found
  # first and its own permission decides.
  defp resolve({:view, board_ref, view_ref}, context) do
    auth = Args.auth(context)

    with {:ok, board} <- Boards.find_board(board_ref),
         {:ok, view} <- Boards.find_saved_view(board, view_ref),
         true <- view_readable?(auth, view) do
      {:ok, {:view, Boards.get_board!(board.id), view}}
    end
  end

  defp resolve(:work, _context), do: {:ok, :work}
end

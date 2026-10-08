defmodule SlipdockWeb.MCP.Tools.ListPages do
  @moduledoc "A board's wiki pages, as `GET /api/boards/:board/pages` lists them, flat or as a tree."
  @behaviour SlipdockWeb.MCP.Tool

  import Ecto.Query

  alias Slipdock.{Access, Repo, Wiki}
  alias Slipdock.Wiki.{Link, Page}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.Args

  @max 500
  @archived %{"exclude" => false, "include" => :all, "only" => true}

  @impl true
  def name, do: "list_pages"

  @impl true
  def title, do: "List wiki pages"

  @impl true
  def description,
    do:
      "A board's wiki pages in order: code, title, summary, folder, parent, pinned cards. " <>
        "tree = children nested under parents. q matches title or text. read_page reads one."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        q: %{type: "string", description: "Only pages whose title or text contains this."},
        archived: %{
          type: "string",
          enum: Map.keys(@archived),
          description: "Archived pages: exclude (default), include or only."
        },
        template: %{type: "boolean", description: "true = only templates, false = none."},
        draft: %{type: "boolean", description: "true = only drafts, false = only published."},
        tree: %{type: "boolean", description: "Nest each page's children under it."},
        limit: %{type: "integer", description: "At most this many (default 100, max #{@max})."}
      },
      required: ["board"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, q} <- Args.optional(args, "q"),
         {:ok, archived} <- archived(args),
         {:ok, template} <- Args.boolean(args, "template"),
         {:ok, draft} <- Args.boolean(args, "draft"),
         {:ok, tree?} <- Args.boolean(args, "tree", false),
         {:ok, limit} <- Args.limit(args, "limit", 100, @max),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :read)) do
      pages =
        case status(draft, writer?(context.user, board)) do
          :none ->
            []

          status ->
            Wiki.list_pages(board, q: q, archived: archived, template: template, status: status)
        end

      shown = Enum.take(pages, limit)
      line = liner(board, shown, context.base_url)

      {:ok,
       %{
         board: %{id: board.id, code: board.code, name: board.name},
         pages: if(tree?, do: nest(Wiki.tree_from(shown), line), else: Enum.map(shown, line)),
         truncated: length(pages) > limit
       }}
    end
  end

  defp archived(args) do
    case args["archived"] do
      nil -> {:ok, false}
      value when is_map_key(@archived, value) -> {:ok, @archived[value]}
      _ -> {:error, "archived must be exclude, include or only"}
    end
  end

  # Drafts are half-written, so only someone who could edit them sees them
  # listed — as the API's page index does. A reader asking for drafts gets none.
  defp status(true, true), do: "draft"
  defp status(true, false), do: :none
  defp status(false, _writer), do: "published"
  defp status(nil, true), do: nil
  defp status(nil, false), do: "published"

  defp writer?(user, board), do: Access.can_write?(Access.board_permission(user, board))

  defp nest(nodes, line) do
    Enum.map(nodes, fn %{page: page, children: children} ->
      page |> line.() |> Map.put(:children, nest(children, line))
    end)
  end

  # Everything a line needs that the pages themselves do not carry, fetched
  # once for the whole listing rather than once a page.
  defp liner(board, pages, base_url) do
    folders =
      if Enum.any?(pages, & &1.folder_id),
        do: Map.new(Wiki.folder_outline(board), &{&1.folder.id, &1.path}),
        else: %{}

    parents = codes(pages |> Enum.map(& &1.parent_id) |> Enum.reject(&is_nil/1))
    pinned = pinned_cards(Enum.map(pages, & &1.id))

    fn page ->
      %{
        code: page.code,
        title: page.title,
        summary: page.summary,
        folder: folders[page.folder_id],
        parent: parents[page.parent_id],
        pinned_cards: Map.get(pinned, page.id, []),
        draft: Page.draft?(page),
        template: page.template,
        archived: not is_nil(page.archived_at),
        updated_at: page.updated_at,
        url: base_url <> SlipdockWeb.API.JSON.page_url(page)
      }
    end
  end

  defp codes([]), do: %{}

  defp codes(ids),
    do: Map.new(Repo.all(from(p in Page, where: p.id in ^ids, select: {p.id, p.code})))

  defp pinned_cards([]), do: %{}

  defp pinned_cards(ids) do
    from(l in Link,
      where: l.page_id in ^ids and l.pinned and l.kind == "card",
      where: not is_nil(l.target_card_id),
      order_by: [asc: l.target_card_id],
      select: {l.page_id, l.target_card_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end
end

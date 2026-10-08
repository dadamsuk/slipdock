defmodule SlipdockWeb.MCP.Tools.ReadPage do
  @moduledoc "One wiki page, its Markdown and its hash for a later edit."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Access, Repo, Wiki}
  alias Slipdock.Boards.Board
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  # Claude's clients take about 150k characters per tool result (W-21).
  @max_body 100_000

  @impl true
  def name, do: "read_page"

  @impl true
  def title, do: "Read a wiki page"

  @impl true
  def description,
    do:
      "A wiki page's Markdown. Page is its code (W-31), or with board: its slug or title. " <>
        "Keep content_hash: write_page needs it to edit without overwriting someone else. " <>
        "board says whose page it is, and whether that board is archived."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        page: %{
          type: "string",
          description: "Page code like W-31, or a slug or title with board."
        },
        board: %{type: "string", description: "The board, when page is a slug or title."}
      },
      required: ["page"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "page"),
         {:ok, board_ref} <- Args.optional(args, "board"),
         {:ok, page} <- find(ref, board_ref, auth),
         :ok <- readable(page, context.user),
         :ok <- Args.refusal(Authorize.page(auth, page, :read)),
         :ok <- visible(page, context.user) do
      page =
        Repo.preload(
          page,
          [:created_by, :updated_by, :assignee, :tags] ++ Wiki.board_preloads()
        )

      body = page.body || ""

      {:ok,
       page
       |> V.page()
       |> Map.take([
         :id,
         :code,
         :title,
         :slug,
         :summary,
         :status,
         :content_hash,
         :updated_at,
         :comments,
         :checklist
       ])
       |> Map.merge(%{
         board: board(page.board_id),
         body: String.slice(body, 0, @max_body),
         truncated: String.length(body) > @max_body,
         url: context.base_url <> V.page_url(page)
       })}
    end
  end

  defp find(ref, nil, auth), do: lookup(Wiki.find_page(ref, as: auth.assigns.current_user))

  defp find(ref, board_ref, auth) do
    with {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, board_ref, :read)) do
      lookup(Wiki.find_page(board, ref))
    end
  end

  # Which board, by more than its id: a page code reaches a page on any board
  # the reader can see, archived ones too, which list_boards leaves out unless
  # asked (#482). An archived board's sub-boards are archived with it.
  defp board(id) do
    board = Repo.get!(Board, id)
    root = if board.root_id, do: Repo.get!(Board, board.root_id), else: board
    %{id: board.id, code: board.code, name: board.name, archived: Board.archived?(root)}
  end

  defp lookup({:ok, page}), do: {:ok, page}
  defp lookup(_), do: {:error, "no page you can see matches that"}

  # A page code reaches any page, so one on a board the reader cannot see at
  # all is not there, the same as a board is (#482); "you don't read this
  # page" would say it exists. What a token's scope refuses still says so.
  defp readable(page, user) do
    if Access.can_read?(Access.page_permission(user, page)),
      do: :ok,
      else: {:error, "no page you can see matches that"}
  end

  # A draft is for its writers alone, and to anyone else is not there.
  defp visible(page, user) do
    if Wiki.visible?(page, Access.page_permission(user, page)),
      do: :ok,
      else: {:error, "no page you can see matches that"}
  end
end

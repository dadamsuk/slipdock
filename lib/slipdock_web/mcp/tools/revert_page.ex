defmodule SlipdockWeb.MCP.Tools.RevertPage do
  @moduledoc """
  Puts a wiki page back to one of its revisions, as the CLI's `page revert`
  does. A revert is a save of its own, so it is undone the same way; it needs
  the `base_hash` a rewrite does, so nobody's newer edit is lost to it unseen.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Access, Wiki}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args
  alias SlipdockWeb.MCP.Tools.PageHistory

  @impl true
  def name, do: "revert_page"

  @impl true
  def title, do: "Revert a wiki page"

  @impl true
  def description,
    do:
      "Puts a page back to a revision from page_history, as a new revision (nothing is lost). " <>
        "Needs base_hash: the page's current content_hash, from read_page or page_history."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        page: %{
          type: "string",
          description: "Page code like W-31, or a slug or title with board."
        },
        board: %{type: "string", description: "Board, when page is a slug or title."},
        rev: %{type: "integer", description: "The revision id to go back to."},
        base_hash: %{type: "string", description: "The page's content_hash as you last read it."},
        message: %{type: "string", description: "Why, for the page history."}
      },
      required: ["page", "rev", "base_hash"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def destructive?, do: true

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, page} <- page(args, auth, context.user),
         {:ok, rev} <- PageHistory.rev(args),
         {:ok, _} <- Args.required(args, "base_hash"),
         {:ok, revision} <- Args.refusal(Wiki.get_revision(page, rev)),
         {:ok, page} <- Args.refusal(Wiki.revert_page(page, revision, opts(args, context))) do
      page = Wiki.get_page!(page.id)
      [latest | _] = Wiki.list_revisions(page, 1)

      {:ok,
       page
       |> V.page_summary()
       |> Map.take([:id, :code, :title, :slug, :status, :content_hash])
       |> Map.merge(%{
         reverted_to: revision.id,
         revision: latest.id,
         url: context.base_url <> V.page_url(page)
       })}
    end
  end

  defp page(args, auth, user) do
    with {:ok, ref} <- Args.required(args, "page"),
         {:ok, board_ref} <- Args.optional(args, "board"),
         {:ok, page} <- find(ref, board_ref, auth),
         :ok <- Args.refusal(Authorize.page(auth, page, :write)) do
      if Wiki.visible?(page, Access.page_permission(user, page)),
        do: {:ok, page},
        else: {:error, "no page you can see matches that"}
    end
  end

  defp find(ref, nil, auth), do: lookup(Wiki.find_page(ref, as: auth.assigns.current_user))

  defp find(ref, board_ref, auth) do
    with {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, board_ref, :read)) do
      lookup(Wiki.find_page(board, ref))
    end
  end

  defp lookup({:ok, page}), do: {:ok, page}
  defp lookup(_), do: {:error, "no page you can see matches that"}

  # Recorded as made over MCP, under the token's name, as write_page's saves are.
  defp opts(args, %{user: user, token: token}) do
    [
      user: user,
      via: "mcp",
      agent: token.label,
      message: args["message"],
      base_hash: args["base_hash"]
    ]
  end
end

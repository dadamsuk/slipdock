defmodule SlipdockWeb.MCP.Tools.WritePage do
  @moduledoc "Writes a wiki page: a new one, or an append, section edit or rewrite."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Access, Wiki}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @modes ~w(create append append_section replace_section replace)

  @impl true
  def name, do: "write_page"

  @impl true
  def title, do: "Write a wiki page"

  @impl true
  def description,
    do:
      "Writes the board's wiki. mode create (board, title) makes a page; append and " <>
        "append_section add to one; replace_section and replace rewrite and need base_hash " <>
        "(content_hash from read_page). Search before creating."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        mode: %{type: "string", enum: @modes},
        page: %{
          type: "string",
          description: "Page code (W-31), or slug/title with board. Not for create."
        },
        board: %{type: "string", description: "Board for create, or for finding page by title."},
        title: %{type: "string", description: "For create."},
        body: %{type: "string", description: "Markdown."},
        section: %{
          type: "string",
          description: "Heading path for the section modes, e.g. \"Deploy/Rollback\"."
        },
        base_hash: %{type: "string", description: "content_hash you read; required to replace."},
        message: %{type: "string", description: "What changed, for the page history."}
      },
      required: ["mode", "body"],
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

    with {:ok, mode} <- mode(args),
         {:ok, body} <- body(args),
         {:ok, page} <- write(mode, args, body, auth, opts(args, context)) do
      page = Wiki.get_page!(page.id)

      {:ok,
       page
       |> V.page_summary()
       |> Map.take([:id, :code, :title, :slug, :status, :content_hash])
       |> Map.put(:url, context.base_url <> V.page_url(page))}
    end
  end

  defp mode(args) do
    case args["mode"] do
      m when m in @modes -> {:ok, m}
      _ -> {:error, "mode must be one of: #{Enum.join(@modes, ", ")}"}
    end
  end

  defp body(%{"body" => body}) when is_binary(body), do: {:ok, body}
  defp body(_), do: {:error, "body is required"}

  defp write("create", args, body, auth, opts) do
    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, title} <- Args.required(args, "title"),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :write)) do
      Args.refusal(Wiki.create_page(board, %{"title" => title, "body" => body}, opts))
    end
  end

  defp write(mode, args, body, auth, opts) do
    with {:ok, page} <- find(args, auth) do
      case mode do
        "append" ->
          Args.refusal(Wiki.append(page, body, opts))

        "append_section" ->
          with {:ok, path} <- Args.required(args, "section"),
               do: Args.refusal(Wiki.append_section(page, path, body, opts))

        "replace_section" ->
          with {:ok, path} <- Args.required(args, "section"),
               {:ok, _} <- Args.required(args, "base_hash"),
               do: Args.refusal(Wiki.replace_section(page, path, body, opts))

        "replace" ->
          with {:ok, _} <- Args.required(args, "base_hash"),
               do: Args.refusal(Wiki.update_page(page, %{"body" => body}, opts))
      end
    end
  end

  defp find(args, auth) do
    user = auth.assigns.current_user

    with {:ok, ref} <- Args.required(args, "page"),
         {:ok, board_ref} <- Args.optional(args, "board"),
         {:ok, page} <- lookup(ref, board_ref, auth),
         :ok <- Args.refusal(Authorize.page(auth, page, :write)) do
      if Wiki.visible?(page, Access.page_permission(user, page)),
        do: {:ok, page},
        else: {:error, "no page you can see matches that"}
    end
  end

  defp lookup(ref, nil, auth), do: found(Wiki.find_page(ref, as: auth.assigns.current_user))

  defp lookup(ref, board_ref, auth) do
    with {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, board_ref, :read)),
         do: found(Wiki.find_page(board, ref))
  end

  defp found({:ok, page}), do: {:ok, page}
  defp found(_), do: {:error, "no page you can see matches that"}

  # Who wrote it and how, for the page's history: "over MCP", and the token's
  # name as the agent — the client's name for a connector.
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

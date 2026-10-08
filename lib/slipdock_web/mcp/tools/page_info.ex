defmodule SlipdockWeb.MCP.Tools.PageInfo do
  @moduledoc """
  Finding the way round a wiki, as the CLI's `page links`, `page sections`,
  `page wanted` and `page resolve` do: one tool with a `what`, rather than
  four more names in the tool list.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Access, Wiki}
  alias Slipdock.Wiki.Page
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @whats ~w(links sections wanted resolve)

  @impl true
  def name, do: "page_info"

  @impl true
  def title, do: "Find your way round a wiki"

  @impl true
  def description,
    do:
      "what=links: a page's outgoing, incoming and unresolved links. sections: its heading " <>
        "paths, as write_page's section takes them. wanted: a board's linked-to, unwritten " <>
        "pages. resolve: is there a page for a title, and how to link it."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        what: %{type: "string", enum: @whats, description: "Which answer."},
        page: %{
          type: "string",
          description: "links, sections: page code like W-31, or a slug or title with board."
        },
        board: %{
          type: "string",
          description: "wanted, resolve: the board. Board id, code or name."
        },
        title: %{type: "string", description: "resolve: the page title to look for."}
      },
      required: ["what"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, what} <- Args.required(args, "what") do
      case what do
        "links" -> links(args, auth, context)
        "sections" -> sections(args, auth, context)
        "wanted" -> wanted(args, auth, context)
        "resolve" -> resolve(args, auth, context)
        _ -> {:error, "what must be links, sections, wanted or resolve"}
      end
    end
  end

  defp links(args, auth, context) do
    with {:ok, page} <- page(args, auth, context.user) do
      outgoing = Wiki.outgoing_links(page)

      {:ok,
       %{
         page: stub(page, context),
         outgoing: outgoing |> Enum.filter(& &1.resolved) |> Enum.map(&V.link/1),
         unresolved: outgoing |> Enum.reject(& &1.resolved) |> Enum.map(&V.link/1),
         incoming: page |> Wiki.backlinks(context.user) |> Enum.map(&V.backlink/1)
       }}
    end
  end

  defp sections(args, auth, context) do
    with {:ok, page} <- page(args, auth, context.user) do
      {:ok,
       %{
         page: stub(page, context),
         sections: Enum.map(Wiki.sections(page), &Map.take(&1, [:path, :title, :level]))
       }}
    end
  end

  # The pages doing the wanting are listed by name, so a draft among them
  # stays out of sight of anyone who could not open it, and so does an
  # archived one; a want only they asked for is not listed at all.
  defp wanted(args, auth, context) do
    with {:ok, board} <- board(args, auth) do
      level = Access.board_permission(context.user, board)
      shown? = &(not Page.archived?(&1) and Wiki.visible?(&1, level))

      wanted =
        board
        |> Wiki.wanted()
        |> Enum.map(&%{&1 | from: Enum.filter(&1.from, shown?)})
        |> Enum.reject(&(&1.from == []))

      {:ok, %{board: board_stub(board), wanted: Enum.map(wanted, &V.wanted/1)}}
    end
  end

  defp resolve(args, auth, context) do
    with {:ok, board} <- board(args, auth),
         {:ok, title} <- Args.required(args, "title") do
      writer? = Access.can_write?(Access.board_permission(context.user, board))

      case Wiki.find_page(board, title) do
        {:ok, page} ->
          if Wiki.visible?(page, Access.page_permission(context.user, page)),
            do: {:ok, found(board, page, context)},
            else: {:ok, missing(board, title, writer?)}

        _ ->
          {:ok, missing(board, title, writer?)}
      end
    end
  end

  defp found(board, page, context) do
    %{
      board: board_stub(board),
      found: true,
      page: stub(page, context),
      write_as: "[[#{page.title}]]"
    }
  end

  defp missing(board, title, writer?) do
    status = if writer?, do: nil, else: "published"

    %{
      board: board_stub(board),
      found: false,
      near:
        board |> Wiki.list_pages(q: title, status: status) |> Enum.take(5) |> Enum.map(&near/1),
      write_as: "[[#{title}]]",
      note: "no page answers to that yet; writing the link anyway leaves a wanted page"
    }
  end

  defp near(page), do: %{code: page.code, title: page.title, summary: page.summary}

  defp page(args, auth, user) do
    with {:ok, ref} <- Args.required(args, "page"),
         {:ok, board_ref} <- Args.optional(args, "board"),
         {:ok, page} <- find(ref, board_ref, auth),
         :ok <- Args.refusal(Authorize.page(auth, page, :read)) do
      # A draft is for its writers alone, and to anyone else is not there.
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

  defp board(args, auth) do
    with {:ok, ref} <- Args.required(args, "board") do
      Args.refusal(Authorize.fetch_board(auth, ref, :read))
    end
  end

  defp stub(page, context),
    do: %{code: page.code, title: page.title, url: context.base_url <> V.page_url(page)}

  defp board_stub(board), do: %{id: board.id, code: board.code, name: board.name}
end

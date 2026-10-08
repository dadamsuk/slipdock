defmodule SlipdockWeb.MCP.Tools.PageHistory do
  @moduledoc """
  A page's history, as the CLI's `page history` and `page diff` give it: the
  revisions newest first, or with `rev` or `diff` the change one save made.
  What an agent needs to see what it (or anyone) did to a page before
  `revert_page` puts it back.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Access, Wiki}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  # Unchanged runs longer than this are cut down to their ends, so a one-line
  # edit to a long page does not come back as the whole page.
  @context 3

  @impl true
  def name, do: "page_history"

  @impl true
  def title, do: "A wiki page's history"

  @impl true
  def description,
    do:
      "A page's revisions, newest first: id, author, via, message, time. With rev, that " <>
        "revision's body and the diff it made; diff=true alone gives the latest save's diff. " <>
        "revert_page puts a revision back."

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
        limit: %{type: "integer", description: "How many revisions to list. Default 20, max 100."},
        rev: %{type: "integer", description: "A revision id from the list: its body and diff."},
        diff: %{type: "boolean", description: "Without rev: the diff of the latest save."}
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

    with {:ok, page} <- page(args, auth, context.user),
         {:ok, diff?} <- Args.boolean(args, "diff", false) do
      cond do
        args["rev"] != nil -> one(page, args, context)
        diff? -> latest(page, context)
        true -> list(page, args, context)
      end
    end
  end

  defp list(page, args, context) do
    with {:ok, limit} <- Args.limit(args, "limit", 20, 100) do
      {:ok,
       %{
         page: stub(page, context),
         revisions: page |> Wiki.list_revisions(limit) |> Enum.map(&line/1)
       }}
    end
  end

  defp one(page, args, context) do
    with {:ok, rev} <- rev(args),
         {:ok, revision} <- Args.refusal(Wiki.get_revision(page, rev)) do
      {:ok, change(page, revision, context, body: true)}
    end
  end

  defp latest(page, context) do
    case Wiki.list_revisions(page, 1) do
      [revision] -> {:ok, change(page, revision, context, body: false)}
      [] -> {:error, "this page has no revisions yet"}
    end
  end

  defp change(page, revision, context, body: body?) do
    previous = Wiki.previous_revision(revision)
    before = if previous, do: previous.body, else: ""

    %{
      page: stub(page, context),
      revision: line(revision),
      previous: previous && previous.id,
      diff: before |> Wiki.diff(revision.body) |> V.diff() |> trim()
    }
    |> then(&if(body?, do: Map.put(&1, :body, revision.body), else: &1))
  end

  # The first and last run of unchanged lines only need the edge next to the
  # change; one in the middle keeps both edges.
  defp trim(hunks) do
    last = length(hunks) - 1

    hunks
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{op: "eq", lines: lines}, i} when length(lines) > 2 * @context ->
        keep_head = if i == 0, do: 0, else: @context
        keep_tail = if i == last, do: 0, else: @context
        skipped = length(lines) - keep_head - keep_tail

        Enum.reject(
          [
            keep_head > 0 && %{op: "eq", lines: Enum.take(lines, keep_head)},
            %{op: "skip", count: skipped},
            keep_tail > 0 && %{op: "eq", lines: Enum.take(lines, -keep_tail)}
          ],
          &(&1 == false)
        )

      {hunk, _} ->
        [hunk]
    end)
  end

  defp line(revision) do
    revision
    |> V.revision()
    |> Map.take([:id, :title, :summary, :via, :agent, :byte_size, :at])
    |> Map.put(:author, revision.author && revision.author.email)
  end

  @doc false
  # A revision id, as page_history lists them; revert_page reads it the same way.
  def rev(args) do
    case args["rev"] do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      s when is_binary(s) ->
        case Integer.parse(String.trim(s)) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "rev must be a revision id from page_history, like 812"}
        end

      _ ->
        {:error, "rev must be a revision id from page_history, like 812"}
    end
  end

  defp page(args, auth, user) do
    with {:ok, ref} <- Args.required(args, "page"),
         {:ok, board_ref} <- Args.optional(args, "board"),
         {:ok, page} <- find(ref, board_ref, auth),
         :ok <- Args.refusal(Authorize.page(auth, page, :read)) do
      # A draft is for its writers alone, and its history with it.
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

  defp stub(page, context),
    do: %{
      code: page.code,
      title: page.title,
      content_hash: page.content_hash,
      url: context.base_url <> V.page_url(page)
    }
end

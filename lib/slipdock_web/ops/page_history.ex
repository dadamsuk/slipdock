defmodule SlipdockWeb.Ops.PageHistory do
  @moduledoc """
  A wiki page's history, defined once (#3188): its revisions newest first,
  or with `rev` one revision's body, and with `diff` the change from the
  save before it (`previous`) or from another revision of the page (its
  id). `diff` without `rev` is the latest save's change. REST has two
  routes for it, `GET /api/pages/:id/revisions` and `GET
  /api/pages/:id/revisions/:rev`, the second this definition with `rev`
  from the path. (`?bodies=all`, every body for the encrypting client
  (W-103), is another thing, and `PageController.revisions/2`'s own.)

  Before it they disagreed. MCP's `rev` always came with its diff from the
  save before, `against` diffed from another revision and `diff: true` was
  the latest save's; REST's revision came without a diff unless asked,
  `diff=previous` or `diff=<id>`. Now `diff` is REST's, on both, and MCP's
  `against` and boolean `diff` are refused. REST's list was `{revisions}`
  and a revision `{revision, diff}`; MCP's had the page (with the
  `content_hash` `revert_page` wants) and revision lines with the author's
  email. Now both answer REST's shapes with MCP's `page` beside them, a
  revision as REST gives it (`author` `{id, email, name}`), and a diff with
  MCP's long unchanged runs cut (a `skip` hunk, `count` lines, `lines`
  empty so an older client prints nothing for it), so a one-line edit to a
  long page doesn't come back as the whole page. `limit` is REST's
  (default 100, at most 500), refused when it isn't a positive number, as
  MCP refused it, where REST took the default.
  """
  @behaviour SlipdockWeb.Ops.Op

  import SlipdockWeb.Ops.Shared, only: [fetch_page: 4, base_url: 1]

  alias Slipdock.Wiki
  alias SlipdockWeb.API.JSON, as: V

  # Unchanged runs longer than twice this are cut down to their ends.
  @context 3

  @impl true
  def definition do
    %{
      name: "page_history",
      title: "A wiki page's history",
      summary:
        "A page's revisions, newest first: id, author, via, summary, time. With rev, that " <>
          "revision's body; diff: \"previous\" (or another revision's id) adds the change " <>
          "it made, and without rev is the latest save's. revert_page puts a revision back.",
      verb: :get,
      path: "/api/pages/:id/revisions",
      permission: {:page, :read},
      writes?: false,
      params: [
        %{
          name: "page",
          type: :string,
          required: true,
          in_path: "id",
          doc: "Page code like W-31, or a slug or title with board."
        },
        %{name: "board", type: :string, doc: "Board, when page is a slug or title."},
        %{
          name: "limit",
          type: :integer,
          default: 100,
          max: 500,
          doc: "How many revisions to list. Default 100, max 500."
        },
        %{name: "rev", type: :integer, doc: "A revision id from the list: its body."},
        %{
          name: "diff",
          type: :any,
          schema: %{type: ["string", "integer"]},
          doc:
            "\"previous\": the change from the save before; a revision id of the page: the " <>
              "change from that one. Without rev, of the latest save."
        }
      ],
      cli: %{
        command: "page history",
        positional: ["page"],
        flags: %{
          "limit" => %{param: "limit"},
          "rev" => %{param: "rev"},
          "against" => %{param: "diff"}
        }
      }
    }
  end

  @impl true
  def run(%{"page" => ref} = params, auth) do
    with {:ok, page} <- fetch_page(auth, ref, params["board"], :read),
         do: answer(page, stub(page, auth), params)
  end

  # The list, or one revision.
  defp answer(page, stub, params)
       when not is_map_key(params, "rev") and not is_map_key(params, "diff") do
    revisions = page |> Wiki.list_revisions(params["limit"]) |> Enum.map(&V.revision/1)
    {:ok, %{page: stub, revisions: revisions}}
  end

  defp answer(page, stub, params) do
    with {:ok, revision} <- revision(page, params["rev"]),
         do: one(page, stub, revision, params["diff"])
  end

  # The one asked for, or (a diff without rev) the latest save.
  defp revision(page, nil) do
    case Wiki.list_revisions(page, 1) do
      [latest] -> {:ok, latest}
      [] -> {:error, :unprocessable_entity, "this page has no revisions yet"}
    end
  end

  defp revision(page, rev), do: Wiki.get_revision(page, rev)

  defp one(page, stub, revision, diff) do
    with {:ok, before} <- diff_base(page, revision, diff) do
      answer = %{page: stub, revision: revision |> V.revision() |> Map.put(:body, revision.body)}

      case before do
        :none ->
          {:ok, answer}

        text ->
          {:ok, Map.put(answer, :diff, text |> Wiki.diff(revision.body) |> V.diff() |> trim())}
      end
    end
  end

  # What a revision is diffed from: nothing asked, the one before it, or
  # another version of the same page by id.
  defp diff_base(_page, _revision, nil), do: {:ok, :none}

  defp diff_base(_page, revision, "previous") do
    previous = Wiki.previous_revision(revision)
    {:ok, if(previous, do: previous.body, else: "")}
  end

  defp diff_base(page, _revision, other) do
    with {n, ""} when n > 0 <- Integer.parse(to_string(other)),
         {:ok, base} <- Wiki.get_revision(page, n) do
      {:ok, base.body}
    else
      {:error, _, _} = not_found -> not_found
      _ -> {:error, :bad_request, "diff must be \"previous\" or a revision id of this page"}
    end
  end

  # The first and last run of unchanged lines only need the edge next to the
  # change; one in the middle keeps both edges. What is cut is a `skip` hunk.
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
            %{op: "skip", count: skipped, lines: []},
            keep_tail > 0 && %{op: "eq", lines: Enum.take(lines, -keep_tail)}
          ],
          &(&1 == false)
        )

      {hunk, _} ->
        [hunk]
    end)
  end

  defp stub(page, auth),
    do: %{
      code: page.code,
      title: page.title,
      content_hash: page.content_hash,
      url: base_url(auth) <> V.page_url(page)
    }
end

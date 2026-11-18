defmodule SlipdockWeb.Ops.RevertPage do
  @moduledoc """
  Putting a wiki page back to one of its revisions, defined once (#3188). A
  revert is a save of its own, so nothing is lost and it is undone the same
  way; it needs the `base_hash` a rewrite does, so nobody's newer edit is
  lost to it unseen (a stale one is a 409 with the page as it stands).

  Before it, MCP called the revision `rev` and REST `revision` (or
  `revision_id`): now both take `revision`, and MCP refuses `rev` (naming
  the arguments it takes) while REST answers a missing `revision` with
  "revision is required". REST took no `base_hash` as last-write-wins;
  MCP required it on purpose: now both do (the CLI reads the page's hash
  first). REST answered `{page}`, MCP the page's summary with
  `reverted_to` and `revision` (the new revision): now both answer `{page,
  reverted_to, revision}`, the page in full as REST gave it. Either takes
  `board` for a page named by slug or title, and records the way it came
  in and the token's name, as every page write does.
  """
  @behaviour SlipdockWeb.Ops.Op

  import SlipdockWeb.Ops.Shared, only: [actor: 1, fetch_page: 4, via: 1]

  alias Slipdock.Wiki
  alias SlipdockWeb.API.JSON, as: V

  @impl true
  def definition do
    %{
      name: "revert_page",
      title: "Revert a wiki page",
      summary:
        "Puts a page back to a revision from page_history, as a new revision (nothing is lost). " <>
          "Needs base_hash: the page's current content_hash, from read_page or page_history.",
      verb: :post,
      path: "/api/pages/:id/revert",
      permission: {:page, :write},
      writes?: true,
      destructive?: true,
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
          name: "revision",
          type: :integer,
          required: true,
          doc: "The revision id to go back to."
        },
        %{
          name: "base_hash",
          type: :string,
          required: true,
          doc: "The page's content_hash as you last read it."
        },
        %{name: "message", type: :string, doc: "Why, for the page history."}
      ],
      cli: %{
        command: "page revert",
        positional: ["page"],
        flags: %{
          "rev" => %{param: "revision"},
          "message" => %{param: "message"},
          "base_hash" => %{param: "base_hash"}
        }
      }
    }
  end

  @impl true
  def run(%{"page" => ref, "revision" => rev} = params, auth) do
    with {:ok, page} <- fetch_page(auth, ref, params["board"], :write),
         {:ok, revision} <- Wiki.get_revision(page, rev),
         {:ok, page} <- Wiki.revert_page(page, revision, opts(params, auth)) do
      page = Wiki.get_page!(page.id)
      [latest | _] = Wiki.list_revisions(page, 1)

      {:ok,
       %{
         page: V.page(with_users(page)),
         reverted_to: revision.id,
         revision: latest.id
       }}
    end
  end

  defp opts(params, auth) do
    [
      user: auth.assigns.current_user,
      via: via(auth),
      agent: actor(auth).agent,
      message: params["message"],
      base_hash: params["base_hash"]
    ]
  end

  defp with_users(page),
    do:
      Wiki.with_board_preloads(page, [
        :created_by,
        :updated_by,
        :assignee,
        :tags,
        [field_values: :field]
      ])
end

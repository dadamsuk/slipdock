defmodule SlipdockWeb.API.PageController do
  @moduledoc """
  The wiki over HTTP: anything a person can do to a page, a token can do too.

  Three choices worth knowing before reading the actions:

    * **Reads return Markdown source**, not HTML and not a JSON tree. The
      model edits what it reads.
    * **`base_hash` is optional but recommended.** Send the `content_hash`
      you read and a save that would land on top of someone else's comes back
      as a 409 with both versions. Leave it out and you get last-write-wins,
      which the revision written on the way past makes recoverable rather
      than lost.
    * **Every write records who made it** — `via` from the client (the CLI
      says so in a header), `agent` from the API token's own name — so
      provenance shows up in the page's history rather than in a separate log.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Boards, Wiki}
  alias Slipdock.Wiki.{Archive, FolderPlacements, FrontMatter, Page, PageTools, Placements, Query}
  alias SlipdockWeb.API.Authorize
  alias Slipdock.Wiki.Sharing
  alias SlipdockWeb.API.Uploads
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.Wiki.Renderer

  action_fallback SlipdockWeb.API.FallbackController

  # The page's own fields, plus the card facets it carries (see
  # `Slipdock.Wiki.Page`), so one PATCH sets either.
  @page_fields ~w(title body summary slug status template parent_id folder_id
                  priority flags start_date due_date date_precision completed
                  percent_complete color icon)

  ## Listing and creating -----------------------------------------------------

  def index(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      opts = list_opts(conn, board, params)

      cond do
        truthy?(params["tree"]) ->
          json(conn, %{pages: V.page_tree(Wiki.tree(board, opts))})

        truthy?(params["recent"]) ->
          pages = board |> Wiki.list_pages(opts) |> recent()
          json(conn, %{pages: Enum.map(pages, &V.page_summary/1)})

        true ->
          json(conn, %{pages: Enum.map(Wiki.list_pages(board, opts), &V.page_summary/1)})
      end
    end
  end

  # `recent`: the wiki tree's Recent view (#738) — the most recently edited
  # first, the newest 100.
  @recent 100

  defp recent(pages), do: pages |> Wiki.newest_first() |> Enum.take(@recent)

  # Drafts are half-written by definition, so a reader who could not edit the
  # page never sees one listed.
  defp list_opts(conn, board, params) do
    status =
      if writer?(conn, board), do: params["status"], else: "published"

    [
      archived: archived_opt(params["archived"]),
      template: boolean_opt(params["template"]),
      status: status,
      q: params["q"],
      parent: parent_opt(params["parent"]),
      folder: folder_opt(board, params["folder"]),
      note_tag: params["note_tag"],
      as: conn.assigns.current_user
    ]
  end

  defp folder_opt(_board, nil), do: nil
  defp folder_opt(_board, ""), do: nil
  defp folder_opt(_board, ref) when ref in ["none", "root"], do: :none

  defp folder_opt(board, ref) do
    case Wiki.find_folder(board, ref) do
      {:ok, folder} -> folder
      _ -> nil
    end
  end

  defp archived_opt("all"), do: :all
  defp archived_opt(value), do: truthy?(value)

  defp boolean_opt(nil), do: nil
  defp boolean_opt(""), do: nil
  defp boolean_opt(value), do: truthy?(value)

  defp parent_opt(nil), do: nil
  defp parent_opt(""), do: nil
  defp parent_opt("root"), do: :root
  defp parent_opt("none"), do: :root

  defp parent_opt(ref) do
    case Integer.parse(to_string(ref)) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp truthy?(value), do: Enum.member?(~w(true 1 yes on), to_string(value))

  def create(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, attrs} <- page_attrs(conn, board, params),
         {:ok, attrs} <- front_matter(attrs, params, nil),
         {:ok, page} <- Wiki.create_page(board, attrs, write_opts(conn, params)) do
      conn |> put_status(:created) |> json(%{page: V.page(with_users(page))})
    end
  end

  @doc """
  The tags a board's notes give themselves — front matter `tags` and inline
  `#tags`, read on boards in a vault — with how many pages carry each. A
  nested tag counts for its parents too. Never the board's card tags.
  """
  def note_tags(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      json(conn, %{tags: Slipdock.Wiki.NoteTags.counts(board)})
    end
  end

  ## One page -----------------------------------------------------------------

  def show(conn, %{"id" => id}) do
    with {:ok, page} <- fetch_page(conn, id, :read) do
      json(conn, %{page: page |> with_users() |> V.page() |> for_reader(conn)})
    end
  end

  # Read through a share (#817), a page says nothing of the board's other
  # folders: the places it is also filed are kept only where the reader can go.
  defp for_reader(%{also_in: also} = json, conn) do
    user = conn.assigns.current_user

    readable =
      Enum.filter(also, fn %{folder_id: id} ->
        case Wiki.get_folder(id) do
          nil -> false
          folder -> Slipdock.Access.can_read?(Slipdock.Access.folder_permission(user, folder))
        end
      end)

    %{json | also_in: readable}
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         board <- Wiki.board_of(page),
         params <- Map.put_new(params, "flags", page.flags),
         {:ok, attrs} <- page_attrs(conn, board, params),
         {:ok, attrs} <- front_matter(attrs, params, page.front_matter),
         {:ok, page} <- Wiki.update_page(page, attrs, write_opts(conn, params)),
         :ok <- set_fields(board, page, params["fields"]) do
      json(conn, %{page: V.page(with_users(Wiki.get_page!(page.id)))})
    end
  end

  # `fields` is a map of field key (or name, or id) to value; "" clears one.
  # A page holds the board's custom fields exactly as a card does.
  defp set_fields(_board, _page, nil), do: :ok

  defp set_fields(board, page, values) when is_map(values) do
    fields = Slipdock.Fields.list_fields(Slipdock.Boards.Board.root_id(board))

    Enum.reduce_while(values, :ok, fn {ref, value}, :ok ->
      case Slipdock.Fields.find_field(fields, ref) do
        nil ->
          {:halt, {:error, :not_found, "field #{ref}"}}

        field ->
          case Slipdock.Fields.set_value(Wiki.get_page!(page.id), field, value) do
            {:ok, _} -> {:cont, :ok}
            {:error, message} -> {:halt, {:error, :unprocessable_entity, message}}
          end
      end
    end)
  end

  defp set_fields(_, _, _), do: {:error, :unprocessable_entity, "fields must be an object"}

  @doc """
  Archives the page and everything beneath it. `?purge=true` deletes it and
  its history for good, and only the board's owner may do that.
  """
  def delete(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         :ok <- Sharing.check(conn.assigns.current_user, :delete, page) do
      if truthy?(params["purge"]) do
        with :ok <- Authorize.board(conn, Wiki.board_of(page), :owner),
             {:ok, _} <- Wiki.delete_page(page) do
          json(conn, %{deleted: true, id: page.id, code: page.code})
        end
      else
        with {:ok, page} <- Wiki.archive_page(page) do
          json(conn, %{page: V.page(with_users(page))})
        end
      end
    end
  end

  def restore(conn, %{"id" => id}) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         :ok <- Sharing.check(conn.assigns.current_user, :delete, page),
         {:ok, page} <- Wiki.unarchive_page(page) do
      json(conn, %{page: V.page(with_users(page))})
    end
  end

  @doc "Reparents or reorders a page: `{parent, position}`."
  # To another board of the page's vault (W-103 R11.8): it keeps its code
  # and what is its own, and `dry_run` says what would be carried and what
  # dropped without moving anything (see `Slipdock.Wiki.Move`).
  def move(conn, %{"id" => id, "board" => board_ref} = params) when board_ref not in [nil, ""] do
    user = conn.assigns.current_user

    with {:ok, page} <- fetch_page(conn, id, :write),
         {:ok, target} <- Authorize.fetch_board(conn, board_ref, :write),
         {:ok, folder} <- move_folder_param(target, params["folder"]) do
      if truthy?(params["dry_run"]) do
        with {:ok, report} <- Wiki.Move.preview(page, target, user),
             do: json(conn, %{dry_run: true, board: target.code, report: report})
      else
        with {:ok, page} <- Wiki.Move.to_board(page, target, folder, user, via: via(conn)),
             do: json(conn, %{page: V.page(with_users(page))})
      end
    end
  end

  def move(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         board <- Wiki.board_of(page),
         {:ok, parent} <- resolve_parent(board, params["parent"]),
         {:ok, page} <- Wiki.move_page(page, parent, position(params["position"])) do
      json(conn, %{page: V.page(with_users(page))})
    end
  end

  defp move_folder_param(_board, ref) when ref in [nil, "", "root", "none"], do: {:ok, nil}
  defp move_folder_param(board, ref), do: Wiki.find_folder(board, ref)

  defp position(nil), do: :bottom
  defp position("top"), do: :top
  defp position("bottom"), do: :bottom
  defp position(n) when is_integer(n), do: n

  defp position(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> :bottom
    end
  end

  defp position(_), do: :bottom

  ## Rendering and sections --------------------------------------------------

  @doc """
  The page with every reference resolved — links followed, card chips filled
  in with what the card says now, directives expanded.

  An agent reading a document wants the *answers*, not the syntax, so this is
  a first-class endpoint rather than a flag on `show`. `?format=markdown`
  (the default) returns tables and links it can reason over; `html` returns
  what a browser would show; `text` strips the markup entirely.
  """
  def render_page(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :read) do
      opts = [page: page, board: Wiki.board_of(page), as: conn.assigns.current_user]

      case params["format"] || "markdown" do
        "html" ->
          json(conn, %{
            page: V.page_summary(page),
            format: "html",
            body: Renderer.to_html(page.body, opts)
          })

        "text" ->
          body = page.body |> Renderer.to_markdown(opts) |> strip_markdown()
          json(conn, %{page: V.page_summary(page), format: "text", body: body})

        "markdown" ->
          json(conn, %{
            page: V.page_summary(page),
            format: "markdown",
            body: Renderer.to_markdown(page.body, opts)
          })

        other ->
          {:error, :bad_request, "format must be markdown, html or text (got #{inspect(other)})"}
      end
    end
  end

  defp strip_markdown(body) do
    body
    |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/^\s{0,3}\#{1,6}\s+/m, "")
    |> String.replace(~r/[*_`]+/, "")
  end

  @doc "The headings of a page, as the paths `section` accepts."
  def sections(conn, %{"id" => id}) do
    with {:ok, page} <- fetch_page(conn, id, :read) do
      json(conn, %{
        sections: Enum.map(Wiki.sections(page), &Map.take(&1, [:path, :title, :level]))
      })
    end
  end

  @doc "One section's text, heading included."
  def read_section(conn, %{"id" => id, "path" => path}) do
    with {:ok, page} <- fetch_page(conn, id, :read),
         {:ok, text} <- Wiki.read_section(page, section_path(path)) do
      json(conn, %{page: V.page_summary(page), path: section_path(path), body: text})
    end
  end

  @doc "Replaces one section. Honours `base_hash` like any other write."
  def replace_section(conn, %{"id" => id, "path" => path} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         {:ok, text} <- require_body(params),
         {:ok, page} <-
           Wiki.replace_section(page, section_path(path), text, write_opts(conn, params)) do
      json(conn, %{page: V.page(with_users(page))})
    end
  end

  @doc """
  Adds to the end of one section. The cheap, safe write: it takes no
  `base_hash` because it cannot clobber anything.
  """
  def append_section(conn, %{"id" => id, "path" => path} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         {:ok, text} <- require_body(params),
         {:ok, page} <-
           Wiki.append_section(page, section_path(path), text, write_opts(conn, params)) do
      json(conn, %{page: V.page(with_users(page))})
    end
  end

  @doc "Adds to the end of the page."
  def append(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         {:ok, text} <- require_body(params),
         {:ok, page} <- Wiki.append(page, text, write_opts(conn, params)) do
      json(conn, %{page: V.page(with_users(page))})
    end
  end

  # A section path arrives as the rest of the route, so "Deploy/Rollback" is
  # two segments.
  defp section_path(path) when is_list(path), do: Enum.join(path, "/")
  defp section_path(path), do: to_string(path)

  defp require_body(%{"body" => body}) when is_binary(body), do: {:ok, body}
  defp require_body(%{"text" => text}) when is_binary(text), do: {:ok, text}
  defp require_body(_), do: {:error, :bad_request, "pass the text as `body`"}

  ## The graph ----------------------------------------------------------------

  @doc "What this page points at, what points at it, and what it wanted but did not find."
  def links(conn, %{"id" => id}) do
    with {:ok, page} <- fetch_page(conn, id, :read) do
      outgoing = Wiki.outgoing_links(page)

      json(conn, %{
        outgoing: outgoing |> Enum.filter(& &1.resolved) |> Enum.map(&V.link/1),
        unresolved: outgoing |> Enum.reject(& &1.resolved) |> Enum.map(&V.link/1),
        incoming:
          page
          |> Wiki.backlinks(conn.assigns.current_user)
          |> Enum.map(&V.backlink/1)
      })
    end
  end

  @doc """
  Pins (or unpins) this page against a card or another page: "this document
  is *the* spec for that".
  """
  def pin(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         {:ok, target} <- pin_target(conn, params),
         {:ok, _} <- Wiki.pin(page, target, params["pinned"] != false) do
      json(conn, %{page: V.page_summary(page), pinned: params["pinned"] != false})
    end
  end

  defp pin_target(conn, %{"card" => ref}) do
    with {:ok, card} <- fetch_card(ref),
         :ok <- Authorize.card(conn, card, :read) do
      {:ok, {:card, card}}
    end
  end

  defp pin_target(conn, %{"page" => ref}) do
    with {:ok, page} <- fetch_page(conn, ref, :read), do: {:ok, {:page, page}}
  end

  defp pin_target(_conn, _params),
    do: {:error, :bad_request, "say what to pin to: `card` or `page`"}

  defp fetch_card(ref) do
    case Integer.parse(to_string(ref)) do
      {id, ""} ->
        case Slipdock.Repo.get(Slipdock.Boards.Card, id) do
          nil -> {:error, :not_found, "card #{ref}"}
          card -> {:ok, card}
        end

      _ ->
        {:error, :bad_request, "a card is named by its number"}
    end
  end

  @doc "Pages linked to but never written — the wiki's own backlog."
  def wanted(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      json(conn, %{wanted: Enum.map(Wiki.wanted(board), &V.wanted/1)})
    end
  end

  @doc """
  Turns a title into a page, so a link can be written safely rather than
  guessed at. Answers with the page, or with what is nearest to it.
  """
  def resolve(conn, params) do
    with {:ok, board} <- Authorize.fetch_board(conn, params["board"], :read) do
      title = params["title"] || params["q"] || ""

      case Wiki.find_page(board, title) do
        {:ok, page} ->
          json(conn, %{found: true, page: V.page_summary(page), write_as: "[[#{page.title}]]"})

        _ ->
          near = Wiki.list_pages(board, q: title) |> Enum.take(5)

          json(conn, %{
            found: false,
            near: Enum.map(near, &V.page_summary/1),
            write_as: "[[#{title}]]",
            note: "no page answers to that yet; writing the link anyway leaves a wanted page"
          })
      end
    end
  end

  ## On the board --------------------------------------------------------------

  @doc """
  Puts a page in one of its board's lists, so it sits beside the work it
  describes and can be dragged about like a card.

  `column` names the list; `before` says where in it, counting cards as well
  as pages — a card's number, or `"page-7"` — and the end when left out.
  `{"column": null}` takes the page off the board again; it stays exactly
  where it is in the wiki either way.
  """
  def place(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write) do
      case params["column"] do
        nil ->
          with {:ok, page} <- Wiki.unplace(page) do
            json(conn, %{page: V.page(with_users(page)), placed: false})
          end

        ref ->
          with {:ok, column} <- resolve_column(Wiki.board_of(page), ref),
               {:ok, page} <- Wiki.place(page, column, params["before"]) do
            json(conn, %{
              page: V.page(with_users(page)),
              placed: true,
              column: %{id: column.id, name: column.name}
            })
          end
      end
    end
  end

  @doc "Takes a page off the board, leaving it exactly where it is in the wiki."
  def unplace(conn, %{"id" => id}) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         {:ok, page} <- Wiki.unplace(page) do
      json(conn, %{page: V.page(with_users(page)), placed: false})
    end
  end

  ## Publishing ---------------------------------------------------------------

  @doc """
  Publishes a page read-only at `/w/:token`, or withdraws it with
  `{"published": false}`.

  The page's live queries are answered **now** and the answers stored: there
  is nobody behind an anonymous request to have permissions, so answering one
  then would be a way to read private cards from the open web. Publishing
  again refreshes them.
  """
  def publish(conn, %{"id" => id} = params) do
    # A public link hands the page to anyone: passing a share on (#816).
    with {:ok, page} <- fetch_page(conn, id, :write),
         :ok <- Sharing.check(conn.assigns.current_user, :share, page) do
      if params["published"] == false do
        with {:ok, page} <- Wiki.unpublish(page) do
          json(conn, %{page: V.page(with_users(page)), published: false})
        end
      else
        with {:ok, page} <- Wiki.publish(page, user: conn.assigns.current_user) do
          json(conn, %{
            page: V.page(with_users(page)),
            published: true,
            url: "/w/#{page.public_token}",
            note: "the answers in it were worked out now, and refresh when you publish again"
          })
        end
      end
    end
  end

  ## Out and back in ----------------------------------------------------------

  @doc """
  A board's wiki as Markdown files: `[{path, body}]` with front matter, the
  same thing `/boards/:id/wiki.zip` puts in a zip.
  """
  def export(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      opts =
        if writer?(conn, board),
          do: [archived: archived_opt(params["archived"])],
          else: [archived: archived_opt(params["archived"]), status: "published"]

      files = Archive.files(board, opts)

      json(conn, %{
        board: %{id: board.id, name: board.name, code: board.code},
        count: length(files),
        files: Enum.map(files, fn {path, body} -> %{path: path, body: body} end)
      })
    end
  end

  @doc """
  Writes Markdown files into a board's wiki.

  `files` is `[{path, body}]` — the shape `export` returns — so a wiki can be
  moved between boards by pasting one answer into the other. Folders in a path
  become parent pages. A title that is already on the board is skipped and
  reported unless `overwrite` is true, so importing twice is not a wiki twice.
  """
  def import_files(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, files} <- read_files(params["files"]) do
      result =
        Archive.import_files(board, files,
          user: conn.assigns.current_user,
          via: via(conn),
          agent: agent(conn),
          message: params["message"] || "imported",
          overwrite: params["overwrite"] == true
        )

      json(conn, %{
        created: Enum.map(result.created, &V.page_summary/1),
        skipped: Enum.map(result.skipped, &%{path: &1.path, reason: &1.reason})
      })
    end
  end

  defp read_files(files) when is_list(files) and files != [] do
    Enum.reduce_while(files, {:ok, []}, fn
      %{"path" => path, "body" => body}, {:ok, acc} when is_binary(path) and is_binary(body) ->
        {:cont, {:ok, acc ++ [{path, body}]}}

      other, _acc ->
        {:halt,
         {:error, :bad_request, "each file needs a path and a body (got #{inspect(other)})"}}
    end)
  end

  defp read_files(_), do: {:error, :bad_request, "pass `files` as a list of {path, body}"}

  ## The query language -------------------------------------------------------

  @doc """
  The grammar a ```slipdock block is written in, as data: the views, the
  settings, the filter operators and the fields they may name.

  Generated from the code, so it cannot drift from what the parser accepts —
  the same bargain `/api/automations/vocabulary` makes.
  """
  def query_vocabulary(conn, _params) do
    json(conn, %{
      views: Query.views(),
      settings: Query.keys(),
      fields: Query.filter_fields(),
      operators: [
        %{write: "field = value", means: "is"},
        %{write: "field != value", means: "is not"},
        %{write: "field ~ text", means: "contains"},
        %{write: "field !~ text", means: "does not contain"},
        %{write: "field in a|b", means: "any of"},
        %{write: "field not in a|b", means: "none of"},
        %{write: "field < value", means: "before (dates) or less than (numbers)"},
        %{write: "field > value", means: "after, or greater than"},
        %{write: "field within 7d", means: "a date in the next N days"},
        %{write: "field older than 30d", means: "a date more than N days ago"},
        %{write: "field set", means: "has a value"},
        %{write: "field not set", means: "has none"}
      ],
      values: [
        "today",
        "tomorrow",
        "yesterday",
        "+7d",
        "-3d",
        "YYYY-MM-DD",
        "true",
        "false",
        "a number",
        "text"
      ],
      example: """
      ```slipdock
      view: table
      board: this
      filter: flag=blocked, due < +7d, priority in high|critical
      group: assignee
      sort: due_date asc
      fields: title, assignee, due_date, status
      limit: 20
      empty: "Nothing blocked and due this week."
      ```
      """,
      note:
        "A block is answered when the page is read, with the reader's own permissions — " <>
          "never the author's. Boards the reader cannot read are dropped before any card is looked at."
    })
  end

  @doc """
  Checks a block without writing it anywhere: `{ok: true}` with the answer it
  would give, or the reason it cannot be answered.
  """
  def check_query(conn, params) do
    with {:ok, board} <- Authorize.fetch_board(conn, params["board"], :read),
         {:ok, text} <- require_body(Map.put_new(params, "body", params["query"])) do
      context = %{board: board, reader: conn.assigns.current_user}

      case Query.parse(text) do
        {:ok, query} ->
          case Query.run(query, context) do
            {:ok, result} ->
              json(conn, %{ok: true, answer: V.query_result(result)})

            {:error, message} ->
              json(conn, %{ok: false, error: message})
          end

        {:error, message} ->
          json(conn, %{ok: false, error: message})
      end
    end
  end

  ## From a card, and back ---------------------------------------------------

  @doc "The wiki pages that talk about this card, pinned first."
  def for_card(conn, %{"id" => id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :read) do
      pages =
        card
        |> Wiki.pages_for_card(conn.assigns.current_user)
        |> Enum.map(&%{page: V.page_summary(&1.page), pinned: &1.pinned, count: &1.count})

      json(conn, %{pages: pages})
    end
  end

  @doc """
  "Write it up": starts a page for a card, pinned to it.

  `template` names a template page on the board to start from; without one the
  page arrives as a stub with a `## Log` to append to. Either way the pin is
  the point — a page explaining a card is no use if the person looking at the
  card cannot see it exists.
  """
  def write_up(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, page} <-
           Wiki.create_page_from_card(
             card,
             write_opts(conn, params) ++
               [
                 title: params["title"],
                 template: params["template"],
                 folder: params["folder"],
                 body: params["body"],
                 summary: params["summary"],
                 values: params["values"] || %{}
               ]
           ) do
      conn |> put_status(:created) |> json(%{page: V.page(with_users(page))})
    end
  end

  @doc """
  Turns a passage of a page into a card, writing the link into both ends.

  `text` is the passage: its first line becomes the title and the rest the
  description, with a link back to the page.
  """
  def make_card(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         {:ok, text} <- require_body(Map.put_new(params, "body", params["text"])),
         board <- Boards.get_board!(page.board_id),
         {:ok, column} <- resolve_column(board, params["column"]),
         {:ok, card} <-
           Wiki.create_card_from_selection(page, column, text, write_opts(conn, params)) do
      conn
      |> put_status(:created)
      |> json(%{card: V.card(Authorize.visible(conn, Boards.get_card!(card.id)))})
    end
  end

  @doc """
  Runs one of the AI tools over a page (#1539): `Slipdock.Wiki.PageTools`, on
  the caller's AI key. It only answers, so reading the page is enough.
  """
  def ai(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :read),
         {:ok, answer} <-
           PageTools.run(
             params["tool"],
             %{title: page.title, body: page.body},
             conn.assigns.current_user
           ) do
      json(conn, %{page: page.code, answer: answer})
    end
  end

  defp resolve_column(board, nil) do
    case Boards.get_board!(board.id).columns do
      [first | _] -> {:ok, first}
      [] -> {:error, :bad_request, "board has no lists"}
    end
  end

  defp resolve_column(board, ref) do
    case Boards.find_column(board, ref) do
      {:ok, column} -> {:ok, column}
      _ -> {:error, :not_found, "list #{inspect(ref)}"}
    end
  end

  @doc """
  Makes a page from a template page, filling its `{{…}}` placeholders.

  `values` supplies anything beyond the built-in bindings; `card` names a card
  whose details the placeholders may use and which the page is pinned to.
  """
  def from_template(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, template} <- fetch_template(board, params["template"]),
         {:ok, card} <- optional_card(conn, params["card"]),
         {:ok, page} <-
           Wiki.create_from_template(
             board,
             template,
             params["values"] || %{},
             write_opts(conn, params) ++
               [title: params["title"], card: card, folder: params["folder"]]
           ) do
      conn |> put_status(:created) |> json(%{page: V.page(with_users(page))})
    end
  end

  defp fetch_template(_board, nil), do: {:error, :bad_request, "name the `template` to use"}

  defp fetch_template(board, ref) do
    case Wiki.find_page(board, ref) do
      {:ok, %Page{template: true} = page} -> {:ok, page}
      {:ok, %Page{}} -> {:error, :bad_request, "#{inspect(ref)} is a page, not a template"}
      _ -> {:error, :not_found, "template #{inspect(ref)}"}
    end
  end

  defp optional_card(_conn, nil), do: {:ok, nil}
  defp optional_card(_conn, ""), do: {:ok, nil}

  defp optional_card(conn, ref) do
    with {:ok, card} <- fetch_card(ref),
         :ok <- Authorize.card(conn, card, :read) do
      {:ok, card}
    end
  end

  ## History ------------------------------------------------------------------

  def revisions(conn, %{"id" => id, "bodies" => "all"}) do
    # Every revision's body, oldest first: what a client that has just
    # encrypted a passage matches against, on its own side (W-103 R6.2).
    with {:ok, page} <- fetch_page(conn, id, :read) do
      json(conn, %{revisions: Wiki.revision_bodies(page)})
    end
  end

  def revisions(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :read) do
      limit = params["limit"] |> to_limit()
      json(conn, %{revisions: Enum.map(Wiki.list_revisions(page, limit), &V.revision/1)})
    end
  end

  @doc """
  Deletes the named revisions, which the client found still hold text it
  has since encrypted (`Slipdock.Wiki.purge_revisions/3`): the board's owner
  only, never the newest revision, logged. `{"ids": [..]}`.
  """
  def purge_revisions(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         :ok <- Sharing.check(conn.assigns.current_user, :delete, page) do
      case Wiki.purge_revisions(page, List.wrap(params["ids"]), user: conn.assigns.current_user) do
        {:ok, count} ->
          json(conn, %{purged: count})

        {:error, :forbidden} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "only the board's owner can purge a page's revisions"})
      end
    end
  end

  defp to_limit(nil), do: 100

  defp to_limit(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 0 -> min(n, 500)
      _ -> 100
    end
  end

  @doc """
  One revision: its body, and with `?diff=previous` the change it made,
  as hunks of equal, deleted and inserted lines. `?diff=<revision id>`
  diffs from that version of the same page to this one instead, so any two
  versions can be compared.
  """
  def revision(conn, %{"id" => id, "rev" => rev} = params) do
    with {:ok, page} <- fetch_page(conn, id, :read),
         {:ok, revision} <- Wiki.get_revision(page, rev),
         {:ok, before} <- diff_base(page, revision, params["diff"]) do
      body = %{revision: V.revision(revision) |> Map.put(:body, revision.body)}

      body =
        case before do
          :none -> body
          text -> Map.put(body, :diff, V.diff(Wiki.diff(text, revision.body)))
        end

      json(conn, body)
    end
  end

  # What a revision is diffed from: nothing asked, the one before it, or
  # another version of the same page by id.
  defp diff_base(_page, _revision, diff) when diff in [nil, ""], do: {:ok, :none}

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

  @doc "Puts the page back to a revision. This is a save of its own, never a deletion."
  def revert(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         {:ok, revision} <- Wiki.get_revision(page, params["revision_id"] || params["revision"]),
         {:ok, page} <- Wiki.revert_page(page, revision, write_opts(conn, params)) do
      json(conn, %{page: V.page(with_users(page))})
    end
  end

  ## Helpers ------------------------------------------------------------------

  ## Folders ------------------------------------------------------------------
  #
  # Filing, as opposed to the page tree, which is composition (see
  # `Slipdock.Wiki.Folder`). A folder holds pages and other folders, to any
  # depth, and deleting one never deletes what is filed in it.

  @doc "The board's folders, nested, with the pages filed in each."
  def folders(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      opts = list_opts(conn, board, params)
      pages = Wiki.list_pages(board, opts)

      also =
        Placements.pages_by_folder(board.id, conn.assigns.current_user, archived: opts[:archived])

      json(conn, %{
        folders: V.folder_tree(Wiki.folder_tree(board, pages), also),
        pages: V.page_tree(Wiki.unfiled(pages))
      })
    end
  end

  @doc """
  The quick switcher's answer (W-103 R11.4): the pages whose title, alias or
  path the letters in `?q=` run through in order, best first, across the
  board's vault (or the board, outside one). `?vaults=all` adds the pages
  of every other vault of the caller's, as the `[[` picker does (#1303).
  `?limit=` up to 50.
  """
  def switch(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      limit =
        params["limit"] |> to_string() |> Integer.parse() |> elem_or(12) |> min(50) |> max(1)

      pool =
        if params["vaults"] == "all",
          do: Wiki.Switcher.linkable_pool(conn.assigns.current_user, board),
          else: Wiki.Switcher.pool(conn.assigns.current_user, board)

      matches =
        pool
        |> Wiki.Switcher.search(params["q"], limit)
        |> Enum.map(fn m ->
          %{
            id: m.id,
            code: m.code,
            title: m.title,
            slug: m.slug,
            board_id: m.board_id,
            board: m.board,
            path: m.path,
            vault: m[:elsewhere],
            matched:
              case m.matched do
                {:alias, name} -> "alias:" <> name
                other -> to_string(other)
              end
          }
        end)

      json(conn, %{matches: matches})
    end
  end

  defp elem_or({n, _}, _default), do: n
  defp elem_or(_, default), do: default

  @doc """
  One level of the wiki tree, as the browser's tree loads it (W-103 R11.1):
  the rows directly inside the root, a folder or a page — folders, pages
  and files, each with how many rows are under it — and never a body.

  `?folder=` (id, slug, name or path) or `?page=` (id or code) names the
  container, or `?node=folder:12|page:7|root`; nothing named is the root.
  `?archived=all` adds archived pages, `?template=false` leaves templates
  out; drafts are listed for writers only.
  """
  def tree(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read),
         {:ok, node} <- tree_node(board, params),
         {:ok, rows} <- Wiki.Tree.children(board, node, tree_opts(conn, board, params)) do
      json(conn, %{node: Wiki.Tree.ref_key(node), rows: rows})
    else
      {:error, :not_found} -> {:error, :not_found, "folder or page"}
      other -> other
    end
  end

  defp tree_node(board, %{"folder" => ref}) when ref not in [nil, ""] do
    case Wiki.find_folder(board, ref) do
      {:ok, folder} -> {:ok, {:folder, folder.id}}
      error -> error
    end
  end

  defp tree_node(board, %{"page" => ref}) when ref not in [nil, ""] do
    case Wiki.find_page(board, ref) do
      {:ok, page} -> {:ok, {:page, page.id}}
      error -> error
    end
  end

  defp tree_node(_board, params) do
    case Wiki.Tree.parse_ref(params["node"]) do
      {:ok, node} -> {:ok, node}
      :error -> {:error, :bad_request, "node is root, folder:<id> or page:<id>"}
    end
  end

  defp tree_opts(conn, board, params) do
    [
      status: if(writer?(conn, board), do: nil, else: "published"),
      archived: if(params["archived"] == "all", do: :all, else: false),
      template: if(params["template"] in ["false", "0"], do: false)
    ]
  end

  @doc "One folder, by id, name or path: where it is, and where else it is filed (#808)."
  def show_folder(conn, params) do
    with {:ok, folder, _board} <- fetch_folder(conn, params, :read),
         do: json(conn, %{folder: V.folder(folder)})
  end

  @doc ~S'Makes a folder. `name` may be a path — "Design/Decisions" makes both.'
  def create_folder(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, attrs} <- folder_attrs(board, params),
         {:ok, folder} <- Wiki.create_folder(board, attrs) do
      conn |> put_status(:created) |> json(%{folder: V.folder(folder)})
    end
  end

  @doc """
  Renames a folder, moves it under another, or reorders it.

  With `to_board`, moves it — its subfolders, every page at home in them and
  their files — to another board you can write to (`Slipdock.Wiki.FolderMove`):
  under `parent` there (a folder on that board; default its top), or with
  `contents: true` only what is in it, the emptied folder deleted. `dry_run`
  reports what would move and what can't be carried, and moves nothing.
  """
  def update_folder(conn, %{"id" => _id, "to_board" => board_ref} = params)
      when board_ref not in [nil, ""] do
    user = conn.assigns.current_user

    with {:ok, folder, _board} <- fetch_folder(conn, params, :write),
         {:ok, target} <- Authorize.fetch_board(conn, board_ref, :write),
         {:ok, parent} <- move_folder_param(target, params["parent"]) do
      opts = [parent: parent, contents: truthy?(params["contents"]), via: via(conn)]

      if truthy?(params["dry_run"]) do
        with {:ok, report} <- Wiki.FolderMove.preview(folder, target, user, opts),
             do: json(conn, %{dry_run: true, board: target.code, report: report})
      else
        with {:ok, %{folder: moved, report: report}} <-
               Wiki.FolderMove.to_board(folder, target, user, opts),
             do:
               json(conn, %{folder: moved && V.folder(moved), board: target.code, report: report})
      end
    end
  end

  # Filing a folder in several folders (#808): `also` files it in one more,
  # `not_in` takes it out of one, each by name or path on its board (or on
  # `in_board`), by id, or by vault path. Other changes may come with them.
  def update_folder(conn, %{"id" => _id} = params)
      when is_map_key(params, "also") or is_map_key(params, "not_in") do
    user = conn.assigns.current_user
    rest = Map.drop(params, ["also", "not_in", "in_board"])

    with {:ok, folder, board} <- fetch_folder(conn, params, :write),
         {:ok, folder} <- maybe_update_folder(folder, board, rest, user),
         {:ok, _} <-
           folder_placement(conn, folder, params, "also", &FolderPlacements.add(folder, &1, user)),
         {:ok, _} <-
           folder_placement(
             conn,
             folder,
             params,
             "not_in",
             &FolderPlacements.remove(folder, &1, user)
           ) do
      json(conn, %{folder: V.folder(Wiki.get_folder(folder.id))})
    end
  end

  def update_folder(conn, %{"id" => _id} = params) do
    with {:ok, folder, board} <- fetch_folder(conn, params, :write),
         {:ok, attrs} <- folder_attrs(board, params),
         {:ok, folder} <- Wiki.update_folder(folder, attrs, user: conn.assigns.current_user) do
      json(conn, %{folder: V.folder(folder)})
    end
  end

  @folder_fields ~w(name slug parent position sort icon color)

  defp maybe_update_folder(folder, board, params, user) do
    if Enum.any?(@folder_fields, &Map.has_key?(params, &1)) do
      with {:ok, attrs} <- folder_attrs(board, params),
           do: Wiki.update_folder(folder, attrs, user: user)
    else
      {:ok, folder}
    end
  end

  defp folder_placement(_conn, _folder, params, key, _act) when not is_map_key(params, key),
    do: {:ok, nil}

  defp folder_placement(conn, folder, params, key, act) do
    with {:ok, target} <- placement_target(conn, folder, params[key], params["in_board"]),
         do: act.(target)
  end

  defp placement_target(_conn, _folder, ref, _board) when ref in [nil, ""],
    do: {:error, :bad_request, "say which folder"}

  defp placement_target(_conn, folder, "/" <> _ = path, _board),
    do: Placements.folder_at(folder, path)

  # An id names the folder wherever it is; `add` checks the board is in reach.
  defp placement_target(conn, _folder, ref, board_ref)
       when is_integer(ref) and board_ref in [nil, ""] do
    with %{} = target <- Wiki.get_folder(ref),
         :ok <- Authorize.board(conn, Boards.get_board!(target.board_id), :read) do
      {:ok, target}
    else
      _ -> {:error, :not_found, "folder #{ref}"}
    end
  end

  defp placement_target(conn, folder, ref, board_ref) do
    board_result =
      if board_ref in [nil, ""],
        do: {:ok, Boards.get_board!(folder.board_id)},
        else: Authorize.fetch_board(conn, board_ref, :write)

    with {:ok, board} <- board_result, do: Wiki.find_folder(board, ref)
  end

  @doc """
  Organises what is filed in a folder (#791): `folder` names it (id, name or
  path), `mode` is `date`, `ai`, `tag` or `flatten`. For `date`: `parent`
  (a path; the folder itself when absent, `""` for the top), `granularity`
  (`month`, `year`, `year_month`, `day`) and `source` (`auto` or `added`).

  `dry_run` returns the plan and changes nothing. Without it the plan is
  made again and filed, so an AI run asks the model again. `only`, a list of
  keys from a plan (`"page:12"`, `"file:3"`), files just those.
  """
  def organise_folder(conn, %{"board" => board_ref, "folder" => ref, "mode" => mode} = params) do
    opts =
      [user: conn.assigns.current_user] ++
        for(
          key <- [:parent, :granularity, :source],
          is_binary(params[to_string(key)]),
          do: {key, params[to_string(key)]}
        )

    with {:ok, folder, board} <- fetch_folder(conn, %{"board" => board_ref, "id" => ref}, :write),
         {:plan, {:ok, plan}} <- {:plan, Wiki.AutoOrganise.plan(folder, mode, opts)} do
      plan =
        case params["only"] do
          keys when is_list(keys) -> Enum.filter(plan, &(&1.key in keys))
          _ -> plan
        end

      if truthy?(params["dry_run"]) do
        json(conn, %{dry_run: true, plan: Enum.map(plan, &organise_entry/1)})
      else
        {:ok, result} = Wiki.AutoOrganise.apply_plan(board, plan)

        json(conn, %{
          plan: Enum.map(plan, &organise_entry/1),
          moved: result.moved,
          folders_made: result.folders,
          skipped: Enum.map(result.skipped, fn {title, why} -> %{title: title, reason: why} end)
        })
      end
    else
      {:plan, {:error, message}} -> {:error, :unprocessable_entity, message}
      error -> error
    end
  end

  def organise_folder(_conn, _params),
    do: {:error, :bad_request, "organising needs a folder and a mode (date, ai, tag or flatten)"}

  defp organise_entry(entry), do: Map.take(entry, [:key, :kind, :id, :title, :from, :to])

  @doc """
  Deletes a folder. Its subfolders move up; its pages go back to the root.

  `?purge=true` deletes the folders beneath it and every page filed in any of
  them, history and all — the board's owner only, as purging a page is.
  """
  def delete_folder(conn, %{"id" => _id} = params) do
    with {:ok, folder, board} <- fetch_folder(conn, params, :write),
         :ok <- Sharing.check(conn.assigns.current_user, :delete, folder) do
      if truthy?(params["purge"]) do
        counts = Wiki.folder_contents_count(folder)

        with :ok <- Authorize.board(conn, board, :owner),
             {:ok, folder} <- Wiki.delete_folder(folder, :purge) do
          json(conn, %{deleted: V.folder(folder), purged: counts})
        end
      else
        with {:ok, folder} <- Wiki.delete_folder(folder) do
          json(conn, %{deleted: V.folder(folder)})
        end
      end
    end
  end

  @doc """
  Files a page in a folder, or takes it out of one with no `folder`.

  And in several folders (W-103 R12): `also` files it in one more, `not_in`
  takes it out of one it was also filed in. Either names a folder on the
  page's board, on `board` when one is given, or by vault path
  (`"/Projects/Notes"`) on a board in the same vault. `folder` may come too.
  """
  def file(conn, %{"id" => id} = params)
      when is_map_key(params, "also") or is_map_key(params, "not_in") do
    user = conn.assigns.current_user

    with {:ok, page} <- fetch_page(conn, id, :write),
         {:ok, page} <- maybe_home(conn, page, params),
         {:ok, _} <- placement(conn, page, params, "also", &Placements.add(page, &1, user)),
         {:ok, _} <- placement(conn, page, params, "not_in", &Placements.remove(page, &1, user)) do
      json(conn, %{page: V.page(with_users(Wiki.get_page!(page.id)))})
    end
  end

  def file(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         board <- Wiki.board_of(page),
         {:ok, attrs} <- resolve_folder(board, %{}, Map.put_new(params, "folder", nil), conn),
         {:ok, page} <- Wiki.update_page(page, attrs, write_opts(conn, params)) do
      json(conn, %{page: V.page(with_users(page))})
    end
  end

  defp maybe_home(conn, page, params) when is_map_key(params, "folder") do
    board = Wiki.board_of(page)

    with {:ok, attrs} <- resolve_folder(board, %{}, params, conn),
         do: Wiki.update_page(page, attrs, write_opts(conn, params))
  end

  defp maybe_home(_conn, page, _params), do: {:ok, page}

  defp placement(_conn, _page, params, key, _act) when not is_map_key(params, key),
    do: {:ok, nil}

  defp placement(conn, page, params, key, act) do
    with {:ok, folder} <-
           placement_folder(conn, page, params[key], params["board"], key == "also"),
         do: act.(folder)
  end

  # A vault path, a folder on a named board, or a folder on the page's own.
  defp placement_folder(_conn, _page, ref, _board, _create?) when ref in [nil, ""],
    do: {:error, :bad_request, "say which folder"}

  # Only a writer on the page's board makes the folders a path names: never
  # somebody the page was shared with (#816).
  defp placement_folder(conn, page, "/" <> _ = path, _board, create?),
    do:
      Placements.folder_at(page, path,
        create: create? and Sharing.board_writer?(conn.assigns.current_user, page.board_id)
      )

  defp placement_folder(conn, page, ref, board_ref, create?) do
    board_result =
      if board_ref in [nil, ""],
        do: {:ok, Wiki.board_of(page)},
        else: Authorize.fetch_board(conn, board_ref, :write)

    with {:ok, board} <- board_result do
      case Wiki.find_folder(board, ref) do
        {:ok, folder} ->
          {:ok, folder}

        _ when create? and is_binary(ref) ->
          Wiki.create_folder(board, %{"name" => ref}, user: conn.assigns.current_user)

        error ->
          error
      end
    end
  end

  @doc """
  The whole wiki, every board the reader can open: boards as the top level,
  then each board's folders and pages.

  One call rather than one per board, because "where is everything written"
  is the question a person opening the Wiki view is asking.
  """
  def wiki(conn, params) do
    user = conn.assigns.current_user

    boards =
      user
      |> Slipdock.Access.list_boards(token: conn.assigns[:api_token])
      |> Enum.map(fn board ->
        pages = Wiki.list_pages(board, list_opts(conn, board, params))

        %{
          id: board.id,
          code: board.code,
          name: board.name,
          color: board.color,
          folders: V.folder_tree(Wiki.folder_tree(board, pages)),
          pages: V.page_tree(Wiki.unfiled(pages))
        }
      end)

    json(conn, %{boards: boards})
  end

  defp folder_attrs(board, params) do
    # `sort` is how the tree orders the folder's pages (W-103 R11.9).
    # `icon` and `color` are what it wears on the main page and in the tree (#792).
    attrs = Map.take(params, ~w(name slug position sort icon color))

    case params["parent"] do
      nil ->
        {:ok, attrs}

      ref when ref in ["", "root", "none"] ->
        {:ok, Map.put(attrs, "parent_id", nil)}

      ref ->
        case Wiki.find_folder(board, ref) do
          {:ok, parent} -> {:ok, Map.put(attrs, "parent_id", parent.id)}
          error -> error
        end
    end
  end

  # A folder is addressed by id on its own, or by any handle at all when the
  # board is named too — `/boards/qvm/folders/Design/Decisions` is what
  # somebody on the command line has to hand.
  defp fetch_folder(conn, %{"board" => ref, "id" => id}, need) do
    # A glob route hands the path over as segments; a folder is named by the
    # whole of it.
    handle = if is_list(id), do: Enum.join(id, "/"), else: id

    with {:ok, board} <- Authorize.fetch_board(conn, ref, need),
         {:ok, folder} <- Wiki.find_folder(board, handle) do
      {:ok, folder, board}
    end
  end

  # By id, a folder answers to its own permission: somebody it was shared
  # with reaches it without its board (#815).
  defp fetch_folder(conn, %{"id" => id}, need) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %{} = folder <- Wiki.get_folder(id),
         board <- Boards.get_board!(folder.board_id),
         :ok <- folder_visible(conn, folder),
         :ok <- Authorize.folder(conn, folder, need) do
      {:ok, folder, board}
    else
      {:error, _, _} = error -> error
      {:error, status} -> {:error, status}
      _ -> {:error, :not_found, "folder #{inspect(id)}"}
    end
  end

  # Not readable at all is "not found", as for a page: a folder's existence
  # is itself what is withheld.
  defp folder_visible(conn, folder) do
    if Slipdock.Access.can_read?(
         Slipdock.Access.folder_permission(conn.assigns.current_user, folder)
       ),
       do: :ok,
       else: {:error, :not_found, "folder #{folder.id}"}
  end

  @doc """
  Makes a page inside a folder, by the folder's id (#816): how somebody a
  folder was shared with to edit adds to it, without reaching its board.
  Takes what `create/2` does; the page is the board owner's, made by the
  caller, and counts against the owner's account.
  """
  def create_in_folder(conn, %{"id" => _} = params) do
    user = conn.assigns.current_user

    with {:ok, folder, board} <- fetch_folder(conn, Map.take(params, ["id"]), :write),
         attrs = params |> Map.take(@page_fields) |> Map.put("folder_id", folder.id),
         {:ok, page} <- Wiki.create_page(board, attrs, write_opts(conn, params) ++ [user: user]) do
      conn
      |> put_status(:created)
      |> json(%{page: V.page(with_users(Wiki.get_page!(page.id)))})
    end
  end

  @doc "Makes a folder inside a folder, by the outer folder's id (#816)."
  def create_folder_in(conn, %{"id" => _, "name" => name} = params) when is_binary(name) do
    with {:ok, parent, board} <- fetch_folder(conn, Map.take(params, ["id"]), :write),
         {:ok, folder} <-
           Wiki.create_folder(board, %{"name" => name, "parent_id" => parent.id},
             user: conn.assigns.current_user
           ) do
      conn |> put_status(:created) |> json(%{folder: V.folder(folder)})
    end
  end

  def create_folder_in(_conn, _params), do: {:error, :bad_request, "name is required"}

  ## The card contents a page carries ----------------------------------------
  #
  # Comments, status updates, a checklist, web links and votes live in the
  # same tables a card's do (see `Slipdock.Boards.Owned`) and are written the
  # same way, so these mirror `CardController`'s exactly. Deleting one of
  # them goes through the shared `/checklist/:id` and `/comments/:id` routes,
  # which authorise by whichever the row hangs off.

  @doc "Comments on a page."
  def add_comment(conn, %{"id" => id, "body" => body}) do
    with {:ok, page} <- fetch_page(conn, id, :comment),
         {:ok, comment} <- Boards.add_comment(page, body, by: conn.assigns.current_user) do
      conn |> put_status(:created) |> json(%{comment: V.comment(comment)})
    end
  end

  @doc "Adds a tick box to a page."
  def add_checklist_item(conn, %{"id" => id, "text" => text}) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         {:ok, item} <- Boards.add_checklist_item(page, text) do
      conn |> put_status(:created) |> json(%{item: V.checklist_item(item)})
    end
  end

  @doc "Reports what somebody believes about the page: on track, at risk, off track."
  def add_status_update(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :comment),
         {:ok, _} <-
           Boards.add_status_update(
             page,
             conn.assigns.current_user,
             Map.take(params, ~w(health body))
           ) do
      conn
      |> put_status(:created)
      |> json(%{page: V.page(with_users(Wiki.get_page!(page.id)))})
    end
  end

  @doc "The files attached to a page — its pasted images among them — oldest first."
  def attachments(conn, %{"id" => id}) do
    with {:ok, page} <- fetch_page(conn, id, :read) do
      json(conn, %{attachments: Enum.map(Wiki.attachments(page), &Uploads.json/1)})
    end
  end

  @doc """
  Attaches a file to a page: the multipart field `file`, and an optional
  `filename`. The `markdown` that comes back is what to put in the body.
  `replace=true` deletes the page's older files of that name (#1017).
  """
  def add_attachment(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         {:ok, meta, path} <- Uploads.take(params),
         {:ok, replace?} <- Uploads.replace(params),
         {:ok, attachment} <- Wiki.add_attachment(page, meta, path) do
      conn |> put_status(:created) |> json(Uploads.stored(attachment, replace?))
    end
  end

  def remove_attachment(conn, %{"id" => id, "attachment_id" => attachment_id}) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         %{} = attachment <- page_attachment_of(page, attachment_id),
         {:ok, _} <- Boards.delete_attachment(attachment) do
      json(conn, %{ok: true})
    else
      nil -> {:error, :not_found, "attachment"}
      other -> other
    end
  end

  # A file is only this page's to remove.
  defp page_attachment_of(page, attachment_id) do
    with {int, ""} <- Integer.parse(to_string(attachment_id)),
         %Slipdock.Boards.Attachment{page_id: page_id} = attachment <-
           Slipdock.Repo.get(Slipdock.Boards.Attachment, int),
         true <- page_id == page.id do
      attachment
    else
      _ -> nil
    end
  end

  @doc "Puts a link to somewhere outside the system on a page."
  def add_url(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         {:ok, url} <- Boards.add_card_url(page, Map.take(params, ["url", "title"])) do
      conn |> put_status(:created) |> json(%{url: V.card_url(url)})
    end
  end

  def remove_url(conn, %{"id" => id, "url_id" => url_id}) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         %{} = url <- page_url_of(page, url_id),
         {:ok, _} <- Boards.delete_card_url(url) do
      json(conn, %{ok: true})
    else
      nil -> {:error, :not_found, "link"}
      other -> other
    end
  end

  # A link is only this page's to remove.
  defp page_url_of(page, url_id) do
    with {int, ""} <- Integer.parse(to_string(url_id)),
         %Slipdock.Boards.CardUrl{page_id: page_id} = url <-
           Slipdock.Repo.get(Slipdock.Boards.CardUrl, int),
         true <- page_id == page.id do
      url
    else
      _ -> nil
    end
  end

  @doc """
  Sets the caller's votes on a page. The budget is the board tree's, and a
  page's votes come out of the same one the cards' do.
  """
  def vote(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :read),
         {:ok, count} <- vote_count(params["count"]),
         {:ok, page} <-
           Slipdock.Votes.set(
             page,
             conn.assigns.current_user,
             count,
             vote_comment(conn, page, params)
           ) do
      json(conn, %{
        page: V.page(with_users(page)),
        my_votes:
          Slipdock.Votes.mine(Slipdock.Repo.preload(page, :votes), conn.assigns.current_user)
      })
    else
      {:error, message} when is_binary(message) -> {:error, :unprocessable_entity, message}
      other -> other
    end
  end

  # Anyone who can read a page can vote on it, but a vote's comment is text
  # left on the page, so only someone who may comment on it may leave one.
  defp vote_comment(conn, page, params) do
    if Authorize.page(conn, page, :comment) == :ok, do: params["comment"]
  end

  defp vote_count(n) when is_integer(n), do: {:ok, n}

  defp vote_count(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, ""} -> {:ok, i}
      _ -> {:error, :unprocessable_entity, "count must be a whole number"}
    end
  end

  defp vote_count(_), do: {:error, :unprocessable_entity, "count is required"}

  # A draft is invisible to anyone who could not have written it, so a reader
  # gets "not found" rather than "forbidden": the existence of the page is
  # itself the thing being withheld.
  defp fetch_page(conn, ref, need) do
    with {:ok, page} <- Wiki.find_page(ref, as: conn.assigns.current_user),
         :ok <- Authorize.page(conn, page, need) do
      level = Slipdock.Access.page_permission(conn.assigns.current_user, page)

      if Wiki.visible?(page, level),
        do: {:ok, page},
        else: {:error, :not_found, "page #{inspect(ref)}"}
    end
  end

  defp writer?(conn, board) do
    Slipdock.Access.can_write?(Slipdock.Access.board_permission(conn.assigns.current_user, board))
  end

  defp page_attrs(conn, board, params) do
    attrs = Map.take(params, @page_fields)

    with {:ok, attrs} <- resolve_assignee(board, attrs, params, conn.assigns.current_user),
         {:ok, attrs} <- resolve_flags(attrs, params),
         {:ok, attrs} <- resolve_folder(board, attrs, params, conn) do
      case resolve_parent(board, params["parent"]) do
        {:ok, nil} -> {:ok, attrs}
        {:ok, parent} -> {:ok, Map.put(attrs, "parent_id", parent.id)}
        error -> error
      end
    end
  end

  # `front_matter` is the YAML between the `---` lines, as the page shows it;
  # stored as a whole header, so a page imported from a file keeps that
  # file's delimiters and the blank line before its body. "" or null clears it.
  defp front_matter(attrs, params, _header) when not is_map_key(params, "front_matter"),
    do: {:ok, attrs}

  defp front_matter(attrs, %{"front_matter" => yaml}, header) do
    case FrontMatter.replace(header, yaml) do
      {:ok, header} -> {:ok, Map.put(attrs, "front_matter", header)}
      {:error, message} -> {:error, :unprocessable_entity, message}
    end
  end

  # `folder` is where the page is filed: an id, a slug, a name, or a path
  # like "Design/Decisions", which is made if it does not exist yet — an
  # agent writing a document should not have to make the filing cabinet in a
  # separate call. "" or null takes the page out of its folder.
  defp resolve_folder(_board, attrs, params, _conn) when not is_map_key(params, "folder"),
    do: {:ok, attrs}

  defp resolve_folder(_board, attrs, %{"folder" => ref}, _conn)
       when ref in [nil, "", "none", "root"],
       do: {:ok, Map.put(attrs, "folder_id", nil)}

  defp resolve_folder(board, attrs, %{"folder" => ref}, conn) do
    case Wiki.find_folder(board, ref) do
      {:ok, folder} ->
        {:ok, Map.put(attrs, "folder_id", folder.id)}

      _ when is_binary(ref) ->
        with {:ok, folder} <-
               Wiki.create_folder(board, %{"name" => ref}, user: conn.assigns.current_user) do
          {:ok, Map.put(attrs, "folder_id", folder.id)}
        end

      error ->
        error
    end
  end

  # `assignee` is an email, as it is for a card; "" or null unassigns. The
  # same rule as a card's (`Boards.resolve_assignees/3`): somebody the caller
  # can see who can read the board, and one 404 for everybody else.
  defp resolve_assignee(_board, attrs, %{"assignee" => email}, _me) when email in [nil, ""],
    do: {:ok, Map.put(attrs, "assignee_id", nil)}

  defp resolve_assignee(board, attrs, %{"assignee" => email}, me) when is_binary(email) do
    case Boards.resolve_assignees(board, me, [String.trim(email)]) do
      {:ok, [id]} -> {:ok, Map.put(attrs, "assignee_id", id)}
      _ -> {:error, :not_found, "user #{email}"}
    end
  end

  defp resolve_assignee(_board, attrs, _params, _me), do: {:ok, attrs}

  # `add_flags` / `remove_flags` adjust rather than replace, as on a card.
  defp resolve_flags(attrs, params) do
    add = List.wrap(params["add_flags"])
    remove = List.wrap(params["remove_flags"])

    if add == [] and remove == [] do
      {:ok, attrs}
    else
      current = attrs["flags"] || []
      {:ok, Map.put(attrs, "flags", Enum.uniq(current ++ add) -- remove)}
    end
  end

  defp resolve_parent(_board, nil), do: {:ok, nil}
  defp resolve_parent(_board, ""), do: {:ok, nil}
  defp resolve_parent(_board, "root"), do: {:ok, nil}
  defp resolve_parent(_board, "none"), do: {:ok, nil}

  defp resolve_parent(board, ref) do
    case Wiki.find_page(board, ref) do
      {:ok, page} -> {:ok, page}
      _ -> {:error, :not_found, "page #{inspect(ref)}"}
    end
  end

  # Who is writing, for the revision this save leaves behind. `via` is the
  # client's own word for itself (the CLI sends `x-slipdock-client: cli`; the
  # pre-rename `x-kanban-client` is still accepted), and
  # `agent` is the name on the token, so history distinguishes two agents
  # sharing one account.
  defp write_opts(conn, params) do
    [
      user: conn.assigns.current_user,
      via: via(conn),
      agent: agent(conn),
      message: params["message"],
      base_hash: params["base_hash"]
    ]
  end

  defp via(conn) do
    case get_req_header(conn, "x-slipdock-client") ++ get_req_header(conn, "x-kanban-client") do
      [client] -> if client in Slipdock.Wiki.Revision.vias(), do: client, else: "api"
      _ -> "api"
    end
  end

  defp agent(conn) do
    case conn.assigns[:api_token] do
      %{label: label} -> label
      _ -> nil
    end
  end

  defp with_users(%Page{} = page),
    do:
      Slipdock.Repo.preload(
        page,
        [:created_by, :updated_by, :assignee, :tags, [field_values: :field]] ++
          Wiki.board_preloads()
      )
end

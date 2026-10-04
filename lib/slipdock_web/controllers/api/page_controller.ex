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
  alias Slipdock.Wiki.{Archive, Page, Query}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.Wiki.Renderer

  action_fallback SlipdockWeb.API.FallbackController

  # The page's own fields, plus the card facets it carries (see
  # `Slipdock.Wiki.Page`), so one PATCH sets either.
  @page_fields ~w(title body summary slug status template parent_id folder_id
                  priority flags start_date due_date date_precision completed
                  percent_complete color)

  ## Listing and creating -----------------------------------------------------

  def index(conn, %{"board" => ref} = params) do
    with {:ok, board} <- fetch_board(ref),
         :ok <- Authorize.board(conn, board, :read) do
      opts = list_opts(conn, board, params)

      if truthy?(params["tree"]) do
        json(conn, %{pages: V.page_tree(Wiki.tree(board, opts))})
      else
        json(conn, %{pages: Enum.map(Wiki.list_pages(board, opts), &V.page_summary/1)})
      end
    end
  end

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
      folder: folder_opt(board, params["folder"])
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

  defp truthy?(value), do: to_string(value) in ~w(true 1 yes on)

  def create(conn, %{"board" => ref} = params) do
    with {:ok, board} <- fetch_board(ref),
         :ok <- Authorize.board(conn, board, :write),
         {:ok, attrs} <- page_attrs(conn, board, params),
         {:ok, page} <- Wiki.create_page(board, attrs, write_opts(conn, params)) do
      conn |> put_status(:created) |> json(%{page: V.page(with_users(page))})
    end
  end

  ## One page -----------------------------------------------------------------

  def show(conn, %{"id" => id}) do
    with {:ok, page} <- fetch_page(conn, id, :read) do
      json(conn, %{page: V.page(with_users(page))})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         board <- Wiki.board_of(page),
         params <- Map.put_new(params, "flags", page.flags),
         {:ok, attrs} <- page_attrs(conn, board, params),
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
    with {:ok, page} <- fetch_page(conn, id, :write) do
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
         {:ok, page} <- Wiki.unarchive_page(page) do
      json(conn, %{page: V.page(with_users(page))})
    end
  end

  @doc "Reparents or reorders a page: `{parent, position}`."
  def move(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         board <- Wiki.board_of(page),
         {:ok, parent} <- resolve_parent(board, params["parent"]),
         {:ok, page} <- Wiki.move_page(page, parent, position(params["position"])) do
      json(conn, %{page: V.page(with_users(page))})
    end
  end

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

  defp pin_target(_conn, %{"page" => ref}) do
    with {:ok, page} <- Wiki.find_page(ref), do: {:ok, {:page, page}}
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
    with {:ok, board} <- fetch_board(ref),
         :ok <- Authorize.board(conn, board, :read) do
      json(conn, %{wanted: Enum.map(Wiki.wanted(board), &V.wanted/1)})
    end
  end

  @doc """
  Turns a title into a page, so a link can be written safely rather than
  guessed at. Answers with the page, or with what is nearest to it.
  """
  def resolve(conn, params) do
    with {:ok, board} <- fetch_board(params["board"]),
         :ok <- Authorize.board(conn, board, :read) do
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
    with {:ok, page} <- fetch_page(conn, id, :write) do
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
    with {:ok, board} <- fetch_board(ref),
         :ok <- Authorize.board(conn, board, :read) do
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
    with {:ok, board} <- fetch_board(ref),
         :ok <- Authorize.board(conn, board, :write),
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
    with {:ok, board} <- fetch_board(params["board"]),
         :ok <- Authorize.board(conn, board, :read),
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
      conn |> put_status(:created) |> json(%{card: V.card(Boards.get_card!(card.id))})
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
    with {:ok, board} <- fetch_board(ref),
         :ok <- Authorize.board(conn, board, :write),
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

  def revisions(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :read) do
      limit = params["limit"] |> to_limit()
      json(conn, %{revisions: Enum.map(Wiki.list_revisions(page, limit), &V.revision/1)})
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
  as hunks of equal, deleted and inserted lines.
  """
  def revision(conn, %{"id" => id, "rev" => rev} = params) do
    with {:ok, page} <- fetch_page(conn, id, :read),
         {:ok, revision} <- Wiki.get_revision(page, rev) do
      body = %{revision: V.revision(revision) |> Map.put(:body, revision.body)}

      body =
        if params["diff"] == "previous" do
          previous = Wiki.previous_revision(revision)
          before = if previous, do: previous.body, else: ""
          Map.put(body, :diff, V.diff(Wiki.diff(before, revision.body)))
        else
          body
        end

      json(conn, body)
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
    with {:ok, board} <- fetch_board(ref),
         :ok <- Authorize.board(conn, board, :read) do
      pages = Wiki.list_pages(board, list_opts(conn, board, params))

      json(conn, %{
        folders: V.folder_tree(Wiki.folder_tree(board, pages)),
        pages: V.page_tree(Wiki.unfiled(pages))
      })
    end
  end

  @doc ~S'Makes a folder. `name` may be a path — "Design/Decisions" makes both.'
  def create_folder(conn, %{"board" => ref} = params) do
    with {:ok, board} <- fetch_board(ref),
         :ok <- Authorize.board(conn, board, :write),
         {:ok, attrs} <- folder_attrs(board, params),
         {:ok, folder} <- Wiki.create_folder(board, attrs) do
      conn |> put_status(:created) |> json(%{folder: V.folder(folder)})
    end
  end

  @doc "Renames a folder, moves it under another, or reorders it."
  def update_folder(conn, %{"id" => _id} = params) do
    with {:ok, folder, board} <- fetch_folder(conn, params, :write),
         {:ok, attrs} <- folder_attrs(board, params),
         {:ok, folder} <- Wiki.update_folder(folder, attrs) do
      json(conn, %{folder: V.folder(folder)})
    end
  end

  @doc """
  Deletes a folder. Its subfolders move up; its pages go back to the root.

  `?purge=true` deletes the folders beneath it and every page filed in any of
  them, history and all — the board's owner only, as purging a page is.
  """
  def delete_folder(conn, %{"id" => _id} = params) do
    with {:ok, folder, board} <- fetch_folder(conn, params, :write) do
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

  @doc "Files a page in a folder, or takes it out of one with no `folder`."
  def file(conn, %{"id" => id} = params) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         board <- Wiki.board_of(page),
         {:ok, attrs} <- resolve_folder(board, %{}, Map.put_new(params, "folder", nil)),
         {:ok, page} <- Wiki.update_page(page, attrs, write_opts(conn, params)) do
      json(conn, %{page: V.page(with_users(page))})
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
    attrs = Map.take(params, ~w(name slug position))

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

    with {:ok, board} <- fetch_board(ref),
         :ok <- Authorize.board(conn, board, need),
         {:ok, folder} <- Wiki.find_folder(board, handle) do
      {:ok, folder, board}
    end
  end

  defp fetch_folder(conn, %{"id" => id}, need) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %{} = folder <- Wiki.get_folder(id),
         board <- Boards.get_board!(folder.board_id),
         :ok <- Authorize.board(conn, board, need) do
      {:ok, folder, board}
    else
      {:error, _, _} = error -> error
      {:error, status} -> {:error, status}
      _ -> {:error, :not_found, "folder #{inspect(id)}"}
    end
  end

  defp fetch_board(ref) do
    case Boards.find_board(ref) do
      {:ok, board} -> {:ok, board}
      _ -> {:error, :not_found, "board #{inspect(ref)}"}
    end
  end

  ## The card contents a page carries ----------------------------------------
  #
  # Comments, status updates, a checklist, web links and votes live in the
  # same tables a card's do (see `Slipdock.Boards.Owned`) and are written the
  # same way, so these mirror `CardController`'s exactly. Deleting one of
  # them goes through the shared `/checklist/:id` and `/comments/:id` routes,
  # which authorise by whichever the row hangs off.

  @doc "Comments on a page."
  def add_comment(conn, %{"id" => id, "body" => body}) do
    with {:ok, page} <- fetch_page(conn, id, :write),
         {:ok, comment} <- Boards.add_comment(page, body) do
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
    with {:ok, page} <- fetch_page(conn, id, :write),
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
           Slipdock.Votes.set(page, conn.assigns.current_user, count, params["comment"]) do
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
    with {:ok, page} <- Wiki.find_page(ref),
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
         {:ok, attrs} <- resolve_folder(board, attrs, params) do
      case resolve_parent(board, params["parent"]) do
        {:ok, nil} -> {:ok, attrs}
        {:ok, parent} -> {:ok, Map.put(attrs, "parent_id", parent.id)}
        error -> error
      end
    end
  end

  # `folder` is where the page is filed: an id, a slug, a name, or a path
  # like "Design/Decisions", which is made if it does not exist yet — an
  # agent writing a document should not have to make the filing cabinet in a
  # separate call. "" or null takes the page out of its folder.
  defp resolve_folder(_board, attrs, params) when not is_map_key(params, "folder"),
    do: {:ok, attrs}

  defp resolve_folder(_board, attrs, %{"folder" => ref}) when ref in [nil, "", "none", "root"],
    do: {:ok, Map.put(attrs, "folder_id", nil)}

  defp resolve_folder(board, attrs, %{"folder" => ref}) do
    case Wiki.find_folder(board, ref) do
      {:ok, folder} ->
        {:ok, Map.put(attrs, "folder_id", folder.id)}

      _ when is_binary(ref) ->
        with {:ok, folder} <- Wiki.create_folder(board, %{"name" => ref}) do
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

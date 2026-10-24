defmodule Slipdock.Handbook do
  @moduledoc """
  A board's handbook (#1261, spec W-1934): wiki pages that describe the
  project as it is now — specification, architecture, UX, components, data
  model, shared modules, testing, operations and decisions — that every
  coding-loop pass reads before it builds and updates before it closes a
  card.

  It is a **built-in Tool**, `handbook`. A published Tool builds a board of
  its own; a handbook belongs to a board that already exists, so it is
  installed onto one (`install/3`), always the root of its tree: epics are
  sub-boards, and a subcard resolves up to the root board's handbook.

  What makes a board a handbook board is on the wiki itself, so nothing
  else has to record it: a `Handbook` folder holding the Index, the page
  whose front matter says `handbook: index`. Every page in the folder can
  carry `handbook:`, `read_when:` (for an agent choosing what to read) and
  `covers:` (paths whose changes should touch it).
  """

  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Blueprint
  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Repo
  alias Slipdock.Wiki.{Folders, FrontMatter, Page}

  @name "handbook"
  @version "1.0.0"
  @folder "Handbook"
  @decisions "Handbook/Decisions"

  def name, do: @name
  def version, do: @version
  def folder, do: @folder
  def decisions_folder, do: @decisions

  @doc "Whether `ref` names the built-in Handbook Tool."
  def tool?(ref) when is_binary(ref), do: String.downcase(String.trim(ref)) == @name
  def tool?(_), do: false

  ## The Tool --------------------------------------------------------------------

  @sections [
    {"Specification", "specification", "What the product does, feature by feature.",
     "adding or changing user-visible behaviour",
     "## Features\n\n_One section per feature: what it does for the person using it, and its rules._\n"},
    {"Architecture", "architecture",
     "Contexts, processes, boundaries and data flow, as they are now.",
     "adding a context, a process or a supervisor, or crossing a module boundary",
     "## Contexts\n\n_The main modules and what each owns._\n\n## Processes\n\n_What runs, and who supervises it._\n\n## Data flow\n\n_How a request or a job moves through the system._\n"},
    {"UX & UI", "ux", "Patterns, layout and interaction rules for the interface.",
     "building or changing a screen, a form, a menu or any UI interaction",
     "## Patterns\n\n_Layouts and interactions the app uses everywhere._\n\n## Rules\n\n_What a new screen must do to fit in._\n"},
    {"Components", "components", "Reusable UI pieces, and when to use each.",
     "adding UI that may already exist as a component, or making a reusable one",
     "## Components\n\n_One section per component: what it is for and how it is called._\n"},
    {"Data model", "data-model", "Schemas, their relations and invariants.",
     "adding or changing a schema, a migration or a constraint",
     "## Schemas\n\n_One section per schema: its fields, relations and invariants._\n"},
    {"Shared modules", "shared-modules", "Utilities and helpers worth reusing.",
     "writing a helper that may already exist, or one worth sharing",
     "## Modules\n\n_One section per module: what it does and when to reach for it._\n"},
    {"Testing & tooling", "testing", "How to test, CI, local setup.",
     "writing tests, changing CI, the build or the local setup",
     "## Tests\n\n_How the suite is laid out and run._\n\n## CI\n\n_What runs on every push._\n\n## Local setup\n\n_From a clean checkout to a running app._\n"},
    {"Operations", "operations", "Deploys, configuration and runbooks.",
     "changing deploys, configuration, secrets or anything run in production",
     "## Deploy\n\n_How a change reaches production._\n\n## Configuration\n\n_Settings and where they come from._\n\n## Runbooks\n\n_What to do when something breaks._\n"}
  ]

  @index_body """
  # Handbook

  How this project is built, as it is now. Coding passes read the sections a
  card needs before building, and update them before closing it (a
  `Handbook:` line in the closing comment). Pages added to this folder join
  the list by themselves.

  ```slipdock
  pages: Handbook
  fields: title, summary, read_when
  ```

  ## Decisions

  One page per decision, in `Handbook/Decisions`. A superseded decision gets
  a new page that links back to it.

  ```slipdock
  pages: Handbook/Decisions
  fields: title, summary
  empty: "No decisions written yet."
  ```
  """

  @doc """
  The handbook as a board blueprint (see `Slipdock.Blueprint`): the folders,
  the Index and a skeleton page per section, each with its front matter.
  """
  def blueprint do
    index = %{
      "title" => "Index",
      "folder" => @folder,
      "summary" => "The handbook's pages, what each covers and when to read it.",
      "front_matter" => "handbook: index\nread_when: starting any card\ncovers: []",
      "body" => @index_body
    }

    sections =
      for {title, key, summary, read_when, body} <- @sections do
        %{
          "title" => title,
          "folder" => @folder,
          "summary" => summary,
          "front_matter" => "handbook: #{key}\nread_when: #{read_when}\ncovers: []",
          "body" => "# #{title}\n\n#{summary}\n\n#{body}"
        }
      end

    %{
      "lists" => [],
      "folders" => [@folder, @decisions],
      "tags" => [],
      "pages" => [index | sections],
      "automations" => []
    }
  end

  @doc """
  Installs the handbook on `board`'s root board for `user`, who must be able
  to write to it. Installing again adds only what is missing — a page somebody
  deleted, a folder — and never touches a page that is there.

  Returns `{:ok, %{board:, created:, upgraded:, version:, install:, report:}}`
  (the shape a Tool install reports), or `{:error, message}`.
  """
  def install(%User{} = user, %Board{} = board, _opts \\ []) do
    root = root(board)

    with :ok <- can_write(user, root) do
      created = is_nil(find(root))

      case Blueprint.apply(root, blueprint(),
             user: user,
             message: "installed by the Handbook Tool, #{@version}"
           ) do
        {:ok, report} ->
          {:ok,
           %{
             board: Boards.get_board!(root.id),
             created: created,
             upgraded: false,
             version: %{version: @version},
             install: %{version: @version},
             report: report
           }}

        {:error, message} ->
          {:error, message}
      end
    end
  end

  defp can_write(user, board) do
    if Slipdock.Access.can_write?(Slipdock.Access.board_permission(user, board)),
      do: :ok,
      else: {:error, "installing a handbook needs write access to #{board.name}"}
  end

  ## Finding one -----------------------------------------------------------------

  @doc "The root of `board`'s tree: a sub-board's handbook is its root board's."
  def root(%Board{root_id: nil} = board), do: board
  def root(%Board{root_id: id}), do: Boards.get_board!(id)

  @doc """
  The handbook of `board`'s tree, or nil when its root board has none:
  `%{board:, folder:, index:, pages:, installed_at:}`, where `pages` are the
  pages filed in the Handbook folder (the Index first), unarchived.
  """
  def find(%Board{} = board) do
    root = root(board)

    with {:ok, folder} <- Folders.find(root, "/" <> @folder),
         pages = folder_pages(root, folder),
         %Page{} = index <- Enum.find(pages, &(key(&1) == "index")) do
      %{
        board: root,
        folder: folder,
        index: index,
        pages: [index | Enum.reject(pages, &(&1.id == index.id))],
        installed_at: index.inserted_at
      }
    else
      _ -> nil
    end
  end

  def find(_), do: nil

  @doc "The decision pages: those filed in `Handbook/Decisions`."
  def decisions(%{board: root}) do
    case Folders.find(root, "/" <> @decisions) do
      {:ok, folder} -> folder_pages(root, folder)
      _ -> []
    end
  end

  defp folder_pages(root, folder) do
    from(p in Page,
      where:
        p.board_id == ^root.id and p.folder_id == ^folder.id and is_nil(p.archived_at) and
          p.template == false,
      order_by: [asc: p.position, asc: p.title]
    )
    |> Repo.all()
  end

  @doc "A page's `handbook:` key (`architecture`, `index`, …), or nil."
  def key(%Page{} = page), do: field(page, "handbook")

  @doc "A front-matter value of a handbook page, as a string or a list of strings."
  def field(%Page{front_matter: header}, key),
    do: header |> FrontMatter.yaml() |> FrontMatter.get(key)
end

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
  alias Slipdock.Wiki
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

  ## Log

  _The reconcile card records each commit range it covered here, newest last._
  """

  @seed_title "Seed the handbook"
  @reconcile_title "Reconcile the handbook"

  @seed_description """
  Write the first real version of this board's handbook (the `Handbook/` folder, see its Index). Its pages are skeletons until this card is done. Spec: the Handbook Tool, W-1934.

  **Procedure**

  1. Read the codebase this board's work lands in: the README, CLAUDE.md / AGENTS.md, the top-level layout, the main modules, the schemas and migrations, the tests and CI config, the deploy scripts.
  2. Read what the board already knows: `slipdock page ls <board>` for specs, design records and decision notes, and the last few dozen done cards for recurring patterns.
  3. For each section page (Specification, Architecture, UX & UI, Components, Data model, Shared modules, Testing & tooling, Operations):
     - write the body as the project is **now**, by `##` section, one subject per section, short, linking to code paths in backticks. Not history: decisions go in their own pages;
     - set the front matter: `read_when:` (the kinds of card that should read it, in a line) and `covers:` (the path globs whose changes should touch it, like `[lib/app/accounts/**, priv/repo/migrations/**]`);
     - keep the page's summary to one line.
  4. Write one page per decision you find in the existing design records, specs and comments, filed in `Handbook/Decisions`: title `Decision: <what was chosen>`, then context, the choice, the alternatives and why not, and a link to where it was decided.
  5. Add one line to the repo's CLAUDE.md (or AGENTS.md) pointing at the Index: `Project handbook: <Index code> on the <board> board — read the sections a card needs before building, and update them before closing it (a Handbook: line in the closing comment).` The wiki is the source of truth: do not copy the handbook into the repo.
  6. Commit the CLAUDE.md change with this card's id, and close the card with a `Handbook:` line listing every page written.

  **Done when:** every section page has real content and front matter, the decisions found have pages, CLAUDE.md points at the Index, and a person has been asked (in the closing comment) to read the drafts once.
  """

  @reconcile_description """
  Bring the handbook (the `Handbook/` folder, see its Index) back in line with the code. Passes update it as they close cards; this catches what they missed, implementation choices above all. Spec: W-1934 §Drift.

  1. Find where the last reconcile stopped: the last line of the Index's `## Log` (a commit range). None yet: start from the commit that seeded the handbook.
  2. `git log --stat <last>..HEAD` on the default branch. For each change, check the pages whose `covers:` globs match its paths, and the checklist: user-visible behaviour → Specification; structure or boundaries → Architecture / Data model; a choice between alternatives → a new page in `Handbook/Decisions`; something reusable → Shared modules / Components; a UI pattern → UX & UI; how to test, build or deploy → Testing & tooling / Operations.
  3. Update what drifted by section, with `--message "#<this card> reconcile <range>"`.
  4. Append the range covered to the Index's `## Log`: `- <date>: <from>..<to>, updated <codes> (or nothing drifted)`.
  5. Close the card with a `Handbook:` line. The next one comes by itself next week.
  """

  def seed_title, do: @seed_title
  def reconcile_title, do: @reconcile_title

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
      "automations" => [],
      "cards" => [
        %{"title" => @seed_title, "description" => @seed_description},
        %{
          "title" => @reconcile_title,
          "description" => @reconcile_description,
          "repeat" => "every mon"
        }
      ]
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
          if @reconcile_title in report.added["cards"], do: reconcile_after_seed(root)

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

  # The first reconcile waits for the seed: there is nothing to reconcile
  # until the pages have been written, and a loop skips a blocked card.
  defp reconcile_after_seed(root) do
    cards =
      from(c in Slipdock.Boards.Card,
        where: c.board_id == ^root.id and c.title in [@seed_title, @reconcile_title],
        order_by: [desc: c.id]
      )
      |> Repo.all()

    seed = Enum.find(cards, &(&1.title == @seed_title))
    reconcile = Enum.find(cards, &(&1.title == @reconcile_title))

    if seed && reconcile && not seed.completed, do: Boards.add_dependency(reconcile, seed)
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

  ## What a pass should read (#1264) -----------------------------------------------

  @index_cap 1536
  @field_chars 90
  @suggestions 5
  # So one long page can't fill every slot (#1281).
  @per_page 2

  @doc """
  What a pass on `card` should read, for `reader`: nil when the card's root
  board has no handbook or `reader` can't read that board, otherwise

      %{board: code, index_page: code, index: [%{code:, title:, summary:, read_when:}],
        suggested: [%{page:, title:, section:, why:}], more: n}

  `index` is every handbook page but the Index itself, its fields cut short
  so the whole stays under #{@index_cap} bytes of JSON (`more` says how many
  pages that left out). `suggested` is up to #{@suggestions} sections, best
  first: pages whose `covers:` globs match a path the card mentions, then
  sections ranked against the card's title and description, by semantic
  search when the server has it and by the words they share otherwise.

  Options: `:token`, the API token asking, which narrows `reader`'s reach.
  """
  def for_card(%Slipdock.Boards.Card{} = card, reader, opts \\ []) do
    board = Repo.get!(Board, card.board_id)

    with %{} = handbook <- find(board),
         true <- readable?(reader, handbook.board, opts[:token]) do
      {index, more} = index(handbook)

      %{
        board: handbook.board.code,
        index_page: handbook.index.code,
        index: index,
        more: more,
        suggested: suggest(handbook, card, reader, opts)
      }
    else
      _ -> nil
    end
  end

  @doc "The index alone, for a board (`slipdock handbook <board>`); nil as `for_card/3`."
  def for_board(%Board{} = board, reader, opts \\ []) do
    with %{} = handbook <- find(board),
         true <- readable?(reader, handbook.board, opts[:token]) do
      {index, more} = index(handbook)

      %{
        board: handbook.board.code,
        index_page: handbook.index.code,
        index: index,
        more: more,
        decisions: Enum.map(decisions(handbook), &%{code: &1.code, title: &1.title})
      }
    else
      _ -> nil
    end
  end

  defp readable?(nil, _board, _token), do: false

  defp readable?(reader, board, token) do
    level = Slipdock.Access.board_permission(reader, board)
    {level, _} = Slipdock.Access.narrow(level, token, board.id)
    Slipdock.Access.can_read?(level)
  end

  @doc false
  def index_cap, do: @index_cap

  defp index(%{pages: [_index | pages]}) do
    entries =
      Enum.map(pages, fn page ->
        %{
          code: page.code,
          title: page.title,
          summary: cut(page.summary),
          read_when: cut(text_field(page, "read_when"))
        }
      end)

    fit(entries, [])
  end

  # Keeps entries while the whole still fits, so a folder somebody filled
  # with fifty pages can't swamp every card it is shown on.
  defp fit([], kept), do: {Enum.reverse(kept), 0}

  defp fit([entry | rest] = left, kept) do
    if byte_size(Jason.encode!(Enum.reverse([entry | kept]))) <= @index_cap,
      do: fit(rest, [entry | kept]),
      else: {Enum.reverse(kept), length(left)}
  end

  defp cut(nil), do: nil
  defp cut(text) when byte_size(text) <= @field_chars, do: text
  defp cut(text), do: String.slice(text, 0, @field_chars - 1) <> "…"

  defp text_field(page, key) do
    case field(page, key) do
      list when is_list(list) -> Enum.join(list, ", ")
      other -> other
    end
  end

  ## Ranking ----------------------------------------------------------------------

  defp suggest(handbook, card, reader, opts) do
    pages = Enum.reject(handbook.pages, &(&1.id == handbook.index.id))
    text = card_text(card)

    covered = covered(pages, mentioned_paths(text))
    words = lexical(pages, text)
    # A short page is one chunk in the search index, so a match on it names
    # no section: the section of it the card shares most words with, if any.
    best = words |> Enum.reverse() |> Map.new(&{&1.page, &1})

    semantic =
      handbook
      |> semantic(pages, text, reader, opts)
      |> Enum.map(fn
        %{section: nil} = s -> if b = best[s.page], do: %{s | section: b.section}, else: s
        s -> s
      end)

    (covered ++ semantic ++ words)
    |> Enum.uniq_by(&{&1.page, &1.section})
    # A page whose covers matched stands for all of it: its sections add nothing.
    |> drop_covered_sections(covered)
    |> per_page(@per_page)
    |> Enum.take(@suggestions)
  end

  defp card_text(card), do: Enum.join([card.title, card.description || ""], "\n")

  defp per_page(suggestions, n) do
    suggestions
    |> Enum.reduce({[], %{}}, fn s, {kept, seen} ->
      count = Map.get(seen, s.page, 0)
      if count < n, do: {[s | kept], Map.put(seen, s.page, count + 1)}, else: {kept, seen}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp drop_covered_sections(suggestions, covered) do
    whole = MapSet.new(covered, & &1.page)
    Enum.reject(suggestions, &(&1.section != nil and MapSet.member?(whole, &1.page)))
  end

  # Paths the card names: anything with a slash, or a file with an extension.
  @path ~r{(?<![\w@])(?:[\w.\-]+/)+[\w.*\-]*|\b[\w\-]+\.(?:exs?|heex|eex|js|ts|tsx|css|md|json|ya?ml|sh|py|sql|toml)\b}

  @doc false
  def mentioned_paths(text) do
    text = Regex.replace(~r{\w+://\S+}, text || "", " ")

    @path
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp covered(_pages, []), do: []

  defp covered(pages, paths) do
    for page <- pages,
        globs = List.wrap(field(page, "covers")),
        path = Enum.find(paths, fn path -> Enum.any?(globs, &glob_match?(&1, path)) end),
        do: %{page: page.code, title: page.title, section: nil, why: "covers #{path}"}
  end

  @doc """
  Whether `path` falls under `glob`: `**` crosses folders, `*` doesn't. A
  path the card names may be a folder (`lib/app/`), which matches a glob for
  anything under it.
  """
  def glob_match?(glob, path) when is_binary(glob) and is_binary(path) do
    regex =
      glob
      |> String.trim()
      |> String.split("**")
      |> Enum.map_join(".*", fn part ->
        part |> String.split("*") |> Enum.map_join("[^/]*", &Regex.escape/1)
      end)

    path = String.trim_leading(path, "./")
    String.match?(path, ~r/\A#{regex}\z/) or String.match?(path <> "x", ~r/\A#{regex}\z/)
  end

  def glob_match?(_, _), do: false

  defp semantic(handbook, pages, text, reader, opts) do
    if Slipdock.AI.Embeddings.configured?() do
      by_id = Map.new(pages, &{&1.id, &1})

      case Slipdock.Search.search(reader, text,
             kind: :page,
             board_id: handbook.board.id,
             limit: 20,
             token: opts[:token]
           ) do
        {:ok, results} ->
          for %{page: %Page{id: id}, matches: matches} <- results,
              page = by_id[id],
              match <- matches,
              do: %{
                page: page.code,
                title: page.title,
                section: section_path(match[:section], page),
                why: "matches the card"
              }

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  A search chunk's section as a path `page section` can read, or nil for
  the whole page (#1281). A long section is chunked in parts (`Deploy#2`):
  the part is the section. The page's lone top heading is all of it.
  """
  def section_path(raw, page) do
    path = Regex.replace(~r/#\d+\z/, raw || "", "")

    cond do
      path == "" -> nil
      not String.contains?(path, "/") and top_heading?(page, path) -> nil
      true -> path
    end
  end

  defp top_heading?(page, path) do
    page.body |> Wiki.Section.headings() |> Enum.any?(&(&1.level == 1 and &1.path == path))
  end

  # Words the card shares with each section, its page's title, summary and
  # read_when counting double: a page says when it should be read.
  defp lexical(pages, text) do
    wanted = words(text)

    pages
    |> Enum.flat_map(fn page ->
      about =
        words(
          Enum.join([page.title, page.summary || "", text_field(page, "read_when") || ""], " ")
        )

      page_score = 2 * MapSet.size(MapSet.intersection(wanted, about))

      page
      |> sections()
      |> Enum.map(fn {path, body} ->
        score = page_score + MapSet.size(MapSet.intersection(wanted, words(body)))
        {score, %{page: page.code, title: page.title, section: path, why: "shares words"}}
      end)
    end)
    |> Enum.filter(fn {score, _} -> score > 0 end)
    |> Enum.sort_by(fn {score, _} -> -score end)
    |> Enum.map(&elem(&1, 1))
  end

  # A page's `##` sections (deeper ones roll into theirs); a page with none
  # is one section, addressed by nothing.
  defp sections(page) do
    case Enum.filter(Wiki.Section.headings(page.body), &(&1.level == 2)) do
      [] ->
        [{nil, page.body || ""}]

      headings ->
        for h <- headings do
          {:ok, body} = Wiki.Section.read(page.body, h.path)
          {h.path, body}
        end
    end
  end

  @stop ~w(a an and are as at be by can do for from has have in into is it its of on or
           our so that the their them then this to was we what when which with you your
           any all not new one way get set use make add adding added)

  defp words(text) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(text || ""))
    |> List.flatten()
    |> Enum.map(&stem/1)
    |> Enum.reject(&(&1 in @stop or String.length(&1) < 2))
    |> MapSet.new()
  end

  defp stem(word) do
    cond do
      String.length(word) > 5 and String.ends_with?(word, "ing") -> String.slice(word, 0..-4//1)
      String.length(word) > 4 and String.ends_with?(word, "es") -> String.slice(word, 0..-3//1)
      String.length(word) > 3 and String.ends_with?(word, "s") -> String.slice(word, 0..-2//1)
      String.length(word) > 4 and String.ends_with?(word, "ed") -> String.slice(word, 0..-3//1)
      true -> word
    end
  end

  ## The docs gate's record (#1266) ---------------------------------------------

  # `Handbook: …` on a line of its own, as a list item or bold or quoted,
  # with something after it: what was updated, or `no change (why)`.
  @gate_line ~r/^[ \t>]*(?:[-*+][ \t]+)?(?:\*\*|__)?Handbook:(?:\*\*|__)?[ \t]*(\S[^\n]*)$/m

  @doc """
  What a closing comment's `Handbook:` line says (`"updated W-3 §Contexts"`,
  `"no change (tests only)"`), or nil when `text` has none. The loop writes
  the line; the gardener reads it.
  """
  def gate_line(text) when is_binary(text) do
    case Regex.run(@gate_line, text) do
      [_, said] -> String.trim(said)
      _ -> nil
    end
  end

  def gate_line(_), do: nil

  @doc "A page's `handbook:` key (`architecture`, `index`, …), or nil."
  def key(%Page{} = page), do: field(page, "handbook")

  @doc "A front-matter value of a handbook page, as a string or a list of strings."
  def field(%Page{front_matter: header}, key),
    do: header |> FrontMatter.yaml() |> FrontMatter.get(key)
end

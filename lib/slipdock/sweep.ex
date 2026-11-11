defmodule Slipdock.Sweep do
  @moduledoc """
  Code sweeps (#1793, spec W-2310 §Sweeps and static checks): the codebase
  read by an agent one area and one lens at a time, on a rotation that
  covers everything every few weeks. Static checks in CI catch the
  mechanical part on every push; a sweep is for what needs reading.

  It is a **built-in Tool**, `sweep`, installed onto a board that exists
  (always the root of its tree), like `Slipdock.Handbook`. Installing it
  adds:

  - a **`Sweeps` page** (front matter `sweep: rotation`) holding the
    rotation: areas against lenses, each cell the commit it was last swept
    at, and a log of runs. The areas come from the handbook's pages and
    their `covers:` when the board has a handbook; otherwise the first run
    fills them in from the top-level contexts;
  - a **`Triage` list**, in the `triage` category: the guide's ready list,
    a `list_top` feed and a rule's runner action never take from it, so
    what a sweep files waits for a person instead of going to the loop;
  - a **recurring card, *Sweep the code***, every day, whose description is
    the procedure and whose bar (`card_bar/1`) names the page but no cell
    of it, so it holds on any day. Each run's builder may reword its own
    instance's bar for the cell it took; the next instance starts again
    from the template (`template_bar/1`, which `Slipdock.Recurrence` asks
    for), never from yesterday's cell (#2611).

  Installing again adds only what is missing, and never touches a page that
  is there. A list already called `Triage` with no category is given the
  `triage` one.
  """

  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Blueprint
  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Handbook
  alias Slipdock.Repo
  alias Slipdock.Wiki.{FrontMatter, Page}

  @name "sweep"
  @version "1.1.0"
  @page_title "Sweeps"
  @triage_list "Triage"
  @card_title "Sweep the code"
  @repeat "every day"

  @lenses [
    {"authorization",
     "Every LiveView event handler, API route and MCP tool checks who may do it."},
    {"duplication", "The same logic written twice, where one should call the other."},
    {"dead code", "Functions, modules, routes and flags nothing reaches any more."},
    {"test gaps", "Behaviour, error paths and edge cases no test asserts."},
    {"old code vs rules",
     "Code older than a handbook rule that breaks it (the rule's check only sees new changes)."},
    {"secrets & personal details",
     "Tokens, keys, real names, addresses and hostnames in code, tests, docs and fixtures."}
  ]

  def name, do: @name
  def version, do: @version
  def page_title, do: @page_title
  def triage_list, do: @triage_list
  def card_title, do: @card_title

  @doc "The lenses, in rotation order: `[{name, what it looks for}]`."
  def lenses, do: @lenses

  @doc "Whether `ref` names the built-in Sweep Tool."
  def tool?(ref) when is_binary(ref), do: String.downcase(String.trim(ref)) == @name
  def tool?(_), do: false

  ## The Tool --------------------------------------------------------------------

  @card_description """
  Read one area of the code through one lens, and file what you find: fixes and investigations for the runners, design questions for a person. It comes every day. Spec: W-2310 §Sweeps and static checks.

  **Two limits.** One area and one lens per run, never more. Security issues get the `security` tag and stay vague anywhere public (commit messages, PR titles and bodies, the log): the detail goes on the card.

  1. Pick: open the `Sweeps` page and take the stalest cell of its Rotation table, a `—` first, else the oldest date; ties go to the area higher in the table. With no areas yet, add a row per area first: the handbook's pages and their `covers:` (`slipdock handbook <board>`), else the top-level contexts (`lib/<app>/*`, one row each), and say so in the closing comment.
  2. Check out the default branch's head in a clean tree, so nothing uncommitted counts: `git fetch origin && git worktree add /tmp/sweep-<this card> origin/<default>`. Note the short sha.
  3. Read the area's paths through the lens (the page's Lenses section says what each looks for). Read; don't change code on this card.
  4. File each issue as its own card, never in the ready list. A **fix or investigation** (something already decided is broken, missing, untested or unexplained) goes to the `Housekeeping` list, which runners work after the ready list: `slipdock add <board> "<what is wrong, where>" --column Housekeeping --origin sweep --desc - <<'EOF'` with the description on the lines after it and `EOF` to end it (`--desc -` reads it from stdin, so a heredoc keeps its lines), saying where (file and function), why it matters and the fix. A **design question** (the answer would change how the product or a process behaves) goes to `Triage` for a person instead (`--column Triage --origin sweep`). On a board with no Housekeeping list, everything goes to Triage. Security issues get `--tag security`. One issue a card; nothing found is a normal result.
  5. Name each card you filed in the closing comment's `Findings:` block with the arrow, `- gotcha: <what is wrong> → #<card>` (or `- rule: …`), so it is kept promoted rather than left open: a fix is a card, not a finding, and the card is where it gets done. Only what is uncertain or cuts across cards, and isn't a card, is a plain finding.
  6. Update the page by section, with `--message "#<this card> sweep <area> × <lens>"`: the cell gets `<sha> <date>`, and the Log gets a line `- <date>: <area> × <lens> at <sha>, filed <card ids or nothing>`.
  7. Remove the worktree, and close the card with what was swept (area, lens, sha) and the cards filed. The next one comes by itself tomorrow.
  """

  @doc """
  The bar of every *#{@card_title}* instance (#2611), for the rotation page
  `code` (`W-…`): what a run does, whichever cell is stalest that day. It
  names no area and no lens, since the run that takes the card is what picks
  them.
  """
  def card_bar(code) do
    """
    Swept the stalest cell of #{code}'s Rotation table (a `—` first, else the oldest date; ties to the area higher in the table): one area through one lens, at the default branch's head
    Each issue found filed as its own card: fixes and investigations in the Housekeeping list (Triage on a board without one), design questions in Triage (security ones tagged `security`), and named in the closing comment's Findings block, or none found said so
    #{code}'s Rotation cell for that area and lens, and its Log, updated with the sha and date; the closing comment names the area, the lens and the sha
    """
    |> String.trim_trailing()
  end

  @doc """
  The bar a new instance of `card` starts from, when `card` is its board's
  *#{@card_title}* card and the board has the sweep installed: the template
  (`card_bar/1`) with the rotation page's code, whatever the instance before
  it said. Nil for any other card, which keeps its own bar.
  """
  def template_bar(%Card{title: @card_title, board_id: board_id}) do
    with %Board{} = board <- Repo.get(Board, board_id),
         %{board: %Board{id: ^board_id}, page: %Page{code: code}} when is_binary(code) <-
           find(board) do
      card_bar(code)
    else
      _ -> nil
    end
  end

  def template_bar(_card), do: nil

  @doc """
  The sweep as a board blueprint (see `Slipdock.Blueprint`): the Triage list,
  the Sweeps page with its rotation table for `areas`, and the recurring card.
  """
  def blueprint(areas \\ []) do
    %{
      "lists" => [%{"name" => @triage_list, "category" => "triage", "color" => "amber"}],
      "folders" => [],
      "tags" => ["security"],
      "pages" => [
        %{
          "title" => @page_title,
          "summary" =>
            "The code sweep's rotation: areas against lenses, and when each was swept.",
          "front_matter" => "sweep: rotation",
          "body" => page_body(areas)
        }
      ],
      "automations" => [],
      "cards" => [
        %{"title" => @card_title, "description" => @card_description, "repeat" => @repeat}
      ]
    }
  end

  @doc """
  The Sweeps page's body for `areas` (`[{name, [glob]}]`): the lenses, the
  rotation table with every cell unswept (`—`), and an empty log.
  """
  def page_body(areas) do
    """
    # Sweeps

    The code read one area and one lens at a time, by the *#{@card_title}* card each day. It files fixes and investigations in the `Housekeeping` list, which runners work after the ready list, and design questions in the `#{@triage_list}` list, for a person to triage: nothing in Triage goes to the loop by itself. On a board with no Housekeeping list, everything goes to Triage.

    ## Lenses

    #{Enum.map_join(@lenses, "\n", fn {lens, what} -> "- **#{lens}**: #{what}" end)}

    ## Rotation

    _Each cell is the commit and date the area was last swept through that lens; `—` is never. A run takes the stalest cell._

    #{table(areas)}

    ## Log

    _Each run adds a line here, newest last: the date, the area and lens, the commit, the cards filed._
    """
  end

  defp table(areas) do
    header = "| Area | Paths | " <> Enum.map_join(@lenses, " | ", &elem(&1, 0)) <> " |"
    rule = "|" <> String.duplicate(" --- |", length(@lenses) + 2)
    cells = Enum.map_join(@lenses, " | ", fn _ -> "—" end)

    rows =
      case areas do
        [] ->
          ["| _no areas yet: the first run adds them_ | | #{cells} |"]

        areas ->
          for {area, paths} <- areas do
            "| #{cell(area)} | #{Enum.map_join(paths, ", ", &"`#{cell(&1)}`")} | #{cells} |"
          end
      end

    Enum.join([header, rule | rows], "\n")
  end

  # A pipe in a page title or a glob would end the cell early.
  defp cell(text), do: String.replace(text, "|", "\\|")

  @doc """
  The rotation's areas for `board`'s tree: each handbook page (the Index
  aside) whose `covers:` names paths, as `{title, globs}` in the handbook's
  order. Empty when the board has no handbook, or none of its pages say what
  they cover.
  """
  def areas(%Board{} = board) do
    case Handbook.find(board) do
      nil ->
        []

      %{pages: [_index | pages]} ->
        for page <- pages,
            globs = covers(page),
            globs != [],
            do: {page.title, globs}
    end
  end

  defp covers(page) do
    case Handbook.field(page, "covers") do
      list when is_list(list) -> list |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))
      glob when is_binary(glob) and glob != "" -> [glob]
      _ -> []
    end
  end

  @doc """
  Installs the sweep on `board`'s root board for `user`, who must be able to
  write to it. Installing again adds only what is missing: a list, the page
  or the card somebody deleted.

  Returns `{:ok, %{board:, created:, upgraded:, version:, install:, report:}}`
  (the shape a Tool install reports), or `{:error, message}`.
  """
  def install(%User{} = user, %Board{} = board, _opts \\ []) do
    root = Handbook.root(board)

    with :ok <- can_write(user, root) do
      created = is_nil(find(root))

      case Blueprint.apply(root, Handbook.scheduled_cards(blueprint(areas(root)), root),
             user: user,
             message: "installed by the Sweep Tool, #{@version}"
           ) do
        {:ok, report} ->
          report = categorise_triage(root, report)
          :ok = put_bar(root, user)
          {report, upgraded} = refresh_card(root, user, report)

          {:ok,
           %{
             board: Boards.get_board!(root.id),
             created: created,
             upgraded: upgraded,
             version: %{version: @version},
             install: %{version: @version},
             report: report
           }}

        {:error, message} ->
          {:error, message}
      end
    end
  end

  # A list already called Triage with no category (one made by hand, before
  # the category existed) is taken as the Triage list and given it, so
  # nothing feeds from it; reported as "Triage (category set)". A list with
  # a category of its own is left alone.
  defp categorise_triage(root, report) do
    name = String.downcase(@triage_list)

    from(c in Column,
      where:
        c.board_id == ^root.id and fragment("lower(?)", c.name) == ^name and
          (is_nil(c.category) or c.category == "")
    )
    |> Repo.all()
    |> Enum.reduce(report, fn col, report ->
      {:ok, _} = col |> Column.changeset(%{category: "triage"}) |> Repo.update()
      update_in(report, [:added, "lists"], &(&1 ++ ["#{col.name} (category set)"]))
    end)
  end

  # The card's bar (#2611), given once the page has its code: on a card made
  # now, or an older install's card that has none. A bar somebody wrote, or
  # one that has locked, is theirs.
  defp put_bar(root, user) do
    case find(root) do
      %{card: %Card{bar: bar, bar_locked_at: nil} = card, page: %Page{code: code}}
      when bar in [nil, ""] and is_binary(code) ->
        {:ok, _} = Boards.update_card(card, %{"bar" => card_bar(code)}, by: user)
        :ok

      _ ->
        :ok
    end
  end

  # 1.1.0 (#2779) files fixes to Housekeeping and design questions to
  # Triage. Installing over an older sweep moves its open card to the
  # current procedure; a card already current is left alone. Reported as
  # "Sweep the code (updated: procedure)".
  defp refresh_card(root, user, report) do
    with %{card: %Card{description: description} = card} <- find(root),
         true <- description != @card_description,
         {:ok, _} <- Boards.update_card(card, %{"description" => @card_description}, by: user) do
      name = "#{@card_title} (updated: procedure)"
      {update_in(report, [:added, "cards"], &(&1 ++ [name])), true}
    else
      _ -> {report, false}
    end
  end

  defp can_write(user, board) do
    if Slipdock.Access.can_write?(Slipdock.Access.board_permission(user, board)),
      do: :ok,
      else: {:error, "installing the sweep needs write access to #{board.name}"}
  end

  @doc """
  The sweep of `board`'s tree, or nil when its root board has none:
  `%{board:, page:, card:}`, where `page` is the root's unarchived page with
  `sweep: rotation` and `card` the open *#{@card_title}* card, if any.
  """
  def find(%Board{} = board) do
    root = Handbook.root(board)

    page =
      from(p in Page,
        where:
          p.board_id == ^root.id and is_nil(p.archived_at) and p.template == false and
            not is_nil(p.front_matter),
        order_by: [asc: p.id]
      )
      |> Repo.all()
      |> Enum.find(&rotation?/1)

    if page do
      card =
        from(c in Card,
          where:
            c.board_id == ^root.id and c.title == @card_title and is_nil(c.archived_at) and
              c.completed == false,
          order_by: [desc: c.id],
          limit: 1
        )
        |> Repo.one()

      %{board: root, page: page, card: card}
    end
  end

  def find(_), do: nil

  defp rotation?(%Page{front_matter: header}),
    do: header |> FrontMatter.yaml() |> FrontMatter.get("sweep") == "rotation"
end

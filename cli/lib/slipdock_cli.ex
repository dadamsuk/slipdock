defmodule SlipdockCLI do
  @moduledoc "Command-line client for the Slipdock board API."

  import SlipdockCLI.Util, only: [fail: 1, bad_usage: 1]

  alias SlipdockCLI.{Admin, Auth, Automations, Boards, Skills, Util, Wiki}

  @help """
  slipdock — read and write cards on your Slipdock boards

  USAGE
    slipdock <command> [args] [--json] [--url URL]

  START HERE
    guide                               how to use these boards as a work tracker, from the server
                                        itself: epics and subcards, what to pick up next, what to
                                        write back as you go (also GET /api/guide)

  FIND ANYTHING  (semantic: matched by meaning, so the words you type needn't be
                  the words that were written; covers cards, comments and status updates)
    search <words...>                   search every board you can see
        --board B     only that board and its sub-boards
        --kind cards|pages|all   cards and their comments, wiki pages, or both (default)
        --limit N     how many results (default 20, max 50)
        --archived    include archived cards
        --full        print the whole matching text, not a snippet
    ask <question...>                   ask the assistant, which searches for itself and
                                        answers in prose, naming the cards it read
    search-status                       what is indexed, and whether anything is queued
    saved [--ask | --mode search]       the searches and questions you have saved (yours alone)
    save <words...> [--ask]             save a search (with --ask, a question)
    unsave <words...> [--ask]           take one off the list (or `unsave --id N`)

  AUTH
    url [<url>]                         which server to talk to, saved in
                                        ~/.config/slipdock/url so it need not be in the
                                        environment (`url --remove` forgets it).
                                        $SLIPDOCK_URL still wins for a one-off
    auth                                sign in without a token: shows a code to approve in a
                                      browser, then saves the token it is given
      --label TEXT  what the approval screen calls this client (default: this host)
      --scope read|write   what to ask for (default: write)
  auth <token>                        save an API token directly (create one at /account/tokens)
    whoami                              show who you are signed in as
    ai-key [<key>]                      show your stored API key (masked), or set one;
                                        `ai-key --remove` deletes it
    ai                                  which model your AI requests go to: endpoint, key, model
    ai-endpoint [<url>]                 point at any OpenAI-compatible API — a local LM Studio,
                                        Ollama, llama.cpp, vLLM — instead of OpenRouter;
                                        no key needed for most. `--key K` sets one at the same
                                        time, `--remove` goes back to the server's default
    ai-models                           what that endpoint can run
    ai-model <id>                       pick one (`--embed <id>` for the search index too).
                                        AI features need a key or an endpoint
    logout                              forget the saved token

  ADMIN  (needs a token made with the admin scope — Account → API tokens)
  admin settings                      what this server allows, and who it tells
  admin build                         the commit and build time now running
  admin set key=value...              signup_mode=open|allowlist|approval|closed,
                                      free_card_limit=20, user_directory=shared_only,
                                      invites_create_accounts=false,
                                      trial_days=30, trial_enabled=true,
                                      board_limit=1000, item_limit=250000,
                                      storage_limit_mb=10240, and <name>_enabled=false
                                      to switch any limit off
                                      posthog_key=phc_... posthog_host=https://eu.i.posthog.com
                                      for analytics; posthog_key= turns it off
                                      ai_system_user=you@example.com: whose AI key semantic
                                      search and scheduled automations use (an admin's);
                                      ai_system_user= clears it
  admin allow <entry>                 let an address or a whole domain register
  admin disallow <entry>
  admin users                         who is here, what they use, when last seen
  admin promote|demote <email>        admin rights (never the last admin)
  admin disable|enable <email>        reversible; ends their sessions at once
  admin limit <email> <n|none>        an item limit of their own
  admin paid <email> <date|none>      paid up to a date: off the free tier and off
                                      the trial clock (e.g. 2026-12-31)
  admin unlimited <email> on|off      off the free tier for good, no date needed;
                                      the server-wide ceilings still apply
  admin signups                       who is waiting to be let in
  admin approve|reject <email>

  READ
    boards [--archived|--all] [--sort S] list boards you own or that are shared with you
        (archived boards are left out unless asked for; S: manual name active newest oldest cards)
    board <board>                       show a board with all columns and cards
    columns <board>                     list columns (lists) on a board
    tags <board>                        list tags on a board
    cards <board> [filters]             list cards on a board
        --column C  --tag T  --priority P  --flag F  --search Q
        --kind card|document                      (document: a card that is just its file)
        --due overdue|today|week|month|has|none   (still-outstanding dates)
        --deps blocked|ready|blocking|violated|free
        --assignee NAME|EMAIL|me | --no-assignee
        --open | --done   --archived (archived alone) | --all (archived too)
    card <id>                           show one card in full (checklist, comments)
    activity <board> [--limit N] [--card ID]  recent activity on a board (or one card)
    swimlanes <board> [view opts]       cards as a grid, grouped on two axes
    table <board> [view opts] [--fields F]  cards as a table (F: comma list of
        id title column priority assignee flags tags start due completed percent time checklist comments deps subcards
        rollup health created updated)
    views <board>                       list saved swimlane views
    automations <board>                 list the board's automation rules
    automation <board> <rule>           show one rule, spec and all
    automation-help                     the triggers, conditions and actions a spec may use
    automation-presets                  the ready-made rules `new-automation --preset` can add
    callbacks <board> [--limit N]       the calls the board's rules have made, and what came back
    alerts                              alerts automation rules have raised for you
    templates                           list board templates (sets of lists)
    fields <board>                      list custom fields (and their {keys} for formulas)
    milestones <board>                  list milestones on a board tree

  FAVOURITES  (yours alone; in the web app they are the phone's Favourites tab,
               two taps from anywhere — nobody else's list changes)
    favourites                          list what you have favourited, with the URL of each
    fav card <id>                       favourite a card
    fav list <board> <column>           favourite a list (opens the board at that list)
    fav view <board> <view>             favourite a saved view
    fav board <board>                   favourite a whole board
    unfav <same args>                   stop favouriting it (or `fav ... --off`)

  WIKI  (Markdown pages on a board: how it works, what was decided and why.
         A page answers to its code — W-31 — its slug, or board/slug.)
    page ls <board> [--q TEXT] [--archived|--all] [--template] [--draft]
                    [--folder F | --no-folder]
    page tree <board>                   the page tree, nesting shown by indent
    page read <page>                    print the Markdown source
    page render <page> [--format markdown|html|text]
                                        the same with every reference resolved: links
                                        followed, #412 filled in with what the card says
                                        now, [[!toc]] expanded
    page new <board> <title...>         write a page
        --body TEXT | --file F | --body -   (- reads the body from stdin)
        --parent P    put it under another page
        --folder F    file it in a folder — a name or a path, made if it is new
        --summary S   one line, shown in listings
        --message M   why, recorded in the page's history
        --draft       only writers can see it
    page edit <page> [--title T] [--summary S] [--body TEXT|--file F|--body -]
        --message M   why (write one every time)
        --base-hash H the hash you read (see `page read --json`); a save that
                      would land on someone else's is refused, not applied
        --draft | --publish
        the card facets, so a doc on the board reads like one:
        --priority P  --flag F (repeatable) / --flag F --off
        --start DATE | --no-start   --due DATE | --no-due
        --percent N | --no-percent  --color C | --no-color
        --assignee EMAIL | --no-assignee   --done | --undone
        --folder F | --no-folder
    page file <page> --folder F | --no-folder
                                        file it in a folder, or take it out of one.
                                        Where a page is *kept*; `page mv` is what it is
                                        *part of*
    page mv <page> [--parent P | --root] [--position N|top|bottom]
    page rm <page> [--purge]            archive it (--purge deletes, owner only)
    page restore <page>
    page history <page> [--limit N]     every save, who made it and why
    page diff <page> [--rev N] [--against M]
                                        what a version changed (default: the latest),
                                        or with --against how it differs from version M
    page revert <page> --rev N [--message M]
    page sections <page>                the heading paths a section may be addressed by
    page section <page> <path>          print one section
    page section <page> <path> --append TEXT | --body TEXT | --file F [--message M]
                                        add to, or replace, one section. Appending cannot
                                        conflict and needs no hash — the write to prefer
    page append <page> --body TEXT|--file F [--message M]   add to the end of the page
    page links <page>                   what it points at, what points at it, what it wanted
    page pin <page> --card N | --page P [--off]
                                        "this page is *the* spec for that"
    page wanted <board>                 pages linked to but never written — the wiki's backlog
    page resolve <board> <title...>     is there a page for this, and what do I write?
    page query-help                     the grammar a ```slipdock block is written in
    page query <board> --body -         try a block without writing it anywhere
    page place <page> <column> [--before REF]
                                        put the page in one of its board's lists, so it sits
                                        beside the work and can be dragged like a card
                                        (REF: a card's number, or page-7)
    page unplace <page>                 take it off the board; it stays in the wiki
    page publish <page> [--off]         read-only at a public link; its live queries are
                                        answered once, when you publish (publish again to
                                        refresh them). --off withdraws the link
    export [<board>...] [--out FILE]    whole board trees as one JSON document: lists, cards,
                                        subcards, tags, checklists, comments, custom fields,
                                        dependencies and the wiki. No board named takes every
                                        one you own; --archived brings in what is put away.
                                        Without --out it goes to stdout
    import <file.json> [--from SRC]     build the trees in a document. Always new boards —
                                        it never merges into what is already here. A
                                        Trello board's JSON export works too, recognised
                                        by its shape; --from trello says so outright
    page export <board> --dir D         write the wiki out as .md files with front matter
    page import <board> --dir D [--overwrite]
                                        read a folder of Markdown in; folders become parents,
                                        and a title already on the board is skipped
    page card <card-id>                 the pages that talk about a card, pinned first
    page from <board> <template> --title T [--set k=v]... [--card N] [--folder F]
                                        a page from a template page, {{placeholders}} filled
    writeup <card-id> [--template T] [--title T] [--folder F]
                                        start a page for a card, pinned to it
    page make-card <page> --body TEXT|--file F [--column C]
                                        turn a passage of a page into a card, linked both ways

  FOLDERS  (where pages are kept, nested to any depth. A folder answers to its
            id, its slug, its name, or a path of names — "Design/Decisions".
            Deleting one never deletes writing.)
    wiki                                every board's wiki at once: boards, then folders
    folder ls <board>                   the board's filing, pages and all
    folder new <board> <name...> [--parent F]
                                        a name with slashes makes the whole path
    folder mv <board> <folder> [--name N] [--parent F | --root] [--position N]
    folder rm <board> <folder> [--purge]
                                        delete the folder only: its subfolders move up and
                                        its pages go back to the root. --purge deletes the
                                        pages in it as well, history and all (owner only)

  SKILLS  (the agent instructions this server ships, versioned with its API)
    skills                              list them, with a version each
    skills install [--dir D]            write them to ~/.claude/skills (or D)
    skills check                        say whether the local copies are behind

  WRITE
    add <board> <title> [opts]          create a card
        --column C (default: first column)  --desc TEXT  --priority P
        --assignee EMAIL|me (repeatable: everybody on it, the first is the lead)
        --flag F (repeatable)  --tag T (repeatable)  --start YYYY-MM-DD  --due YYYY-MM-DD  --color C
        --percent N (0-100)
        --spent T  --estimate T  --unit minutes|hours|days|weeks|months   (time tracking; see edit)
    edit <id> [opts]                    change fields on a card
        --title T  --desc TEXT  --priority P  --start DATE | --no-start  --due DATE | --no-due
        --color C | --no-color  --column C
        --assignee EMAIL|me (repeatable; replaces who is on it) | --no-assignee
        --add-assignee EMAIL|me  --remove-assignee EMAIL|me   (repeatable; others stay)
        --percent N | --no-percent   (% complete, 0-100)
        --spent T | --no-spent  --estimate T | --no-estimate   time spent and the estimate.
                                     A bare number is in the card's unit; or say 90m, 1.5h,
                                     2d, 1w, 1mo, "1h 30m" (a day is 8h, a week 5d, a month 4w)
        --unit minutes|hours|days|weeks|months   how the card shows both (default hours)
        --log T                      add T to the time spent (--log=-30m takes it off)
    timer <id> start|stop               run a card's timer; stopping adds what it ran to the
                                        time spent
    log <id> <time>                     add time spent by hand (same as edit --log)
    move <id> <column> [--top|--bottom|--index N]
    move <id> <column> --board B         move the card to a list on another board, with its
                                         subcards; tags travel by name, custom fields only
                                         where that board has the same one
    done <id>...  |  undone <id>...     mark complete / incomplete
    flag <id> <flag>... [--off]         add (or remove) flags
    tag <id> <tag>... [--off]           add (or remove) tags
    check <id> <text>                   add a checklist item
    tick <item-id>                      toggle a checklist item done/undone
    comment <id> <text>                 add a comment
                                        (check, comment, status, vote, weblink and unweblink take
                                        a wiki page too: a page code like W-31 instead of a number)
    link <id> <kind> <card-id>...       link cards across boards (kind: relates contributes duplicates)
    unlink <id> <link-id>...            remove links (ids shown by `card`)
    weblink <id> <url> [--label TEXT]   link a card to a web page, drive or file (datestamped)
    unweblink <id> <url-id>...          remove web links (ids shown by `card`)
    blocked-by <id> <card-id>... [--off] mark <id> as waiting on other cards, on any board you
                                        can read (or remove)
    blocks <id> <card-id>... [--off]     mark <id> as holding up other cards; you need write on
                                        theirs (or remove)
    archive <id>...  |  restore <id>... archive / restore cards
    delete <id>...                      permanently delete (prefer archive)
    new-board <name> [--code C] [--shortcut K] [--desc TEXT] [--color C] [--template T]
        [--list "Name[:wip[:color]]"]... [--save-template NAME]
                                        --list (repeatable) sets the board's own lists instead
                                        of a template's; --save-template keeps them as one too
    welcome [--force]                   build the "Getting Started" board: a tour of the whole
                                        app, cards, subcards, automation and wiki pages included
                                        (the one a first sign-in makes by itself)
    set-board <board> [--name N] [--code C] [--shortcut K] [--desc TEXT] [--color C]
        [--no-add-card] [--no-add-page] [--no-add-document] [--sprints | --no-sprints]
        [--simple | --no-simple]
                                        rename a board, change its code, shortcut key or colour,
                                        say what the foot of each list offers, make it a
                                        sprint board (every card a sprint), or a simple one (a
                                        plain to-do list: % complete, start dates, health,
                                        time, votes, dependencies, Timeline and Prioritise
                                        hidden — not deleted)
    sprint <board> [--name N] [--start DATE] [--days N] [--goal TEXT]
                                        start the next sprint on a sprint board: a dated card
                                        ("Sprint 4", following on from the last, 14 days unless
                                        told) with its own board of subcards
    sprint-add <sprint-id> <card-id>... move cards from any board into a sprint, with their
                                        subcards; ones that can't go in are listed, not fatal
    sprint-sources <board> [<source>[:list,list...]]... [--clear]
                                        the boards (and lists on them) a sprint board's sprints
                                        are planned from; with no sources, show them. A source
                                        without lists shows every open list on it
    sprint-plan <sprint-id> [--sort position|score|priority|estimate]
                                        the planning view: every source list's open cards with
                                        priority, scores, votes and estimate (Σ: added up from
                                        its subcards), and what the sprint holds already
    burndown <sprint-id>                a sprint's work left at the end of each day, against
                                        the ideal straight line to zero
    velocity <board>                    cards committed and completed in each sprint on a
                                        sprint board, and the average of the finished ones
    archive-board <board>               put a whole board away, keeping every card on it
    restore-board <board>               bring an archived board back
    order-boards <board>...             set the order you list boards in (yours alone; boards
                                        left out fall to the end, oldest first)
    subboard <card-id> --template T     give a card its own board of subcards
    subboard <card-id> --off            remove a card's subcards
    new-template <name> [--desc TEXT] --list "Name[:wip[:color]]"...
    delete-template <template>
    new-column <board> <name> [--wip N] [--color C] [--category C]
    set-column <board> <column> [--name N] [--wip N] [--color C] [--category C]
                                        change a list; category is todo, doing, done,
                                        dropped, or "" for none
                                        (both) --sort position|created|updated|start_date|
                                        due_date|priority [--descending] and --group none|
                                        flag|tag|start_date|due_date: how the app draws it
    new-tag <board> <name> [--color C]
    set <id> <key>=<value>...           set custom fields on a card ("" clears; choice by label or key)
    vote <id> <n>                       put n of your votes on a card or page (0 removes them)
    status <id> <on_track|at_risk|off_track> [note...]  report a card's or page's health
    new-field <board> <name> --kind K   add a custom field (K: number rating select date text formula)
        [--options "Small=1, Large=3"] [--formula "{value} / {effort}"] [--sum]
    delete-field <board> <field>
    preset <board> <rice|ice|value_effort>  set a scoring scheme up (inputs + formula)
    milestone <board> <name> --date YYYY-MM-DD [--color C]
    delete-milestone <board> <id>
    new-automation <board> <description...>         write a rule in plain English (the server's AI
                                                   turns it into a spec; needs an API key there)
    new-automation <board> --spec JSON [--name N] [--tree]
                                                   add a rule exactly (see `automation-help`;
                                                   --spec - reads the JSON from stdin)
    new-automation <board> --preset KEY [field=value...] [--name N]
                                                   add a ready-made rule, no AI needed (see
                                                   `automation-presets`), e.g. --preset follow_list
                                                   column=Doing notify=email
    set-automation <board> <rule> [--on|--off] [--name N] [--spec JSON] [--text "..."]
                                                   [--tree|--no-tree] also watch subcards, or not
    run-automation <board> <rule>                  run a timed rule now (forgets what it has done)
    delete-automation <board> <rule>
    dismiss <alert-id>... | dismiss --all           dismiss alerts (yours only; others keep theirs)
    save-view <board> <name> [view opts]            save a swimlane configuration
    update-view <board> <view> [view opts] [--name N] change a saved view
    delete-view <board> <view>

  VIEW OPTIONS (swimlanes, save-view, update-view)
    --view V              start from a saved view (id or name), then apply the options below
    --group A             (table) group rows by an attribute, same values as --rows
    --rows A  --cols A    axis attribute: none column assignee priority tag flag completed color
                          due_date schedule created updated   (default: priority x column;
                          schedule = the due date rolled up from a card's subcards)
    --unit U              day | week | month | quarter | year for date axes (default: week)
    --sort S [--descending]  position | title | priority | start_date | due_date | created | updated
                          votes | f:<field id>
    --show-empty          keep empty groups (and fill gaps between dates)
    filters: --tag T... --priority P... --flag F... --column C... --search Q
             --kind card|document|page... (what a list holds; page = a wiki page placed in it)
             --due overdue|today|week|month|has|none   --open | --done

  VALUES
    <board>    numeric id, code, or name (case-insensitive) — 14, qvm-v1-rem,
               or "QVM V1 Remediation". The code is the board's short name: unique,
               URL-safe, up to 10 characters, taken from the name and editable.
    <column>   numeric id or name, e.g. "In Progress"
    priority   none | low | medium | high | critical
    flag       flagged | blocked | review | waiting | starred
    color      slate red orange amber lime emerald teal sky indigo violet fuchsia rose

  OUTPUT
    --json     print the raw API response as JSON (best for programs)
    --url URL  API base (default: $SLIPDOCK_URL, else this host's Tailscale IP :4000)
  """

  @switches [
    json: :boolean,
    from: :string,
    scope: :string,
    remove: :boolean,
    key: :string,
    embed: :string,
    url: :string,
    column: :keep,
    tag: :keep,
    priority: :keep,
    flag: :keep,
    rows: :string,
    cols: :string,
    unit: :string,
    sort: :string,
    descending: :boolean,
    view: :string,
    show_empty: :boolean,
    name: :string,
    code: :string,
    shortcut: :string,
    add_card: :boolean,
    add_page: :boolean,
    add_document: :boolean,
    sprints: :boolean,
    clear: :boolean,
    simple: :boolean,
    days: :integer,
    goal: :string,
    template: :string,
    save_template: :string,
    list: :keep,
    fields: :string,
    group: :string,
    search: :string,
    open: :boolean,
    done: :boolean,
    archived: :boolean,
    deps: :string,
    limit: :integer,
    board: :string,
    title: :string,
    desc: :string,
    due: :string,
    no_due: :boolean,
    assignee: :keep,
    add_assignee: :keep,
    remove_assignee: :keep,
    no_assignee: :boolean,
    start: :string,
    no_start: :boolean,
    percent: :integer,
    no_percent: :boolean,
    spent: :string,
    no_spent: :boolean,
    estimate: :string,
    no_estimate: :boolean,
    log: :string,
    color: :string,
    no_color: :boolean,
    top: :boolean,
    bottom: :boolean,
    index: :integer,
    off: :boolean,
    wip: :integer,
    category: :string,
    kind: :keep,
    label: :string,
    options: :string,
    formula: :string,
    sum: :boolean,
    date: :string,
    spec: :string,
    preset: :string,
    text: :string,
    on: :boolean,
    tree: :boolean,
    all: :boolean,
    full: :boolean,
    ask: :boolean,
    mode: :string,
    id: :string,
    parent: :string,
    root: :boolean,
    folder: :string,
    no_folder: :boolean,
    summary: :string,
    message: :string,
    base_hash: :string,
    body: :string,
    file: :string,
    rev: :string,
    against: :string,
    position: :string,
    draft: :boolean,
    publish: :boolean,
    purge: :boolean,
    force: :boolean,
    append: :string,
    card: :string,
    page: :string,
    dir: :string,
    out: :string,
    overwrite: :boolean,
    before: :string,
    undone: :boolean,
    format: :string,
    set: :keep,
    q: :string,
    help: :boolean
  ]

  def main(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: [h: :help, j: :json])

    if invalid != [] do
      fail("unknown option(s): " <> Enum.map_join(invalid, ", ", &elem(&1, 0)))
    end

    if opts[:url], do: System.put_env("SLIPDOCK_URL", opts[:url])

    try do
      case {args, opts[:help]} do
        {_, true} -> IO.puts(@help)
        {[], _} -> IO.puts(@help)
        {["help" | _], _} -> IO.puts(@help)
        {[cmd | rest], _} -> run(cmd, rest, opts)
      end
    rescue
      # stdout closed early (e.g. piped into `head`): exit quietly. Only that
      # — a blanket rescue here twice swallowed a real bug (`not nil`, which
      # raises) and made a broken command look like a silent success. Anything
      # else is reraised, including an exception with no `:original` at all.
      error ->
        if Map.get(error, :original) in [:terminated, :epipe, :ebadf],
          do: System.halt(0),
          else: reraise(error, __STACKTRACE__)
    end
  end

  # Each area module lists the command names it answers to; the first that
  # claims a name gets every clause of it, so a name must live in one place.
  @areas [Auth, Admin, Boards, Automations, Wiki, Skills]

  defp run(cmd, args, o) do
    case Enum.find(@areas, &(cmd in &1.commands())) do
      nil -> bad_usage(cmd)
      area -> area.run(cmd, args, o)
    end
  end

  # Kept callable here, where the tests (and anyone scripting against the
  # module) have always found them.
  @doc false
  defdelegate contained(dir, path), to: Util

  @doc false
  defdelegate await_device_approval(started, interval, sleep \\ &Process.sleep/1), to: Auth
end

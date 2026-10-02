defmodule SlipdockCLI do
  @moduledoc "Command-line client for the Slipdock board API."

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

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
    auth                                sign in without a token: shows a code to approve in a
                                      browser, then saves the token it is given
      --label TEXT  what the approval screen calls this client (default: this host)
      --scope read|write   what to ask for (default: write)
  auth <token>                        save an API token directly (create one at /account)
    whoami                              show who you are signed in as
    ai-key [<key>]                      show your stored OpenRouter key (masked), or set one;
                                        `ai-key --remove` deletes it. AI features need it
    logout                              forget the saved token

  ADMIN  (needs a token made with the admin scope — Account → API tokens)
  admin settings                      what this server allows, and who it tells
  admin build                         the commit and build time now running
  admin set key=value...              signup_mode=open|allowlist|approval|closed,
                                      free_card_limit=20, user_directory=shared_only,
                                      invites_create_accounts=false
  admin allow <entry>                 let an address or a whole domain register
  admin disallow <entry>
  admin users                         who is here, what they use, when last seen
  admin promote|demote <email>        admin rights (never the last admin)
  admin disable|enable <email>        reversible; ends their sessions at once
  admin limit <email> <n|none>        a card limit of their own
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
        --open | --done   --archived
    card <id>                           show one card in full (checklist, comments)
    activity <board> [--limit N]        recent activity on a board
    swimlanes <board> [view opts]       cards as a grid, grouped on two axes
    table <board> [view opts] [--fields F]  cards as a table (F: comma list of
        id title column priority assignee flags tags start due completed percent checklist comments deps subcards
        rollup health created updated)
    views <board>                       list saved swimlane views
    automations <board>                 list the board's automation rules
    automation <board> <rule>           show one rule, spec and all
    automation-help                     the triggers, conditions and actions a spec may use
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
    page diff <page> [--rev N]          what a version changed (default: the latest)
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
    import <file.json>                  build the trees in a document. Always new boards —
                                        it never merges into what is already here
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
        --column C (default: first column)  --desc TEXT  --priority P  --assignee EMAIL
        --flag F (repeatable)  --tag T (repeatable)  --start YYYY-MM-DD  --due YYYY-MM-DD  --color C
        --percent N (0-100)
    edit <id> [opts]                    change fields on a card
        --title T  --desc TEXT  --priority P  --start DATE | --no-start  --due DATE | --no-due
        --color C | --no-color  --column C  --assignee EMAIL | --no-assignee
        --percent N | --no-percent   (% complete, 0-100)
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
    blocked-by <id> <card-id>... [--off] mark <id> as waiting on other cards (or remove)
    blocks <id> <card-id>... [--off]     mark <id> as holding up other cards (or remove)
    archive <id>...  |  restore <id>... archive / restore cards
    delete <id>...                      permanently delete (prefer archive)
    new-board <name> [--code C] [--shortcut K] [--desc TEXT] [--color C] [--template T]
    welcome [--force]                   build the "Getting Started" board: a tour of the whole
                                        app, cards, subcards, automation and wiki pages included
                                        (the one a first sign-in makes by itself)
    set-board <board> [--name N] [--code C] [--shortcut K] [--desc TEXT] [--color C]
        [--no-add-card] [--no-add-page] [--no-add-document]
                                        rename a board, change its code, shortcut key or colour,
                                        or say what the foot of each list offers
    archive-board <board>               put a whole board away, keeping every card on it
    restore-board <board>               bring an archived board back
    order-boards <board>...             set the order you list boards in (yours alone; boards
                                        left out fall to the end, oldest first)
    subboard <card-id> --template T     give a card its own board of subcards
    subboard <card-id> --off            remove a card's subcards
    new-template <name> [--desc TEXT] --list "Name[:wip[:color]]"...
    delete-template <template>
    new-column <board> <name> [--wip N] [--color C]
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
    scope: :string,
    remove: :boolean,
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
    template: :string,
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
    assignee: :string,
    no_assignee: :boolean,
    start: :string,
    no_start: :boolean,
    percent: :integer,
    no_percent: :boolean,
    color: :string,
    no_color: :boolean,
    top: :boolean,
    bottom: :boolean,
    index: :integer,
    off: :boolean,
    wip: :integer,
    kind: :keep,
    label: :string,
    options: :string,
    formula: :string,
    sum: :boolean,
    date: :string,
    spec: :string,
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

  ## Read ---------------------------------------------------------------------

  defp run("auth", [token], o) do
    System.put_env("SLIPDOCK_TOKEN", token)

    HTTP.get("/me")
    |> out(o, fn r ->
      path = HTTP.save_token(token)
      IO.puts("signed in as #{r["user"]["email"]}; token saved to #{path}")
    end)
  end

  # No token to paste: ask the server for a code, show it, and wait for a
  # person to approve it in a browser (RFC 8628). Nothing here needs access to
  # the machine the server runs on, which is the whole point.
  defp run("auth", [], o) do
    label = o[:label] || default_label()

    case HTTP.post("/auth/device", %{label: label, scope: o[:scope] || "write"}) do
      {:ok, started} ->
        IO.puts("")
        IO.puts("  Open  #{Render.bold(started["verification_uri"])}")
        IO.puts("  Enter #{Render.bold(started["user_code"])}")
        IO.puts("")
        IO.puts(Render.dim("  Signing in as \"#{label}\". Waiting — Ctrl-C to stop."))

        started
        |> await_device_approval(started["interval"] || 5)
        |> finish_device_auth(o)

      {:error, _, %{"error_description" => why}} ->
        fail(why)

      other ->
        out(other, o, fn _ -> :ok end)
    end
  end

  # The server's own instructions for agents; needs no token, but says more with one.
  defp run("guide", [], o), do: HTTP.get("/guide") |> out(o, &IO.puts(&1["guide"]))

  # Semantic search. Everything after the command is the query, so it needs no
  # quoting: `slipdock search what did we decide about refunds`.
  defp run("search", words, o) when words != [] do
    HTTP.get("/search",
      q: Enum.join(words, " "),
      board: o[:board],
      kind: o[:kind],
      limit: o[:limit],
      archived: if(o[:archived], do: "true")
    )
    |> out(o, &Render.search_results(&1, full: o[:full]))
  end

  defp run("ask", words, o) when words != [] do
    HTTP.post("/ask", %{q: Enum.join(words, " ")}) |> out(o, &Render.answer/1)
  end

  defp run("search-status", [], o),
    do: HTTP.get("/search/status") |> out(o, &Render.search_status/1)

  # Saved queries: the person's own, and only the question — never the answer.
  defp run("saved", [], o),
    do: HTTP.get("/saved-queries", mode: saved_mode(o, nil)) |> out(o, &Render.saved_queries/1)

  defp run("save", words, o) when words != [] do
    HTTP.post("/saved-queries", %{mode: saved_mode(o, "search"), q: Enum.join(words, " ")})
    |> out(o, &Render.saved_queries/1)
  end

  defp run("unsave", [], o) do
    case o[:id] do
      nil -> fail("unsave needs the query's words, or --id N (see `slipdock saved`)")
      id -> HTTP.delete("/saved-queries/#{HTTP.seg(id)}") |> out(o, &Render.saved_queries/1)
    end
  end

  defp run("unsave", words, o) do
    HTTP.delete("/saved-queries", mode: saved_mode(o, "search"), q: Enum.join(words, " "))
    |> out(o, &Render.saved_queries/1)
  end

  # Administering the server. Needs a token made with the `admin` scope — an
  # ordinary read/write token is deliberately not enough, because those are the
  # ones that end up in agents and CI.
  defp run("admin", ["settings"], o), do: HTTP.get("/admin/settings") |> out(o, &render_admin/1)

  defp run("admin", ["build"], o),
    do: HTTP.get("/admin/settings") |> out(o, &IO.puts(render_build(&1["build"])))

  defp run("admin", ["set" | pairs], o) when pairs != [] do
    body =
      Enum.reduce(pairs, %{}, fn pair, acc ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> Map.put(acc, key, admin_value(key, value))
          _ -> fail("settings are key=value, e.g. signup_mode=closed")
        end
      end)

    HTTP.patch("/admin/settings", body) |> out(o, &render_admin/1)
  end

  defp run("admin", ["allow", entry], o),
    do: HTTP.post("/admin/allowlist", %{entry: entry}) |> out(o, &render_admin/1)

  defp run("admin", ["disallow", entry], o),
    do: HTTP.delete("/admin/allowlist", entry: entry) |> out(o, &render_admin/1)

  defp run("admin", ["users"], o), do: HTTP.get("/admin/users") |> out(o, &render_admin_users/1)

  defp run("admin", ["promote", email], o), do: admin_user(email, %{admin: true}, o)
  defp run("admin", ["demote", email], o), do: admin_user(email, %{admin: false}, o)
  defp run("admin", ["disable", email], o), do: admin_user(email, %{disabled: true}, o)
  defp run("admin", ["enable", email], o), do: admin_user(email, %{disabled: false}, o)

  defp run("admin", ["limit", email, limit], o) do
    value = if limit in ["", "none", "-"], do: nil, else: limit
    admin_user(email, %{card_limit: value}, o)
  end

  defp run("admin", ["signups"], o),
    do: HTTP.get("/admin/signups") |> out(o, &render_admin_signups/1)

  defp run("admin", ["approve", email], o), do: admin_signup(email, "approve", o)
  defp run("admin", ["reject", email], o), do: admin_signup(email, "reject", o)

  defp run("admin", _args, _o) do
    fail("""
    admin settings                      what this server allows
    admin build                         the commit and build time now running
    admin set key=value...              signup_mode, free_card_limit, user_directory,
                                        invites_create_accounts, login_fallback_enabled
    admin allow <entry> | disallow <entry>
    admin users                         who is here
    admin promote|demote|disable|enable <email>
    admin limit <email> <n|none>        their own card limit
    admin signups                       who is waiting
    admin approve|reject <email>

    Needs a token made with the admin scope (Account → API tokens).
    Mail settings and the admin address are deliberately not here: both have to
    prove something first, and a PATCH would skip that.
    """)
  end

  defp run("whoami", [], o) do
    HTTP.get("/me")
    |> out(o, fn r ->
      IO.puts(
        "#{r["user"]["email"]}#{if r["user"]["name"], do: " (#{r["user"]["name"]})", else: ""}"
      )
    end)
  end

  # The OpenRouter key the server spends on your behalf. Shown masked; set by
  # passing it, or read from OPENROUTER_API_KEY when no argument is given.
  defp run("ai-key", args, o) do
    cond do
      o[:remove] ->
        HTTP.delete("/me/ai-key") |> out(o, &render_ai_key/1)

      args != [] ->
        HTTP.put("/me/ai-key", %{api_key: Enum.join(args, " ")}) |> out(o, &render_ai_key/1)

      key = System.get_env("OPENROUTER_API_KEY") ->
        HTTP.put("/me/ai-key", %{api_key: key}) |> out(o, &render_ai_key/1)

      true ->
        HTTP.get("/me") |> out(o, &render_ai_key/1)
    end
  end

  defp run("logout", [], _o) do
    HTTP.forget_token()
    IO.puts("token forgotten")
  end

  # `--archived` lists the archived boards alone, `--all` lists them alongside
  # the rest; without either, archived boards are left out.
  defp run("boards", [], o) do
    archived =
      cond do
        o[:all] -> "all"
        o[:archived] -> "true"
        true -> nil
      end

    HTTP.get("/boards", archived: archived, sort: o[:sort])
    |> out(o, &Render.boards(&1["boards"]))
  end

  defp run("board", [ref], o),
    do: HTTP.get("/boards/#{HTTP.seg(ref)}") |> out(o, &Render.board(&1["board"]))

  defp run("columns", [ref], o),
    do: HTTP.get("/boards/#{HTTP.seg(ref)}/columns") |> out(o, &Render.columns(&1["columns"]))

  defp run("tags", [ref], o),
    do: HTTP.get("/boards/#{HTTP.seg(ref)}/tags") |> out(o, &Render.tags(&1["tags"]))

  defp run("activity", [ref], o) do
    HTTP.get("/boards/#{HTTP.seg(ref)}/activity", limit: o[:limit])
    |> out(o, &Render.activity(&1["activity"]))
  end

  defp run("cards", [ref], o) do
    completed =
      cond do
        o[:done] -> "true"
        o[:open] -> "false"
        true -> nil
      end

    HTTP.get("/boards/#{HTTP.seg(ref)}/cards",
      column: o[:column],
      tag: List.first(Keyword.get_values(o, :tag)),
      priority: o[:priority],
      flag: List.first(Keyword.get_values(o, :flag)),
      q: o[:search],
      due: o[:due],
      deps: o[:deps],
      kind: List.first(kind_values(o)),
      assignee: if(o[:no_assignee], do: "none", else: o[:assignee]),
      completed: completed,
      archived: o[:archived]
    )
    |> out(o, &Render.cards(&1["cards"]))
  end

  defp run("card", [id], o), do: HTTP.get("/cards/#{id}") |> out(o, &Render.card(&1["card"]))

  defp run("swimlanes", [ref], o) do
    HTTP.get("/boards/#{HTTP.seg(ref)}/swimlanes", view_query(o))
    |> out(o, &Render.swimlanes/1)
  end

  defp run("views", [ref], o),
    do: HTTP.get("/boards/#{HTTP.seg(ref)}/views") |> out(o, &Render.views(&1["views"]))

  ## Favourites ---------------------------------------------------------------
  #
  # A favourite is the token holder's own: there is no way to read or set
  # anyone else's, and favouriting something changes nothing about it.

  defp run("favourites", [], o),
    do: HTTP.get("/favourites") |> out(o, &Render.favourites(&1["favourites"]))

  defp run("fav", args, o), do: favourite(args, o, if(o[:off], do: :off, else: :on))
  defp run("unfav", args, o), do: favourite(args, o, :off)

  defp run("table", [ref], o) do
    query = view_query(o) |> Keyword.put(:cols, "none")

    query =
      if o[:group],
        do: Keyword.put(query, :rows, o[:group]),
        else: Keyword.put_new(query, :rows, "none")

    fields = if o[:fields], do: String.split(o[:fields], ",", trim: true), else: nil

    HTTP.get("/boards/#{HTTP.seg(ref)}/swimlanes", query)
    |> out(o, &Render.card_table(&1, fields))
  end

  defp run("fields", [ref], o),
    do: HTTP.get("/boards/#{enc(ref)}/fields") |> out(o, &Render.fields(&1["fields"]))

  defp run("milestones", [ref], o),
    do: HTTP.get("/boards/#{enc(ref)}/milestones") |> out(o, &Render.milestones(&1["milestones"]))

  defp run("templates", [], o),
    do: HTTP.get("/templates") |> out(o, &Render.templates(&1["templates"]))

  ## Automations and alerts ---------------------------------------------------

  defp run("automations", [ref], o) do
    HTTP.get("/boards/#{enc(ref)}/automations")
    |> out(o, &Render.automations(&1["automations"]))
  end

  defp run("automation", [ref, rule], o) do
    HTTP.get("/boards/#{enc(ref)}/automations/#{enc(rule)}")
    |> out(o, &Render.automation(&1["automation"]))
  end

  # The grammar a --spec has to be written in, straight from the server.
  defp run("automation-help", [], o),
    do: HTTP.get("/automations/vocabulary") |> out(o, &Render.vocabulary/1)

  defp run("alerts", [], o), do: HTTP.get("/alerts") |> out(o, &Render.alerts(&1["alerts"]))

  defp run("dismiss", ids, o) do
    cond do
      o[:all] ->
        HTTP.delete("/alerts")
        |> out(o, fn r -> IO.puts("dismissed #{r["dismissed"]} alert(s)") end)

      ids == [] ->
        fail("pass alert ids (see `slipdock alerts`) or --all")

      true ->
        Enum.each(ids, fn id ->
          HTTP.delete("/alerts/#{id}") |> out(o, fn _ -> IO.puts("dismissed alert ##{id}") end)
        end)
    end
  end

  defp run("new-automation", [ref | words], o) do
    body =
      cond do
        o[:spec] ->
          compact(%{
            "spec" => spec_json(o[:spec]),
            "name" => o[:name] || nonblank(Enum.join(words, " ")),
            "scope" => scope_of(o[:tree]),
            "text" => nonblank(Enum.join(words, " "))
          })

        words != [] ->
          %{"text" => Enum.join(words, " ")}

        true ->
          fail("describe the rule in words, or pass --spec (see `slipdock automation-help`)")
      end

    HTTP.post("/boards/#{enc(ref)}/automations", body)
    |> out(o, fn r ->
      a = r["automation"]
      IO.puts("added automation ##{a["id"]}: #{a["name"]}")
      IO.puts(Render.dim(a["summary"]))
    end)
  end

  defp run("set-automation", [ref, rule], o) do
    body =
      compact(%{
        "enabled" => cond_bool(o[:on], o[:off]),
        "name" => o[:name],
        "spec" => o[:spec] && spec_json(o[:spec]),
        "text" => o[:text],
        "scope" => scope_of(o[:tree])
      })

    if body == %{}, do: fail("nothing to change — pass --on, --off, --name, --spec or --text")

    HTTP.patch("/boards/#{enc(ref)}/automations/#{enc(rule)}", body)
    |> out(o, fn r ->
      a = r["automation"]
      IO.puts("##{a["id"]} #{a["name"]} is #{if a["enabled"], do: "on", else: "off"}")
      IO.puts(Render.dim(a["summary"]))
    end)
  end

  defp run("run-automation", [ref, rule], o) do
    HTTP.post("/boards/#{enc(ref)}/automations/#{enc(rule)}/run", %{})
    |> out(o, fn r ->
      a = r["automation"]

      IO.puts(
        case r["fired"] do
          0 -> "nothing matched “#{a["name"]}” right now"
          1 -> "“#{a["name"]}” ran once"
          n -> "“#{a["name"]}” ran #{n} times"
        end
      )

      if a["last_error"], do: IO.puts(Render.dim("last error: " <> a["last_error"]))
    end)
  end

  defp run("delete-automation", [ref, rule], o) do
    HTTP.delete("/boards/#{enc(ref)}/automations/#{enc(rule)}")
    |> out(o, fn _ -> IO.puts("deleted automation #{rule}") end)
  end

  ## Wiki --------------------------------------------------------------------
  #
  # `<page>` is whatever handle you have: the code (W-31), the slug, or
  # board-code/slug. Reads print Markdown, because that is what an agent
  # edits and what a diff is taken of.

  # Filing. A folder is named by id, slug, name, or a path of names
  # ("Design/Decisions"), which is what a person would say out loud.

  defp run("folder", ["ls", ref], o) do
    HTTP.get("/boards/#{enc(ref)}/folders", archived: archived_param(o))
    |> out(o, &Render.folders(&1["folders"], &1["pages"]))
  end

  defp run("folder", ["new", ref | name_words], o) when name_words != [] do
    body = compact(%{"name" => Enum.join(name_words, " "), "parent" => o[:parent]})

    HTTP.post("/boards/#{enc(ref)}/folders", body) |> out(o, &Render.folder(&1["folder"]))
  end

  defp run("folder", ["mv", ref, folder], o) do
    if is_nil(o[:parent]) and o[:root] != true and is_nil(o[:name]),
      do: fail("say what to change: --parent P, --root, or --name N")

    body =
      compact(%{
        "name" => o[:name],
        "parent" => if(o[:root], do: "root", else: o[:parent]),
        "position" => o[:position]
      })

    HTTP.patch("/boards/#{enc(ref)}/folders/#{path_enc(folder)}", body)
    |> out(o, &Render.folder(&1["folder"]))
  end

  defp run("folder", ["rm", ref, folder], o) do
    query = if o[:purge], do: [purge: "true"], else: []

    HTTP.delete("/boards/#{enc(ref)}/folders/#{path_enc(folder)}", query)
    |> out(o, fn
      %{"purged" => purged} = r ->
        IO.puts(
          "deleted the folder #{r["deleted"]["path"]} and everything in it " <>
            "— #{purged["pages"]} page(s), #{purged["folders"]} subfolder(s)"
        )

      r ->
        IO.puts("deleted the folder #{r["deleted"]["path"]} — nothing in it was deleted")
    end)
  end

  defp run("folder", _args, _o),
    do:
      fail(
        "usage: slipdock folder ls BOARD | new BOARD NAME [--parent F] | mv BOARD F --parent G|--root|--name N | rm BOARD F [--purge]"
      )

  # Every board's wiki at once: what the Wiki view on the web shows.
  defp run("wiki", [], o),
    do: HTTP.get("/wiki") |> out(o, &Render.wiki(&1["boards"]))

  defp run("wiki", _args, _o), do: fail("usage: slipdock wiki")

  defp run("page", ["ls", ref], o) do
    HTTP.get("/boards/#{enc(ref)}/pages",
      q: o[:q] || o[:search],
      archived: archived_param(o),
      template: if(o[:template], do: "true"),
      status: if(o[:draft], do: "draft"),
      parent: if(o[:root], do: "root", else: o[:parent]),
      folder: if(o[:no_folder], do: "none", else: o[:folder])
    )
    |> out(o, &Render.pages(&1["pages"]))
  end

  defp run("page", ["tree", ref], o) do
    HTTP.get("/boards/#{enc(ref)}/pages", tree: "true", archived: archived_param(o))
    |> out(o, &Render.page_tree(&1["pages"]))
  end

  defp run("page", ["read", ref], o),
    do: HTTP.get("/pages/#{enc(ref)}") |> out(o, &Render.page(&1["page"]))

  # `read` is the source you would edit; `render` is what it says once every
  # reference has been followed. Answering a question wants the second.
  defp run("page", ["render", ref], o) do
    HTTP.get("/pages/#{enc(ref)}/render", format: o[:format])
    |> out(o, fn r -> IO.puts(r["body"] || "") end)
  end

  defp run("page", ["sections", ref], o) do
    HTTP.get("/pages/#{enc(ref)}/sections")
    |> out(o, &Render.sections(&1["sections"]))
  end

  defp run("page", ["section", ref | path_words], o) when path_words != [] do
    path = path_words |> Enum.join(" ") |> section_path()

    cond do
      # Appending is the write that cannot conflict, so it is its own flag
      # rather than a mode of the replacing one.
      o[:append] ->
        HTTP.post(
          "/pages/#{enc(ref)}/section/#{path}",
          compact(%{
            "body" => o[:append],
            "message" => o[:message]
          })
        )
        |> out(o, &page_ok("appended to #{Enum.join(path_words, " ")} of", &1))

      body = page_body(o) ->
        HTTP.put(
          "/pages/#{enc(ref)}/section/#{path}",
          compact(%{
            "body" => body,
            "message" => o[:message],
            "base_hash" => o[:base_hash]
          })
        )
        |> out(o, &page_ok("replaced #{Enum.join(path_words, " ")} of", &1))

      true ->
        HTTP.get("/pages/#{enc(ref)}/section/#{path}")
        |> out(o, fn r -> IO.puts(r["body"] || "") end)
    end
  end

  defp run("page", ["append", ref], o) do
    case page_body(o) do
      nil ->
        fail("what should be added? pass --body TEXT, --file F, or --body - for stdin")

      body ->
        HTTP.post(
          "/pages/#{enc(ref)}/append",
          compact(%{
            "body" => body,
            "message" => o[:message]
          })
        )
        |> out(o, &page_ok("appended to", &1))
    end
  end

  defp run("page", ["links", ref], o),
    do: HTTP.get("/pages/#{enc(ref)}/links") |> out(o, &Render.page_links/1)

  defp run("page", ["pin", ref], o) do
    target =
      cond do
        o[:card] -> %{"card" => o[:card]}
        o[:page] -> %{"page" => o[:page]}
        true -> fail("pin it to what? --card N or --page P")
      end

    HTTP.post("/pages/#{enc(ref)}/links", Map.put(target, "pinned", o[:off] != true))
    |> out(o, fn r ->
      IO.puts("#{if r["pinned"], do: "pinned", else: "unpinned"} #{r["page"]["code"]}")
    end)
  end

  # A live query block is answered when the page is *read*, with the reader's
  # own permissions. These two are how to get one right before writing it.
  # A page can sit in one of its board's lists and be dragged about like a
  # card. It stays where it is in the wiki either way.
  defp run("page", ["place", ref | column_words], o) when column_words != [] do
    HTTP.post(
      "/pages/#{enc(ref)}/place",
      compact(%{"column" => Enum.join(column_words, " "), "before" => o[:before]})
    )
    |> out(o, fn r ->
      IO.puts("put #{r["page"]["code"]} #{r["page"]["title"]} in #{r["column"]["name"]}")
    end)
  end

  defp run("page", ["unplace", ref], o) do
    HTTP.delete("/pages/#{enc(ref)}/place")
    |> out(o, fn r ->
      IO.puts("took #{r["page"]["code"]} #{r["page"]["title"]} off the board")
    end)
  end

  defp run("page", ["publish", ref], o) do
    HTTP.post("/pages/#{enc(ref)}/publish", %{"published" => o[:off] != true})
    |> out(o, fn r ->
      if r["published"] do
        IO.puts("published #{r["page"]["code"]} at #{HTTP.base_url()}#{r["url"]}")
        IO.puts(Render.dim(r["note"]))
      else
        IO.puts("withdrew the link for #{r["page"]["code"]}")
      end
    end)
  end

  # Whole board trees out as one JSON document and back in again. The wiki's
  # own `page export`/`page import` below is the Markdown route and stays:
  # this one is for moving a board, that one is for reading your writing
  # somewhere else.
  defp run("export", refs, o) do
    params =
      [archived: if(o[:archived] || o[:all], do: "all")] ++
        if refs == [], do: [], else: [boards: Enum.join(refs, ",")]

    HTTP.get("/export", params)
    |> out(o, fn r ->
      json = Render.json_string(r["export"])

      case o[:out] do
        nil ->
          IO.puts(json)

        path ->
          File.write!(path, json)
          trees = length(r["export"]["boards"] || [])
          IO.puts("wrote #{trees} board tree(s) to #{path}")
          Enum.each(r["leaving_behind"] || [], &IO.puts(Render.dim("  " <> &1)))
      end
    end)
  end

  defp run("import", [path], o) do
    unless File.regular?(path), do: fail("#{path} is not a file")

    HTTP.post("/import", read_document(path))
    |> out(o, fn r ->
      report = r["imported"]
      IO.puts("imported #{report["cards"]} card(s) and #{report["pages"]} page(s)")

      Enum.each(report["boards"] || [], fn b ->
        IO.puts("  #{b["code"]}  #{b["name"]}")
      end)

      # What could not come through. Said rather than swallowed: an import
      # that half-worked in silence is the worst of the outcomes.
      Enum.each(report["skipped"] || [], &IO.puts(Render.dim("  " <> &1)))
    end)
  end

  defp run("import", _args, _o), do: fail("import <file.json>")

  # Out and back in: a wiki you cannot get your writing out of is one to think
  # twice about putting writing into.
  defp run("page", ["export", ref], o) do
    dir = o[:dir] || fail("where should the files go? pass --dir D")

    HTTP.get("/boards/#{enc(ref)}/pages/export", archived: archived_param(o))
    |> out(o, fn r ->
      Enum.each(r["files"], fn %{"path" => path, "body" => body} ->
        full = Path.join(dir, path)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, body)
      end)

      IO.puts("wrote #{length(r["files"])} file(s) into #{dir}")
    end)
  end

  defp run("page", ["import", ref], o) do
    dir = o[:dir] || fail("where are the files? pass --dir D")
    unless File.dir?(dir), do: fail("#{dir} is not a folder")

    files =
      dir
      |> markdown_files()
      |> Enum.map(fn path ->
        %{"path" => Path.relative_to(path, dir), "body" => File.read!(path)}
      end)

    if files == [], do: fail("no .md files under #{dir}")

    HTTP.post("/boards/#{enc(ref)}/pages/import", %{
      "files" => files,
      "overwrite" => o[:overwrite] == true,
      "message" => o[:message] || "imported from #{Path.basename(dir)}"
    })
    |> out(o, fn r ->
      IO.puts("created #{length(r["created"])} page(s)")
      Enum.each(r["created"], fn p -> IO.puts("  #{p["code"]}  #{p["title"]}") end)

      if r["skipped"] != [] do
        IO.puts(Render.dim("skipped #{length(r["skipped"])}:"))

        Enum.each(r["skipped"], fn s -> IO.puts(Render.dim("  #{s["path"]} — #{s["reason"]}")) end)
      end
    end)
  end

  defp run("page", ["query-help"], o),
    do: HTTP.get("/pages/query-vocabulary") |> out(o, &Render.query_help/1)

  defp run("page", ["query", ref], o) do
    case page_body(o) do
      nil ->
        fail("what should the block say? pass --body TEXT, --file F, or --body - for stdin")

      body ->
        HTTP.post("/pages/query", %{"board" => ref, "body" => body})
        |> out(o, &Render.query_answer/1)
    end
  end

  defp run("page", ["card", id], o),
    do: HTTP.get("/cards/#{enc(id)}/pages") |> out(o, &Render.card_pages(&1["pages"]))

  defp run("page", ["from", ref, template], o) do
    HTTP.post(
      "/boards/#{enc(ref)}/pages/from-template",
      compact(%{
        "template" => template,
        "title" => o[:title],
        "card" => o[:card],
        "folder" => o[:folder],
        "values" => values_of(o),
        "message" => o[:message]
      })
    )
    |> out(o, &page_ok("wrote", &1))
  end

  defp run("page", ["make-card", ref], o) do
    case page_body(o) do
      nil ->
        fail("what should the card say? pass --body TEXT, --file F, or --body - for stdin")

      body ->
        HTTP.post("/pages/#{enc(ref)}/cards", compact(%{"body" => body, "column" => o[:column]}))
        |> out(o, &card_ok("created", &1))
    end
  end

  # "Write it up": a page for a card, pinned to it. A top-level command
  # because it is a thing people ask for by name, not a mode of `page new`.
  defp run("writeup", [id], o) do
    HTTP.post(
      "/cards/#{enc(id)}/pages",
      compact(%{
        "title" => o[:title],
        "template" => o[:template],
        "folder" => o[:folder],
        "summary" => o[:summary],
        "message" => o[:message]
      })
    )
    |> out(o, &page_ok("started", &1))
  end

  defp run("page", ["wanted", ref], o),
    do: HTTP.get("/boards/#{enc(ref)}/pages/wanted") |> out(o, &Render.wanted(&1["wanted"]))

  defp run("page", ["resolve", ref | words], o) when words != [] do
    HTTP.get("/pages/resolve", board: ref, title: Enum.join(words, " "))
    |> out(o, &Render.resolved/1)
  end

  defp run("page", ["new", ref | title_words], o) when title_words != [] do
    body =
      compact(%{
        "title" => Enum.join(title_words, " "),
        "body" => page_body(o),
        "summary" => o[:summary],
        "parent" => o[:parent],
        "folder" => o[:folder],
        "status" => if(o[:draft], do: "draft"),
        "template" => o[:template] && true,
        "message" => o[:message]
      })

    HTTP.post("/boards/#{enc(ref)}/pages", body) |> out(o, &page_ok("wrote", &1))
  end

  defp run("page", ["edit", ref], o) do
    flags = Keyword.get_values(o, :flag)

    body =
      compact(%{
        "title" => o[:title],
        "summary" => o[:summary],
        "body" => page_body(o),
        "status" =>
          cond do
            o[:draft] -> "draft"
            o[:publish] -> "published"
            true -> nil
          end,
        # The card facets. A page carries them so a doc on the board can be
        # grouped, filtered and sorted beside the work.
        "priority" => o[:priority],
        "folder" => if(o[:no_folder], do: "", else: o[:folder]),
        "add_flags" => if(flags != [] and o[:off] != true, do: flags),
        "remove_flags" => if(flags != [] and o[:off] == true, do: flags),
        "start_date" => if(o[:no_start], do: nil, else: o[:start]),
        "due_date" => if(o[:no_due], do: nil, else: o[:due]),
        "percent_complete" => if(o[:no_percent], do: nil, else: o[:percent]),
        "color" => if(o[:no_color], do: nil, else: o[:color]),
        "assignee" => if(o[:no_assignee], do: "", else: o[:assignee]),
        "completed" => cond_bool(o[:done], o[:undone]),
        "message" => o[:message],
        "base_hash" => o[:base_hash]
      })
      |> then(fn b -> if o[:no_start], do: Map.put(b, "start_date", nil), else: b end)
      |> then(fn b -> if o[:no_due], do: Map.put(b, "due_date", nil), else: b end)
      |> then(fn b -> if o[:no_percent], do: Map.put(b, "percent_complete", nil), else: b end)
      |> then(fn b -> if o[:no_color], do: Map.put(b, "color", nil), else: b end)

    if Map.drop(body, ["message", "base_hash"]) == %{},
      do: fail("nothing to change — pass --title, --body/--file, a facet, --draft or --publish")

    HTTP.patch("/pages/#{enc(ref)}", body) |> out(o, &page_ok("saved", &1))
  end

  # Filing a page that already exists. Separate from `mv`, which moves it in
  # the page tree: where a page is kept and what it is part of are two axes.
  defp run("page", ["file", ref], o) do
    if is_nil(o[:folder]) and o[:no_folder] != true and o[:root] != true,
      do: fail("say where: --folder PATH, or --no-folder to take it out of one")

    body = %{"folder" => if(o[:no_folder] || o[:root], do: nil, else: o[:folder])}

    HTTP.post("/pages/#{enc(ref)}/folder", body) |> out(o, &page_ok("filed", &1))
  end

  defp run("page", ["mv", ref], o) do
    if is_nil(o[:parent]) and o[:root] != true and is_nil(o[:position]),
      do: fail("say where: --parent P, --root, or --position N|top|bottom")

    body =
      compact(%{
        "parent" => if(o[:root], do: "root", else: o[:parent]),
        "position" => o[:position]
      })

    HTTP.post("/pages/#{enc(ref)}/move", body) |> out(o, &page_ok("moved", &1))
  end

  defp run("page", ["rm", ref], o) do
    query = if o[:purge], do: [purge: "true"], else: []

    HTTP.delete("/pages/#{enc(ref)}", query)
    |> out(o, fn
      %{"deleted" => true} = r -> IO.puts("deleted #{r["code"]}")
      r -> page_ok("archived", r)
    end)
  end

  defp run("page", ["restore", ref], o),
    do: HTTP.post("/pages/#{enc(ref)}/restore", %{}) |> out(o, &page_ok("restored", &1))

  defp run("page", ["history", ref], o) do
    HTTP.get("/pages/#{enc(ref)}/revisions", limit: o[:limit])
    |> out(o, &Render.revisions(&1["revisions"]))
  end

  defp run("page", ["diff", ref], o) do
    rev = o[:rev] || latest_revision(ref)

    HTTP.get("/pages/#{enc(ref)}/revisions/#{enc(rev)}", diff: "previous")
    |> out(o, &Render.diff(&1["diff"] || []))
  end

  defp run("page", ["revert", ref], o) do
    rev = o[:rev] || fail("which version? pass --rev N (see `slipdock page history`)")

    HTTP.post(
      "/pages/#{enc(ref)}/revert",
      compact(%{
        "revision_id" => rev,
        "message" => o[:message]
      })
    )
    |> out(o, &page_ok("reverted", &1))
  end

  ## Skills ------------------------------------------------------------------
  #
  # The server ships the instructions for using it, versioned with the code
  # they describe. A skill file that hardcodes board names rots; one that is
  # fetched from the server that answers the calls does not.

  defp run("skills", [], o), do: HTTP.get("/skills") |> out(o, &Render.skills(&1["skills"]))

  defp run("skills", ["install"], o) do
    dir = skills_dir(o)

    {:ok, %{"skills" => skills}} = HTTP.get("/skills")

    written =
      Enum.flat_map(skills, fn skill ->
        Enum.map(skill["files"], fn file ->
          {:ok, %{"content" => content}} =
            HTTP.get("/skills/#{HTTP.seg(skill["name"])}/#{file}")

          path = Path.join([dir, skill["name"], file])
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, content)
          path
        end)
      end)

    if o[:json] do
      Render.json(%{"installed" => written, "dir" => dir})
    else
      IO.puts("installed #{length(skills)} skill(s), #{length(written)} file(s), into #{dir}")
      Enum.each(skills, fn s -> IO.puts("  " <> s["name"] <> "  " <> Render.dim(s["sha"])) end)
    end
  end

  defp run("skills", ["check"], o) do
    dir = skills_dir(o)
    {:ok, %{"skills" => skills}} = HTTP.get("/skills")

    rows =
      Enum.map(skills, fn skill ->
        local = Path.join([dir, skill["name"], "SKILL.md"])

        state =
          cond do
            not File.exists?(local) -> "not installed"
            skill_current?(dir, skill) -> "current"
            true -> "behind — run `slipdock skills install`"
          end

        [skill["name"], skill["sha"], state]
      end)

    if o[:json],
      do: Render.json(%{"skills" => skills, "dir" => dir}),
      else: Render.table(["SKILL", "SERVER", "LOCAL COPY"], rows)
  end

  defp run("skills", _args, _o),
    do: fail("usage: slipdock skills | skills install [--dir D] | skills check")

  defp run("page", _args, _o),
    do:
      fail(
        "usage: slipdock page ls|tree|read|new|edit|file|mv|rm|restore|history|diff|revert (see --help)"
      )

  ## Write --------------------------------------------------------------------

  defp run("add", [ref | title_words], o) when title_words != [] do
    body =
      %{
        "title" => Enum.join(title_words, " "),
        "column" => o[:column],
        "description" => o[:desc],
        "priority" => o[:priority],
        "flags" => nonempty(Keyword.get_values(o, :flag)),
        "tags" => nonempty(Keyword.get_values(o, :tag)),
        "start_date" => o[:start],
        "due_date" => o[:due],
        "percent_complete" => o[:percent],
        "color" => o[:color],
        "assignee" => o[:assignee]
      }
      |> compact()

    HTTP.post("/boards/#{HTTP.seg(ref)}/cards", body) |> out(o, &card_ok("created", &1))
  end

  defp run("edit", [id], o) do
    body =
      %{
        "title" => o[:title],
        "description" => o[:desc],
        "priority" => o[:priority],
        "start_date" => if(o[:no_start], do: nil, else: o[:start]),
        "due_date" => if(o[:no_due], do: nil, else: o[:due]),
        "percent_complete" => if(o[:no_percent], do: nil, else: o[:percent]),
        "color" => if(o[:no_color], do: nil, else: o[:color]),
        "column" => o[:column],
        "assignee" => if(o[:no_assignee], do: nil, else: o[:assignee])
      }
      |> compact()
      |> then(fn b -> if o[:no_start], do: Map.put(b, "start_date", nil), else: b end)
      |> then(fn b -> if o[:no_due], do: Map.put(b, "due_date", nil), else: b end)
      |> then(fn b -> if o[:no_percent], do: Map.put(b, "percent_complete", nil), else: b end)
      |> then(fn b -> if o[:no_color], do: Map.put(b, "color", nil), else: b end)
      |> then(fn b -> if o[:no_assignee], do: Map.put(b, "assignee", ""), else: b end)

    if body == %{}, do: fail("nothing to change — pass at least one option (see --help)")
    HTTP.patch("/cards/#{id}", body) |> out(o, &card_ok("updated", &1))
  end

  defp run("set", [id | pairs], o) when pairs != [] do
    fields =
      Map.new(pairs, fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {String.trim(key), value}
          _ -> fail("expected key=value, got #{pair}")
        end
      end)

    HTTP.patch("/cards/#{id}", %{"fields" => fields}) |> out(o, &card_ok("updated", &1))
  end

  defp run("vote", [id, n], o) do
    HTTP.post(item_path(id, "/vote"), %{"count" => n})
    |> out(o, fn r ->
      subject = r["card"] || r["page"]

      name =
        (r["card"] && Render.card_line(subject, true)) || "#{subject["code"]} #{subject["title"]}"

      IO.puts("you have #{r["my_votes"]} on " <> name)
    end)
  end

  defp run("status", [id, health | words], o) do
    HTTP.post(item_path(id, "/status"), %{"health" => health, "body" => Enum.join(words, " ")})
    |> out(o, &card_ok("reported #{health} on", &1))
  end

  defp run("new-field", [ref | words], o) when words != [] do
    options =
      (o[:options] || "")
      |> String.split(",", trim: true)
      |> Enum.map(fn item ->
        case String.split(item, "=", parts: 2) do
          [label, weight] -> %{"label" => String.trim(label), "weight" => String.trim(weight)}
          [label] -> %{"label" => String.trim(label)}
        end
      end)

    body =
      %{
        "name" => Enum.join(words, " "),
        "kind" => o[:kind] || "number",
        "sum" => o[:sum] || false,
        "options" => options,
        "config" =>
          if(o[:formula], do: %{"mode" => "expression", "expression" => o[:formula]}, else: %{})
      }

    HTTP.post("/boards/#{enc(ref)}/fields", body)
    |> out(o, fn r -> IO.puts("added field " <> Render.field_line(r["field"])) end)
  end

  defp run("delete-field", [ref, field], o) do
    HTTP.delete("/boards/#{enc(ref)}/fields/#{enc(field)}")
    |> out(o, fn _ -> IO.puts("deleted") end)
  end

  defp run("preset", [ref, key], o) do
    HTTP.post("/boards/#{enc(ref)}/presets/#{key}", %{})
    |> out(o, fn r -> Render.fields(r["fields"]) end)
  end

  defp run("milestone", [ref | words], o) when words != [] do
    unless o[:date], do: fail("--date YYYY-MM-DD is required")

    HTTP.post("/boards/#{enc(ref)}/milestones", %{
      "name" => Enum.join(words, " "),
      "date" => o[:date],
      "color" => o[:color]
    })
    |> out(o, fn r ->
      IO.puts("added milestone #{r["milestone"]["name"]} on #{r["milestone"]["date"]}")
    end)
  end

  defp run("delete-milestone", [ref, id], o) do
    HTTP.delete("/boards/#{enc(ref)}/milestones/#{id}") |> out(o, fn _ -> IO.puts("deleted") end)
  end

  defp run("move", [id | column_words], o) when column_words != [] do
    column = Enum.join(column_words, " ")

    if o[:board] do
      # Another board entirely: the card goes with its subcards, its tags
      # travel by name, and custom fields survive only where the other board
      # has the same one. `index` means nothing in a list it has never been in.
      HTTP.post("/cards/#{id}/move", %{"board" => o[:board], "column" => column})
      |> out(o, fn r ->
        card_ok("moved", r)
        note_losses(r["moved"])
      end)
    else
      index =
        cond do
          o[:top] -> "top"
          o[:index] -> o[:index]
          true -> "bottom"
        end

      HTTP.post("/cards/#{id}/move", %{"column" => column, "index" => index})
      |> out(o, &card_ok("moved", &1))
    end
  end

  defp run("done", ids, o) when ids != [],
    do: each(ids, o, &HTTP.patch("/cards/#{&1}", %{"completed" => true}), "completed")

  defp run("undone", ids, o) when ids != [],
    do: each(ids, o, &HTTP.patch("/cards/#{&1}", %{"completed" => false}), "reopened")

  defp run("flag", [id | flags], o) when flags != [] do
    key = if o[:off], do: "remove_flags", else: "add_flags"
    HTTP.patch("/cards/#{id}", %{key => flags}) |> out(o, &card_ok("updated", &1))
  end

  defp run("tag", [id | tags], o) when tags != [] do
    key = if o[:off], do: "remove_tags", else: "add_tags"
    HTTP.patch("/cards/#{id}", %{key => tags}) |> out(o, &card_ok("updated", &1))
  end

  defp run("check", [id | words], o) when words != [] do
    HTTP.post(item_path(id, "/checklist"), %{"text" => Enum.join(words, " ")})
    |> out(o, fn r ->
      IO.puts("added checklist item ##{r["item"]["id"]}: #{r["item"]["text"]}")
    end)
  end

  defp run("tick", [item_id], o) do
    HTTP.post("/checklist/#{item_id}/toggle")
    |> out(o, fn r ->
      IO.puts(
        "item ##{r["item"]["id"]} is now #{if r["item"]["done"], do: "done", else: "not done"}: #{r["item"]["text"]}"
      )
    end)
  end

  defp run("comment", [id | words], o) when words != [] do
    HTTP.post(item_path(id, "/comments"), %{"body" => Enum.join(words, " ")})
    |> out(o, fn r -> IO.puts("added comment ##{r["comment"]["id"]} to #{item_name(id)}") end)
  end

  defp run("link", [id, kind | others], o) when others != [] do
    each(others, o, &HTTP.post("/cards/#{id}/links", %{"to" => &1, "kind" => kind}), "linked")
  end

  defp run("unlink", [id | link_ids], o) when link_ids != [] do
    each(link_ids, o, &HTTP.delete("/cards/#{id}/links/#{&1}"), "unlinked")
  end

  defp run("weblink", [id, url], o) do
    HTTP.post(item_path(id, "/urls"), compact(%{"url" => url, "title" => o[:label]}))
    |> out(o, fn r ->
      IO.puts("linked #{item_name(id)} to #{r["url"]["url"]} [url ##{r["url"]["id"]}]")
    end)
  end

  defp run("unweblink", [id | url_ids], o) when url_ids != [] do
    each(url_ids, o, &HTTP.delete(item_path(id, "/urls/#{&1}")), "unlinked")
  end

  defp run("blocked-by", [id | others], o) when others != [],
    do: dependencies(id, others, "blocked_by", o)

  defp run("blocks", [id | others], o) when others != [],
    do: dependencies(id, others, "blocks", o)

  defp run("archive", ids, o) when ids != [],
    do: each(ids, o, &HTTP.post("/cards/#{&1}/archive"), "archived")

  defp run("restore", ids, o) when ids != [],
    do: each(ids, o, &HTTP.post("/cards/#{&1}/restore"), "restored")

  defp run("delete", ids, o) when ids != [] do
    Enum.each(ids, fn id ->
      HTTP.delete("/cards/#{id}") |> out(o, fn _ -> IO.puts("deleted card ##{id}") end)
    end)
  end

  defp run("subboard", [id], o) do
    cond do
      o[:off] ->
        HTTP.delete("/cards/#{id}/subboard")
        |> out(o, fn _ -> IO.puts("removed subcards of card ##{id}") end)

      o[:template] ->
        HTTP.post("/cards/#{id}/subboard", %{"template" => o[:template]})
        |> out(o, fn r ->
          b = r["board"]

          IO.puts(
            "card ##{id} now has sub-board ##{b["id"]} (#{Enum.map_join(b["columns"], " · ", & &1["name"])})"
          )

          IO.puts(Render.dim("open it with: slipdock board #{b["id"]}"))
        end)

      true ->
        fail(
          "pass --template <name|id> to add subcards (see `slipdock templates`) or --off to remove them"
        )
    end
  end

  defp run("new-template", words, o) when words != [] do
    lists = Keyword.get_values(o, :list)
    if lists == [], do: fail("pass at least one --list \"Name[:wip[:color]]\"")

    columns =
      Enum.map(lists, fn spec ->
        case String.split(spec, ":") do
          [name] -> %{"name" => name}
          [name, wip] -> %{"name" => name, "wip_limit" => wip}
          [name, wip, color | _] -> %{"name" => name, "wip_limit" => wip, "color" => color}
        end
      end)

    body =
      compact(%{"name" => Enum.join(words, " "), "description" => o[:desc], "columns" => columns})

    HTTP.post("/templates", body)
    |> out(o, fn r ->
      IO.puts("created template ##{r["template"]["id"]}: #{r["template"]["name"]}")
    end)
  end

  defp run("delete-template", [ref], o) do
    HTTP.delete("/templates/#{HTTP.seg(ref)}")
    |> out(o, fn _ -> IO.puts("deleted template #{ref}") end)
  end

  defp run("new-board", words, o) when words != [] do
    body =
      compact(%{
        "name" => Enum.join(words, " "),
        "code" => o[:code],
        "shortcut" => o[:shortcut],
        "description" => o[:desc],
        "color" => o[:color],
        "template" => o[:template]
      })

    HTTP.post("/boards", body)
    |> out(o, fn r -> IO.puts("created board ##{r["board"]["id"]}: #{r["board"]["name"]}") end)
  end

  # The tour board a first sign-in builds by itself. Here for an account that
  # archived it, or one made before the tour existed.
  defp run("welcome", [], o) do
    HTTP.post("/boards/welcome", compact(%{"force" => o[:force]}))
    |> out(o, fn r ->
      board = r["board"]

      IO.puts(
        "built “#{board["name"]}” (#{board["code"]}) — open it and work down the To Do list"
      )
    end)
  end

  defp run("set-board", [ref], o) do
    body =
      compact(%{
        "name" => o[:name],
        "code" => o[:code],
        "shortcut" => o[:shortcut],
        "description" => o[:desc],
        "color" => o[:color],
        # What the foot of every list offers: --add-page / --no-add-page.
        "add_card" => o[:add_card],
        "add_page" => o[:add_page],
        "add_document" => o[:add_document]
      })

    if body == %{},
      do:
        fail(
          "nothing to change — pass --name, --code, --shortcut, --desc, --color " <>
            "or --[no-]add-card / --[no-]add-page / --[no-]add-document"
        )

    HTTP.patch("/boards/#{HTTP.seg(ref)}", body)
    |> out(o, fn r -> IO.puts("updated board ##{r["board"]["id"]}: #{r["board"]["name"]}") end)
  end

  # Archiving a board puts it away without losing anything on it; restoring
  # brings it back where it was.
  defp run("archive-board", [ref], o) do
    HTTP.post("/boards/#{enc(ref)}/archive", %{})
    |> out(o, fn r -> IO.puts("archived board #{r["board"]["name"]}") end)
  end

  defp run("restore-board", [ref], o) do
    HTTP.post("/boards/#{enc(ref)}/restore", %{})
    |> out(o, fn r -> IO.puts("restored board #{r["board"]["name"]}") end)
  end

  # The order is the token holder's own: it moves nobody else's board index.
  # Boards left out fall to the end, oldest first.
  defp run("order-boards", refs, o) when refs != [] do
    HTTP.post("/boards/order", %{"boards" => refs})
    |> out(o, &Render.boards(&1["boards"]))
  end

  defp run("new-column", [ref | words], o) when words != [] do
    body =
      compact(%{"name" => Enum.join(words, " "), "wip_limit" => o[:wip], "color" => o[:color]})

    HTTP.post("/boards/#{HTTP.seg(ref)}/columns", body)
    |> out(o, fn r -> IO.puts("created column ##{r["column"]["id"]}: #{r["column"]["name"]}") end)
  end

  defp run("new-tag", [ref | words], o) when words != [] do
    body = compact(%{"name" => Enum.join(words, " "), "color" => o[:color]})

    HTTP.post("/boards/#{HTTP.seg(ref)}/tags", body)
    |> out(o, fn r -> IO.puts("created tag ##{r["tag"]["id"]}: #{r["tag"]["name"]}") end)
  end

  defp run("save-view", [ref | words], o) when words != [] do
    body =
      view_query(o)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("name", Enum.join(words, " "))

    HTTP.post("/boards/#{HTTP.seg(ref)}/views", body)
    |> out(o, fn r ->
      IO.puts(
        "saved view ##{r["view"]["id"]}: #{r["view"]["name"]}  " <> Render.dim(r["view"]["url"])
      )
    end)
  end

  defp run("update-view", [ref, view], o) do
    body = view_query(o) |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.delete("view")
    body = if o[:name], do: Map.put(body, "name", o[:name]), else: body
    if body == %{}, do: fail("nothing to change — pass view options or --name (see --help)")

    HTTP.patch("/boards/#{HTTP.seg(ref)}/views/#{HTTP.seg(view)}", body)
    |> out(o, fn r -> IO.puts("updated view ##{r["view"]["id"]}: #{r["view"]["name"]}") end)
  end

  defp run("delete-view", [ref, view], o) do
    HTTP.delete("/boards/#{HTTP.seg(ref)}/views/#{HTTP.seg(view)}")
    |> out(o, fn _ -> IO.puts("deleted view #{view}") end)
  end

  defp run(cmd, _args, _o) do
    fail("bad usage for '#{cmd}' (or unknown command). Run `slipdock --help`.")
  end

  ## Helpers ------------------------------------------------------------------

  defp dependencies(id, others, key, o) do
    Enum.each(others, fn other ->
      result =
        if o[:off],
          do: HTTP.delete("/cards/#{id}/dependencies/#{other}"),
          else: HTTP.post("/cards/#{id}/dependencies", %{key => other})

      # Report errors as they happen; the final card print covers success.
      case result do
        {:ok, _} -> :ok
        error -> out(error, o, fn _ -> :ok end)
      end
    end)

    HTTP.get("/cards/#{id}") |> out(o, &card_ok("updated", &1))
  end

  # Said out loud, because it is not recoverable by trying again.
  defp note_losses(nil), do: :ok

  defp note_losses(moved) do
    [
      {moved["tags_created"], "tag", "created on the new board"},
      {moved["fields_dropped"], "field value", "dropped (no such field there)"},
      {moved["milestones_unpinned"], "milestone", "unpinned"}
    ]
    |> Enum.reject(fn {n, _, _} -> is_nil(n) or n == 0 end)
    |> Enum.each(fn {n, noun, what} ->
      IO.puts("  #{n} #{noun}#{if n == 1, do: "", else: "s"} #{what}")
    end)
  end

  ## Favourites ---------------------------------------------------------------

  # `--ask` picks the question list and `--mode` names either explicitly.
  # `--search` is not a mode flag here: it is already the substring filter on
  # `cards`, and one switch meaning two things is worse than one extra switch.
  # `default` is what an unqualified command means (nil lists both).
  defp saved_mode(o, default) do
    cond do
      o[:mode] -> o[:mode]
      o[:ask] -> "ask"
      true -> default
    end
  end

  defp favourite(["card", id], o, dir), do: set_favourite("card", id, o, dir)

  defp favourite(["board", ref], o, dir) do
    set_favourite("board", fetch!("/boards/#{enc(ref)}")["board"]["id"], o, dir)
  end

  defp favourite(["list", ref | name], o, dir) when name != [] do
    columns = fetch!("/boards/#{enc(ref)}/columns")["columns"]
    set_favourite("column", pick(columns, Enum.join(name, " "), "list", ref), o, dir)
  end

  defp favourite(["view", ref | name], o, dir) when name != [] do
    views = fetch!("/boards/#{enc(ref)}/views")["views"]
    set_favourite("view", pick(views, Enum.join(name, " "), "view", ref), o, dir)
  end

  defp favourite(_, _, _) do
    fail(
      "usage: slipdock fav card <id> | list <board> <column> | view <board> <view> | board <board>"
    )
  end

  defp set_favourite(kind, id, o, :on) do
    HTTP.post("/favourites", %{"kind" => kind, "id" => id})
    |> out(o, fn r ->
      IO.puts("favourited: " <> describe(r["favourites"], kind, id))
    end)
  end

  defp set_favourite(kind, id, o, :off) do
    HTTP.delete("/favourites/#{kind}/#{enc(id)}")
    |> out(o, fn _ -> IO.puts("no longer a favourite: #{kind} #{id}") end)
  end

  # What the server says it just added, so the confirmation names the thing
  # rather than repeating the id back.
  defp describe(favourites, kind, id) do
    case Enum.find(
           favourites || [],
           &(&1["kind"] == kind and to_string(&1["resource_id"]) == to_string(id))
         ) do
      nil -> "#{kind} #{id}"
      f -> "#{kind} “#{f["name"]}” — #{f["url"]}"
    end
  end

  # A list or a view named on the command line, resolved to its id the way
  # the rest of the CLI resolves things: by id, else by name, case-insensitively.
  defp pick(items, ref, what, board) do
    match =
      Enum.find(items, &(to_string(&1["id"]) == ref)) ||
        Enum.find(items, &(String.downcase(&1["name"]) == String.downcase(ref)))

    case match do
      nil ->
        names = Enum.map_join(items, ", ", &~s("#{&1["name"]}"))
        fail(~s(no #{what} called "#{ref}" on #{board}. There is: #{names}))

      item ->
        item["id"]
    end
  end

  # Like `out/3`, but hands the body back instead of printing it; errors are
  # reported and halt exactly as they would there.
  defp fetch!(path) do
    case HTTP.get(path) do
      {:ok, data} -> data
      error -> out(error, [], fn _ -> :ok end)
    end
  end

  ## Wiki helpers ------------------------------------------------------------

  defp page_ok(verb, %{"page" => p}) do
    IO.puts("#{verb} #{p["code"]} #{p["title"]}  " <> Render.dim(p["url"]))
  end

  # The body can be given outright, read from a file, or piped in — the last
  # is how an agent writes a document without quoting a page of Markdown.
  defp page_body(o) do
    cond do
      o[:file] == "-" -> IO.read(:stdio, :eof) |> body_text()
      o[:file] -> File.read!(o[:file])
      o[:body] == "-" -> IO.read(:stdio, :eof) |> body_text()
      o[:body] -> o[:body]
      true -> nil
    end
  end

  defp body_text(:eof), do: ""
  defp body_text(text) when is_binary(text), do: text
  defp body_text(_), do: fail("could not read the body from stdin")

  defp latest_revision(ref) do
    case fetch!("/pages/#{enc(ref)}/revisions?limit=1") do
      %{"revisions" => [%{"id" => id} | _]} -> to_string(id)
      _ -> fail("that page has no history yet")
    end
  end

  # A section path is the rest of the route, so each level is its own segment.
  defp section_path(path) do
    path
    |> String.split("/")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("/", &HTTP.seg/1)
  end

  # `--set key=value`, repeatable, for a template's {{placeholders}}.
  defp values_of(o) do
    case Keyword.get_values(o, :set) do
      [] ->
        nil

      pairs ->
        Map.new(pairs, fn pair ->
          case String.split(pair, "=", parts: 2) do
            [k, v] -> {String.trim(k), v}
            [k] -> {String.trim(k), ""}
          end
        end)
    end
  end

  defp markdown_files(dir) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      path = Path.join(dir, name)

      cond do
        File.dir?(path) -> markdown_files(path)
        String.ends_with?(String.downcase(name), [".md", ".markdown"]) -> [path]
        true -> []
      end
    end)
  end

  defp skills_dir(o) do
    o[:dir] || Path.join([System.get_env("HOME") || ".", ".claude", "skills"])
  end

  # The server's sha is over every file of the skill; recomputing it locally is
  # how `check` answers without diffing four files.
  defp skill_current?(dir, skill) do
    digest =
      Enum.reduce(skill["files"], :crypto.hash_init(:sha256), fn file, acc ->
        case File.read(Path.join([dir, skill["name"], file])) do
          {:ok, text} -> :crypto.hash_update(acc, file <> "\0" <> text)
          _ -> acc
        end
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    digest == skill["sha"]
  end

  defp archived_param(o) do
    cond do
      o[:all] -> "all"
      o[:archived] -> "true"
      true -> nil
    end
  end

  # Swimlane configuration from CLI options, as API query/body params.
  # Absent options are left out so the server falls back to the saved view
  # (or the defaults).
  defp view_query(o) do
    done =
      cond do
        o[:done] -> "only"
        o[:open] -> "hide"
        true -> nil
      end

    [
      view: o[:view],
      rows: o[:rows],
      cols: o[:cols],
      unit: o[:unit],
      sort: o[:sort],
      dir: if(o[:descending], do: "desc"),
      empty: if(o[:show_empty], do: "show"),
      q: o[:search],
      due: o[:due],
      done: done,
      kinds: kind_values(o) |> Enum.join(",") |> presence(),
      tags: joined(o, :tag),
      priorities: joined(o, :priority),
      flags: joined(o, :flag),
      columns: joined(o, :column)
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  # `--kind card` and `--kind cards` both read well on the command line, so
  # both are taken; the API's vocabulary is the singular one.
  defp kind_values(o), do: o |> Keyword.get_values(:kind) |> Enum.map(&singular_kind/1)

  defp singular_kind("cards"), do: "card"
  defp singular_kind("documents"), do: "document"
  defp singular_kind("docs"), do: "document"
  defp singular_kind("doc"), do: "document"
  defp singular_kind("pages"), do: "page"
  defp singular_kind("wiki"), do: "page"
  defp singular_kind(other), do: other

  defp presence(""), do: nil
  defp presence(string), do: string

  defp joined(o, key) do
    case Keyword.get_values(o, key) do
      [] -> nil
      values -> Enum.join(values, ",")
    end
  end

  defp each(ids, o, fun, verb) do
    Enum.each(ids, fn id -> fun.(id) |> out(o, &card_ok(verb, &1)) end)
  end

  defp card_ok(verb, %{"card" => c}), do: IO.puts("#{verb} " <> Render.card_line(c, true))
  defp card_ok(verb, %{"page" => p}), do: page_ok(verb, %{"page" => p})

  # A card is a number; anything else — "W-31", "board-code/slug" — names a
  # wiki page. A page holds comments, a checklist, status updates, web links
  # and votes in the same tables a card does (see `Slipdock.Boards.Owned`), so
  # the commands below take either and only the path changes.
  defp item_path(ref, suffix) do
    ref = to_string(ref)

    case Integer.parse(ref) do
      {_, ""} -> "/cards/#{ref}#{suffix}"
      _ -> "/pages/#{URI.encode_www_form(ref)}#{suffix}"
    end
  end

  defp item_name(ref) do
    case Integer.parse(to_string(ref)) do
      {_, ""} -> "card ##{ref}"
      _ -> "page #{ref}"
    end
  end

  defp admin_user(email, change, o) do
    with {:ok, %{"users" => users}} <- HTTP.get("/admin/users"),
         %{"id" => id} <- Enum.find(users, &(&1["email"] == String.downcase(email))) do
      HTTP.patch("/admin/users/#{id}", change) |> out(o, &render_admin_user/1)
    else
      nil -> fail("no account here uses #{email}")
      other -> out(other, o, &render_admin_user/1)
    end
  end

  defp admin_signup(email, decision, o) do
    with {:ok, %{"requests" => requests}} <- HTTP.get("/admin/signups"),
         %{"id" => id} <- Enum.find(requests, &(&1["email"] == String.downcase(email))) do
      HTTP.post("/admin/signups/#{id}/#{decision}")
      |> out(o, fn _ -> IO.puts("#{decision}d #{email}") end)
    else
      nil -> fail("nobody with that address is waiting")
      other -> out(other, o, fn _ -> :ok end)
    end
  end

  # Numbers and booleans have to arrive as themselves, not as strings, or the
  # server rejects "20" where it wants 20.
  defp admin_value(key, value) when key in ["free_card_limit"] do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp admin_value(key, value) when key in ["invites_create_accounts", "login_fallback_enabled"],
    do: value in ["1", "true", "yes", "on"]

  defp admin_value(_key, value), do: value

  defp render_admin(%{"settings" => s} = body) do
    IO.puts("""
    Build:            #{render_build(body["build"])}
    Registration:     #{s["signup_mode"]}#{allowlist_note(s)}
    Card limit:       #{s["free_card_limit"] || "no limit"}
    People visible:   #{s["user_directory"]}
    Invites create:   #{s["invites_create_accounts"]}
    Admin address:    #{s["admin_email"] || "—"}
    Mail:             #{if s["smtp"]["configured"], do: "#{s["smtp"]["host"]}:#{s["smtp"]["port"] || 587}", else: "not configured"}
    Sign-in fallback: #{if s["login_fallback"]["enabled"], do: s["login_fallback"]["path"], else: "off"}
    Waiting:          #{s["pending_signups"]}\
    """)
  end

  # The commit and the time it was compiled, which is what "which build is
  # running" means — see `Slipdock.Build` on the server.
  defp render_build(%{} = b) do
    "#{b["git_short_sha"]}#{if b["git_dirty"], do: "+modified"} built #{b["built_at"]} UTC (v#{b["version"]})"
  end

  defp render_build(_), do: "unknown"

  defp allowlist_note(%{"signup_mode" => "allowlist", "allowlist" => list}),
    do: " (#{if list == [], do: "nobody listed", else: Enum.join(list, ", ")})"

  defp allowlist_note(_), do: ""

  defp render_admin_users(%{"users" => users}) do
    for u <- users do
      flags =
        [u["admin"] && "admin", u["disabled"] && "disabled", u["invited"] && "invited"]
        |> Enum.filter(& &1)

      cards =
        case u["cards"] do
          %{"limited?" => true, "used" => used, "limit" => limit} -> "#{used}/#{limit} cards"
          %{"used" => used} -> "#{used} cards"
          _ -> ""
        end

      IO.puts(
        "#{u["email"]}  #{cards}  #{u["last_signed_in_at"] || "never seen"}#{if flags == [], do: "", else: "  [" <> Enum.join(flags, " ") <> "]"}"
      )
    end
  end

  defp render_admin_user(%{"user" => u}), do: render_admin_users(%{"users" => [u]})
  defp render_admin_user(other), do: Render.json(other)

  defp render_admin_signups(%{"requests" => []}), do: IO.puts("Nobody is waiting.")

  defp render_admin_signups(%{"requests" => requests}) do
    for r <- requests do
      IO.puts(
        "#{r["email"]}  asked #{r["asked_at"]}#{if r["note"] in [nil, ""], do: "", else: "  “" <> r["note"] <> "”"}"
      )
    end
  end

  defp out({:ok, data}, o, render) do
    if o[:json], do: Render.json(data), else: render.(data)
  end

  defp out({:error, :connect, reason}, _o, _render) do
    fail(
      "could not reach #{HTTP.base_url()} (#{inspect(reason)}). Is the server running? Set SLIPDOCK_URL or --url."
    )
  end

  defp out({:error, 401, _}, _o, _render) do
    fail(
      "not signed in. Create an API token under Account in the web UI, then run: slipdock auth <token>"
    )
  end

  # A wiki save that would have landed on someone else's. Say what to do about
  # it rather than just refusing: the hash to re-base on, and where to read the
  # version that got there first.
  defp out({:error, 409, %{"current" => current}}, _o, _render) do
    IO.puts(:stderr, "error: this page changed since you read it. Nothing was overwritten.")

    IO.puts(
      :stderr,
      "  it now reads #{current["title"] |> inspect()}, hash #{String.slice(to_string(current["content_hash"]), 0, 12)}"
    )

    IO.puts(:stderr, "  read it again, merge, then save with --base-hash <the new hash>")
    System.halt(1)
  end

  defp out({:error, status, %{"error" => msg} = data}, _o, _render) do
    details =
      if data["details"], do: " " <> IO.iodata_to_binary(:json.encode(data["details"])), else: ""

    fail("#{msg}#{details} (HTTP #{status})")
  end

  defp out({:error, status, data}, _o, _render), do: fail("HTTP #{status}: #{inspect(data)}")

  defp enc(s), do: HTTP.seg(s)

  # A folder may be named by a path, and the slashes in it are part of the
  # route rather than part of one segment.
  defp path_enc(s),
    do: s |> to_string() |> String.split("/", trim: true) |> Enum.map_join("/", &enc/1)

  # A spec is JSON: inline, from a file, or from stdin with `--spec -`.
  defp spec_json("-"), do: decode_spec(IO.read(:stdio, :eof))

  defp spec_json(source) do
    if File.regular?(source), do: decode_spec(File.read!(source)), else: decode_spec(source)
  end

  defp decode_spec(text) when is_binary(text) do
    case :json.decode(text) do
      %{} = spec -> spec
      _ -> fail("--spec must be a JSON object (see `slipdock automation-help`)")
    end
  rescue
    _ -> fail("--spec isn't valid JSON (see `slipdock automation-help`)")
  end

  defp decode_spec(_), do: fail("could not read the spec")

  # A portable export, read off disk. Same shape of care as `decode_spec/1`:
  # say which of "missing", "not JSON" and "not an object" went wrong.
  defp read_document(path) do
    case :json.decode(File.read!(path)) do
      %{} = document -> document
      _ -> fail("#{path} does not hold a JSON object — an export is one")
    end
  rescue
    e in [File.Error] -> fail("couldn't read #{path}: #{Exception.message(e)}")
    _ -> fail("#{path} isn't valid JSON")
  end

  # --tree watches the board's subcards too; --no-tree goes back to the board alone.
  defp scope_of(true), do: "tree"
  defp scope_of(false), do: "board"
  defp scope_of(nil), do: nil

  defp cond_bool(true, _), do: true
  defp cond_bool(_, true), do: false
  defp cond_bool(_, _), do: nil

  defp nonblank(""), do: nil
  defp nonblank(s), do: s

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
  defp nonempty([]), do: nil
  defp nonempty(list), do: list

  defp fail(msg) do
    IO.puts(:stderr, "error: " <> msg)
    System.halt(1)
  end

  defp render_ai_key(%{"ai_key" => k}) do
    cond do
      k["masked"] ->
        IO.puts(
          "#{k["masked"]}#{if k["set_at"], do: "  set #{String.slice(k["set_at"], 0, 10)}"}"
        )

      k["ai_available"] ->
        IO.puts("no key of your own; this server has a shared one")

      true ->
        IO.puts("no key — AI features are off for you (slipdock ai-key <key>)")
    end
  end

  # Poll until somebody decides. The server tells us how often to ask and says
  # `slow_down` if we ask faster; ignoring either is how a client locks itself
  # out, so the interval widens rather than the loop tightening.
  defp await_device_approval(started, interval) do
    deadline = System.monotonic_time(:second) + (started["expires_in"] || 600)
    poll_device(started["device_code"], interval, deadline)
  end

  defp poll_device(device_code, interval, deadline) do
    Process.sleep(interval * 1000)

    cond do
      System.monotonic_time(:second) > deadline ->
        {:error, "the code expired before anybody approved it — run `slipdock auth` again"}

      true ->
        case HTTP.post("/auth/device/token", %{device_code: device_code}) do
          {:ok, %{"token" => token}} ->
            {:ok, token}

          {:error, _, %{"error" => "authorization_pending"}} ->
            poll_device(device_code, interval, deadline)

          {:error, _, %{"error" => "slow_down"}} ->
            poll_device(device_code, interval + 5, deadline)

          {:error, _, %{"error" => "access_denied"}} ->
            {:error, "the request was refused"}

          {:error, _, %{"error" => "expired_token"}} ->
            {:error, "the code expired before anybody approved it — run `slipdock auth` again"}

          {:error, :connect, reason} ->
            {:error, "lost the server while waiting (#{inspect(reason)})"}

          _ ->
            {:error, "the server gave an answer this version does not understand"}
        end
    end
  end

  defp finish_device_auth({:ok, token}, o) do
    System.put_env("SLIPDOCK_TOKEN", token)

    HTTP.get("/me")
    |> out(o, fn r ->
      path = HTTP.save_token(token)
      IO.puts("signed in as #{r["user"]["email"]}; token saved to #{path}")
    end)
  end

  defp finish_device_auth({:error, message}, _o), do: fail(message)

  # What the person approving will see named on the screen, so make it say
  # something about this machine rather than "CLI".
  defp default_label do
    host =
      case :inet.gethostname() do
        {:ok, name} -> to_string(name)
        _ -> "unknown host"
      end

    "slipdock CLI on #{host}"
  end
end

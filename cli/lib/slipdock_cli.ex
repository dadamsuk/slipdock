defmodule SlipdockCLI do
  @moduledoc "Command-line client for the Slipdock board API."

  import SlipdockCLI.Util, only: [fail: 1, bad_usage: 1]

  alias SlipdockCLI.{
    Admin,
    Auth,
    Automations,
    Boards,
    Deploy,
    Garden,
    Meetings,
    Runners,
    Skills,
    Sync,
    Tools,
    Util,
    Vaults,
    Wiki
  }

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
        --archived    include archived cards (a card's #id or link
                      as the query finds it, archived or not)
        --full        print the whole matching text, not a snippet
    ask <question...>                   ask the assistant, which searches for itself and
                                        answers in prose, naming the cards it read
        --board B     keep it to one board (id, code or name)
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
    whoami                              show who you are signed in as (and how many things
                                        are waiting on you)
    work [--board B] [--done]           my work: what is waiting on you (waits, review and
                                        waiting flags, runner trouble, cards in progress with
                                        nobody on them), oldest first, then my cards by due date
    passkeys                            your passkeys: name, when added, when last used
    passkeys remove <id>                remove one (a lost phone) — it can't sign in after.
                                        Adding one needs the device, so is in a browser only
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
                                      meetings_enabled=true turns meeting capture on;
                                      chat_capture_enabled=false turns chat capture off;
                                      meetings_visibility=used_only|every_board,
                                      meetings_hideable=false, and what may be sent:
                                      meetings_accept_transcripts|audio|findings=false,
                                      meetings_reading_model=<id> (empty: each person's own),
                                      meetings_second_reading=same|model|off,
                                      meetings_second_model=<id>; per person per month:
                                      meetings_transcription_minutes=600,
                                      meetings_audio_storage_mb=2048,
                                      meetings_transcript_captures=200 (each with _enabled),
                                      meetings_longest_minutes=240, meetings_max_file_mb=500,
                                      meetings_audio_retention=until_committed|30_days|90_days,
                                      meetings_transcription=none|provider|endpoint,
                                      meetings_transcription_model=openai/whisper-large-v3,
                                      meetings_transcription_url=, meetings_transcription_max_mb=25,
                                      meetings_diarisation=labels|endpoint,
                                      meetings_diarisation_url=, meetings_dialogue_inference=false,
                                      meetings_voiceprints=true, meetings_voiceprint_url=,
                                      meetings_relisten_model=<audio-capable model> (empty: off)
                                      transcription_server_url=https://host:8765 (your own
                                      transcription server: Transcribe on a card's recording;
                                      empty: off),
                                      transcription_server_token=<key> (empty: none)
  admin meetings-usage                meeting capture this month: totals, heaviest users
  admin allow <entry>                 let an address or a whole domain register
  admin disallow <entry>
  admin users                         who is here, what they use, when last seen
  admin overview [--sort S]           usage at a glance: accounts, active and joined in
                                      7/30 days, and per person signed up, last active,
                                      boards, lists, cards, pages, files, storage (S:
                                      storage|cards|boards|lists|pages|files|last_active|
                                      signed_up|email)
  admin promote|demote <email>        admin rights (never the last admin)
  admin disable|enable <email>        reversible; ends their sessions at once
  admin limit <email> <n|none>        an item limit of their own
  admin paid <email> <date|none>      paid up to a date: off the free tier and off
                                      the trial clock (e.g. 2026-12-31)
  admin unlimited <email> on|off      off the free tier for good, no date needed;
                                      the server-wide ceilings still apply
  admin meetings <email> on|off       let them use meetings, recording transcription
                                      and voiceprints (admins always may)
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
        --snoozed include|only                    (snoozed cards are left out otherwise)
        --stuck                                   (in their list longer than it usually takes)
        --driver all|agent|human                  (who holds or last moved it; runner boards)
    card <id>                           show one card in full (checklist, comments)
    activity <board> [--limit N] [--card ID]  recent activity on a board (or one card)
    dora <board> [--env E] [--days N]   the board's delivery performance from its recorded
                                        deploys: deployment frequency, lead time, change
                                        failure rate, time to restore, rework rate and idea
                                        to production, each with its DORA band and the trend
                                        (needs the board's delivery metrics on; see `deploy`)
    pulse <board>                       the board's flow numbers: in progress, waiting, done in
                                        7 days and today, P50/P85 time to done, moves in 24h
                                        forward and back, and each list's in/out and usual stay
    flow <board> [--days 7|30|90]       the board's flow day by day: cards in backlog, ready,
                                        doing and done, completed, added and open each day,
                                        completed per week, and P50/P85 cycle time
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
    runners <board>                     the runners taking jobs from the board's tree (owner only)
    runner-stats <board> [--days 7|30|90]  how the board's runners are doing: status, outcomes,
                                        job time, queue wait, waits on people, reopened cards
                                        and the last 12 jobs
    jobs <board> [--status S] [--limit N]   jobs the board's rules sent to runners, newest first
                                        (S: open, queued, claimed, running, done, failed, cancelled, timeout)
    jobs --card ID                      one card's jobs
    job <id>                            one job: status, runner, prompt and the tail of its log
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
    fav page <page>                     favourite a wiki page (W-31, its slug or board/slug)
    unfav <same args>                   stop favouriting it (or `fav ... --off`)
    hotkeys                             your board hotkeys: Ctrl+Shift+a digit in the web app
    hotkey <board> <0-9|none>           give a board a digit (it leaves any other board), or none
    header                              your header links: boards and vaults pinned left of
                                        quick add in the web app, and the icons they can wear
    header add board|vault <ref> --icon NAME
                                        pin one (again: change its icon); up to 8
    header rm <id>                      unpin one
    header move <id> left|right         move one a place along

  WIKI  (Markdown pages on a board: how it works, what was decided and why.
         A page answers to its code — W-31 — its slug, or board/slug.)
    page ls <board> [--q TEXT] [--archived|--all] [--template] [--draft]
                    [--folder F | --no-folder] [--recent]
                                        --recent: the most recently edited first, the
                                        newest 100 (the wiki tree's Recent view)
    page tree <board>                   the page tree, nesting shown by indent
    page read <page>                    print the Markdown source
    page tags <board>                   the tags its notes give themselves (front matter tags
                                        and inline #tags, on a board in a vault), with counts.
                                        page ls <board> --note-tag T lists the notes tagged T
                                        or anything under it (T/sub)
    page props <page> [--body TEXT | --file F | --clear]
                                        the front matter its file came with, kept exactly as
                                        written; with --body/--file, replace it (YAML only,
                                        no --- lines)
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
        --icon I | --no-icon        what it wears in the wiki, tinted by --color
                                    (icons: see `folder new`)
    page file <page> --folder F | --no-folder
                                        file it in a folder, or take it out of one.
                                        Where a page is *kept*; `page mv` is what it is
                                        *part of*
    page file <page> --also F | --not-in F [--board B]
                                        file it in one more folder as well as its home
                                        (one page, several places), or take it out of
                                        one. F is a folder on its board, on --board B,
                                        or a vault path ("/Projects/Notes") in its vault
    page mv <page> [--parent P | --root] [--position N|top|bottom]
    page mv <page> --board B [--folder F] [--dry-run]
                                        to another board of its vault: it keeps its code,
                                        history and comments; tags, fields and pins go where
                                        that board has a match (--dry-run says which won't)
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
    page encrypt <page> [--section S] [--hint H] [--purge-history]
                                        encrypt the page, or one section, in Meld Encrypt's
                                        format (Obsidian opens it). Done here: the passphrase,
                                        asked for twice, and the text never reach the server.
                                        Earlier revisions still holding the text are counted;
                                        --purge-history deletes them (the board's owner only)
    page decrypt <page> [--section S] [--in-place]
                                        print the page, or a section, with its encrypted
                                        blocks opened; --in-place removes the encryption and
                                        saves the plain text. Both take --passphrase-file F or
                                        $SLIPDOCK_MELD_PASSPHRASE where nobody can type it
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
    page share <page> [EMAIL|GROUP] [--read|--comment|--write] [--off]
                                        share it with a person (an email; a stranger is
                                        invited) or a group of yours, read only (default),
                                        --comment (read, comment, report a status, vote;
                                        no edits) or --write; --off takes it back; nobody
                                        named lists who has it. Only its board's writers
                                        can share
    shared                              what other people have shared with you, by owner;
                                        `page read` and `page edit` take the codes it lists
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
    page switch <board> <letters...> [--limit N]
                                        the quick switcher: notes whose title, alias or path
                                        the letters run through in order, across the vault
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
    wiki files <board> [--folder F]     the wiki's files that are not pages, by path (a
                                        Tool's board files are in its Tool folder)
    wiki get <board> <path> [--out F|-] [--force]
                                        save one by its path ("Tool/cv.docx") under its
                                        own name here, as F, or to stdout (--out -)
    folder ls <board>                   the board's filing, pages and all
    folder open <board> [<folder>] [--page P] [--all]
                                        one level of the tree, as the web's tree loads it:
                                        folders, pages and files with how much is under each,
                                        never a body. No folder: the top of the wiki
    folder new <board> <name...> [--parent F] [--icon I] [--color C]
                                        a name with slashes makes the whole path.
                                        --icon and --color: what it wears on the wiki's
                                        main page and in its tree. Icons: star heart
                                        bookmark flag bolt fire light-bulb sparkles
                                        rocket-launch beaker book-open academic-cap
                                        briefcase calendar chat-bubble-left-right
                                        check-circle clipboard-document-list code-bracket
                                        cog-6-tooth cube currency-dollar document-text
                                        exclamation-triangle globe-alt home inbox key
                                        lock-closed map megaphone musical-note photo
                                        puzzle-piece shield-check tag trophy user-group
                                        wrench-screwdriver archive-box folder. Colours:
                                        slate red orange amber lime emerald teal sky
                                        indigo violet fuchsia rose
    folder mv <board> <folder> [--name N] [--parent F | --root] [--position N]
                                        [--sort board|manual|name|modified|created]  how the
                                        tree orders the pages in it
                                        [--icon I | --no-icon] [--color C | --no-color]
    folder mv <board> <folder> --board B [--parent F] [--contents] [--dry-run]
                                        to another board you can write to, with its
                                        subfolders, every page in them and their files;
                                        pages keep codes and history. --contents moves
                                        only what is in it (the folder itself goes).
                                        --dry-run: what would move and what can't
    folder show <board> <folder>        one folder: its path, and where else it is filed
    folder share <board> <folder> [EMAIL|GROUP] [--read|--comment|--write] [--off]
                                        share a folder and everything in it, subfolders and
                                        all, as `page share` does a page
    folder file <board> <folder> --also F | --not-in F [--board B]
                                        file it in one more folder as well as its home
                                        (one folder and all in it, several places), or
                                        take it out of one; both repeat. F is a folder on
                                        its board, on --board B, an id, or a vault path
                                        ("/Projects/Notes") in its vault. Never inside
                                        itself, by any route
    folder rm <board> <folder> [--purge]
                                        delete the folder only: its subfolders move up and
                                        its pages go back to the root. --purge deletes the
                                        pages in it as well, history and all (owner only)
    folder organise <board> <folder> --by date|ai|tag|flatten [--dry-run]
                                        sort what is filed in the folder. date: into
                                        <parent>/2026-10 (--parent F, default the folder;
                                        --root for the top; --per month|year|year_month|day;
                                        dated by created:/date: front matter, else when
                                        added — --added for always when added). ai: a cheap
                                        model suggests homes under existing top-level
                                        folders. tag: a subfolder per first tag. flatten:
                                        everything in its subfolders back up into it.
                                        Missing folders are made. --dry-run: the plan only

  VAULTS  (board wikis laid out as one Obsidian-style vault: each mapping puts a
           vault path onto a board's wiki or one folder of it, the longest prefix
           winning. A board belongs to one vault, and only one you can write to)
    vault ls                            your vaults, their mappings (with page counts)
                                        and the folders each is synced to
    vault show <vault>                  one of them
    vault new <name...> [--with-board]  make one; --with-board also makes a board named
                                        after it to hold its pages, mapped at / and kept
                                        inside the vault
    vault rename <vault> <name...>
    vault rm <vault>                    its mappings go; every page stays on its board
    vault set <vault> [--shortcut K] [--hotkey 0-9|none] [--recordings-folder PATH]
                                        the folder on your Google Drive its meeting
                                        recordings are in ("" clears it); a page whose
                                        front matter says recording: gdrive:<path> plays
                                        it beside its transcript
    drive status                        your Google Drive connection, and each vault's
                                        recordings folder
    vault map <vault> <path> --board B [--folder F] [--inside] [--dry-run]
                                        put a vault path ("/", "/Projects") onto a board's wiki;
                                        --dry-run lists the pages it brings in and takes over;
                                        --inside keeps the board inside the vault
    vault inside <vault> <path> [--off] keep the board mapped whole at <path> inside the
                                        vault: the web app names it on the vault's tile, not
                                        among your boards (`boards` marks it). --off lets it out
    vault dress <vault> <path> [--icon NAME] [--color NAME]
                                        what the board or folder mounted at <path> wears in
                                        the vault's tree (the wiki's icon set and palette;
                                        none takes one off)
    vault unmap <vault> <path> [--dry-run]
                                        take a mapping out (--dry-run: which pages leave)
    vault split <vault> <path> --board B | --new-board NAME [--dry-run]
                                        give a vault folder its own board: what is in it
                                        moves to B (or a board made for it) and <path> is
                                        mapped onto B. The notes keep their vault paths,
                                        so a synced folder sees no change to them
    vault locate <vault> <path>         which mapping a vault path lands in, and the rest
    vault resolve <vault> <link...>     the page a [[link]] finds anywhere in the vault
                                        (Note, or Folder/Note; the shortest path wins)
    vault wanted <vault>                pages linked to but never written, every board at once
    vault changes <vault> [--since N] [--limit N]
                                        what changed (pages, folders, attachments) after cursor
                                        N, each once and as it is now; without --since, the
                                        cursor to start from. What sync polls
    vault import <dir> --vault V [--dry-run] [--all]
                                        bring an existing Obsidian vault in, once: each note a
                                        page and each other file a file at its vault path,
                                        routed by the mappings, bytes as they are (front matter,
                                        Excalidraw, Meld ciphertext). What the server has at a
                                        path already is left alone. --dry-run says what would be
                                        created or skipped, and which links, embeds and plugin
                                        blocks won't resolve. Afterwards, `sync init` on the
                                        same folder adopts the files instead of duplicating them

  SYNC  (a vault mirrored both ways to a local folder that stays a valid Obsidian
         vault. The server is the source of truth; the folder is a working copy,
         and anything that writes a file into it writes into the vault)
    sync init <dir> --vault V           bind a folder to a vault, then run once. Files already
                                        there that match the vault are adopted, not duplicated
    sync [<dir>]                        one pass, both ways (default: the folder you are in).
                                        A .md file is a page; images, PDFs, .excalidraw and
                                        other files are kept at the same vault path (250 MB
                                        each), so ![[image.png]] works on both sides.
                                        A rename or move is the same page; a delete archives
                                        it. Changed on both sides: the server's version keeps
                                        the path and yours is saved beside it as
                                        "Name (conflict DATE host).md", and synced too.
                                        Dot folders (.obsidian, .trash) and editors' temp
                                        files are left alone, and so is anything named in
                                        .slipdockignore (gitignore-style: *.pdf, Private/)
        --watch       keep running: a pass once the folder has been still for 2 s, and
                      whenever the server's change feed has news
        --interval S  how often --watch asks the server (default 10)
    sync from-server [<dir>]            one pass that only brings changes down: nothing is
                                        sent, archived or moved on the server
    sync to-server [<dir>]              one pass that only sends changes up: nothing in the
                                        folder is written, moved or removed. Either way what
                                        it skips is listed as held (·) and stays waiting for
                                        the next pass; a conflict waits for a pass both ways.
                                        --watch and --json work as for sync
    sync status [<dir>]                 the last sync, what is waiting on each side, conflicts
                                        left to resolve, and a warning if Obsidian Sync,
                                        Dropbox, iCloud, OneDrive or Syncthing is syncing the
                                        same folder (two sync tools on one folder fight)
    sync service install|uninstall|print [<dir>]
                                        run sync --watch in the background: a systemd user
                                        unit, a launchd agent or a Windows logon task.
                                        print shows what install would do

  SKILLS  (the agent instructions this server ships, versioned with its API)
    skills                              list them, with a version each
    skills install [--dir D]            write them to ~/.claude/skills (or D)
    skills check                        say whether the local copies are behind
    skills chatgpt [--dir D]            save ChatGPT's versions, one zip per skill, here (or D)

  TOOLS  (packages of docs, files, a board and skills that people on this server share)
    tools                               the Tools you can see: yours, shared with you, listed
    tools show <name> [--version V]     what one holds: its board, skills, files and versions
    tools publish <dir>                 pack the folder (tool.json, README.md, board.json,
                                        skills/, files/) and publish it as a new version
    tools install <name> [--version V] [--dir D]
                                        put its skills, and the files that go beside them,
                                        in ~/.claude/skills (or D)
    tools check [<name>...]             say whether the installed Tool skills are behind
    tools request-listing <name> [--version V]
                                        ask an admin to list a version for everyone here
    tools install-board <name> [--version V] [--name N]
                                        have the server build the Tool's board for you
                                        (again: answers with the board you already have)
    tools file <name> <path> [--version V] [--out F]
                                        one file of the package by its path
                                        (skills/<skill>/SKILL.md, files/build.py) to
                                        stdout or F; the latest version unless --version
    tools download <name> [--version V] [--out F|-] [--force]
                                        the whole package, every file at its path, as
                                        <name>-<version>.tar.gz (or F, or - for stdout):
                                        unpack it, change it, publish it again

  MEETINGS  (meeting capture: off unless this server's admin turns it on, and
             every command here says "meeting mode is off on this server" until then)
    meetings                            whether meeting mode is on, and where it shows
    capture new <board> [opts]          send a meeting: prints its id, link and questions
        --transcript F  WebVTT, SRT, Name: text, a Fireflies or Otter export (- for stdin)
        --audio F       the recording (wav, mp3, m4a, flac, ogg, webm, aac)
        --findings F    your own findings, in the schema `capture schema` prints
        --ics F         the invite: attendees, start and title
        --title T  --when 2026-10-07T10:00  --attendees "Priya, sam@example.com"
        --format vtt|srt|text|blocks|fireflies|otter  --with-parent (read the parent board too)
    capture ls <board>                  the board's captures, newest first
    capture show <id>                   what it found, and the questions to settle
    capture resolve <id> <question> <answer>   answer by number or label;
                                        --replayed 7:38-7:44 says what you listened to
    capture include|leave-out <id> <finding>
    capture preview <id>                exactly what committing writes, and its digest
    capture commit <id> [--preview D]   write it, in one go (refused if anything moved)
    capture undo <id> [--rest]          undo it all (--rest: all but what was edited since)
    capture retry <id>                  carry a failed capture on
    capture discard <id>                decide against it; nothing is written
    capture schema                      the findings format, as JSON Schema
    capture-chat <board> <file> [opts]  send a conversation with an AI assistant (chat
                                        capture: on unless the admin turned it off; needs no
                                        meeting mode). The file: Name: text turns, or a
                                        Claude or ChatGPT export (- for stdin)
        --format chat|claude-export|chatgpt-export  --conversation ID|TITLE (one of several)
        --title T  --findings F (your own, quoting the conversation exactly)
        --drop-transcript  once committed, keep only the quoted words
    voiceprint                          your own voiceprint, if you have one (only while the
                                        admin has voiceprints on), and meetings to enrol from
    voiceprint enrol --audio F --consent       from a recording of your own voice;
    voiceprint enrol --from-capture ID --consent   or a meeting where your voice was confirmed.
                                        Prints the consent wording; --consent agrees to it
    voiceprint delete                   delete it now: meetings stop using it

  WRITE
    add <board> <title> [opts]          create a card
        --column C (default: first column)  --desc TEXT  --priority P
        --assignee EMAIL|me (repeatable: everybody on it, the first is the lead)
        --flag F (repeatable)  --tag T (repeatable)  --start YYYY-MM-DD  --due YYYY-MM-DD  --color C
        --percent N (0-100)  --border C, --border-top/-right/-bottom/-left C   (see edit)
        --spent T  --estimate T  --unit minutes|hours|days|weeks|months   (time tracking; see edit)
        --archived                  archive it as soon as it is made (a record of finished work)
    edit <id> [opts]                    change fields on a card
        --title T  --desc TEXT  --priority P  --start DATE | --no-start  --due DATE | --no-due
        --color C | --no-color  --column C
        --border C | --no-border     every edge of the card's front in palette colour C;
        --border-top C  --border-right C  --border-bottom C  --border-left C
                                     one edge (after --border, so the edge wins); C none
                                     takes that edge's colour off
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
    repeat <id> "every mon" [--at 07:00] [--lead 2] [--ends DATE | --count N]
        [--on-missed bump|skip|stack] [--column C] [--tz Europe/London]
                                        make a card recurring, or change how: the next one is
                                        a copy of it, made in the board's ready list. Rules:
                                        day, weekday, mon, mon,thu, 2w mon, month 1, month
                                        last fri, month first mon, year, 3d after (after the
                                        last is done), or FREQ=WEEKLY;BYDAY=MO
    repeat <id>                         how it repeats, and the next three dates
    repeat <id> --skip | --pause | --resume | --off
                                        let the next one go / hold it / carry on / stop it
    recurring <board>                   every card on the board that repeats, soonest first
    snooze <id>... <when> [--note T] [--notify]
                                        hide cards until a date (2026-11-02, tomorrow, mon,
                                        next week, in 3 days; midnight where you are). They
                                        wake at the top of their list, or sooner when someone
                                        else comments or assigns them. --notify alerts then
    wake <id>...                        bring snoozed cards back now
    garden <board> [--run] [--check K]  tidy-up suggestions: epics done but open, cards stuck in
                                        progress, overdue, duplicates, orphaned pages, mistyped
                                        [[links]]. --run looks the board over first
    garden apply <id>... [--keep CARD] [--choice NAME]
                                        apply suggestions you approve (--keep: the duplicate
                                        that stays; --choice: one of its alternatives)
    garden dismiss|undo <id>...         dismiss (it stays dismissed) or undo an applied one
    garden settings <board> [<check> key=value...]
                                        show the checks, or change one (enabled=false, days=30)
    copy <id> [--board B] [--column C] [--title T] [--top|--bottom]
                                        a copy of the card as it is now: checklist unticked,
                                        subcards reopened; no comments, dates or attachments.
                                        Lands straight after the original unless told otherwise
    move <id> <column> [--top|--bottom|--index N]
    move <id> <column> --board B         move the card to a list on another board, with its
                                         subcards; tags travel by name, custom fields only
                                         where that board has the same one
    done <id>...  |  undone <id>...     mark complete / incomplete
    flag <id> <flag>... [--off]         add (or remove) flags
    tag <id> <tag>... [--off]           add (or remove) tags
    check <id> <text>                   add a checklist item
    tick <item-id>                      toggle a checklist item done/undone
    comment <id> <text>                 add a comment (Markdown). For more than a line,
                                        --body - with a heredoc keeps the line breaks
                                        (or --body TEXT, --file F)
                                        (check, comment, status, vote, weblink, unweblink and attach take
                                        a wiki page too: a page code like W-31 instead of a number)
    link <id> <kind> <card-id>...       link cards across boards (kind: relates contributes duplicates)
    unlink <id> <link-id>...            remove links (ids shown by `card`)
    weblink <id> <url> [--label TEXT]   link a card to a web page, drive or file (datestamped)
    unweblink <id> <url-id>...          remove web links (ids shown by `card`)
    attach <id> <file>... [--name N] [--hide-on-card] [--replace]
                                        upload files to a card or page; prints the Markdown that
                                        embeds each (an image shows inline, anything else links).
                                        A card's first image is the thumbnail on its front unless
                                        --hide-on-card keeps it off. --replace deletes older files
                                        of the same name once the new one is in
    transcribe <id> <attachment-id> [--wait]
                                        send a card's recording to the transcription server;
                                        --wait prints the transcript once it is done
    card-front <id> <attachment-id>... [--off]
                                        let an image be the card's thumbnail (--off: keep it off)
    attachments <id>                    list a card's or page's files
    download <attachment-id> [--out F] [--force]
                                        save a file's bytes, under its own name here, or as F
                                        (--out - writes it to stdout)
    detach <id> <attachment-id>...      delete attached files
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
        [--simple | --no-simple] [--page-card-features | --no-page-card-features]
        [--show-pulse | --no-show-pulse] [--automation-wip | --no-automation-wip]
        [--delivery-metrics | --no-delivery-metrics] [--incident-tag T] [--hotfix-hours N]
        [--card-ref-pattern RE] [--default-view V] [--handoff-label L]
        [--handoff-prompt TEXT | --handoff-prompt-file PATH]
                                        rename a board, change its code, shortcut key or colour,
                                        say what the foot of each list offers, make it a
                                        sprint board (every card a sprint), or a simple one (a
                                        plain to-do list: % complete, start dates, health,
                                        time, votes, dependencies, Timeline and Prioritise
                                        hidden — not deleted); --no-page-card-features hides
                                        status, checklist, links, fields, votes and comments
                                        on every page of the board's wiki (not deleted);
                                        --show-pulse puts the board's pulse over its lists;
                                        --automation-wip makes the first in-progress list's
                                        WIP limit hold runner jobs and list sends;
                                        --delivery-metrics lets the board record deploys
                                        and shows its DORA numbers (see `deploy`, `dora`);
                                        --incident-tag names the tag on incident cards
                                        (incident); --hotfix-hours how soon a fix naming one
                                        makes the deploy before it a failed change (24);
                                        --card-ref-pattern the regex finding card ids in
                                        commit messages, id in its first group (#(\\d+))
                                        --default-view picks what opening the board shows
                                        in the web app: board, swimlanes, table, timeline,
                                        calendar, outline, narrative, prioritise or wiki;
                                        --handoff-label renames "Left off" where people read
                                        a card's handoff, --handoff-prompt(-file) is what the
                                        AI is told when it drafts one ("" for the defaults)
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
    handoff <id>                        where the card was left: its handoff and the history
    handoff <id> --next "the one next step" [--body TEXT | --file F | --body -]
                                        leave a handoff for whoever picks the card up next
                                        (write one whenever you stop with it unfinished)
    handoff <id> --clear                clear it (the history keeps that it was cleared)
    timeline <id>                       the lists a card sat in, its waits and its jobs:
                                        when, for how long and who moved it
    wait <id> "what you need" [--on EMAIL] [--choice X]... [--job ID]
                                        wait on a person: flags the card waiting and asks on
                                        it (on anyone without --on); the job is
                                        $SLIPDOCK_JOB_ID unless --job names one
    wait <id> --withdraw                withdraw the card's open wait
    answer <id> ["text"] [--choice N]   answer the card's open wait, in words or by choice
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
    deploy run [--env E] [--tag T] [--dir D] [--dry-run] -- <command…>
                                                   record a deploy around your deploy command (in
                                                   CI): asks the board for the environment's last
                                                   deployed sha, sends the commits since it (git log
                                                   in --dir, default .), runs the command, records
                                                   succeeded/failed from its exit code and exits
                                                   with it. A rollback (HEAD behind the last deploy)
                                                   says so; a shallow clone is deepened or the fix is
                                                   named. Needs $SLIPDOCK_DEPLOY_TOKEN (and
                                                   $SLIPDOCK_URL); env defaults to production
    deploy start [--env E] [--tag T] [--sha S] [--dry-run]
                                                   the same in two steps: prints the deploy's id…
    deploy finish --status succeeded|failed [--id N]
                                                   …and records how it ended (id from --id or
                                                   $SLIPDOCK_DEPLOY_ID)
    deploy last [--env E]                          the environment's last succeeded deploy
    deploy backfill --from-tags [--env E] [--pattern 'v*'] [--dir D] [--dry-run]
                                                   record past releases: each tag (oldest first) as
                                                   a succeeded deploy at its date, with the commits
                                                   since the tag before. Running it again records
                                                   nothing twice
    deploy setup <board> [--ci github|gitlab|shell] [--env production,staging]
                 [--card-ref-pattern RE] [--prompt]
                                                   track a board's deploys: turns its delivery
                                                   metrics on, issues its deploy token (shown once)
                                                   and prints the CI step to paste; --prompt prints
                                                   a prompt for Claude Code in the repo instead and
                                                   changes nothing
    deploy token <board> [--revoke]                issue (or replace) the board's deploy token,
                                                   shown once — it records deploys and nothing
                                                   else; --revoke ends it. Owner only, API token
    incident-of <card> <deploy-id> | --clear       say which deploy an incident card was caused
                                                   by (that deploy counts as a failed change)
    runner new <board> [name] --pool P [--scenario server|windows|loop|cloud|chatgpt]
               [--agent claude|codex|custom] [--command CMD] [--kind K] [--cwd DIR]
               [--permission-mode M] [--timeout SECONDS] [--service auto|systemd|launchd|none]
               [--where desktop|cloud] [--repo owner/repo]
               [--column LIST [--top] [--[no-]wait-while-doing] [--requeue-stuck N]] [--alert]
               [--verbosity nothing|quiet|normal|verbose] [--instructions TEXT]
               [--before-job CMD] [--after-job CMD] [--hooks prompt|hook]
               [--[no-]in-progress] [--[no-]assign] [--[no-]commit] [--[no-]push]
               [--[no-]move-done] [--[no-]complete] [--[no-]percent-100]
               [--no-slipdock-tools] [--mcp-servers A,B] [--install-name NAME]
                                                   connect a runner: prints exactly what to paste
                                                   (and, for server/windows, its token, once);
                                                   --column adds a rule sending that list's cards
                                                   (--top: its top card, one at a time, in order;
                                                   its jobs wait while anything is in progress
                                                   unless --no-wait-while-doing; a card its
                                                   job leaves in progress goes back on top
                                                   --requeue-stuck times, 1 by default, then
                                                   is flagged blocked); --alert adds a rule
                                                   raising an alert when a job of the pool
                                                   times out or its card is put back or
                                                   given up on
                                                   a claude runner may use the Slipdock MCP tools
                                                   (servers claude_ai_Slipdock, slipdock) unless
                                                   --no-slipdock-tools; a job does nothing to
                                                   its card or repo unless told: --in-progress,
                                                   --assign, --commit, --push (needs --commit),
                                                   --move-done, --complete, --percent-100;
                                                   server/windows runners are installed under a
                                                   name of their own (default <board>-<pool>),
                                                   so one machine runs several: --install-name
    runner show <board> <runner>                   one runner in full: who made it, its job now,
                                                   how its jobs ended, its latest jobs, its rules
    runner setup <board> <runner> [answers...]     a runner's steps again (token left out); with
                                                   any of runner new's options, saves them and
                                                   prints what changes first
    runner setup <board> <runner> --hook-prompt    a prompt for Claude Code on that machine
                                                   to write its before/after-job hooks
    runner token <board> <runner>                  a new token for a runner, with its steps
    runner rm <board> <runner>                     revoke a runner (its token stops working)
    cancel-job <id>                                stop a job: a queued one at once, a running one
                                                   on the runner's next heartbeat
    claim-job <board> --pool P                     take the next queued job as this session (prints
                                                   "nothing queued" when there is none, or why
                                                   work is held: paused, WIP full…)
    pause <board> [--pool P] --reason "…"          hold the board tree's runner work (or one
                                                   pool's): nothing is claimed and no list_top
                                                   rule sends a card; running jobs finish.
                                                   The board owner's
    resume <board> [--pool P]                      let exactly that pause off again (a person's:
                                                   refused when run under an agent)
    job-progress <id> [--message NOTE]             renew the job's lease (a session holds it 20 min); the
                                                   note is also a comment on the card (--message - reads
                                                   it from stdin). Prints ok or cancel
    finish-job <id> --status done|failed|cancelled|timeout [--summary S]
                                                   end a job this session claimed
    finish-job <id> --status waiting --needs "Q" [--choice X]... [--on EMAIL]
                                                   ask a person and park the job in one step;
                                                   the answer sends the card again
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
    page_card_features: :boolean,
    show_pulse: :boolean,
    # `slipdock deploy` (#1134).
    env: :string,
    sha: :string,
    revoke: :boolean,
    from_tags: :boolean,
    ci: :string,
    prompt: :boolean,
    incident_tag: :string,
    hotfix_hours: :integer,
    handoff_label: :string,
    handoff_prompt: :string,
    handoff_prompt_file: :string,
    card_ref_pattern: :string,
    pattern: :string,
    delivery_metrics: :boolean,
    automation_wip: :boolean,
    default_view: :string,
    sprints: :boolean,
    clear: :boolean,
    # `slipdock handoff <id> --next …`.
    next: :string,
    simple: :boolean,
    days: :integer,
    # `slipdock garden <board> --run --check K`, `garden apply <id> --keep N --choice C`.
    run: :boolean,
    check: :string,
    keep: :string,
    # `garden apply <id> --choice C`; `wait <id> … --choice X --choice Y`.
    choice: :keep,
    # `slipdock wait <id> --withdraw`, `--job ID`, and `--on EMAIL` (read
    # as `--wait-on`, since `--on` is a switch elsewhere: see `main/1`).
    withdraw: :boolean,
    job: :string,
    wait_on: :string,
    needs: :string,
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
    since: :integer,
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
    # Each edge of a card's front in its own colour (#1209).
    border: :string,
    border_top: :string,
    border_right: :string,
    border_bottom: :string,
    border_left: :string,
    no_border: :boolean,
    icon: :string,
    no_icon: :boolean,
    top: :boolean,
    bottom: :boolean,
    index: :integer,
    off: :boolean,
    # `slipdock snooze <id> mon --note T --notify`, `slipdock cards B --snoozed only`.
    note: :string,
    notify: :boolean,
    snoozed: :string,
    # `slipdock cards B --stuck --driver agent` (#1117).
    stuck: :boolean,
    driver: :string,
    # `slipdock repeat <id> "every mon" --at 07:00 --lead 2 --ends DATE|--count N`.
    at: :string,
    lead: :integer,
    tz: :string,
    on_missed: :string,
    ends: :string,
    count: :integer,
    skip: :boolean,
    pause: :boolean,
    resume: :boolean,
    read: :boolean,
    comment: :boolean,
    write: :boolean,
    wip: :integer,
    category: :string,
    kind: :keep,
    label: :string,
    hide_on_card: :boolean,
    replace: :boolean,
    wait: :boolean,
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
    recent: :boolean,
    note_tag: :string,
    also: :keep,
    not_in: :keep,
    summary: :string,
    # `slipdock pause <board> --reason "…"`.
    reason: :string,
    message: :string,
    base_hash: :string,
    section: :string,
    hint: :string,
    in_place: :boolean,
    passphrase_file: :string,
    purge_history: :boolean,
    body: :string,
    file: :string,
    rev: :string,
    against: :string,
    position: :string,
    draft: :boolean,
    publish: :boolean,
    purge: :boolean,
    force: :boolean,
    dry_run: :boolean,
    by: :string,
    per: :string,
    added: :boolean,
    contents: :boolean,
    new_board: :string,
    inside: :boolean,
    with_board: :boolean,
    recordings_folder: :string,
    hotkey: :string,
    append: :string,
    card: :string,
    page: :string,
    dir: :string,
    # `slipdock tools show|install|install-board`: a version other than the latest.
    version: :string,
    out: :string,
    overwrite: :boolean,
    before: :string,
    undone: :boolean,
    format: :string,
    # Meeting capture (`slipdock capture …`).
    audio: :string,
    transcript: :string,
    findings: :string,
    ics: :string,
    when: :string,
    attendees: :string,
    with_parent: :boolean,
    preview: :string,
    replayed: :string,
    rest: :boolean,
    consent: :boolean,
    from_capture: :string,
    conversation: :string,
    drop_transcript: :boolean,
    set: :keep,
    q: :string,
    pool: :string,
    status: :string,
    scenario: :string,
    agent: :string,
    cwd: :string,
    timeout: :integer,
    permission_mode: :string,
    service: :string,
    install_name: :string,
    command: :string,
    where: :string,
    repo: :string,
    verbosity: :string,
    instructions: :string,
    before_job: :string,
    after_job: :string,
    hooks: :string,
    in_progress: :boolean,
    assign: :boolean,
    commit: :boolean,
    push: :boolean,
    move_done: :boolean,
    complete: :boolean,
    percent_100: :boolean,
    slipdock_tools: :boolean,
    wait_while_doing: :boolean,
    requeue_stuck: :integer,
    hook_prompt: :boolean,
    alert: :boolean,
    mcp_servers: :string,
    # `slipdock sync`.
    vault: :string,
    watch: :boolean,
    interval: :integer,
    help: :boolean
  ]

  @doc false
  # The options every command is parsed with.
  def switches, do: @switches

  def main(argv) do
    {opts, args, invalid} =
      OptionParser.parse(wait_on(argv), strict: @switches, aliases: [h: :help, j: :json])

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

  # `slipdock wait <id> "…" --on EMAIL`: everywhere else `--on` is a switch
  # with no value (`automation <id> --on`), so for `wait` it is read as
  # `--wait-on`, which takes one.
  @doc false
  def wait_on([cmd | rest]) when cmd in ["wait", "finish-job"],
    do: [cmd | Enum.map(rest, &if(&1 == "--on", do: "--wait-on", else: &1))]

  def wait_on(argv), do: argv

  # Each area module lists the command names it answers to; the first that
  # claims a name gets every clause of it, so a name must live in one place.
  @areas [
    Auth,
    Admin,
    Boards,
    Garden,
    Automations,
    Runners,
    Wiki,
    Vaults,
    Sync,
    Skills,
    Tools,
    Meetings,
    Deploy
  ]

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

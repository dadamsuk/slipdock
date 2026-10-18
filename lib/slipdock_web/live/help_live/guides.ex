defmodule SlipdockWeb.HelpLive.Guides do
  @moduledoc """
  Help's guides to the app itself: boards, the wiki, sharing, automations,
  Tools and the AI features. Each is one page of short parts; the hub lists the parts so
  a reader can jump straight to one. The part ids here are those anchors, so
  a part's `id` in its page and in `@sections` have to agree (the tests check).
  """
  use SlipdockWeb, :html

  import SlipdockWeb.HelpLive.Components

  @sections [
    %{
      slug: "boards",
      title: "Boards",
      icon: "hero-view-columns",
      intro:
        "Boards hold lists and lists hold cards. Any card can have subcards of its own, " <>
          "so a board can be a plan, a backlog, a sprint or a roadmap.",
      parts: [
        {"boards-basics", "Boards, lists and cards"},
        {"boards-subcards", "Subcards and epics"},
        {"boards-views", "Views"},
        {"boards-planning", "Planning"},
        {"boards-fast", "Getting around fast"},
        {"boards-moving", "Templates, moving and archiving"}
      ]
    },
    %{
      slug: "wiki",
      title: "Wiki",
      icon: "hero-book-open",
      intro:
        "Every board has a wiki of Markdown pages for how things work and what was decided " <>
          "and why. It uses the board's own permissions.",
      parts: [
        {"wiki-why", "What it's for"},
        {"wiki-writing", "Writing"},
        {"wiki-linking", "Linking and live queries"},
        {"wiki-organising", "Organising"},
        {"wiki-history", "History"},
        {"wiki-vaults", "Vaults and your own folder"},
        {"wiki-publishing", "Publishing"}
      ]
    },
    %{
      slug: "sharing",
      title: "Sharing",
      icon: "hero-user-plus",
      intro:
        "Share a board, a single card, a saved view, or a wiki page or folder with a person " <>
          "or a group. Give each one read-only, comment or edit access.",
      parts: [
        {"sharing-levels", "Access levels"},
        {"sharing-what", "What you can share"},
        {"sharing-pages", "Wiki pages and folders"},
        {"sharing-groups", "Groups and new people"},
        {"sharing-public", "Public links"}
      ]
    },
    %{
      slug: "automations",
      title: "Automations",
      icon: "hero-arrow-path-rounded-square",
      intro:
        "Rules that act on a board for you: email someone, raise an alert, move or tag a " <>
          "card, call a URL, or send the card to an agent.",
      parts: [
        {"automations-presets", "Ready-made rules"},
        {"automations-words", "Rules in your own words"},
        {"automations-parts", "Triggers, conditions and actions"},
        {"automations-agents", "From an agent"},
        {"automations-alerts", "Alerts"},
        {"automations-limits", "Safety rails"}
      ]
    },
    %{
      slug: "tools",
      title: "Tools",
      icon: "hero-puzzle-piece",
      intro:
        "Ready-made ways of working that people on this server share: a board Slipdock " <>
          "builds for you, and the skills that teach your assistant to use it.",
      parts: [
        {"tools-what", "What a Tool is"},
        {"tools-install", "Installing one"},
        {"tools-safety", "Before you install"},
        {"tools-upgrade", "New versions"},
        {"tools-publish", "Publishing your own"},
        {"tools-format", "The package"},
        {"tools-listing", "Sharing and listing"}
      ]
    },
    %{
      slug: "ai",
      title: "AI",
      icon: "hero-sparkles",
      intro:
        "Ask about the board in front of you, search everything by meaning, or ask a question " <>
          "and get an answer drawn from every board you can read.",
      parts: [
        {"ai-model", "Before you start"},
        {"ai-board", "Ask about this board"},
        {"ai-search", "Search anywhere"},
        {"ai-ask", "Ask about anywhere"},
        {"ai-which", "Which one to use"},
        {"ai-more", "Elsewhere in the app"}
      ]
    }
  ]

  @slugs Enum.map(@sections, & &1.slug)

  def sections, do: @sections
  def slugs, do: @slugs

  attr :slug, :string, required: true
  attr :current_user, :any, required: true

  # ── Boards ────────────────────────────────────────────────────────────────

  def guide(%{slug: "boards"} = assigns) do
    ~H"""
    <.part title="Boards, lists and cards" id="boards-basics">
      <p>
        A board is a set of lists (columns), and each list holds cards that you drag
        between and within lists. Every board also has a short <strong>code</strong>, such
        as <code>qvm-v1-rem</code>, that names it in links, the API and the CLI.
      </p>
      <p>A card can carry:</p>
      <ul class="list-disc space-y-1 pl-5">
        <li>a Markdown description, a checklist and comments</li>
        <li>a priority from low to critical, a start date and a due date</li>
        <li>flags: flagged, blocked, needs review, waiting, starred</li>
        <li>tags, one or more assignees, a cover colour, web links and attachments</li>
        <li>a timer, with time spent against an estimate</li>
      </ul>
      <p>
        <code>@name</code> in a description or comment mentions someone who can see the
        board, and they get an email. Lists can have a colour, a WIP limit, and their own
        sort order or grouping.
      </p>
    </.part>

    <.part title="Subcards and epics" id="boards-subcards">
      <p>
        Any card can have subcards. It becomes a board of its own, with lists from a
        template, and those subcards can have subcards too, to any depth. A common pattern
        is for top-level cards to be <strong>epics</strong> and their subcards to be the actual tasks.
      </p>
      <p>
        Each card summarises everything beneath it: how many tasks are done, the earliest
        start and latest due date, whether anything below is blocked or overdue, and a
        health state. <.app_link current_user={@current_user} to={~p"/work"}>My work</.app_link>
        lists everything assigned to you across every board and level.
      </p>
      <p>
        Cards can also <strong>depend</strong>
        on each other ("blocked by" and "blocks"). A card waiting on unfinished work shows a
        blocked badge.
      </p>
    </.part>

    <.part title="Views" id="boards-views">
      <p>
        The same cards, shown different ways. Switch between them from the view menu, or press <kbd class="kbd kbd-xs">v</kbd>:
      </p>
      <ul class="list-disc space-y-1 pl-5">
        <li><strong>Board</strong>: lists side by side.</li>
        <li>
          <strong>Swimlanes</strong>: a grid with any attribute on each axis, such as assignee by priority.
        </li>
        <li>
          <strong>Table</strong>: a sortable row per card, with editing in place and CSV export.
        </li>
        <li>
          <strong>Timeline</strong>: a Gantt chart by start and due date, with dependency lines.
        </li>
        <li><strong>Calendar</strong>: a month or week, by due date.</li>
        <li><strong>Outline</strong>: the board as a tree of cards and subcards.</li>
        <li>
          <strong>Narrative</strong>: what happened to the cards over a date range, told as prose.
        </li>
        <li>
          <strong>Prioritise</strong>: a ranked table where priority, votes and scores are edited in place.
        </li>
      </ul>
      <p>
        The filter bar narrows any view by text, tag, priority, flag and due date. A view
        with its filters can be saved, shared, or published as a public link.
      </p>
    </.part>

    <.part title="Planning" id="boards-planning">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          <strong>Sprints</strong>: a sprint board where every card is a sprint, with burndown
          and velocity charts.
        </li>
        <li>
          <strong>Roadmaps</strong>: give lists a category (to do, in progress, done, dropped)
          and a horizon such as Q1 2027; add milestones; colour any view by list, priority,
          health, assignee or tag.
        </li>
        <li>
          <strong>Recurring cards</strong>: <em>Repeat…</em>
          on a card (or <code>every: mon</code>
          in quick add) makes it repeat: daily, weekdays, weekly, monthly on a date or the
          last Friday, yearly, or some days after the last one is done. The next one is a copy
          of the current one, made in your timezone, and one still open has its due date moved
          on rather than another piling up. <em>Duplicate</em>
          makes the same copy by hand.
        </li>
        <li>
          <strong>Snooze</strong>: <em>Snooze…</em>
          on a card, or <kbd>z</kbd>
          over it on the board (<kbd>z</kbd> <kbd>z</kbd>
          is tomorrow), hides a card that isn't actionable yet until a day, then brings it back
          at the top of its list. Each list's foot counts what is snoozed in it and shows them,
          faded, on a click. <code>snooze: mon</code>
          in quick add does it as you add the card.
        </li>
        <li>
          <strong>Tidy up…</strong>
          in the board's menu looks the board, and every board beneath it, over for rot: epics
          whose work is all done but still open, cards in Done never ticked off, cards stuck in
          progress, epics with no next step, long-overdue cards, likely duplicates, wiki pages
          nothing links to and links with a typo. Each comes with the evidence and a proposed fix
          to apply or dismiss; a dismissal is remembered, and an applied fix can be undone. Board
          settings → <em>Gardening</em>
          picks the checks and how long before something counts.
        </li>
        <li>
          <strong>Status updates</strong>: on track, at risk or off track, with a note, shown
          beside the health the board works out for itself.
        </li>
        <li>
          <strong>Custom fields</strong>
          (numbers, ratings, choices, dates, text) and formula fields with RICE and ICE presets.
        </li>
        <li>
          <strong>Budget voting</strong>: everyone spends a set number of votes across the board.
        </li>
        <li>
          <strong>Typed links</strong>
          between cards on any board, so a goal card can collect the work contributing to it.
        </li>
      </ul>
    </.part>

    <.part title="Getting around fast" id="boards-fast">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          <strong>Quick add</strong>: press <kbd class="kbd kbd-xs">c</kbd>
          or use the header box and type a line such as "call the printers about the banners
          friday, urgent". It becomes a card on your default board.
        </li>
        <li>
          <kbd class="kbd kbd-xs">Ctrl</kbd>-<kbd class="kbd kbd-xs">P</kbd>
          opens the command palette, and <kbd class="kbd kbd-xs">Ctrl</kbd>-<kbd class="kbd kbd-xs">O</kbd>
          opens any card by its title or number. Press <kbd class="kbd kbd-xs">?</kbd>
          for every keyboard shortcut.
        </li>
        <li>
          <strong>Favourites</strong>: heart a board, list, card or saved view to keep it two
          taps away.
        </li>
        <li>
          On a phone, the board becomes one list at a time, with navigation and quick add in thumb reach.
        </li>
      </ul>
    </.part>

    <.part title="Templates, moving and archiving" id="boards-moving">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          <.app_link current_user={@current_user} to={~p"/templates"}>Templates</.app_link>
          are named sets of lists for new boards and sub-boards.
        </li>
        <li>
          A card moves to another board with its subcards, from the same menu that moves it between lists.
        </li>
        <li>
          Archiving a card or a whole board puts it away without deleting anything, and it can be restored.
        </li>
        <li>
          Boards can be imported from Trello or another Slipdock server, and everything you
          have can be exported, under <.app_link current_user={@current_user} to={~p"/account/data"}>Account → Import & export</.app_link>.
        </li>
      </ul>
    </.part>
    """
  end

  # ── Wiki ──────────────────────────────────────────────────────────────────

  def guide(%{slug: "wiki"} = assigns) do
    ~H"""
    <.part title="What it's for" id="wiki-why">
      <p>
        The board shows what you're doing. The wiki holds the things a card is a poor home
        for: how something works, what was decided and why, and runbooks and specs. Each
        board has one, from the view menu. It follows the board's permissions and is
        covered by the same API, so an agent can write documentation the same way a person does.
        <.app_link current_user={@current_user} to={~p"/wiki"}>Wiki</.app_link>
        shows every board's wiki at once, each as a top-level folder.
      </p>
    </.part>

    <.part title="Writing" id="wiki-writing">
      <p>
        Pages are Markdown, edited with a live preview, as in Obsidian: each line shows
        formatted until your cursor is on it. Paste or drop an image to attach it. What's
        saved is exactly the Markdown you typed.
      </p>
      <p>
        Every page has a <strong>code</strong>, such as <code>W-31</code>, that never changes
        even when the page is renamed. That makes it the right thing to use in a commit
        message or a link.
      </p>
    </.part>

    <.part title="Linking and live queries" id="wiki-linking">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          <code>[[Page title]]</code> links to a page. Each page lists the pages that link to it.
        </li>
        <li>A card reference shows as a live chip with the card's current state.</li>
        <li>
          A <code>```slipdock</code>
          block is a live query, such as "open cards tagged docs". It's answered each time
          the page is read, using the reader's own permissions.
        </li>
        <li><strong>Wanted pages</strong> lists links to pages nobody has written yet.</li>
        <li>A page can be pinned to a card, as the page about that card.</li>
      </ul>
    </.part>

    <.part title="Organising" id="wiki-organising">
      <p>
        A page has two independent places. Its <strong>parent page</strong>
        says what it is part of, such as the rollback section of a runbook. Its
        <strong>folder</strong>
        says where it is kept, such as Design, Contracts or Meetings. You don't have to
        invent a page just to hold others.
      </p>
      <p>
        Folders and pages can have an icon and a colour. Pages can start from a template, and
        stay drafts until they're ready.
      </p>
    </.part>

    <.part title="History" id="wiki-history">
      <p>
        Every save is kept as a revision, recording who made it, how (the web, the CLI or
        an agent) and why. You can compare any two revisions, or put a page back to an
        earlier one. The revert is itself a new revision, so nothing is lost.
      </p>
    </.part>

    <.part title="Vaults and your own folder" id="wiki-vaults">
      <p>
        A <strong>vault</strong>
        combines several boards' wikis into one folder tree of your own, for example a
        handbook at <code>/</code>
        and a project's notes at <code>/Projects</code>. <code>slipdock sync</code>
        mirrors a vault to a folder on your computer and keeps the two in step, so you can
        write in Obsidian or any editor that works on a folder of Markdown. An existing
        Obsidian vault can be imported. See <.link patch={~p"/help/agents/cli"} class="link">the CLI</.link>.
      </p>
    </.part>

    <.part title="Publishing" id="wiki-publishing">
      <p>
        A page can be published at a public, read-only link that needs no account. Its live
        queries are answered at the moment you publish, and its links become plain text,
        since an anonymous reader has no permissions to follow them. Publishing again
        refreshes it, and you can withdraw it at any time.
      </p>
    </.part>
    """
  end

  # ── Sharing ───────────────────────────────────────────────────────────────

  def guide(%{slug: "sharing"} = assigns) do
    ~H"""
    <.part title="Access levels" id="sharing-levels">
      <p>
        Every board has one <strong>owner</strong>: the person who made it. Anything you share,
        you share at one of three levels:
      </p>
      <ul class="list-disc space-y-1 pl-5">
        <li><strong>Read only</strong>: can see, but not change anything.</li>
        <li>
          <strong>Can comment</strong>: a reader who can also comment, post status updates
          and vote, but not change the card itself.
        </li>
        <li><strong>Can edit</strong>: can change cards and pages.</li>
      </ul>
      <p>
        Only the owner can rename or delete a board. The server enforces these levels,
        and they apply the same way to the API, the CLI and agents.
      </p>
    </.part>

    <.part title="What you can share" id="sharing-what">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          <strong>A board</strong>, from its settings: covers every card on it and every
          sub-board inside them. A board shared with you sits on your board list, marked with who shared it.
        </li>
        <li>
          <strong>A single card</strong>, from its window: the person sees that card and nothing
          else on the board. It's listed under "Cards shared with you" on their home page.
        </li>
        <li>
          <strong>A saved view</strong>, from the Views menu: the person sees the board only
          through that view, and only the cards it selects.
        </li>
        <li><strong>A wiki page or folder</strong>: see below.</li>
      </ul>
    </.part>

    <.part title="Wiki pages and folders" id="sharing-pages">
      <p>
        <strong>Share…</strong>
        on a page's or folder's menu shares it with someone who has no reason to see the rest
        of the board. A folder shares everything filed in it, to any depth, and a page brings
        the images and files it embeds. What's shared with you appears under <strong>Shared with me</strong>, below your wiki tree, without showing the board it's on.
      </p>
      <p>
        Someone with edit access to a shared folder can write and rearrange inside it, but
        can't delete anything, move it out of the share, or share it on.
      </p>
    </.part>

    <.part title="Groups and new people" id="sharing-groups">
      <p>
        <.app_link current_user={@current_user} to={~p"/groups"}>Groups</.app_link>
        are named sets of people you can share with in one go. Sharing with an email address
        that has no account usually invites that person. Whether that's allowed, and who may
        register at all, is up to the server's admin.
      </p>
      <p>
        Signing in needs no password: you get a one-time link and code by email, or you can
        use a passkey once you've added one.
      </p>
    </.part>

    <.part title="Public links" id="sharing-public">
      <p>
        For readers without an account, a <strong>saved view</strong>
        or a <strong>wiki page</strong>
        can be published at a public, read-only link. A published view is live; a published
        page is its text plus a snapshot of its query answers. Unpublishing withdraws the link
        immediately.
      </p>
    </.part>
    """
  end

  # ── Automations ───────────────────────────────────────────────────────────

  def guide(%{slug: "automations"} = assigns) do
    ~H"""
    <.part title="Ready-made rules" id="automations-presets">
      <p>
        Every board has an <strong>Automations</strong>
        panel, in the board's menu, for its owner. It opens with a gallery of the rules most
        boards want, each set up with a short form. These need no AI model:
      </p>
      <ul class="list-disc space-y-1 pl-5">
        <li>
          <strong>Follow</strong>: new cards, a list, one card, comments, a field changing, cards assigned to you.
        </li>
        <li><strong>Remind</strong>: due soon, overdue, or untouched for a number of days.</li>
        <li>
          <strong>Tidy</strong>: complete cards that reach Done, archive old ones, let a tag set the
          priority, and a <em>Weekly tidy-up</em>
          that looks the board over and alerts you to what <em>Tidy up…</em>
          found, changing nothing.
        </li>
        <li>
          <strong>Connect</strong>: call a URL on every change (a <.link
            patch={~p"/help/agents/webhooks"}
            class="link"
          >webhook</.link>).
        </li>
      </ul>
    </.part>

    <.part title="Rules in your own words" id="automations-words">
      <p>Or describe a rule in a sentence:</p>
      <.snippet
        id="help-automations-example"
        text="automatically move cards in In Progress to Backlog if they've not been touched for 7 days"
      />
      <p>
        A model turns the sentence into a rule once, and the app runs that rule from then on.
        The panel reads the rule back to you as a sentence, so you can check it says what you
        meant. Anything the model makes up that the app doesn't support is rejected before the
        rule is saved.
      </p>
    </.part>

    <.part title="Triggers, conditions and actions" id="automations-parts">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          <strong>Triggers</strong>: a card is created, arrives in a list, moves, changes, is
          completed, assigned, tagged, flagged or commented on; or, on a clock, it's
          untouched, due soon, overdue, starting soon, or it's a time of day.
        </li>
        <li>
          <strong>Conditions</strong>: the list, priority, tag, assignee, flag, dates, health,
          age, and more.
        </li>
        <li>
          <strong>Actions</strong>: send an email, raise an alert, move, set priority, tag,
          flag, assign, comment, set dates, complete or archive, add checklist items, create a
          card, start a wiki page, call a URL, or send the card to a
          <.link patch={~p"/help/agents/runners"} class="link">runner</.link>
          for an AI agent to work.
        </li>
      </ul>
      <p>
        Text in an action can include details of the card, such as <code>{"{{card.title}}"}</code>
        or <code>{"{{card.url}}"}</code>.
      </p>
    </.part>

    <.part title="From an agent" id="automations-agents">
      <p>
        The board's owner can also have an AI agent list, add, change, switch off and delete
        rules, over <.link patch={~p"/help/agents/mcp"} class="link">MCP</.link>
        or with the <.link patch={~p"/help/agents/cli"} class="link">CLI</.link>. An agent can
        write a rule exactly, start from a ready-made one, or describe it in a sentence as you would.
      </p>
    </.part>

    <.part title="Alerts" id="automations-alerts">
      <p>
        An alert is the quiet option: no email, just a line in the header of every page,
        with a count and how urgent it is. Each person dismisses their own alerts, and you
        only see alerts from boards you can read.
      </p>
    </.part>

    <.part title="Safety rails" id="automations-limits">
      <ul class="list-disc space-y-1 pl-5">
        <li>Automation email only goes to people who can read the board.</li>
        <li>
          One rule's changes can set off another, but the chain stops after three steps, so
          two rules can't bounce a card back and forth forever.
        </li>
        <li>
          Each rule shows how often it has run and what went wrong last time. Rules can be
          switched off, reworded or run by hand.
        </li>
        <li>Recent callbacks lists what each call to a URL got back.</li>
      </ul>
    </.part>
    """
  end

  # ── Tools ─────────────────────────────────────────────────────────────────

  def guide(%{slug: "tools"} = assigns) do
    ~H"""
    <.part title="What a Tool is" id="tools-what">
      <p>
        A Tool is a ready-made way of working that somebody on this server has packaged up:
        a board with its lists, folders, tags, wiki pages and rules already in place, the
        skills that tell your AI assistant how to use that board, and the docs that explain
        it. Job Scan, an automated job search, is one.
      </p>
      <p>
        You'll find the Tools you can use under
        <.link navigate={~p"/tools"} class="link">Tools</.link>
        in the menu: your own, the ones shared with you, and the ones listed for everyone here.
      </p>
    </.part>

    <.part title="Installing one" id="tools-install">
      <p>
        Open a Tool and pick the assistant you use — Claude on the website or app, Claude
        Code, or ChatGPT — and follow its steps. They come to the same thing: connect your
        assistant to Slipdock, add the Tool's skills to it, and then start a chat and say
        <strong>“Set up …&nbsp;for me.”</strong>
      </p>
      <p>
        The assistant then asks Slipdock to build the Tool's board, which it does the same
        way for everybody, and talks you through filling it in. You can also build the board
        yourself with <strong>Make the board</strong> on the Tool's page. Either way you get
        one board per Tool: asking again finds the board you already have.
      </p>
    </.part>

    <.part title="Before you install" id="tools-safety">
      <p>
        A Tool's skills are instructions your assistant follows with your access to your
        boards. So the Tool's page shows everything before you install it: the board it will
        build, the files it adds, and every skill file in full. Read them as you would
        anything you let act for you.
      </p>
      <ul class="list-disc space-y-1 pl-5">
        <li>Installing touches only the new board it makes, never your other boards.</li>
        <li>A published version never changes. A new version has a new number.</li>
        <li>
          A Tool listed for everyone has had that version approved by an admin; a newer
          version isn't shown to you until it has been approved too.
        </li>
      </ul>
    </.part>

    <.part title="New versions" id="tools-upgrade">
      <p>
        When a Tool you've installed has a newer version, its page offers <strong>Upgrade the board</strong>. Upgrading adds what your board is missing — new
        lists, folders, tags, pages, rules and files — and leaves everything you've changed
        exactly as it is. A page you've edited is never overwritten. Update the skills the
        same way you added them.
      </p>
    </.part>

    <.part title="Publishing your own" id="tools-publish">
      <p>
        Put the Tool in a folder (see the next part) and publish it with the <.link
          patch={~p"/help/agents/cli"}
          class="link"
        >CLI</.link>:
      </p>
      <.snippet id="help-tools-publish" text="slipdock tools publish ./my-tool" />
      <p>
        Its page then appears under Tools for you alone. Publish again with a higher
        <code>version</code>
        for each change; the same version twice is refused.
      </p>
    </.part>

    <.part title="The package" id="tools-format">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          <code>tool.json</code>: <code>name</code>
          (lowercase, unique on this server), <code>version</code>
          (like 1.0.0), <code>summary</code>, and optionally <code>title</code>, <code>author</code>,
          <code>requires</code>
          and <code>files</code>.
        </li>
        <li><code>README.md</code>: the docs, shown as the Tool's page.</li>
        <li>
          <code>board.json</code>: the board — <code>lists</code>
          (each with a <code>role</code>:
          ready, backlog, doing, done or dropped), <code>folders</code>, <code>tags</code>,
          <code>pages</code>
          (skeletons, which may use <code>{"{{board.name}}"}</code>
          and <code>{"{{today}}"}</code>) and <code>automations</code>
          (ready-made rules by
          preset name).
        </li>
        <li>
          <code>skills/&lt;name&gt;/SKILL.md</code>, with front matter naming the skill and saying
          when to use it, and anything else the skill needs beside it.
        </li>
        <li>
          <code>files/</code>: each listed in <code>tool.json</code>
          as going on the <code>board</code>
          (into a Tool folder in its wiki) or <code>local</code>
          (beside
          a skill, on the installer's machine).
        </li>
      </ul>
      <p>
        Slipdock checks all of it when you publish and says exactly what is wrong — a list
        meant to be the ready list that wouldn't be read as one, a rule on a list that
        doesn't exist, a file not listed in <code>tool.json</code>.
      </p>
    </.part>

    <.part title="Sharing and listing" id="tools-listing">
      <p>
        On your Tool's page, share it with people by email; they can read it and install it.
        To offer it to everyone on this server, ask an admin to list it. Admins approve one
        version at a time, under <strong>Tool listings</strong>, so each new version is
        approved before it reaches anyone you haven't shared it with.
      </p>
    </.part>
    """
  end

  # ── AI ────────────────────────────────────────────────────────────────────

  def guide(%{slug: "ai"} = assigns) do
    ~H"""
    <.part title="Before you start" id="ai-model">
      <p>
        The AI features need a model to talk to. Each person brings their own, under <.app_link
          current_user={@current_user}
          to={~p"/account/settings"}
        >Account → Settings → AI model</.app_link>:
        either an OpenRouter key, billed to your OpenRouter account, or an OpenAI-compatible
        endpoint of your own (LM Studio, Ollama and the like), which keeps everything on your network.
      </p>
      <p>
        Without one, those features stay hidden. Nothing is sent to a model unless you ask,
        and every answer is limited to what you're allowed to read.
      </p>
    </.part>

    <.part title="Ask about this board" id="ai-board">
      <p>
        The <strong>Chat</strong>
        button in the header of every board page, and of My work, opens a conversation about
        what's on screen (or press <kbd class="kbd kbd-xs">a</kbd>). The model is given the
        board, its lists, tags and people, the cards the current view shows, the board's wiki
        pages, and the open card in full. An open card also has
        <strong>Ask AI about this card</strong>
        at the bottom.
      </p>
      <p>
        Switch on <strong>Edit</strong>
        and a request such as "set this due next Tuesday and pick a suitable priority" becomes
        a list of changes. Nothing happens until you press <strong>Apply</strong>, and each
        change is checked against your permissions first.
      </p>
    </.part>

    <.part title="Search anywhere" id="ai-search">
      <p>
        <.app_link current_user={@current_user} to={~p"/search"}>Search</.app_link>
        covers every board at once and matches by <em>meaning</em>, not exact words. "The
        thing that was blocked on legal" finds the card whose comment said "waiting on the
        contract review". It searches cards, comments, status updates, meeting transcripts
        and wiki pages.
      </p>
      <p>
        Each result shows the passage that matched, linked straight to that comment or
        section. Results update as you type. Star a query to save it, and filter to one board
        or include archived cards. The server keeps the search index, so you don't need your
        own model for this.
      </p>
    </.part>

    <.part title="Ask about anywhere" id="ai-ask">
      <p>
        <.app_link current_user={@current_user} to={~p"/ask"}>Ask</.app_link>
        answers a question in plain language, using every board you can read. Unlike chat,
        it isn't given a page. Instead it uses tools to find what it needs: searching by
        meaning, counting a board's cards list by list, describing a board, listing one
        person's work, reading the activity log ("what changed this week?"), and reading your alerts.
      </p>
      <p>
        It shows which searches it ran and links every card it read, so you can check its
        answer. It only reads; it never changes anything.
      </p>
    </.part>

    <.part title="Which one to use" id="ai-which">
      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th></th>
              <th>Looks at</th>
              <th>Gives you</th>
              <th>Can change things</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <th scope="row">Ask about this board</th>
              <td>The page you're on</td>
              <td>A conversation</td>
              <td>Yes, in Edit mode, after you approve</td>
            </tr>
            <tr>
              <th scope="row">Search anywhere</th>
              <td>Every board you can read</td>
              <td>Cards and pages, best match first</td>
              <td>No</td>
            </tr>
            <tr>
              <th scope="row">Ask about anywhere</th>
              <td>Every board you can read</td>
              <td>An answer, with its sources</td>
              <td>No</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p>
        The toggle at the top of Search and Ask carries what you typed across, so going from
        "I searched" to "now ask the same thing" takes one click.
      </p>
    </.part>

    <.part title="Elsewhere in the app" id="ai-more">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          <strong>Narrative</strong>: Generate narrative writes up a date range, from a one-liner to a stakeholder update.
        </li>
        <li>
          <strong>Quick add</strong>: reads a line of plain English into a card with dates, priority and tags.
        </li>
        <li>
          <strong>Automations</strong>: describe a rule in a sentence (see <.link
            patch={~p"/help/automations"}
            class="link"
          >Automations</.link>).
        </li>
        <li>
          To use an AI agent of your own, such as Claude or ChatGPT, see <.link
            patch={~p"/help/agents"}
            class="link"
          >Agents</.link>.
        </li>
      </ul>
    </.part>
    """
  end
end

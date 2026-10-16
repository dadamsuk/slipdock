defmodule SlipdockWeb.HelpLive.Agents do
  @moduledoc """
  Help › Agents: the ways an AI agent can work with this server. The overview
  introduces and compares them; each has a page of its own. Addresses on them
  are this server's own, worked out from the request as the Set up an agent
  tab does, so what is copied from here works here.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.HelpLive.Components

  # The ways in, in the order the page presents them: what needs least first.
  @topics [
    %{
      slug: "guide",
      title: "The agent guide & HTTP API",
      short: "Guide & API",
      icon: "hero-document-text",
      intro:
        "Paste one prompt that points the agent at this server's guide. The guide " <>
          "explains the boards and gives a curl line for every call, so any agent " <>
          "that can run a shell command can start straight away.",
      when:
        "You want the quickest start, or the agent can make HTTP requests but you " <>
          "can't or won't install anything."
    },
    %{
      slug: "mcp",
      title: "MCP server",
      short: "MCP",
      icon: "hero-puzzle-piece",
      intro:
        "This server is also an MCP server. Add it as a connector and the agent " <>
          "gets tools to read and write boards, cards and wiki pages, with no shell needed.",
      when:
        "You use claude.ai, the Claude desktop or mobile apps, ChatGPT, or any " <>
          "other client that speaks MCP. It's also a tidy option for Claude Code."
    },
    %{
      slug: "cli",
      title: "The slipdock CLI",
      short: "CLI",
      icon: "hero-command-line",
      intro:
        "A command-line client that wraps the whole API. It keeps the token for you, " <>
          "reads better in a transcript than raw curl, and does a few things nothing else does.",
      when:
        "The agent works in a terminal on your machine, or you want what only the " <>
          "CLI has: syncing a vault to a folder, files over 10 MB, imports and exports."
    },
    %{
      slug: "skills",
      title: "Skills",
      short: "Skills",
      icon: "hero-academic-cap",
      intro:
        "Longer instructions installed where the agent looks for them. They cover " <>
          "judgement more than syntax: what to pick up next, what belongs on the wiki, " <>
          "and how to work a backlog unattended.",
      when:
        "You'll work with an agent here regularly and want it to follow the board's " <>
          "conventions without being told. Use them alongside the CLI or MCP."
    },
    %{
      slug: "runners",
      title: "Runners",
      short: "Runners",
      icon: "hero-cpu-chip",
      intro:
        "Reverses the direction: the board sends cards to an agent on a machine of " <>
          "yours when something happens, such as a card arriving in a list. The agent " <>
          "works the card and reports back.",
      when:
        "You want work to start without anyone opening a session, such as a list " <>
          "that agents empty on their own, or a queue several machines share."
    },
    %{
      slug: "webhooks",
      title: "Webhooks",
      short: "Webhooks",
      icon: "hero-bolt",
      intro:
        "An automation can call a URL of yours when something happens on a board. " <>
          "The request carries the card's details, so your own service can react to it.",
      when:
        "You have your own service or workflow tool (n8n, Zapier, an agent behind " <>
          "an HTTP endpoint) and it only needs to know when something happened."
    }
  ]

  @slugs Enum.map(@topics, & &1.slug)

  # The comparison: each row is a question, each cell the answer for one way
  # in, in @topics order. {mark, note}: :yes, :some or :no, and the words that
  # make the mark honest.
  @features [
    {"Install something on the agent's machine",
     [
       {:no, "curl is enough"},
       {:no, "add the address"},
       {:yes, "an escript (Erlang)"},
       {:some, "optional files"},
       {:yes, "a small service"},
       {:no, "nothing"}
     ]},
    {"Works from claude.ai, ChatGPT and the phone apps",
     [
       {:no, "needs a shell"},
       {:yes, "as a connector"},
       {:no, "needs a shell"},
       {:some, "ChatGPT zips"},
       {:some, "scheduled Claude, ChatGPT"},
       {:no, "—"}
     ]},
    {"Read boards and cards, and search",
     [
       {:yes, ""},
       {:yes, ""},
       {:yes, ""},
       {:yes, "through the CLI or MCP"},
       {:some, "the card it was sent"},
       {:some, "the card's fields"}
     ]},
    {"Change cards: move, comment, complete",
     [
       {:yes, ""},
       {:yes, ""},
       {:yes, ""},
       {:yes, "through the CLI or MCP"},
       {:yes, "reports back on its card"},
       {:no, "one way only"}
     ]},
    {"Read and write wiki pages",
     [
       {:yes, ""},
       {:yes, ""},
       {:yes, ""},
       {:yes, "and when to"},
       {:some, "through the CLI or MCP"},
       {:no, ""}
     ]},
    {"Attach and download files",
     [
       {:yes, ""},
       {:yes, "up to 10 MB each"},
       {:yes, "up to 250 MB, recordings too"},
       {:yes, "through the CLI or MCP"},
       {:no, ""},
       {:no, ""}
     ]},
    {"List and change a board's automations",
     [
       {:yes, ""},
       {:yes, "the board's owner"},
       {:yes, ""},
       {:yes, "through the CLI or MCP"},
       {:no, ""},
       {:no, ""}
     ]},
    {"Connect runners",
     [
       {:yes, ""},
       {:no, ""},
       {:yes, ""},
       {:some, "through the CLI"},
       {:some, "from the board"},
       {:no, ""}
     ]},
    {"Mirror a vault to a local folder",
     [
       {:no, ""},
       {:no, ""},
       {:yes, "slipdock sync"},
       {:no, ""},
       {:no, ""},
       {:no, ""}
     ]},
    {"The board starts the work",
     [
       {:no, "you start it"},
       {:some, "claim_job in a loop"},
       {:some, "claim-job in a loop"},
       {:some, "slipdock-loop"},
       {:yes, "pushed from a rule"},
       {:yes, "on any rule"}
     ]},
    {"Runs with nobody watching",
     [
       {:some, "if you schedule it"},
       {:some, "if you schedule it"},
       {:some, "if you schedule it"},
       {:yes, "slipdock-loop"},
       {:yes, ""},
       {:yes, ""}
     ]},
    {"Can be limited to read-only",
     [
       {:yes, "read-only token"},
       {:yes, "approve read-only"},
       {:yes, "read-only token"},
       {:yes, "follows the token"},
       {:some, "its token takes jobs only"},
       {:no, "—"}
     ]},
    {"Signs in with",
     [
       {:text, "approve a code, or a token"},
       {:text, "the browser (OAuth), or a token"},
       {:text, "slipdock auth"},
       {:text, "whatever the agent uses"},
       {:text, "a runner token"},
       {:text, "nothing: it calls out"}
     ]}
  ]

  def topics, do: @topics
  def slugs, do: @slugs
  def features, do: @features

  # ── The overview ──────────────────────────────────────────────────────────

  def overview(assigns) do
    ~H"""
    <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
      <h1 class="text-2xl font-bold tracking-tight">Working with an AI agent</h1>
      <p class="mt-2 text-sm text-base-content/70">
        Claude, ChatGPT, Codex, Cursor, or a script you wrote can all read and work
        these boards. The agent runs wherever you already use it (your laptop, a cloud
        session, a phone app) and talks to this server over the web, as your browser does.
        It never runs on the server, and you don't need access to the machine the server
        runs on.
      </p>
      <p class="mt-2 text-sm text-base-content/70">
        There are several ways to connect, depending on where the agent runs and who starts
        the work. Most people need only one or two. Each one is introduced briefly below,
        followed by a table comparing them; every way has its own page with more detail.
      </p>
      <p class="mt-3 text-sm">
        <.link :if={@current_user} navigate={~p"/account/agent"} class="link font-medium">
          Set up an agent with your details filled in →
        </.link>
        <.link :if={!@current_user} navigate={~p"/login"} class="link font-medium">
          Sign in to set one up →
        </.link>
      </p>
    </section>

    <section id="help-ways" aria-labelledby="help-ways-title">
      <h2 id="help-ways-title" class="mb-3 text-lg font-semibold">The ways in</h2>
      <div class="grid gap-4 sm:grid-cols-2">
        <article
          :for={t <- @topics}
          id={"help-way-#{t.slug}"}
          class="flex flex-col rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
        >
          <h3 class="flex items-center gap-2 font-semibold">
            <.icon name={t.icon} class="size-5 text-primary" /> {t.title}
          </h3>
          <p class="mt-2 text-sm text-base-content/70">{t.intro}</p>
          <p class="mt-2 text-sm">
            <span class="font-medium">Use it when</span>
            <span class="text-base-content/70">{lowercase_first(t.when)}</span>
          </p>
          <.link patch={~p"/help/agents/#{t.slug}"} class="link mt-auto pt-3 text-sm font-medium">
            More about {t.short} →
          </.link>
        </article>
      </div>
    </section>

    <section
      id="help-compare"
      aria-labelledby="help-compare-title"
      class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
    >
      <h2 id="help-compare-title" class="text-lg font-semibold">Side by side</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Skills and runners aren't separate connections. Skills teach an agent that uses
        the CLI or MCP, and a runner's agent reads and writes through one of them too. They
        are listed here because they are what you choose between.
      </p>
      <div class="mt-4 overflow-x-auto">
        <table id="help-compare-table" class="table table-sm min-w-[44rem]">
          <thead>
            <tr>
              <th class="w-48"></th>
              <th :for={t <- @topics} scope="col" class="align-bottom">
                <.link patch={~p"/help/agents/#{t.slug}"} class="link">{t.short}</.link>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{label, cells} <- @features}>
              <th scope="row" class="font-medium">{label}</th>
              <td :for={{mark, note} <- cells} class="align-top">
                <.mark mark={mark} note={note} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="mt-3 text-xs text-base-content/50">
        <.icon name="hero-check-circle" class="size-3.5 text-success" /> yes ·
        <.icon name="hero-minus-circle" class="size-3.5 text-warning" /> partly ·
        <.icon name="hero-x-circle" class="size-3.5 text-base-content/30" /> no
      </p>
    </section>

    <section
      id="help-choose"
      class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
    >
      <h2 class="text-lg font-semibold">If you're not sure</h2>
      <ul class="mt-3 space-y-2 text-sm text-base-content/70">
        <li>
          <span class="font-medium text-base-content">Using claude.ai, ChatGPT or a phone?</span>
          Add the <.link patch={~p"/help/agents/mcp"} class="link">MCP connector</.link>.
        </li>
        <li>
          <span class="font-medium text-base-content">
            Claude Code, Codex or another terminal agent?
          </span>
          Start with <.link patch={~p"/help/agents/guide"} class="link">the guide</.link>, then add
          the <.link patch={~p"/help/agents/skills"} class="link">skills</.link>
          and either <.link patch={~p"/help/agents/mcp"} class="link">MCP</.link>
          or the <.link patch={~p"/help/agents/cli"} class="link">CLI</.link>
          once you use it often.
        </li>
        <li>
          <span class="font-medium text-base-content">Want cards worked without you there?</span>
          Connect a <.link patch={~p"/help/agents/runners"} class="link">runner</.link>.
        </li>
        <li>
          <span class="font-medium text-base-content">
            Only need to tell another system something happened?
          </span>
          Use a <.link patch={~p"/help/agents/webhooks"} class="link">webhook</.link>.
        </li>
      </ul>
    </section>
    """
  end

  # ── One way in ────────────────────────────────────────────────────────────

  def topic_page(assigns) do
    ~H"""
    <nav
      id="help-topics"
      aria-label="Help topics"
      class="flex gap-1 overflow-x-auto rounded-2xl bg-base-100 p-1 text-sm shadow-sm ring-1 ring-base-content/10"
    >
      <.link
        patch={~p"/help/agents"}
        class="flex items-center gap-1.5 whitespace-nowrap rounded-xl px-3 py-2 font-medium text-base-content/60 hover:bg-base-200/70 hover:text-base-content"
      >
        <.icon name="hero-arrow-left" class="size-4" /> All ways in
      </.link>
      <.link
        :for={t <- @topics}
        patch={~p"/help/agents/#{t.slug}"}
        aria-current={t.slug == @topic.slug && "page"}
        class={[
          "flex items-center gap-1.5 whitespace-nowrap rounded-xl px-3 py-2 font-medium",
          (t.slug == @topic.slug && "bg-primary/10 text-primary") ||
            "text-base-content/60 hover:bg-base-200/70 hover:text-base-content"
        ]}
      >
        {t.short}
      </.link>
    </nav>

    <article id={"help-topic-#{@topic.slug}"} class="space-y-6">
      <header class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <h1 class="flex items-center gap-2 text-2xl font-bold tracking-tight">
          <.icon name={@topic.icon} class="size-6 text-primary" /> {@topic.title}
        </h1>
        <p class="mt-2 text-sm text-base-content/70">{@topic.intro}</p>
        <p class="mt-2 text-sm">
          <span class="font-medium">Use it when</span>
          <span class="text-base-content/70">{lowercase_first(@topic.when)}</span>
        </p>
      </header>
      <.topic slug={@topic.slug} base_url={@base_url} current_user={@current_user} />
    </article>
    """
  end

  attr :slug, :string, required: true
  attr :base_url, :string, required: true
  attr :current_user, :any, required: true

  defp topic(%{slug: "guide"} = assigns) do
    ~H"""
    <.part title="How it works">
      <p>
        <a href={~p"/api/guide"} class="link">{@base_url}/api/guide</a>
        is written for agents rather than people. It explains how these boards are used
        (top-level cards are epics and their subcards are the tasks), how to choose
        what to do next, what to write back while working, and gives a <code>curl</code>
        line for every call. The running server generates it, so it always matches the API.
      </p>
      <p>
        The guide is the only thing on the server an agent can read without signing in.
        Everything about your boards needs a token, including just listing them.
      </p>
    </.part>

    <.part title="Get started" id="help-guide-start">
      <p>Paste this at the start of a session:</p>
      <.snippet
        id="help-guide-prompt"
        text={"Work from my Slipdock board at #{@base_url}. Read #{@base_url}/api/guide and follow it. Nothing about my boards is readable until you sign in, so start with the device flow the guide describes and tell me the code to approve."}
      />
      <p>
        The agent asks the server for a short code and shows it to you. You open
        <code>{@base_url}/activate</code>
        in a browser where you're signed in, check what's asking, and approve. A few
        seconds later the agent gets a token that acts as you and saves it in <code>~/.config/slipdock/token</code>. Your password never reaches the agent, and
        the code expires after a few minutes.
      </p>
      <p>
        After it signs in, the agent should read the guide again. With a token, the guide
        ends with your own boards and their lists, so the agent doesn't have to guess
        their names.
      </p>
    </.part>

    <.part title="Choosing what it can do">
      <p>
        If you'd rather hand the agent a token yourself, make one under <.app_link
          current_user={@current_user}
          to={~p"/account/tokens"}
        >Account → API tokens</.app_link>:
      </p>
      <ul class="list-disc space-y-1 pl-5">
        <li><strong>Read only</strong> lets it summarise, search and report, but change nothing.</li>
        <li>
          <strong>Read and write</strong> is the usual choice for an agent that works the board.
        </li>
        <li>A token can also be <strong>limited to some boards</strong>.</li>
      </ul>
      <p>
        Every token is listed with when and where it was last used, and <strong>Revoke</strong>
        cuts off its access immediately.
      </p>
    </.part>

    <.part title="Good to know">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          Any agent that can make an HTTP request works this way: Claude Code, Codex,
          Cursor, a shell script or a cron job.
        </li>
        <li>
          Point agents at the URL instead of pasting API details into their instructions.
          A copied description goes out of date; the URL stays current.
        </li>
        <li>
          <code>?format=json</code> on the guide returns the same text, plus the vocabularies
          and endpoint list as data.
        </li>
      </ul>
    </.part>
    """
  end

  defp topic(%{slug: "mcp"} = assigns) do
    ~H"""
    <.part title="How it works">
      <p>
        This server is also an MCP server at <code>{@base_url}/mcp</code>. A client that
        connects gets a small set of tools that each do a whole step of the work: reading boards,
        cards, the guide and wiki pages; searching and asking; creating, updating, moving,
        commenting on, completing, archiving and deleting cards; uploading and downloading the
        files on cards and pages; lists, tags and boards;
        writing, sharing and reverting pages; listing, adding, changing and deleting a board's
        automations, for its owner; finding and installing
        <.link navigate={~p"/help/tools"} class="link">Tools</.link>
        (<code>list_tools</code>, <code>install_tool</code>); and taking runner jobs. The tools go through the same
        permission checks as the API, so a connection can't do anything its token couldn't.
      </p>
      <p>
        Read-only tools are marked as such, so a client can run them without asking each
        time. Deletes are marked destructive and need a confirmation in the call.
      </p>
    </.part>

    <.part title="From claude.ai and the Claude apps" id="help-mcp-claude">
      <ol class="list-decimal space-y-1 pl-5">
        <li>In claude.ai, open <strong>Settings → Connectors → Add custom connector</strong>.</li>
        <li>Give it a name, and this address:</li>
      </ol>
      <.snippet id="help-mcp-url" text={"#{@base_url}/mcp"} />
      <p>
        Press <strong>Connect</strong>. You're sent here to sign in and approve the
        connection, or lower it to read-only first. A connector added once also works in the
        desktop and mobile apps. Each connection appears as a <em>connected app</em>
        under <.app_link current_user={@current_user} to={~p"/account/tokens"}>Account → API tokens</.app_link>, and deleting it there disconnects it.
      </p>
      <p>
        claude.ai connects from Anthropic's servers, not from your browser, so this server
        has to be reachable from the internet over https.
      </p>
    </.part>

    <.part title="From Claude Code" id="help-mcp-claude-code">
      <p>Add the server, then run <code>/mcp</code> in a session to sign in through the browser:</p>
      <.snippet
        id="help-mcp-claude-code-cmd"
        text={"claude mcp add --transport http slipdock #{@base_url}/mcp"}
      />
      <p>Or pass a token from Account → API tokens instead of signing in:</p>
      <.snippet
        id="help-mcp-token-cmd"
        text={"claude mcp add --transport http slipdock #{@base_url}/mcp --header \"Authorization: Bearer <token>\""}
      />
      <p>
        Claude Code connects from your own machine, so a server on your LAN or tailnet works
        as long as that machine can reach it.
      </p>
    </.part>

    <.part title="From ChatGPT and other clients">
      <p>
        Any client that supports MCP's OAuth sign-in connects with just the address. Clients
        that take a URL and a header can use an API token instead, as above. In ChatGPT, add
        it as a connector, then upload the ChatGPT versions of the
        <.link patch={~p"/help/agents/skills"} class="link">skills</.link>
        so it knows which tool to use for what.
      </p>
    </.part>

    <.part title="What it can't do">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          Upload a file over 10 MB, such as most recordings, or transcribe one. Use the
          <.link patch={~p"/help/agents/cli"} class="link">CLI</.link>
          or the API.
        </li>
        <li>
          Set up runners, or run an automation now and read its callbacks. Do that on the
          board, or with the CLI.
        </li>
        <li>Mirror a vault to a folder on disk. Only the CLI does that.</li>
      </ul>
    </.part>
    """
  end

  defp topic(%{slug: "cli"} = assigns) do
    ~H"""
    <.part title="How it works">
      <p>
        <code>slipdock</code>
        is a command-line client for everything the API does: boards, cards, comments,
        the wiki, files (<code>slipdock attach</code>
        and <code>slipdock download</code>), search,
        automations, runners and meeting capture. It saves the server's
        address and your token, so neither you nor the agent has to repeat them, and its
        output is easier to read in a transcript than raw JSON.
      </p>
      <p>
        It's an Elixir escript, so the machine that runs it needs Erlang/OTP. That's why
        nothing else on this page depends on it.
      </p>
    </.part>

    <.part title="Install it" id="help-cli-install">
      <p>On Windows, in PowerShell. This installs Erlang through winget if it isn't already there:</p>
      <.snippet id="help-cli-windows" text={"irm #{@base_url}/cli/install.ps1 | iex\nslipdock auth"} />
      <p>Elsewhere, build it from the repository (Elixir 1.19 or later):</p>
      <.snippet
        id="help-cli-build"
        text={"cd cli && mix escript.build && cp slipdock ~/.local/bin/\nslipdock url #{@base_url}\nslipdock auth"}
      />
      <p>
        <code>slipdock auth</code>
        uses the same sign-in as <.link patch={~p"/help/agents/guide"} class="link">the guide</.link>: it prints a code and you approve it in the browser.
        <code>slipdock url</code>
        with no argument shows which server it's pointing at, which is the first thing to
        check when it can't connect.
      </p>
    </.part>

    <.part title="What it has that MCP doesn't">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          <code>slipdock sync</code>
          mirrors a vault to a local folder and keeps the two in step, so you can edit pages
          in Obsidian or any other editor.
        </li>
        <li>
          <code>slipdock attach</code>
          uploads files up to 250 MB, recordings included, where MCP takes up to 10 MB.
        </li>
        <li>Importing and exporting boards and pages, including from Trello.</li>
        <li>
          <code>slipdock skills install</code>
          and <code>slipdock skills check</code>
          keep the skills up to date, and <code>slipdock tools install</code>
          and <code>slipdock tools check</code>
          do the same for a Tool's skills.
        </li>
        <li>
          <code>slipdock tools publish</code> packs a folder and publishes it as a Tool.
        </li>
      </ul>
    </.part>

    <.part title="Good to know">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          <code>$SLIPDOCK_URL</code>
          and <code>$SLIPDOCK_TOKEN</code>
          override the saved address and token for a single command, such as one run against
          another server.
        </li>
        <li><code>slipdock guide</code> prints the agent guide.</li>
        <li>
          The <.link patch={~p"/help/agents/skills"} class="link">skills</.link>
          use the CLI where it's installed and fall back to <code>curl</code>
          where it isn't.
        </li>
      </ul>
    </.part>
    """
  end

  defp topic(%{slug: "skills"} = assigns) do
    ~H"""
    <.part title="How they work">
      <p>
        A skill is a Markdown file of instructions that an agent loads when the task matches.
        The guide tells an agent how to make each call; the skills tell it how to work well:
        what to pick up next, what belongs on the wiki rather than in a comment, and how to
        leave a record someone will want to read.
      </p>
      <p>
        They contain nothing about your own boards. Board names, lists and tags come from the
        guide for each caller, so renaming a list never makes a skill wrong.
      </p>
    </.part>

    <.part title="What you get" id="help-skills-list">
      <ul class="space-y-1">
        <li><code>slipdock</code>: the command and API reference.</li>
        <li>
          <code>slipdock-work</code>: working from a board, with epics, subcards and what to pick up next.
        </li>
        <li><code>slipdock-wiki</code>: finding, reading, writing and linking wiki pages.</li>
        <li><code>slipdock-docs</code>: what's worth writing down, and where it belongs.</li>
        <li>
          <code>slipdock-loop</code>: working the To Do list unattended, one card per pass, from
          <code>/loop</code>
          or a schedule. It watches the build after each push and never closes a card while the build is red.
        </li>
        <li>
          <code>slipdock-capture</code>: sending a meeting for capture where it's switched on,
          answering only with your answers.
        </li>
      </ul>
    </.part>

    <.part title="Install them for Claude Code" id="help-skills-install">
      <p>
        Into <code>~/.claude/skills</code>, on any machine with <code>curl</code>
        and <code>tar</code>.
        This also saves this server's address in <code>~/.config/slipdock/url</code>. It
        doesn't sign anything in.
      </p>
      <.snippet id="help-skills-sh" text={"curl -fsSL #{@base_url}/install.sh | sh"} />
      <p>On Windows, in PowerShell (not WSL, whose home folder Claude on Windows doesn't read):</p>
      <.snippet id="help-skills-ps" text={"irm #{@base_url}/install.ps1 | iex"} />
      <p>
        Want to read the script first? <code>curl {@base_url}/install.sh</code>
        prints it. The skills are also available as
        <a href={~p"/api/skills.tar.gz"} class="link">a tar.gz</a>
        and as <a href={~p"/api/skills"} class="link">a JSON listing</a>. They're versioned with this
        server, and <code>slipdock skills check</code>
        tells you if your copy is out of date.
      </p>
    </.part>

    <.part title="For ChatGPT" id="help-skills-chatgpt">
      <p>
        ChatGPT can't run commands, so each skill also comes as a zip that names the
        <.link patch={~p"/help/agents/mcp"} class="link">MCP</.link>
        tool to use instead of each command. Connect ChatGPT to <code>{@base_url}/mcp</code>
        first, then upload the zips you want:
      </p>
      <ul class="list-disc space-y-1 pl-5">
        <li :for={skill <- Slipdock.Skills.ChatGPT.list()}>
          <a href={~p"/api/skills/#{skill.name}/chatgpt.zip"} class="link" download>
            {skill.name}.zip
          </a>
        </li>
      </ul>
      <p>
        There's no <code>slipdock-loop</code> zip, because that skill commits, pushes and
        watches builds, and a chat can't do any of those.
      </p>
    </.part>

    <.part title="Skills that come with a Tool" id="help-skills-tools">
      <p>
        A <.link navigate={~p"/help/tools"} class="link">Tool</.link>
        brings skills of its own, alongside a board. Its page has them for each client: one
        command for Claude Code (<code>slipdock tools install &lt;name&gt;</code>), and a zip
        per skill for claude.ai's and ChatGPT's skill upload. A Tool's setup skill calls
        <code>install_tool</code>
        over MCP, which has the server build the board — lists, folders, tags, page skeletons
        and rules — and answers with its code; the skill then fills the pages in with you.
        <code>list_tools</code>
        says which Tools you can install and which board each install made, which is how a
        Tool's skills find their board.
      </p>
      <p>
        A Tool is a folder with <code>tool.json</code>, <code>README.md</code>, an optional <code>board.json</code>,
        <code>skills/&lt;name&gt;/SKILL.md</code>
        and an optional <code>files/</code>, published with <code>slipdock tools publish</code>.
        <.link navigate={~p"/help/tools#tools-format"} class="link">The package</.link>
        has the details.
      </p>
    </.part>
    """
  end

  defp topic(%{slug: "runners"} = assigns) do
    ~H"""
    <.part title="How they work">
      <p>
        With the other options, you start an agent and it reads the board. A runner works the
        other way round. An automation rule queues a <strong>job</strong>
        for a <strong>pool</strong>, for example whenever a card arrives in a list. A runner
        in that pool, on a machine of yours, takes the job, runs the agent on the card, and
        reports how it went.
      </p>
      <p>
        Runners <strong>pull</strong>: they connect out to ask for work, and the server never
        connects to them, so there are no ports to open or tunnels to set up. The server sends
        only the card and a prompt. What actually runs is decided by the runner's own config on
        your machine, and a kind of job it doesn't define is refused. A runner's token can
        only take and report on its own pool's jobs.
      </p>
    </.part>

    <.part title="Set one up" id="help-runners-setup">
      <p>
        On the board, open <strong>Automations → Connect a runner</strong>. It asks where the
        work should happen and gives you exactly what to paste:
      </p>
      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Where</th>
              <th>What it is</th>
              <th>Cost while idle</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Linux or macOS</td>
              <td>
                A shell runner (<code>sh</code> and <code>curl</code>) as a systemd or launchd service
              </td>
              <td>Nothing</td>
            </tr>
            <tr>
              <td>Windows</td>
              <td>A PowerShell runner, started at logon</td>
              <td>Nothing</td>
            </tr>
            <tr>
              <td>Claude Code</td>
              <td>A <code>/loop</code> that takes jobs from the pool's queue</td>
              <td>A Claude turn per check</td>
            </tr>
            <tr>
              <td>Claude, scheduled</td>
              <td>A Claude Desktop or cloud routine with the Slipdock connector</td>
              <td>A Claude turn per run</td>
            </tr>
            <tr>
              <td>ChatGPT</td>
              <td>A chat or scheduled task that claims one job and works it in the conversation</td>
              <td>A ChatGPT turn per check</td>
            </tr>
          </tbody>
        </table>
      </div>
    </.part>

    <.part title="Sending it work">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          <strong>Send cards to a runner</strong>: when a card arrives in a list, queue it
          for a pool.
        </li>
        <li>
          <strong>Work a list with a runner</strong>: take the top card, one at a time, and
          skip cards that are blocked, waiting or already assigned. This is how a runner
          takes over from a <code>/loop</code> working the To Do list.
        </li>
        <li>
          A Claude or ChatGPT session can also take jobs from the same queue itself, with
          <code>claim_job</code>
          over <.link patch={~p"/help/agents/mcp"} class="link">MCP</.link>
          or <code>slipdock claim-job</code>, so a loop and a shell runner never work the same card.
        </li>
      </ul>
    </.part>

    <.part title="Good to know">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          Jobs run with nobody watching. Every prompt says so, and tells the agent to choose
          from what's on the card, or to comment, flag the card <em>waiting</em> and stop.
        </li>
        <li>
          Give the runner the project's folder as its working directory. Claude Code only loads
          a project's own commands and settings from the folder it starts in.
        </li>
        <li>
          With <strong>Work a list with a runner</strong>, a card its job leaves in progress
          goes back to the top of the list for another try, then gets flagged as blocked.
        </li>
        <li>
          ChatGPT has no shell or repository, so give it its own pool of cards it can finish
          in conversation, such as writing, research or planning.
        </li>
      </ul>
    </.part>
    """
  end

  defp topic(%{slug: "webhooks"} = assigns) do
    ~H"""
    <.part title="How they work">
      <p>
        Every board has <strong>Automations</strong>: rules that react when something happens,
        such as a card being added, moved, commented on, or coming due. One thing a rule can do is <strong>call a URL</strong>. It POSTs a JSON body with the rule, the event, the board
        and the card (title, link, list, priority, assignee, dates, status, health, flags and
        tags), or sends the same fields as query parameters if you choose GET.
      </p>
      <p>
        It's the lightest way to connect: nothing to install, and no token to hand out,
        because the board calls you. It only goes one way, though. To change the board in
        response, the receiving end needs the <.link patch={~p"/help/agents/guide"} class="link">API</.link>,
        <.link patch={~p"/help/agents/mcp"} class="link">MCP</.link>
        or the <.link patch={~p"/help/agents/cli"} class="link">CLI</.link>.
      </p>
    </.part>

    <.part title="Set one up" id="help-webhooks-setup">
      <p>
        On a board you own, open <strong>Automations</strong>
        and pick the ready-made <strong>webhook</strong>
        rule, or describe what you want in your own words, for example:
      </p>
      <.snippet
        id="help-webhooks-example"
        text="when a card moves to Done, POST to https://example.com/hooks/done"
      />
      <p>
        The URL can include placeholders such as <code>{"{{card.id}}"}</code> in its path or query.
      </p>
    </.part>

    <.part title="Good to know">
      <ul class="list-disc space-y-1 pl-5">
        <li>
          Only public <code>http</code>
          and <code>https</code>
          addresses are called. Loopback, private and tailnet addresses are refused, so a
          webhook can't reach into the network the server runs on.
        </li>
        <li>
          To have an agent <em>work</em>
          the card, rather than just hear about it, use a <.link
            patch={~p"/help/agents/runners"}
            class="link"
          >runner</.link>.
        </li>
      </ul>
    </.part>
    """
  end
end

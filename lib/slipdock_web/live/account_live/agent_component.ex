defmodule SlipdockWeb.AccountLive.AgentComponent do
  @moduledoc """
  The Set up an agent tab: pointing an agent at this server. The short
  version is the first section; everything under it is optional, and
  labelled as such, because the thing that goes wrong here is people
  believing they must install something first.
  """
  use SlipdockWeb, :live_component

  # Everything on this tab is built from one fact: the address this server was
  # reached on. It is the thing people get wrong when they copy setup
  # instructions out of a repository, so the page works it out for them.
  @impl true
  def update(assigns, socket) do
    base = SlipdockWeb.BaseURL.from_socket(socket)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       base_url: base,
       agent_prompt:
         "Work from my Slipdock board at #{base}. Read #{base}/api/guide and " <>
           "follow it. Nothing about my boards is readable until you sign in, so " <>
           "start with the device flow the guide describes and tell me the code " <>
           "to approve."
     )}
  end

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, default: "Copy"

  # Something to copy, with the button that copies it. The text is selectable
  # too: a copy button that needs JavaScript must not be the only way out.
  defp copy_block(assigns) do
    ~H"""
    <div class="mt-3">
      <code
        id={@id}
        class="block select-all whitespace-pre-wrap break-words rounded-xl bg-base-200 px-3 py-2 font-mono text-xs leading-relaxed"
        phx-no-format
      >{@text}</code>
      <button
        type="button"
        id={"#{@id}-copy"}
        class="btn btn-ghost btn-xs mt-1 gap-1"
        phx-hook="CopyText"
        data-target={@id}
      >
        <.icon name="hero-clipboard" class="size-3.5" /> <span data-label>{@label}</span>
      </button>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <h2 class="text-lg font-semibold">Set up an agent</h2>
        <p class="mt-1 text-sm text-base-content/60">
          Claude, ChatGPT or anything else that can run a shell command can read and
          write these boards. The agent runs wherever you already use it — your laptop,
          a cloud session, a phone app — and talks to this server over the web. You do
          not need access to the machine this is running on, and there is nothing to
          install first.
        </p>
      </section>

      <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <h2 class="text-lg font-semibold">1 · Tell it where the board is</h2>
        <p class="mt-1 text-sm text-base-content/60">
          Paste this at the start of a session. The address is this server's own, and
          <.link href={~p"/api/guide"} class="link">the guide</.link>
          it names is written for agents: the model, what a card means here, how to pick
          up the next thing, and every call it can make. Read with a token it also ends
          with your own boards and lists, which is why it is worth reading twice.
        </p>
        <.copy_block id="agent-prompt" text={@agent_prompt} label="Copy prompt" />
      </section>

      <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <h2 class="text-lg font-semibold">2 · Approve it, once</h2>
        <p class="mt-1 text-sm text-base-content/60">
          Not optional, and not only about writing: the guide is the one thing an agent
          can read without a token. Your boards need one — listing them, opening a card,
          searching — so it will ask almost straight away. It shows you a short code;
          you approve it here, in this browser, where you are already signed in. The
          agent never sees your password, and a code is only good for a few minutes.
        </p>
        <p class="mt-3 text-sm">
          <.link href={~p"/activate"} class="link font-medium">Approve a code →</.link>
        </p>
        <p class="mt-3 text-sm text-base-content/60">
          What it gets is an API token that acts as you. If you would rather it only
          looked, make a read-only one on the
          <.link navigate={~p"/account/tokens"} class="link">API tokens</.link>
          tab and give the agent that instead. Every token is listed there, with when it
          was last used and from where, and <span class="font-medium">Revoke</span>
          ends its access immediately.
        </p>
      </section>

      <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <h2 class="text-lg font-semibold">
          Optional · install the skills
          <span class="ml-1 align-middle text-xs font-normal text-base-content/50">
            for Claude Code and anything that reads <code>~/.claude/skills</code>
          </span>
        </h2>
        <p class="mt-1 text-sm text-base-content/60">
          The guide above is enough on its own, and needs no token either. These are
          the longer instructions — the
          wiki, documents, working a backlog unattended — installed where your agent
          looks for them without being asked. The script needs <code>curl</code>
          and <code>tar</code>, nothing else: it writes the skills and
          saves this server's address in <code>~/.config/slipdock/url</code>, and signs
          nothing in.
        </p>
        <.copy_block
          id="agent-install"
          text={"curl -fsSL #{@base_url}/install.sh | sh"}
          label="Copy command"
        />
        <p class="mt-2 text-xs text-base-content/50">
          Rather read it first? <code>curl {@base_url}/install.sh</code>
          prints it. The skills are also
          <.link href={~p"/api/skills.tar.gz"} class="link">a tar.gz</.link>
          and <.link href={~p"/api/skills"} class="link">a JSON listing</.link>, each
          versioned with this server.
        </p>
      </section>

      <section
        id="agent-mcp-section"
        class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
      >
        <h2 class="text-lg font-semibold">
          Optional · connect over MCP
          <span class="ml-1 align-middle text-xs font-normal text-base-content/50">
            for claude.ai, the Claude apps, Claude Code and anything else that speaks MCP
          </span>
        </h2>
        <p class="mt-1 text-sm text-base-content/60">
          This server is also an MCP server, at <code>{@base_url}/mcp</code>. A client that
          connects gets a small set of tools: reading boards, cards, pages and the guide,
          searching, and adding, updating, moving, commenting on and completing cards and
          writing pages. There is no delete tool.
        </p>
        <p class="mt-3 text-sm text-base-content/60">
          <strong>From claude.ai or the Claude apps:</strong>
          Settings → Connectors → Add custom connector, with this address. You are sent here to
          sign in and approve it, read-only if you like, and it then shows on the
          <.link navigate={~p"/account/tokens"} class="link">API tokens</.link>
          tab as a connected app, where deleting it disconnects it.
        </p>
        <.copy_block id="agent-mcp-url" text={"#{@base_url}/mcp"} label="Copy address" />
        <p class="mt-3 text-sm text-base-content/60">
          <strong>With an API token,</strong>
          for clients that take a URL and a header: make one on the
          <.link navigate={~p"/account/tokens"} class="link">API tokens</.link>
          tab, read-only if the client should only look, and put it in place of <code>&lt;token&gt;</code>. In Claude Code:
        </p>
        <.copy_block
          id="agent-mcp"
          text={"claude mcp add --transport http slipdock #{@base_url}/mcp --header \"Authorization: Bearer <token>\""}
          label="Copy command"
        />
        <p class="mt-2 text-xs text-base-content/50">
          Or leave the header off and run <code>/mcp</code>
          in Claude Code to sign in through the browser instead.
        </p>
      </section>

      <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <h2 class="text-lg font-semibold">
          Optional · the <code>slipdock</code>
          CLI
          <span class="ml-1 align-middle text-xs font-normal text-base-content/50">
            needs Elixir to build
          </span>
        </h2>
        <p class="mt-1 text-sm text-base-content/60">
          A command-line client that wraps every call the agent would otherwise make with <code>curl</code>. Nicer to read in a transcript, and it keeps the token for
          you. Build it from the repository, then point it here:
        </p>
        <.copy_block
          id="agent-cli"
          text={"cd cli && mix escript.build && cp slipdock ~/.local/bin/\nslipdock url #{@base_url}\nslipdock auth"}
          label="Copy commands"
        />
      </section>
    </div>
    """
  end
end

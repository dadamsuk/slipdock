[
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
        "CLI has: syncing your wiki to a folder, files over 10 MB, imports and exports."
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

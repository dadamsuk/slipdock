defmodule SlipdockWeb.HelpLive.CLIReference do
  @moduledoc """
  Help › Agents › CLI › Command reference (`/help/agents/cli/reference`): every
  command in the CLI's help, by group, with a contents list and a filter. The
  groups come from `SlipdockWeb.HelpLive.CLIHelp`, parsed at compile time.
  """
  use SlipdockWeb, :html

  alias SlipdockWeb.HelpLive.CLIHelp

  @reference CLIHelp.parse(CLIHelp.text())

  @doc "The parsed help: `%{title, usage, groups}` (see `CLIHelp.parse/1`)."
  def reference, do: @reference

  @doc "The groups whose commands match `query`, each keeping only those commands."
  def filter(query), do: CLIHelp.filter(@reference.groups, query)

  # ── The page ──────────────────────────────────────────────────────────────

  attr :groups, :list, required: true, doc: "the groups to show, already filtered"
  attr :query, :string, default: ""

  def page(assigns) do
    assigns = assign(assigns, :all, @reference)

    ~H"""
    <article id="cli-reference" class="min-w-0 space-y-6">
      <header class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <.page_header
          title="CLI command reference"
          subtitle="Every command the slipdock CLI has, as its own help prints them, by group."
          class=""
        >
          <:leading><.icon name="hero-command-line" class="size-6 text-primary" /></:leading>
        </.page_header>
        <p class="mt-2 text-sm text-base-content/70">
          This page is made from the same text as <code>slipdock help</code>, so it always matches
          the CLI this server serves. Installing it is on <.link
            patch={~p"/help/agents/cli"}
            class="link"
          >the CLI's page</.link>.
        </p>
        <code
          id="cli-reference-usage"
          class="mt-3 block break-words rounded-xl bg-base-200 px-3 py-2 font-mono text-xs"
          phx-no-format
        ><%= for line <- @all.usage do %><span class="block"><%= for {chunk, i} <- Enum.with_index(CLIHelp.chunks(line)) do %><%= if i > 0, do: " " %><span class="inline-block max-w-full">{chunk}</span><% end %></span><% end %></code>
        <p id="cli-reference-title" class="mt-2 text-xs text-base-content/60">{@all.title}</p>
      </header>

      <nav
        id="cli-reference-contents"
        aria-label="Command groups"
        class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
      >
        <h2 class="section-title">Contents</h2>
        <ol class="mt-3 grid gap-x-6 gap-y-1 text-sm sm:grid-cols-2 lg:grid-cols-3">
          <li :for={g <- @all.groups}>
            <a href={"##{g.id}"} class="link" data-group={g.name}>{g.title}</a>
            <span class="text-xs text-base-content/50">
              {length(g.entries)}
            </span>
          </li>
        </ol>
        <form
          id="cli-reference-filter"
          phx-change="filter_commands"
          phx-submit="filter_commands"
          class="mt-4"
          role="search"
        >
          <label for="cli-reference-q" class="field-label">Find a command</label>
          <input
            id="cli-reference-q"
            name="q"
            type="search"
            value={@query}
            placeholder="e.g. page, sync, done"
            autocomplete="off"
            phx-debounce="150"
            class="field w-full sm:w-80"
          />
        </form>
      </nav>

      <.empty_state
        :if={@groups == []}
        id="cli-reference-none"
        icon="hero-magnifying-glass"
        title="No command by that name"
        compact
      >
        No command in the CLI’s help contains “{@query}”.
      </.empty_state>

      <section
        :for={g <- @groups}
        id={g.id}
        data-group={g.name}
        class="min-w-0 scroll-mt-4 rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
      >
        <h2 class="section-title">
          <a href={"##{g.id}"} class="hover:underline">{g.title}</a>
        </h2>
        <p :if={g.note != ""} class="mt-1 break-words text-sm text-base-content/60">{g.note}</p>
        <dl class="mt-4 divide-y divide-base-content/10">
          <div :for={e <- g.entries} class="min-w-0 py-3" data-role="cli-command">
            <dt>
              <code
                class="break-words font-mono text-sm font-medium text-base-content"
                data-role="cli-usage"
                phx-no-format
              ><%= for {chunk, i} <- Enum.with_index(CLIHelp.chunks(e.usage)) do %><%= if i > 0, do: " " %><span class="inline-block max-w-full">{chunk}</span><% end %></code>
            </dt>
            <dd :if={e.desc != ""} class="mt-1 break-words text-sm text-base-content/70">{e.desc}</dd>
            <dd :if={e.details != []} class="mt-2 min-w-0">
              <pre
                class="overflow-x-auto rounded-xl bg-base-200 px-3 py-2 font-mono text-xs leading-relaxed"
                phx-no-format
              >{Enum.join(e.details, "\n")}</pre>
            </dd>
          </div>
        </dl>
      </section>
    </article>
    """
  end
end

defmodule SlipdockWeb.HelpLive.Index do
  @moduledoc """
  Help. Readable signed out, because the questions come up before anybody has
  an account, and nothing on it is about anybody's boards.

    * `/help` — the hub: what each section covers, with links into its parts.
    * `/help/:section` — a guide to part of the app (`SlipdockWeb.HelpLive.Guides`).
    * `/help/agents` and `/help/agents/:topic` — connecting an AI agent
      (`SlipdockWeb.HelpLive.Agents`).
    * `/help/agents/cli/reference` — every CLI command, from the CLI's own help
      (`SlipdockWeb.HelpLive.CLIReference`). Under the CLI's topic, because it
      is part of that way in; a path of its own, so it can be linked and
      bookmarked like any other page.
    * `/help/agents/flow` — how a card flows through runners, verifiers and CI
      to a deploy (`SlipdockWeb.HelpLive.Flow`): not a way in, so not a topic,
      but beside them.

  The agent topics lived at `/help/:topic` first; those addresses still work,
  and redirect to where the topic is now.
  """
  use SlipdockWeb, :live_view

  alias SlipdockWeb.HelpLive.{Agents, CLIReference, Flow, Guides}

  @agent_slugs Agents.slugs()
  @guide_slugs Guides.slugs()

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       sections: Guides.sections(),
       topics: Agents.topics(),
       base_url: SlipdockWeb.BaseURL.from_socket(socket),
       section: nil,
       topic: nil,
       cli_query: "",
       cli_groups: CLIReference.reference().groups
     )}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, :index, _params),
    do: assign(socket, section: nil, topic: nil, page_title: "Help")

  defp apply_action(socket, :agents, _params),
    do: assign(socket, section: nil, topic: nil, page_title: "Agents · Help")

  defp apply_action(socket, :cli_reference, _params),
    do: assign(socket, section: nil, topic: nil, page_title: "CLI command reference · Help")

  defp apply_action(socket, :flow, _params),
    do: assign(socket, section: nil, topic: nil, page_title: "How work flows · Help")

  defp apply_action(socket, :agent_topic, %{"topic" => slug}) when slug in @agent_slugs do
    topic = Enum.find(socket.assigns.topics, &(&1.slug == slug))
    assign(socket, section: nil, topic: topic, page_title: "#{topic.title} · Help")
  end

  defp apply_action(socket, :section, %{"section" => slug}) when slug in @guide_slugs do
    section = Enum.find(socket.assigns.sections, &(&1.slug == slug))
    assign(socket, section: section, topic: nil, page_title: "#{section.title} · Help")
  end

  # Where the agent topics used to be.
  defp apply_action(socket, :section, %{"section" => slug}) when slug in @agent_slugs,
    do: push_patch(socket, to: ~p"/help/agents/#{slug}", replace: true)

  defp apply_action(socket, :agent_topic, _params), do: not_found(socket, ~p"/help/agents")
  defp apply_action(socket, :section, _params), do: not_found(socket, ~p"/help")

  defp not_found(socket, to) do
    socket
    |> put_flash(:error, "There is no help page by that name.")
    |> push_patch(to: to)
  end

  @impl true
  def handle_event("filter_commands", %{"q" => q}, socket) do
    groups = CLIReference.filter(q)
    {:noreply, assign(socket, cli_query: q, cli_groups: groups)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <:actions>
        <.link :if={!@current_user} navigate={~p"/login"} class="btn btn-primary btn-sm">
          Sign in
        </.link>
      </:actions>
      <div id="help" class="kanban-scroll h-full overflow-y-auto">
        <.page width="standard" class="space-y-8">
          <.hub :if={@live_action == :index} sections={@sections} current_user={@current_user} />

          <.section_nav
            :if={@live_action != :index}
            sections={@sections}
            section={@section}
            agents?={@live_action in [:agents, :agent_topic, :cli_reference, :flow]}
          />

          <article :if={@section} id={"help-section-#{@section.slug}"} class="space-y-6">
            <header class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <.page_header title={@section.title} subtitle={@section.intro} class="">
                <:leading><.icon name={@section.icon} class="size-6 text-primary" /></:leading>
              </.page_header>
              <ul class="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-sm">
                <li :for={{id, title} <- @section.parts}>
                  <a href={"##{id}"} class="link">{title}</a>
                </li>
              </ul>
            </header>
            <Guides.guide slug={@section.slug} current_user={@current_user} />
          </article>

          <Agents.overview
            :if={@live_action == :agents}
            topics={@topics}
            features={Agents.features()}
            current_user={@current_user}
          />
          <Agents.topic_page
            :if={@topic}
            topic={@topic}
            topics={@topics}
            base_url={@base_url}
            current_user={@current_user}
          />

          <Flow.page :if={@live_action == :flow} topics={@topics} />

          <Agents.topic_nav :if={@live_action == :cli_reference} topics={@topics} current="cli" />
          <CLIReference.page
            :if={@live_action == :cli_reference}
            groups={@cli_groups}
            query={@cli_query}
          />
        </.page>
      </div>
    </Layouts.app>
    """
  end

  attr :sections, :list, required: true
  attr :current_user, :any, required: true

  defp hub(assigns) do
    ~H"""
    <.page_header
      title="Help"
      subtitle="Slipdock is a kanban board with a wiki beside it. You can share it with people, automate it with rules, ask it questions, and let AI agents work on it alongside you. Choose a section below, or go straight to one of its parts."
    >
      <:actions :if={!@current_user}>
        <.link navigate={~p"/login"} class="link text-sm font-medium">Sign in →</.link>
      </:actions>
    </.page_header>

    <div id="help-sections" class="grid gap-4 sm:grid-cols-2">
      <article
        :for={s <- @sections}
        id={"help-hub-#{s.slug}"}
        class="flex flex-col rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
      >
        <h2 class="flex items-center gap-2 font-semibold">
          <.icon name={s.icon} class="size-5 text-primary" />
          <.link patch={~p"/help/#{s.slug}"} class="link">{s.title}</.link>
        </h2>
        <p class="mt-2 text-sm text-base-content/70">{s.intro}</p>
        <ul class="mt-3 space-y-0.5 text-sm">
          <li :for={{id, title} <- s.parts}>
            <.link patch={"/help/#{s.slug}##{id}"} class="link">{title}</.link>
          </li>
        </ul>
      </article>

      <article
        id="help-hub-agents"
        class="flex flex-col rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
      >
        <h2 class="flex items-center gap-2 font-semibold">
          <.icon name="hero-cpu-chip" class="size-5 text-primary" />
          <.link patch={~p"/help/agents"} class="link">Agents</.link>
        </h2>
        <p class="mt-2 text-sm text-base-content/70">
          Let Claude, ChatGPT or an agent of your own read and work your boards. Covers each way
          of connecting, a table comparing them, and how to set each one up.
        </p>
        <ul class="mt-3 space-y-0.5 text-sm">
          <li>
            <.link patch={~p"/help/agents"} id="help-hub-agents-summary" class="link font-medium">
              Summary: every way in, side by side
            </.link>
          </li>
          <li>
            <.link patch={~p"/help/agents/flow"} id="help-hub-agents-flow" class="link">
              How work flows: a card from idea to deploy
            </.link>
          </li>
          <li :for={t <- Agents.topics()}>
            <.link patch={~p"/help/agents/#{t.slug}"} class="link">{t.title}</.link>
          </li>
        </ul>
      </article>
    </div>
    """
  end

  attr :sections, :list, required: true
  attr :section, :map, default: nil
  attr :agents?, :boolean, default: false

  # Across the top of every page but the hub: back to it, each section, Agents.
  defp section_nav(assigns) do
    ~H"""
    <nav
      id="help-sections-nav"
      aria-label="Help sections"
      class="flex gap-1 overflow-x-auto rounded-2xl bg-base-100 p-1 text-sm shadow-sm ring-1 ring-base-content/10"
    >
      <.link
        patch={~p"/help"}
        class="flex items-center gap-1.5 whitespace-nowrap rounded-xl px-3 py-2 font-medium text-base-content/60 hover:bg-base-200/70 hover:text-base-content"
      >
        <.icon name="hero-arrow-left" class="size-4" /> Help
      </.link>
      <.nav_pill
        :for={s <- @sections}
        to={~p"/help/#{s.slug}"}
        label={s.title}
        on={@section != nil && @section.slug == s.slug}
      />
      <.nav_pill to={~p"/help/agents"} label="Agents" on={@agents?} />
    </nav>
    """
  end

  attr :to, :string, required: true
  attr :label, :string, required: true
  attr :on, :boolean, default: false

  defp nav_pill(assigns) do
    ~H"""
    <.link
      patch={@to}
      aria-current={@on && "page"}
      class={[
        "flex items-center whitespace-nowrap rounded-xl px-3 py-2 font-medium",
        (@on && "bg-primary/10 text-primary") ||
          "text-base-content/60 hover:bg-base-200/70 hover:text-base-content"
      ]}
    >
      {@label}
    </.link>
    """
  end
end

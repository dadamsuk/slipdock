defmodule SlipdockWeb.SkillRegistryLive.Index do
  @moduledoc """
  The skills registry page (#2061, spec W-2513 §Sources and entries): the
  skill sources somebody has added and the seeds everybody sees, each with
  its entries and their metadata. Adding a source by URL fetches it
  (`Slipdock.SkillRegistry.add_source/2`); a source's owner (an admin, for a
  seed) refreshes or removes it. `/skills/entries/:id` shows one entry's
  full text, as fetched, before anybody lets an agent follow it.

  The fetch runs off the LiveView process (`start_async/3`), so the page
  stays live while GitHub answers. Whatever it refuses comes back as the
  context's own sentence and is shown as it is.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents, only: [timestamp: 1]

  alias Slipdock.SkillRegistry

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Skills",
       form: url_form(""),
       add_error: nil,
       busy: nil,
       notice: nil,
       entry: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :entry}} = socket) do
    case SkillRegistry.get_entry(socket.assigns.current_user, id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That skill isn't one you can see.")
         |> push_navigate(to: ~p"/skills")}

      entry ->
        {:noreply, assign(socket, entry: entry, page_title: entry.name)}
    end
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, socket |> assign(entry: nil, page_title: "Skills") |> load()}

  @impl true
  def handle_event("add", %{"url" => url}, socket) do
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(form: url_form(url), add_error: nil, notice: nil, busy: :add)
     |> start_async(:add, fn -> SkillRegistry.add_source(user, url) end)}
  end

  def handle_event("refresh", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case SkillRegistry.get_source(user, id) do
      nil ->
        {:noreply, gone(socket)}

      source ->
        {:noreply,
         socket
         |> assign(busy: {:refresh, source.id}, notice: nil)
         |> start_async(:refresh, fn -> SkillRegistry.refresh_source(user, source) end)}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with %{} = source <- SkillRegistry.get_source(user, id),
         {:ok, removed} <- SkillRegistry.remove_source(user, source) do
      {:noreply,
       socket
       |> assign(notice: {:info, "Removed #{removed.name} and its skills."})
       |> load()}
    else
      nil -> {:noreply, gone(socket)}
      {:error, message} -> {:noreply, socket |> assign(notice: {:error, message}) |> load()}
    end
  end

  @impl true
  def handle_async(:add, {:ok, {:ok, source}}, socket) do
    {:noreply,
     socket
     |> assign(form: url_form(""), busy: nil, notice: {:info, added(source)})
     |> load()}
  end

  def handle_async(:add, {:ok, {:error, message}}, socket),
    do: {:noreply, assign(socket, busy: nil, add_error: message)}

  def handle_async(:refresh, {:ok, {:ok, source, changes}}, socket) do
    {:noreply,
     socket
     |> assign(busy: nil, notice: {:info, refreshed(source, changes)})
     |> load()}
  end

  def handle_async(:refresh, {:ok, {:error, message}}, socket),
    do: {:noreply, socket |> assign(busy: nil, notice: {:error, message}) |> load()}

  def handle_async(name, {:exit, _reason}, socket) do
    message = "The fetch stopped before it finished. Try again in a moment."

    socket = assign(socket, busy: nil)

    case name do
      :add -> {:noreply, assign(socket, add_error: message)}
      _ -> {:noreply, assign(socket, notice: {:error, message})}
    end
  end

  defp url_form(url), do: to_form(%{"url" => url})

  defp gone(socket),
    do: socket |> assign(notice: {:error, "That source has gone."}) |> load()

  defp load(socket) do
    user = socket.assigns.current_user
    sources = SkillRegistry.list_sources(user)
    {seeds, own} = Enum.split_with(sources, &is_nil(&1.owner_id))

    assign(socket,
      sections: [{"yours", "Yours", own}, {"seeds", "On this server", seeds}],
      manage: Map.new(sources, &{&1.id, SkillRegistry.can_manage?(user, &1)})
    )
  end

  @doc false
  def added(source) do
    count = length(source.entries)
    "Added #{source.name}: #{count} #{plural(count, "skill", "skills")}."
  end

  @doc false
  def refreshed(source, changes) do
    parts =
      for {group, label} <- [added: "added", changed: "changed", removed: "removed"],
          names = Map.get(changes, group, []),
          names != [],
          do: "#{label} #{Enum.join(names, ", ")}"

    case parts do
      [] -> "Refreshed #{source.name}: nothing changed."
      _ -> "Refreshed #{source.name}: #{Enum.join(parts, "; ")}."
    end
  end

  defp plural(1, one, _many), do: one
  defp plural(_n, _one, many), do: many

  defp short(nil), do: "-"
  defp short("sha256:" <> _ = version), do: version
  defp short(version) when byte_size(version) == 40, do: String.slice(version, 0, 7)
  defp short(version), do: version

  @impl true
  def render(%{live_action: :entry, entry: %{}} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      waiting_count={@waiting_count}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:skills}
    >
      <div class="kanban-scroll h-full overflow-y-auto">
        <.page width="standard" class="space-y-6">
          <.link navigate={~p"/skills"} class="text-sm text-base-content/60 hover:text-base-content">
            <.icon name="hero-arrow-left" class="size-4" /> Skills
          </.link>
          <.page_header title={@entry.name}>
            <:meta>{@entry.description}</:meta>
          </.page_header>

          <dl
            id="skill-entry-meta"
            class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-sm"
          >
            <dt class="text-base-content/60">From</dt>
            <dd>
              <a href={@entry.source.url} class="link" rel="noopener noreferrer" target="_blank">
                {@entry.source.name}
              </a>
            </dd>
            <dt class="text-base-content/60">File</dt>
            <dd><code>{@entry.path}</code></dd>
            <dt class="text-base-content/60">Version</dt>
            <dd><code>{short(@entry.version)}</code></dd>
            <dt class="text-base-content/60">Licence</dt>
            <dd>{@entry.licence || "none given"}</dd>
            <dt class="text-base-content/60">Fetched</dt>
            <dd><.timestamp at={@entry.fetched_at} format={:datetime} /></dd>
          </dl>

          <p class="text-sm text-base-content/60">
            This is the whole file, as fetched. A board's agents follow it only once a
            board writer enables it there, so read it as you would anything you let act
            for you.
          </p>
          <pre
            id="skill-entry-body"
            class="whitespace-pre-wrap break-words rounded-2xl bg-base-200 p-4 text-sm"
          >{@entry.body}</pre>
        </.page>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      waiting_count={@waiting_count}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:skills}
    >
      <div class="kanban-scroll h-full overflow-y-auto">
        <.page width="standard" class="space-y-8">
          <.page_header title="Skills">
            <:meta>
              Skill collections from elsewhere, such as a GitHub repository of <code>SKILL.md</code>
              files. Slipdock fetches and keeps each one, so you can read it in full here
              and a board can hand it to its agents without anything installed.
            </:meta>
          </.page_header>

          <section
            id="skills-add"
            class="rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <h2 class="section-title">Add a source</h2>
            <p class="mt-1 text-sm text-base-content/60">
              A GitHub repository (<code>https://github.com/owner/repo</code>), a folder or
              one file in one, or a <code>SKILL.md</code>
              at any https address. Slipdock reads each <code>SKILL.md</code>
              in it, or its README when there are none.
            </p>
            <.form
              for={@form}
              id="skills-add-form"
              phx-submit="add"
              class="mt-3 field-row gap-2"
            >
              <div class="min-w-0 flex-1">
                <.input
                  field={@form[:url]}
                  id="skills-add-url"
                  type="url"
                  label="Source URL"
                  required
                  placeholder="https://github.com/owner/repo"
                  class="input field w-full"
                  disabled={@busy == :add}
                />
              </div>
              <.button class="btn btn-primary btn-sm" disabled={@busy == :add}>
                {if @busy == :add, do: "Fetching…", else: "Add"}
              </.button>
            </.form>
            <.callout :if={@add_error} id="skills-add-error" kind={:error} class="mt-2">
              {@add_error}
            </.callout>
          </section>

          <.callout :if={@notice} id="skills-notice" kind={elem(@notice, 0)}>
            {elem(@notice, 1)}
          </.callout>

          <section :for={{key, title, sources} <- @sections} id={"skills-#{key}"}>
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
              {title}
            </h2>
            <.empty_state
              :if={sources == [] and key == "yours"}
              id="skills-yours-empty"
              icon="hero-book-open"
              title="No sources of yours yet"
              class="mt-2"
              compact
            >
              Add one above by its URL.
            </.empty_state>
            <.empty_state
              :if={sources == [] and key == "seeds"}
              id="skills-seeds-empty"
              icon="hero-building-library"
              title="None on this server"
              class="mt-2"
              compact
            >
              A source an admin adds for everyone shows here.
            </.empty_state>

            <article
              :for={source <- sources}
              id={"skill-source-#{source.id}"}
              class="mt-3 rounded-2xl bg-base-100 p-4 shadow-sm ring-1 ring-base-content/10"
            >
              <div class="flex flex-wrap items-baseline justify-between gap-2">
                <div class="min-w-0">
                  <h3 class="font-semibold">
                    <a href={source.url} class="link" rel="noopener noreferrer" target="_blank">
                      {source.name}
                    </a>
                  </h3>
                  <p class="text-xs text-base-content/60">
                    Licence {source.licence || "none given"} · version
                    <code>{short(source.version)}</code>
                    · fetched <.timestamp at={source.fetched_at} />
                  </p>
                </div>
                <div :if={@manage[source.id]} class="flex gap-2">
                  <.button
                    id={"skill-source-#{source.id}-refresh"}
                    phx-click="refresh"
                    phx-value-id={source.id}
                    disabled={@busy == {:refresh, source.id}}
                  >
                    {if @busy == {:refresh, source.id}, do: "Refreshing…", else: "Refresh"}
                  </.button>
                  <.button
                    id={"skill-source-#{source.id}-remove"}
                    variant="danger"
                    phx-click="remove"
                    phx-value-id={source.id}
                    data-confirm={"Remove #{source.name} and its skills?"}
                  >
                    Remove
                  </.button>
                </div>
              </div>

              <.callout
                :if={source.report != []}
                id={"skill-source-#{source.id}-report"}
                kind={:warning}
                title="Left out of the last fetch"
                class="mt-2"
              >
                <ul class="list-disc pl-5">
                  <li :for={line <- source.report}>{line}</li>
                </ul>
              </.callout>

              <ul class="mt-3 divide-y divide-base-content/10">
                <li :for={entry <- source.entries} id={"skill-entry-#{entry.id}"} class="py-2">
                  <.link navigate={~p"/skills/entries/#{entry.id}"} class="font-medium link">
                    {entry.name}
                  </.link>
                  <span class="ml-2 text-xs text-base-content/50">
                    <code>{entry.path}</code>
                  </span>
                  <p :if={entry.description} class="text-sm text-base-content/70">
                    {entry.description}
                  </p>
                </li>
              </ul>
            </article>
          </section>
        </.page>
      </div>
    </Layouts.app>
    """
  end
end

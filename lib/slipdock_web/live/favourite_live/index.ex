defmodule SlipdockWeb.FavouriteLive.Index do
  @moduledoc """
  Favourites: the things this person marked, and the way back to each.

  This page is the point of the feature. It is the phone's fifth tab, so
  whatever is on it is two taps from anywhere in the app — the tab, then the
  row. Templates used to have that slot; a template is something you reach
  for when making a board, which is rare, and a favourite is something you
  reach for all day, which is not.

  Each row also carries its own heart, so the list prunes itself from here
  without having to go and find the thing first.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.SwimlaneComponents, only: [view_path: 2, mode_icon: 1]

  alias Slipdock.Favourites

  @sections [
    {:view, "Views", "hero-bookmark"},
    {:page, "Pages", "hero-document-text"},
    {:column, "Lists", "hero-view-columns"},
    {:card, "Cards", "hero-rectangle-stack"},
    {:board, "Boards", "hero-squares-2x2"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Slipdock.Boards.subscribe_all()
    {:ok, socket |> assign(page_title: "Favourites") |> load()}
  end

  defp load(socket) do
    entries = Favourites.list(socket.assigns.current_user)

    sections =
      for {kind, label, icon} <- @sections,
          items = Enum.filter(entries, &(&1.kind == kind)),
          items != [],
          do: %{kind: kind, label: label, icon: icon, items: items}

    assign(socket, sections: sections)
  end

  @impl true
  def handle_info({:boards_changed}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_favourite", %{"kind" => kind, "id" => id}, socket) do
    with {:ok, kind} <- Favourites.kind(kind),
         id when is_integer(id) <- SlipdockWeb.Params.id(id),
         {:ok, _} <- Favourites.toggle(socket.assigns.current_user, kind, id) do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  ## The way back to each kind of thing ---------------------------------------

  # A list is not a page of its own: it is a column of a board that is wider
  # than a phone. `?list=` opens the board scrolled to it (see
  # `SlipdockWeb.BoardLive.Show.scroll_to_list/2`).
  defp path(%{kind: :column, resource: column, board: board}),
    do: ~p"/boards/#{board}?#{[list: column.id]}"

  defp path(%{kind: :card, resource: card, board: board}),
    do: ~p"/boards/#{board}/cards/#{card.id}"

  defp path(%{kind: :page, resource: page, board: board}),
    do: ~p"/boards/#{board}/wiki/#{page.slug}"

  defp path(%{kind: :view, resource: view, board: board}), do: view_path(board, view)
  defp path(%{kind: :board, board: board}), do: ~p"/boards/#{board}"

  defp name(%{kind: :card, resource: card}), do: card.title
  defp name(%{kind: :page, resource: page}), do: page.title
  defp name(%{resource: resource}), do: resource.name

  defp row_icon(%{kind: :view, resource: view}), do: mode_icon(view.config["mode"])
  defp row_icon(%{kind: :column}), do: "hero-view-columns"
  defp row_icon(%{kind: :card}), do: "hero-rectangle-stack"
  defp row_icon(%{kind: :page}), do: "hero-document-text"
  defp row_icon(%{kind: :board}), do: "hero-squares-2x2"

  # Where the thing lives, for a list that mixes boards: "Plan › To Do".
  defp where(%{kind: :board}), do: nil

  defp where(%{kind: :card, resource: card, board: board}),
    do: "#{board.name} › #{card.column.name}"

  defp where(%{board: board}), do: board.name

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:favourites}
    >
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl px-4 py-6 sm:px-6 sm:py-10">
          <h1 class="mb-6 text-2xl font-bold tracking-tight sm:text-3xl">Favourites</h1>

          <div
            :if={@sections == []}
            class="rounded-2xl border-2 border-dashed border-base-content/15 p-12 text-center sm:p-16"
          >
            <div class="mx-auto mb-4 flex size-14 items-center justify-center rounded-2xl bg-rose-500/10 text-rose-500">
              <.icon name="hero-heart" class="size-7" />
            </div>
            <h2 class="text-lg font-semibold">Nothing favourited yet</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Press the heart on a view, a list or a card.
            </p>
          </div>

          <section :for={section <- @sections} id={"favourites-#{section.kind}"} class="mb-8">
            <h2 class="mb-2 flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-base-content/60">
              <.icon name={section.icon} class="size-4" />
              {section.label}
              <span class="badge badge-ghost badge-sm font-mono">{length(section.items)}</span>
            </h2>
            <ul class="divide-y divide-base-300/60 overflow-hidden rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/10">
              <li
                :for={entry <- section.items}
                id={"favourite-#{entry.id}"}
                class="flex items-center gap-1 pr-2 hover:bg-base-200/40"
              >
                <.link navigate={path(entry)} class="flex min-w-0 flex-1 items-center gap-3 px-4 py-3">
                  <.icon name={row_icon(entry)} class="size-4 shrink-0 text-base-content/40" />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-sm font-medium">{name(entry)}</span>
                    <span :if={where(entry)} class="block truncate text-xs text-base-content/50">
                      {where(entry)}
                    </span>
                  </span>
                  <.icon name="hero-chevron-right" class="size-4 shrink-0 text-base-content/30" />
                </.link>
                <.favourite_toggle
                  kind={to_string(entry.kind)}
                  id={entry.resource_id}
                  name={name(entry)}
                  marks={MapSet.new([{entry.kind, entry.resource_id}])}
                  class="p-2"
                />
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

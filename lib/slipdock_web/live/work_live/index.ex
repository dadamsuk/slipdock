defmodule SlipdockWeb.WorkLive.Index do
  @moduledoc """
  My work: every card assigned to the signed-in user, across all boards and
  levels, grouped by when it is due, each with the path of cards above it.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents
  alias Slipdock.{Access, Boards, Work}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Boards.subscribe_all()

    {:ok,
     socket
     |> assign(
       page_title: "My work",
       show_done: false,
       ai?: Slipdock.AI.configured?(socket.assigns.current_user)
     )
     |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_user
    cards = Work.assigned(user)
    open = Enum.reject(cards, &(&1.section == :done))

    assign(socket,
      sections: Work.group(cards, socket.assigns.show_done),
      open_count: length(open),
      done_count: length(cards) - length(open)
    )
  end

  @impl true
  def handle_info({:boards_changed}, socket) do
    Boards.drain_boards_changed()
    {:noreply, load(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_done", _, socket) do
    {:noreply, socket |> assign(show_done: not socket.assigns.show_done) |> load()}
  end

  def handle_event("toggle_complete", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    card = Boards.get_card!(id)

    if Access.can_write?(Access.card_permission(user, card)) do
      Boards.toggle_completed(card)
      {:noreply, load(socket)}
    else
      {:noreply, put_flash(socket, :error, "You have read-only access to that card.")}
    end
  end

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
      nav_active={:work}
    >
      <:actions>
        <button
          :if={@ai?}
          type="button"
          class="btn btn-ghost btn-sm btn-square"
          title="Chat about your work with AI"
          aria-label="Chat about your work with AI"
          phx-click="toggle"
          phx-target="#page-ai"
        >
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-4" />
        </button>
      </:actions>
      <.live_component
        :if={@ai?}
        module={SlipdockWeb.AIChatComponent}
        id="page-ai"
        layout="drawer"
        title="Chat about my work"
        source={%{kind: :work, sections: @sections, user: @current_user}}
        current_user={@current_user}
        can_write={true}
      />
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-5xl px-4 py-6 sm:py-10 sm:px-6">
          <div class="mb-6 flex flex-wrap items-end justify-between gap-4">
            <div>
              <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">My work</h1>
              <p class="mt-1 text-sm text-base-content/60">
                {@open_count} open {if @open_count == 1, do: "card", else: "cards"} assigned to you, across every board and level.
              </p>
            </div>
            <label class="flex cursor-pointer items-center gap-2 text-sm">
              <input
                type="checkbox"
                class="toggle toggle-sm"
                checked={@show_done}
                phx-click="toggle_done"
              /> Show completed
              <span :if={@done_count > 0} class="badge badge-ghost badge-sm font-mono">
                {@done_count}
              </span>
            </label>
          </div>

          <div
            :if={@sections == []}
            class="rounded-2xl border-2 border-dashed border-base-content/15 p-16 text-center"
          >
            <div class="mx-auto mb-4 flex size-14 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-check-badge" class="size-7" />
            </div>
            <h2 class="text-lg font-semibold">Nothing assigned to you</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Cards you are assigned to, on any board, show up here.
            </p>
          </div>

          <section :for={section <- @sections} id={"work-#{section.key}"} class="mb-8">
            <h2 class={[
              "mb-2 flex items-center gap-2 text-sm font-semibold uppercase tracking-wide",
              section.tone || "text-base-content/60"
            ]}>
              {section.label}
              <span class="badge badge-ghost badge-sm font-mono">{length(section.items)}</span>
            </h2>
            <ul class="divide-y divide-base-300/60 overflow-hidden rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/10">
              <li
                :for={%{card: card, path: path} <- section.items}
                id={"work-card-#{card.id}"}
                class={[
                  "flex items-center gap-3 px-4 py-2.5 hover:bg-base-200/40",
                  card.completed && "opacity-60"
                ]}
              >
                <button
                  type="button"
                  class={[
                    "shrink-0 rounded-full transition",
                    if(card.completed,
                      do: "text-success",
                      else: "text-base-content/25 hover:text-success"
                    )
                  ]}
                  phx-click="toggle_complete"
                  phx-value-id={card.id}
                  title={if card.completed, do: "Mark incomplete", else: "Mark complete"}
                >
                  <.icon
                    name={if card.completed, do: "hero-check-circle-solid", else: "hero-check-circle"}
                    class="size-5"
                  />
                </button>
                <span
                  :if={card.color}
                  class={["size-2 shrink-0 rounded-full", Slipdock.Palette.dot(card.color)]}
                ></span>
                <div class="min-w-0 flex-1">
                  <.link
                    navigate={~p"/boards/#{card.board_id}/cards/#{card.id}"}
                    class={[
                      "block truncate font-medium hover:underline",
                      card.completed && "text-base-content/50"
                    ]}
                  >
                    {card.title}
                  </.link>
                  <p class="truncate text-xs text-base-content/50" title={Enum.join(path, " › ")}>
                    {Enum.join(path, " › ")} · {card.column.name}
                  </p>
                </div>
                <span :if={card.tags != []} class="hidden items-center gap-1 sm:flex">
                  <.tag_chip :for={tag <- card.tags} tag={tag} size="xs" />
                </span>
                <.flag_icon :for={flag <- card.flags} flag={flag} class="size-3.5" />
                <.subcards_badge card={card} />
                <.priority_badge priority={card.priority} />
                <.schedule_badges card={card} />
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

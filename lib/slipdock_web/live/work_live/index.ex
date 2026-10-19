defmodule SlipdockWeb.WorkLive.Index do
  @moduledoc """
  My work: every card assigned to the signed-in user, across all boards and
  levels, grouped by when it is due, each with the path of cards above it.

  It opens with "Waiting on you" (#1118): everything that needs this person,
  oldest first (`Slipdock.Work.waiting_on_me/2`), with a wait's answers
  right there. The header's count is the length of that section.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents
  alias Slipdock.{Access, Actor, Boards, Pulse, Work}
  alias SlipdockWeb.BoardNotices

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> BoardNotices.subscribe()
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

    waiting = Work.waiting_on_me(user)

    assign(socket,
      waiting: waiting,
      # The header's number is this section's length, never a second count.
      waiting_count: length(waiting),
      now: DateTime.utc_now(),
      sections: Work.group(cards, socket.assigns.show_done),
      open_count: length(open),
      done_count: length(cards) - length(open)
    )
  end

  @impl true
  def handle_info({:boards_changed}, socket) do
    Boards.drain_boards_changed()
    socket = BoardNotices.resubscribe(socket)
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

  # A wait answered from here: by choice button or in words.
  def handle_event("answer_wait", %{"card" => id} = params, socket) do
    user = socket.assigns.current_user
    card = Boards.get_card!(id)

    attrs = %{
      "choice" => params["choice"],
      "answer" => get_in(params, ["wait", "answer"]) || params["answer"]
    }

    with true <- Access.can_write?(Access.card_permission(user, card)),
         {:ok, _} <- Boards.answer_wait(card, Actor.web(user), attrs) do
      # `load/1` counts the header's number again, from the same section.
      {:noreply, load(socket)}
    else
      false -> {:noreply, put_flash(socket, :error, "You have read-only access to that card.")}
      {:error, message} when is_binary(message) -> {:noreply, put_flash(socket, :error, message)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "That answer couldn't be saved.")}
    end
  end

  defp since(item, now), do: Pulse.duration(max(DateTime.diff(now, item.since), 0))

  @impl true
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

          <section :if={@waiting != []} id="work-waiting" class="mb-8">
            <h2 class="mb-2 flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-warning">
              Waiting on you
              <span class="badge badge-ghost badge-sm font-mono">{length(@waiting)}</span>
            </h2>
            <ul class="divide-y divide-base-300/60 overflow-hidden rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/10">
              <li
                :for={item <- @waiting}
                id={"waiting-card-#{item.card.id}"}
                class="px-4 py-2.5 hover:bg-base-200/40"
              >
                <div class="flex items-center gap-3">
                  <.icon name="hero-hand-raised" class="size-5 shrink-0 text-warning" />
                  <div class="min-w-0 flex-1">
                    <.link
                      navigate={~p"/boards/#{item.card.board_id}/cards/#{item.card.id}"}
                      class="block truncate font-medium hover:underline"
                    >
                      {item.card.title}
                    </.link>
                    <p
                      class="truncate text-xs text-base-content/50"
                      title={Enum.join(item.path, " › ")}
                    >
                      {Enum.join(item.path, " › ")} · {item.card.column.name}
                    </p>
                  </div>
                  <span class="shrink-0 font-mono text-xs text-base-content/60">
                    {since(item, @now)}
                  </span>
                </div>
                <p class="mt-1 pl-8 text-sm text-base-content/80">{item.text}</p>
                <div :if={item.wait} class="mt-2 flex flex-wrap items-center gap-2 pl-8">
                  <button
                    :for={{choice, n} <- Enum.with_index(item.wait.choices, 1)}
                    type="button"
                    class="btn btn-outline btn-xs"
                    phx-click="answer_wait"
                    phx-value-card={item.card.id}
                    phx-value-choice={n}
                  >
                    {choice}
                  </button>
                  <form
                    id={"waiting-answer-#{item.card.id}"}
                    phx-submit="answer_wait"
                    class="flex min-w-0 flex-1 items-center gap-2"
                  >
                    <input type="hidden" name="card" value={item.card.id} />
                    <input
                      type="text"
                      name="wait[answer]"
                      placeholder="Answer…"
                      class="input input-bordered input-xs min-w-0 flex-1"
                      maxlength="4000"
                      required
                    />
                    <button type="submit" class="btn btn-primary btn-xs">Answer</button>
                  </form>
                </div>
              </li>
            </ul>
          </section>

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

defmodule SlipdockWeb.GardenLive.Index do
  @moduledoc """
  A board's Tidy-up page (W-1807): what the gardener found, grouped by
  check, each with its evidence, the cards and pages it is about and the
  steps applying it would take. Apply, dismiss or apply a whole group; a
  duplicate is shown side by side, to keep one; what was applied can be
  undone.

  Anyone who can read the board can look. Looking the board over again and
  every decision need write access.
  """
  use SlipdockWeb, :live_view

  import Ecto.Query

  alias Slipdock.{Access, Boards, Gardener, Repo}
  alias Slipdock.Boards.Card
  alias Slipdock.Gardener.{Steps, Suggestion}
  alias Slipdock.Palette
  alias Slipdock.Wiki.Page

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    with %Boards.Board{} = board <- Boards.get_board(id),
         perm = Access.board_permission(user, board),
         true <- Access.can_read?(perm) do
      if connected?(socket), do: Gardener.subscribe(board.id)

      {:ok,
       socket
       |> assign(
         board: board,
         can_write: Access.can_write?(perm),
         can_manage: perm == :owner,
         page_title: "Tidy up · #{board.name}",
         page_jumps: []
       )
       |> load()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to that board.")
         |> push_navigate(to: "/")}
    end
  end

  defp load(socket) do
    board = socket.assigns.board
    open = Gardener.list_open(board)
    applied = Gardener.list_applied(board, 10)
    all = open ++ applied

    assign(socket,
      groups: Enum.chunk_by(open, & &1.check),
      open_count: length(open),
      applied: applied,
      last_run: Gardener.last_run(board),
      cards: cards(Enum.flat_map(all, &Suggestion.card_ids/1)),
      pages: pages(Enum.flat_map(all, &Suggestion.page_ids/1))
    )
  end

  defp cards(ids) do
    from(c in Card,
      where: c.id in ^Enum.uniq(ids),
      preload: [:column]
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp pages(ids) do
    from(p in Page,
      where: p.id in ^Enum.uniq(ids),
      select: struct(p, [:id, :title, :slug, :board_id, :code])
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @impl true
  def handle_info({:garden_changed, _board_id}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event(_event, _params, %{assigns: %{can_write: false}} = socket),
    do: {:noreply, put_flash(socket, :error, "You have read-only access to this board.")}

  def handle_event("run", _params, socket) do
    {:ok, run} =
      Gardener.run(socket.assigns.board, trigger: "manual", user: socket.assigns.current_user)

    message =
      case run.counts do
        %{"total" => 0} -> "Looked the board over: nothing to tidy."
        %{"new" => n, "total" => t} -> "Looked the board over: #{t} suggestion(s), #{n} new."
      end

    {:noreply, socket |> put_flash(:info, message) |> load()}
  end

  def handle_event("apply", %{"id" => id} = params, socket) do
    with_suggestion(socket, id, fn s ->
      Gardener.apply(s, socket.assigns.current_user,
        choice: params["choice"],
        keep: params["keep"]
      )
    end)
  end

  def handle_event("dismiss", %{"id" => id}, socket),
    do: with_suggestion(socket, id, &Gardener.dismiss(&1, socket.assigns.current_user))

  def handle_event("undo", %{"id" => id}, socket),
    do: with_suggestion(socket, id, &Gardener.undo(&1, socket.assigns.current_user))

  # Every suggestion of one check, each on its own: one that can't be
  # applied (it wants a pick, or something moved on) is left, and said.
  def handle_event("apply_group", %{"check" => check}, socket) do
    user = socket.assigns.current_user

    results =
      for s <- Gardener.list_open(socket.assigns.board, check: check),
          not Steps.needs_pick?(s.proposal),
          do: Gardener.apply(s, user)

    failed = Enum.count(results, &(not match?({:ok, _}, &1)))
    done = length(results) - failed

    socket =
      if failed == 0,
        do: put_flash(socket, :info, "Applied #{done}."),
        else: put_flash(socket, :error, "Applied #{done}; #{failed} couldn't be applied.")

    {:noreply, load(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp with_suggestion(socket, id, fun) do
    board_id = socket.assigns.board.id

    case Gardener.get_suggestion(id) do
      %Suggestion{board_id: ^board_id} = s ->
        case fun.(s) do
          {:ok, _} ->
            {:noreply, load(socket)}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "You can't change everything that touches.")}

          {:error, message} ->
            {:noreply, socket |> put_flash(:error, message) |> load()}
        end

      _ ->
        {:noreply, socket}
    end
  end

  ## Words -------------------------------------------------------------------------

  defp label(check_key) do
    case Gardener.check(check_key) do
      nil -> check_key
      check -> check.label()
    end
  end

  # One step in words, naming the cards, pages and lists it touches.
  defp step_words(step, cards, pages) do
    card = card_name(step["card"], cards)

    case step["op"] do
      "complete" ->
        "Complete #{card}"

      "move" ->
        "Move #{card} to #{column_name(step["column"])}"

      "archive" ->
        if step["page"], do: "Archive #{page_name(step["page"], pages)}", else: "Archive #{card}"

      "link_duplicate" ->
        "Link #{card} as a duplicate of #{card_name(step["other"], cards)}"

      "flag" ->
        "Flag #{card} #{step["flag"]}"

      "comment" ->
        "Comment on #{card}: “#{step["body"]}”"

      "snooze" ->
        "Snooze #{card} until #{step["until"]}"

      "redate" ->
        "Re-date #{card} to #{step["due"]}"

      "rewrite_link" ->
        "Rewrite [[#{step["from"]}]] as [[#{step["to"]}]] on #{page_name(step["page"], pages)}"

      "file_page" ->
        "File #{page_name(step["page"], pages)} into a folder"

      op ->
        op
    end
  end

  defp card_name("pick", _cards), do: "the one not kept"
  defp card_name("keep", _cards), do: "the one kept"

  defp card_name(id, cards) do
    case cards[id] do
      nil -> "##{id}"
      c -> "“#{c.title}”"
    end
  end

  defp page_name(id, pages) do
    case pages[id] do
      nil -> "page #{id}"
      p -> "“#{p.title}”"
    end
  end

  defp column_name(id) do
    case Repo.get(Boards.Column, id) do
      nil -> "another list"
      col -> "“#{col.name}”"
    end
  end

  defp steps_text(steps, cards, pages),
    do: Enum.map_join(steps, "; ", &step_words(&1, cards, pages))

  defp card_path(%Card{} = c), do: ~p"/boards/#{c.board_id}/cards/#{c.id}"
  defp page_path(%Page{} = p), do: ~p"/boards/#{p.board_id}/wiki/#{p.slug}"

  defp when_text(nil), do: "never"
  defp when_text(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y, %H:%M UTC")

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
      nav_active={:boards}
      page_jumps={@page_jumps}
    >
      <:subnav>
        <nav class="flex min-w-0 items-center gap-1 text-sm">
          <.link
            navigate={~p"/boards/#{@board}"}
            class="flex min-w-0 items-center gap-2 rounded-lg px-2 py-1 hover:bg-base-200"
          >
            <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(@board.color)]}></span>
            <span class="truncate font-semibold">{@board.name}</span>
          </.link>
          <.icon name="hero-chevron-right" class="size-3 shrink-0 text-base-content/40" />
          <span class="px-2 py-1 font-semibold">Tidy up</span>
        </nav>
      </:subnav>
      <:subactions>
        <button
          :if={@can_write}
          id="garden-run"
          type="button"
          phx-click="run"
          phx-disable-with="Looking…"
          class="btn btn-primary btn-sm gap-1.5"
        >
          <.icon name="hero-sparkles" class="size-4" />
          <span class="hidden sm:inline">Look the board over</span>
        </button>
      </:subactions>

      <div id="garden-shell" class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl space-y-6 p-4 sm:p-6">
          <p class="text-sm text-base-content/60">
            The gardener looks this board, and every board beneath it, over for rot: epics done
            but still open, cards stuck in progress, likely duplicates, pages nothing links to,
            mistyped links. Nothing changes until you apply a suggestion, and one you dismiss
            stays dismissed until what it is about changes.
            Last looked over: <span id="garden-last-run">{when_text(@last_run && @last_run.finished_at)}</span>.
            <.link
              :if={@can_manage}
              navigate={~p"/boards/#{@board}/settings?tab=gardening"}
              class="link"
            >
              Choose the checks
            </.link>
          </p>

          <div
            :if={@groups == []}
            id="garden-empty"
            class="rounded-2xl bg-base-100 p-8 text-center shadow-sm ring-1 ring-base-content/10"
          >
            <.icon name="hero-sparkles" class="size-8 text-base-content/30" />
            <h2 class="mt-3 text-lg font-semibold">Nothing to tidy</h2>
            <p class="mx-auto mt-2 max-w-md text-sm text-base-content/60">
              {if @last_run,
                do: "Every suggestion has been dealt with.",
                else: "This board hasn't been looked over yet."}
            </p>
          </div>

          <section
            :for={[first | _] = group <- @groups}
            id={"garden-#{first.check}"}
            class="space-y-2"
          >
            <div class="flex items-center justify-between gap-2">
              <h2 class="text-base font-semibold">
                {label(first.check)} <span class="badge badge-ghost badge-sm">{length(group)}</span>
              </h2>
              <button
                :if={@can_write and length(group) > 1 and not Steps.needs_pick?(first.proposal)}
                id={"garden-apply-all-#{first.check}"}
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="apply_group"
                phx-value-check={first.check}
                data-confirm={"Apply all #{length(group)}?"}
              >
                Apply all in this group
              </button>
            </div>

            <ul class="space-y-2">
              <li
                :for={s <- group}
                id={"suggestion-#{s.id}"}
                class="space-y-2 rounded-xl bg-base-100 p-3 shadow-sm ring-1 ring-base-content/10"
              >
                <p class="text-sm">{s.explanation}</p>
                <div class="flex flex-wrap gap-1 text-xs">
                  <.link
                    :for={id <- Suggestion.card_ids(s)}
                    :if={@cards[id]}
                    navigate={card_path(@cards[id])}
                    class="chip chip-line"
                  >
                    #{id} {@cards[id].title}
                  </.link>
                  <.link
                    :for={id <- Suggestion.page_ids(s)}
                    :if={@pages[id]}
                    navigate={page_path(@pages[id])}
                    class="chip chip-line"
                  >
                    <.icon name="hero-document-text" class="size-3" /> {@pages[id].title}
                  </.link>
                </div>

                <%!-- A duplicate: the two side by side, keep one. --%>
                <div :if={Steps.needs_pick?(s.proposal)} class="grid gap-2 sm:grid-cols-2">
                  <div
                    :for={id <- Suggestion.card_ids(s)}
                    :if={@cards[id]}
                    id={"suggestion-#{s.id}-card-#{id}"}
                    class="flex flex-col gap-1 rounded-lg bg-base-200/60 p-2 text-sm"
                  >
                    <p class="font-medium">{@cards[id].title}</p>
                    <p class="text-xs text-base-content/50">
                      #{id} · {@cards[id].column && @cards[id].column.name} · updated {when_text(
                        @cards[id].updated_at
                      )}
                    </p>
                    <p class="line-clamp-4 text-xs text-base-content/70">{@cards[id].description}</p>
                    <button
                      :if={@can_write}
                      type="button"
                      class="btn btn-sm mt-auto"
                      phx-click="apply"
                      phx-value-id={s.id}
                      phx-value-keep={id}
                    >
                      Keep this one
                    </button>
                  </div>
                </div>

                <p :if={not Steps.needs_pick?(s.proposal)} class="text-xs text-base-content/60">
                  → {steps_text(s.proposal, @cards, @pages)}
                </p>

                <div :if={@can_write} class="flex flex-wrap items-center gap-1">
                  <button
                    :if={not Steps.needs_pick?(s.proposal)}
                    type="button"
                    class="btn btn-primary btn-xs"
                    phx-click="apply"
                    phx-value-id={s.id}
                  >
                    Apply
                  </button>
                  <button
                    :for={{name, steps} <- Enum.sort(s.alternatives || %{})}
                    type="button"
                    class="btn btn-xs"
                    phx-click="apply"
                    phx-value-id={s.id}
                    phx-value-choice={name}
                    title={steps_text(steps, @cards, @pages)}
                  >
                    {String.capitalize(name)}
                  </button>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="dismiss"
                    phx-value-id={s.id}
                  >
                    Dismiss
                  </button>
                </div>
              </li>
            </ul>
          </section>

          <section :if={@applied != []} id="garden-applied" class="space-y-2">
            <h2 class="text-sm font-semibold text-base-content/70">Recently applied</h2>
            <ul class="space-y-1">
              <li
                :for={s <- @applied}
                id={"applied-#{s.id}"}
                class="flex items-center gap-2 rounded-lg bg-base-200/50 px-3 py-1.5 text-sm"
              >
                <span class="min-w-0 flex-1 truncate" title={s.explanation}>{s.explanation}</span>
                <span class="shrink-0 text-xs text-base-content/50">
                  {s.decided_by && (s.decided_by.name || s.decided_by.email)}
                </span>
                <button
                  :if={@can_write}
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="undo"
                  phx-value-id={s.id}
                >
                  <.icon name="hero-arrow-uturn-left" class="size-3.5" /> Undo
                </button>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

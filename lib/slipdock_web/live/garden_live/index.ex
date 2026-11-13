defmodule SlipdockWeb.GardenLive.Index do
  @moduledoc """
  A board's Tidy-up page (W-1807): what the gardener found, grouped by
  check, each with its evidence, the cards and pages it is about and the
  steps applying it would take. Apply, dismiss, or apply or dismiss a whole group; a
  duplicate is shown side by side, to keep one; what was applied can be
  undone. A step that edits a page's section (a proposed handbook edit,
  #1788) shows the change as a diff against the section as it is now.

  Anyone who can read the board can look. Looking the board over again and
  every decision need write access.
  """
  use SlipdockWeb, :live_view
  alias SlipdockWeb.Dates

  alias Slipdock.{Access, Boards, Gardener}
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
       # The level is read again before every event (#2998).
       |> SlipdockWeb.LiveAccess.refresh_on_event(&assign_access/2)
       |> load()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to that board.")
         |> push_navigate(to: "/")}
    end
  end

  defp assign_access(socket, perm),
    do: assign(socket, can_write: Access.can_write?(perm), can_manage: perm == :owner)

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
      pages: pages(Enum.flat_map(all, &Suggestion.page_ids/1)),
      diffs: Map.new(open, &{&1.id, section_diffs(Gardener.mergeable(&1.proposal, &1))}),
      shared: Gardener.shared_sections(open)
    )
  end

  # Each edit_section step against the section as the page has it now: its
  # lines removed and added, or why it can't be shown. One whose section has
  # changed since shows what applying it would do now: its own lines merged
  # into the section (#2772), or why it would be refused.
  defp section_diffs(steps) do
    for %{"op" => "edit_section", "page" => id, "section" => path} = step <- steps do
      section_diff(Slipdock.Wiki.get_page(id), id, path, step)
    end
  end

  defp section_diff(nil, id, path, _step),
    do: %{page: id, section: path, lines: [], note: "The page has been deleted."}

  defp section_diff(page, id, path, step) do
    case Steps.section_edit(page, step) do
      {:ok, after_body, how} ->
        %{
          page: id,
          section: path,
          lines: diff_lines(page.body, after_body),
          note:
            if(how == :merged,
              do:
                "The section has changed since this was proposed. " <>
                  "Applying it now changes only its own lines, as shown."
            )
        }

      {:error, reason} ->
        lines =
          case Slipdock.Wiki.Section.replace(page.body, path, step["body"]) do
            {:ok, after_body, _} -> diff_lines(page.body, after_body)
            {:error, :not_found} -> []
          end

        %{page: id, section: path, lines: lines, note: "Applying it would be refused: " <> reason}
    end
  end

  # The open proposals this one shares a section with, in words.
  defp shared_words(entry, pages) do
    others = Enum.map_join(entry.with, ", ", &"##{&1}")

    "#{page_name(entry.page, pages)} §#{entry.section} is edited by #{others} too. " <>
      "Apply them one after another: each changes only its own lines of what the last left, " <>
      "and is refused only where they change the same lines."
  end

  # The changed lines, with a couple of unchanged ones either side.
  @diff_context 2

  defp diff_lines(old, new) do
    chunks = Slipdock.Wiki.diff(String.trim_trailing(old), String.trim_trailing(new))
    last = length(chunks) - 1

    chunks
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:eq, lines}, i} ->
        before = if i > 0, do: Enum.take(lines, @diff_context), else: []
        next = if i < last, do: Enum.take(lines, -@diff_context), else: []
        kept = if length(lines) > 2 * @diff_context, do: before ++ next, else: lines
        kept = if i == 0 or i == last, do: before ++ next, else: kept
        Enum.map(kept, &{:eq, &1})

      {{op, lines}, _i} ->
        Enum.map(lines, &{op, &1})
    end)
  end

  defp cards(ids), do: Boards.Cards.cards_by_id(ids)

  defp pages(ids), do: Slipdock.Wiki.page_stubs(ids)

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
        keep: params["keep"],
        actor: in_person(socket)
      )
    end)
  end

  def handle_event("dismiss", %{"id" => id}, socket),
    do:
      with_suggestion(
        socket,
        id,
        &Gardener.dismiss(&1, socket.assigns.current_user, actor: in_person(socket))
      )

  def handle_event("undo", %{"id" => id}, socket),
    do:
      with_suggestion(
        socket,
        id,
        &Gardener.undo(&1, socket.assigns.current_user, actor: in_person(socket))
      )

  # Every suggestion of one check, each on its own: one that can't be
  # applied (it wants a pick, or something moved on) is left, and said.
  def handle_event("apply_group", %{"check" => check}, socket) do
    user = socket.assigns.current_user

    results =
      for s <- Gardener.list_open(socket.assigns.board, check: check),
          not Steps.needs_pick?(s.proposal),
          do: Gardener.apply(s, user, actor: in_person(socket))

    failed = Enum.count(results, &(not match?({:ok, _}, &1)))
    done = length(results) - failed

    socket =
      if failed == 0,
        do: put_flash(socket, :info, "Applied #{done}."),
        else: put_flash(socket, :error, "Applied #{done}; #{failed} couldn't be applied.")

    {:noreply, load(socket)}
  end

  # Every suggestion of one check, dismissed each on its own (#3048). One
  # only a person decides (a handbook edit) is left to be decided by itself,
  # and said.
  def handle_event("dismiss_group", %{"check" => check}, socket) do
    user = socket.assigns.current_user

    {kept, mine} =
      socket.assigns.board
      |> Gardener.list_open(check: check)
      |> Enum.split_with(&Gardener.person_only?/1)

    results = Enum.map(mine, &Gardener.dismiss(&1, user, actor: in_person(socket)))
    left = length(kept) + Enum.count(results, &(not match?({:ok, _}, &1)))
    done = length(mine) + length(kept) - left

    socket =
      if left == 0,
        do: put_flash(socket, :info, "Dismissed #{done}."),
        else: put_flash(socket, :error, "Dismissed #{done}; #{left} left to decide one by one.")

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

  defp label(check_key), do: Gardener.label(check_key)

  # One step in words, naming the cards, pages and lists it touches.
  defp step_words(%{"op" => "archive", "page" => page}, _cards, pages) when not is_nil(page),
    do: "Archive #{page_name(page, pages)}"

  defp step_words(%{"op" => "rewrite_link"} = step, _cards, pages),
    do: "Rewrite [[#{step["from"]}]] as [[#{step["to"]}]] on #{page_name(step["page"], pages)}"

  defp step_words(%{"op" => "file_page"} = step, _cards, pages),
    do: "File #{page_name(step["page"], pages)} into a folder"

  defp step_words(%{"op" => "edit_section"} = step, _cards, pages),
    do: "Edit §#{step["section"]} of #{page_name(step["page"], pages)}"

  defp step_words(%{"op" => "comment", "page" => page} = step, _cards, pages)
       when not is_nil(page),
       do: "Comment on #{page_name(page, pages)}: “#{step["body"]}”"

  defp step_words(%{"op" => "link_duplicate"} = step, cards, _pages),
    do:
      "Link #{card_name(step["card"], cards)} as a duplicate of #{card_name(step["other"], cards)}"

  defp step_words(%{"op" => op} = step, cards, _pages),
    do: card_step_words(op, card_name(step["card"], cards), step)

  defp card_step_words("complete", card, _step), do: "Complete #{card}"
  defp card_step_words("move", card, step), do: "Move #{card} to #{column_name(step["column"])}"
  defp card_step_words("archive", card, _step), do: "Archive #{card}"
  defp card_step_words("flag", card, step), do: "Flag #{card} #{step["flag"]}"
  defp card_step_words("comment", card, step), do: "Comment on #{card}: “#{step["body"]}”"
  defp card_step_words("snooze", card, step), do: "Snooze #{card} until #{step["until"]}"
  defp card_step_words("redate", card, step), do: "Re-date #{card} to #{step["due"]}"
  defp card_step_words(op, _card, _step), do: op

  defp diff_mark(:del), do: "-"
  defp diff_mark(:ins), do: "+"
  defp diff_mark(:eq), do: " "

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
    case Boards.Columns.get_column(id) do
      nil -> "another list"
      col -> "“#{col.name}”"
    end
  end

  defp steps_text(steps, cards, pages),
    do: Enum.map_join(steps, "; ", &step_words(&1, cards, pages))

  defp card_path(%Card{} = c), do: ~p"/boards/#{c.board_id}/cards/#{c.id}"
  defp page_path(%Page{} = p), do: ~p"/boards/#{p.board_id}/wiki/#{p.slug}"

  defp when_text(nil), do: "never"
  defp when_text(%DateTime{} = at), do: Dates.exact(at)

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
        <.page width="standard" class="space-y-6">
          <.page_header id="garden-title" title="Tidy up">
            <:meta>
              Suggestions for keeping this board and its sub-boards tidy. Nothing changes until you apply one.
              <span class="mt-1 block text-xs">
                Last looked over: <span id="garden-last-run">{when_text(@last_run && @last_run.finished_at)}</span>.
                <.link
                  :if={@can_manage}
                  navigate={~p"/boards/#{@board}/settings?tab=gardening"}
                  class="link"
                >
                  Choose the checks
                </.link>
              </span>
            </:meta>
          </.page_header>

          <.empty_state
            :if={@groups == []}
            id="garden-empty"
            icon="hero-sparkles"
            title="Nothing to tidy"
          >
            {if @last_run,
              do: "Every suggestion has been dealt with.",
              else:
                "Look the board over for finished epics left open, stuck cards, duplicates and pages nothing links to."}
            <:action :if={@can_write}>
              <button
                id="garden-empty-run"
                type="button"
                phx-click="run"
                phx-disable-with="Looking…"
                class="btn btn-primary btn-sm gap-1.5"
              >
                <.icon name="hero-sparkles" class="size-4" /> Look the board over
              </button>
            </:action>
          </.empty_state>

          <section
            :for={[first | _] = group <- @groups}
            id={"garden-#{first.check}"}
            class="space-y-2"
          >
            <div class="flex items-center justify-between gap-2">
              <h2 class="section-title">
                {label(first.check)} <span class="badge badge-ghost badge-sm">{length(group)}</span>
              </h2>
              <div
                :if={@can_write and length(group) > 1 and not Gardener.person_only?(first)}
                class="flex items-center gap-1"
              >
                <button
                  :if={not Steps.needs_pick?(first.proposal)}
                  id={"garden-apply-all-#{first.check}"}
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="apply_group"
                  phx-value-check={first.check}
                  data-confirm={"Apply all #{length(group)}?"}
                >
                  Apply all in this group
                </button>
                <button
                  id={"garden-dismiss-all-#{first.check}"}
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="dismiss_group"
                  phx-value-check={first.check}
                  data-confirm={"Dismiss all #{length(group)}? A dismissal can't be undone here."}
                >
                  Dismiss all in this group
                </button>
              </div>
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

                <%!-- Proposals that edit the same section (#2772). --%>
                <.callout
                  :for={{entry, i} <- Enum.with_index(@shared[s.id] || [])}
                  id={"suggestion-#{s.id}-shared-#{i}"}
                  kind={:info}
                >
                  {shared_words(entry, @pages)}
                </.callout>

                <%!-- A section edit: what it changes, against the page as it is now. --%>
                <div
                  :for={{d, i} <- Enum.with_index(@diffs[s.id] || [])}
                  id={"suggestion-#{s.id}-diff-#{i}"}
                  class="rounded-lg border border-base-300 text-xs"
                >
                  <p class="border-b border-base-300 px-2 py-1 font-medium text-base-content/70">
                    {page_name(d.page, @pages)} §{d.section}
                  </p>
                  <.callout :if={d.note} kind={:warning}>{d.note}</.callout>
                  <pre class="overflow-x-auto px-2 py-1 font-mono leading-5"><span
                      :for={{op, line} <- d.lines}
                      class={[
                        "block whitespace-pre-wrap",
                        op == :del && "bg-error/10 text-error",
                        op == :ins && "bg-success/10 text-success",
                        op == :eq && "text-base-content/50"
                      ]}
                      data-op={op}
                    >{diff_mark(op)} {line}</span></pre>
                </div>

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
        </.page>
      </div>
    </Layouts.app>
    """
  end

  # The signed-in person deciding here: the only decider a person-only
  # suggestion accepts (`Gardener.in_person?/1`).
  defp in_person(socket), do: Slipdock.Actor.web(socket.assigns.current_user)
end

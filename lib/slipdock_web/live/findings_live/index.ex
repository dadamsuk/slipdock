defmodule SlipdockWeb.FindingsLive.Index do
  @moduledoc """
  A board tree's Findings page (W-2310 §Findings, see `Slipdock.Findings`):
  what passes learned and what the system saw go wrong, kept on the tree's
  root board for a person to triage.

  It lists what `GET /api/boards/:board/findings` lists, with the same
  filters (`status`, open by default; `kind`, `source`, `card`, `since`),
  kept in the URL. Anyone who can read the board can look; with write access
  a finding can be promoted (with a note), dismissed, merged into another
  finding of the tree or reopened, through `Slipdock.Findings.triage/3` as
  `PATCH /api/findings/:id` does. Promote and merge are a panel opened at
  `?triage=<id>`, so it survives a reload (UX-5).
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Access, Boards, Findings}
  alias Slipdock.Boards.Board
  alias Slipdock.Findings.Finding
  alias Slipdock.{Palette, Repo}
  alias SlipdockWeb.Params

  import SlipdockWeb.SlipdockComponents, only: [modal: 1]

  @filters ~w(status kind source card since scope)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    with %Board{} = board <- Boards.get_board(id),
         true <- Access.can_read?(Access.board_permission(user, board)),
         root = root(board),
         perm = Access.board_permission(user, root),
         true <- Access.can_read?(perm) do
      {:ok,
       assign(socket,
         board: board,
         root: root,
         can_write: Access.can_write?(perm),
         page_title: "Findings · #{board.name}",
         page_jumps: []
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to that board.")
         |> push_navigate(to: "/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Map.new(@filters, &{&1, params[&1] || ""})
    filters = if filters["status"] == "", do: %{filters | "status" => "open"}, else: filters

    {:noreply,
     socket |> assign(filters: filters, triage_id: Params.id(params["triage"])) |> load()}
  end

  defp load(socket) do
    %{root: root, filters: filters} = socket.assigns

    {findings, error} =
      case Findings.list(root, filters) do
        {:ok, findings} ->
          {findings, nil}

        {:error, message} ->
          {elem(Findings.list(root, %{filters | "since" => "", "scope" => ""}), 1), message}
      end

    triage = socket.assigns.triage_id && triage_finding(root, socket.assigns.triage_id)

    assign(socket,
      findings: findings,
      filter_error: error,
      filter_form: to_form(filters, as: :filters),
      triage: triage,
      panel_error: nil,
      promote_form: to_form(%{"note" => ""}, as: :promote),
      merge_form: to_form(%{"into" => ""}, as: :merge),
      merge_options: if(triage, do: merge_options(root, triage), else: [])
    )
  end

  # The finding the panel is open on: one of this tree's, or none.
  defp triage_finding(root, id) do
    case Findings.get(id) do
      %Finding{board_id: board_id} = finding when board_id == root.id -> finding
      _ -> nil
    end
  end

  # What a finding can merge into: the tree's other open findings.
  defp merge_options(root, finding) do
    {:ok, open} = Findings.list(root, %{"status" => "open", "scope" => "all"})

    for f <- open, f.id != finding.id do
      {"##{f.id} #{f.kind}: #{String.slice(f.text, 0, 80)}", f.id}
    end
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = Map.new(@filters, &{&1, String.trim(params[&1] || "")})
    {:noreply, push_patch(socket, to: findings_path(socket.assigns.board, filters, nil))}
  end

  def handle_event(event, _params, %{assigns: %{can_write: false}} = socket)
      when event in ~w(promote dismiss merge reopen),
      do: {:noreply, put_flash(socket, :error, "You have read-only access to this board.")}

  def handle_event(action, %{"id" => id} = params, socket)
      when action in ~w(promote dismiss merge reopen) do
    with %Finding{} = finding <- triage_finding(socket.assigns.root, Params.id(id)),
         {:ok, _} <- Findings.triage(finding, action, triage_params(action, params)) do
      {:noreply,
       socket
       |> put_flash(:info, done_text(action, finding))
       |> push_patch(to: findings_path(socket.assigns.board, socket.assigns.filters, nil))}
    else
      nil -> {:noreply, refused(socket, action, "That finding isn't on this board.")}
      {:error, %Ecto.Changeset{}} -> {:noreply, refused(socket, action, "Couldn't save that.")}
      {:error, message} -> {:noreply, refused(socket, action, message)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The panel's forms post `promote[note]` and `merge[into]`; a row's buttons
  # (and the API's shape) post them flat.
  defp triage_params("promote", params),
    do: %{"note" => params["promote"]["note"] || params["note"]}

  defp triage_params("merge", params), do: %{"into" => params["merge"]["into"] || params["into"]}
  defp triage_params(_action, params), do: Map.take(params, ["note"])

  # A refusal from the panel is said in the panel (UX-29); one from a row's
  # button, on the page.
  defp refused(%{assigns: %{triage: %Finding{}}} = socket, action, message)
       when action in ~w(promote merge),
       do: assign(socket, panel_error: message)

  defp refused(socket, _action, message), do: put_flash(socket, :error, message)

  defp done_text("promote", f), do: "Finding ##{f.id} promoted."
  defp done_text("dismiss", f), do: "Finding ##{f.id} dismissed."
  defp done_text("merge", f), do: "Finding ##{f.id} merged."
  defp done_text("reopen", f), do: "Finding ##{f.id} reopened."

  # The page's URL with these filters (blank and default ones left out) and the panel.
  defp findings_path(board, filters, triage) do
    query =
      filters
      |> Enum.reject(fn {k, v} ->
        blank?(v) or Enum.member?([{"status", "open"}, {"scope", "board"}], {k, v})
      end)
      |> Map.new()
      |> then(&if(triage, do: Map.put(&1, "triage", triage), else: &1))

    ~p"/boards/#{board}/findings?#{query}"
  end

  defp blank?(v), do: is_nil(v) or v == ""

  # The other cards the lesson was said on: those merged into it (#1941).
  defp also(%Finding{card_id: own, cards: cards}), do: Enum.reject(cards || [], &(&1.id == own))

  defp runner_name(%Finding{runner: %Slipdock.Runners.Runner{name: name}}), do: name
  defp runner_name(_finding), do: nil

  defp root(%Board{root_id: nil} = board), do: board
  defp root(%Board{root_id: id}), do: Repo.get!(Board, id)

  defp status_options,
    do:
      [{"Open", "open"}, {"Promoted", "promoted"}, {"Dismissed", "dismissed"}] ++
        [{"Merged", "merged"}, {"Any status", "all"}]

  # A runner's tooling (#1941) is about one machine, so it is out of the
  # board's list unless asked for.
  defp scope_options,
    do: [{"The project", "board"}, {"Runners' tooling", "runner"}, {"Both", "all"}]

  defp status_class("open"), do: "badge-info"
  defp status_class("promoted"), do: "badge-success"
  defp status_class("merged"), do: "badge-ghost"
  defp status_class(_), do: "badge-ghost"

  attr :finding, :map, required: true
  attr :can_write, :boolean, required: true
  attr :triage_path, :string, required: true

  defp finding_row(assigns) do
    ~H"""
    <li
      id={"finding-#{@finding.id}"}
      class="space-y-1 rounded-xl bg-base-100 p-3 shadow-sm ring-1 ring-base-content/10"
    >
      <div class="flex flex-wrap items-center gap-2 text-xs">
        <span class="badge badge-sm badge-outline" data-role="kind">{@finding.kind}</span>
        <span class="text-base-content/60" data-role="source">{@finding.source}</span>
        <span :if={@finding.count > 1} class="badge badge-sm badge-warning" data-role="count">
          ×{@finding.count}
        </span>
        <span
          :if={@finding.status != "open"}
          class={["badge badge-sm", status_class(@finding.status)]}
        >
          {@finding.status}{if @finding.merged_into_id, do: " into ##{@finding.merged_into_id}"}
        </span>
        <span class="text-base-content/50">#{@finding.id}</span>
        <.link
          :if={@finding.card}
          navigate={~p"/boards/#{@finding.card.board_id}/cards/#{@finding.card.id}"}
          class="link"
          data-role="card"
        >
          #{@finding.card.id} {@finding.card.title}
        </.link>
        <span :if={also(@finding) != []} class="text-base-content/60" data-role="also">
          also
          <.link
            :for={c <- also(@finding)}
            navigate={~p"/boards/#{c.board_id}/cards/#{c.id}"}
            class="link"
          >
            #{c.id}
          </.link>
        </span>
        <span :if={@finding.scope == "runner"} class="badge badge-sm badge-ghost" data-role="runner">
          runner{if runner_name(@finding), do: " #{runner_name(@finding)}"}
        </span>
        <span :if={@finding.by} class="text-base-content/50" data-role="by">by {@finding.by}</span>
        <%!-- The rule drafted for it once it was seen often enough (#1942). --%>
        <.link
          :if={@finding.proposal_id}
          navigate={~p"/boards/#{@finding.board_id}/tidy"}
          class="badge badge-sm badge-outline"
          data-role="proposal"
          title="A rule drafted from this finding, for you to apply or dismiss on the Tidy-up page"
        >
          proposal #{@finding.proposal_id}{if @finding.proposed_rule,
            do: " · #{@finding.proposed_rule}"}
        </.link>
        <div :if={@can_write} class="ml-auto flex items-center gap-1" data-role="triage">
          <%= if @finding.status == "open" do %>
            <.link
              patch={@triage_path}
              id={"finding-triage-#{@finding.id}"}
              class="btn btn-ghost btn-xs"
            >
              Promote or merge…
            </.link>
            <button
              type="button"
              id={"finding-dismiss-#{@finding.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="dismiss"
              phx-value-id={@finding.id}
            >
              Dismiss
            </button>
          <% else %>
            <button
              type="button"
              id={"finding-reopen-#{@finding.id}"}
              class="btn btn-ghost btn-xs"
              phx-click="reopen"
              phx-value-id={@finding.id}
            >
              Reopen
            </button>
          <% end %>
        </div>
      </div>
      <p class="whitespace-pre-wrap text-sm" data-role="text">{@finding.text}</p>
      <p :if={@finding.note} class="text-xs text-base-content/60" data-role="note">
        Note: {@finding.note}
      </p>
    </li>
    """
  end

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

      <div id="findings-shell" class="kanban-scroll h-full overflow-y-auto">
        <.page width="standard" class="space-y-6">
          <.page_header id="findings-title" title="Findings">
            <:meta>
              What passes learned on this board and the boards beneath it, and what the system saw go wrong: promote what should become a handbook rule, merge repeats, dismiss the rest.
            </:meta>
          </.page_header>

          <.form
            for={@filter_form}
            id="findings-filters"
            phx-change="filter"
            phx-submit="filter"
            class="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-6"
          >
            <.input
              field={@filter_form[:status]}
              type="select"
              label="Status"
              options={status_options()}
            />
            <.input
              field={@filter_form[:kind]}
              type="select"
              label="Kind"
              prompt="Any kind"
              options={Finding.kinds()}
            />
            <.input
              field={@filter_form[:source]}
              type="select"
              label="Source"
              prompt="Any source"
              options={Finding.sources()}
            />
            <.input
              field={@filter_form[:card]}
              type="text"
              label="Card"
              placeholder="id"
              inputmode="numeric"
              phx-debounce="400"
            />
            <.input
              field={@filter_form[:since]}
              type="text"
              label="Since"
              placeholder="days or a date"
              phx-debounce="400"
            />
            <.input
              field={@filter_form[:scope]}
              type="select"
              label="Scope"
              options={scope_options()}
            />
          </.form>

          <.callout :if={@filter_error} id="findings-filter-error" kind={:error}>
            {@filter_error}
          </.callout>

          <.empty_state
            :if={@findings == []}
            id="findings-empty"
            icon="hero-light-bulb"
            title="No findings"
          >
            Passes write what a card taught them in a <code>Findings:</code>
            block in their closing comment, and the system records rejections, timeouts and other signals; they appear here to triage.
          </.empty_state>

          <section :if={@findings != []} id="findings-list" class="space-y-2">
            <h2 class="section-title">
              Findings <span class="badge badge-ghost badge-sm">{length(@findings)}</span>
            </h2>
            <ul class="space-y-2">
              <.finding_row
                :for={f <- @findings}
                finding={f}
                can_write={@can_write}
                triage_path={findings_path(@board, @filters, f.id)}
              />
            </ul>
          </section>
        </.page>
      </div>

      <.modal
        :if={@triage && @can_write}
        id="finding-panel"
        size="md"
        on_close={JS.patch(findings_path(@board, @filters, nil))}
      >
        <div class="space-y-5">
          <.callout :if={@panel_error} id="finding-panel-error" kind={:error}>
            {@panel_error}
          </.callout>

          <div class="space-y-1">
            <p class="text-xs text-base-content/60">
              Finding #{@triage.id} · {@triage.kind} · {@triage.source}
            </p>
            <p class="whitespace-pre-wrap text-sm">{@triage.text}</p>
          </div>

          <.form
            for={@promote_form}
            id="finding-promote"
            phx-submit="promote"
            phx-value-id={@triage.id}
            class="space-y-2"
          >
            <.input
              field={@promote_form[:note]}
              type="textarea"
              id="finding-promote-note"
              label="Promote: what it became"
              placeholder="W-1950 §Tests TEST-9"
            />
            <button type="submit" class="btn btn-primary btn-sm">Promote</button>
          </.form>

          <.form
            :if={@merge_options != []}
            for={@merge_form}
            id="finding-merge"
            phx-submit="merge"
            phx-value-id={@triage.id}
            class="space-y-2"
          >
            <.input
              field={@merge_form[:into]}
              type="select"
              id="finding-merge-into"
              label="Merge into another finding (it takes this one's count)"
              options={@merge_options}
            />
            <button type="submit" class="btn btn-sm">Merge</button>
          </.form>
        </div>
      </.modal>
    </Layouts.app>
    """
  end
end

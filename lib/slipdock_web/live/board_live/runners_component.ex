defmodule SlipdockWeb.BoardLive.RunnersComponent do
  @moduledoc """
  The Runners part of a board's Automations panel: the runners taking jobs
  from the board's tree, and **Connect a runner**, the wizard that turns a
  scenario and a few options into exactly what to paste (see
  `Slipdock.Runners.Setup`, which the API and the CLI print from too).

  Like the rest of the panel it is the board owner's alone, and checks that
  for itself on every event.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents, only: [relative_time: 1]
  import SlipdockWeb.BoardLive.Helpers, only: [flash: 3]

  alias Slipdock.{Access, Automations, Runners}
  alias Slipdock.Automations.Spec
  alias Slipdock.Runners.{Drift, Runner, Setup}

  @events ~w(open_wizard close_wizard wizard_change connect regenerate rotate_token
    revoke_runner close_setup close_dialog show_runner
    open_pause pause_change pause cancel_pause resume)

  @doc false
  def events, do: @events

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       runners: [],
       steps: %{},
       wizard: nil,
       wizard_error: nil,
       setup: nil,
       setup_runner: nil,
       token: nil,
       shown: nil,
       details: nil,
       # The pause form (#1116): nil, :tree, or the pool it would hold.
       pausing: nil,
       pause_reason: "",
       pauses: []
     )}
  end

  @impl true
  def update(assigns, socket) do
    %{board: board, current_user: user} = assigns

    {:ok,
     socket
     |> assign(
       board: board,
       current_user: user,
       base_url: Slipdock.Automations.Runner.base_url(),
       can_manage: Access.board_permission(user, board) == :owner
     )
     |> assign_runners()}
  end

  defp assign_runners(%{assigns: %{can_manage: true, board: board}} = socket) do
    runners = Runners.list_runners(board)

    socket
    |> assign(runners: runners, steps: Runners.current_steps(runners))
    |> assign(pauses: Runners.pauses(board))
    |> assign_details()
  end

  defp assign_runners(socket),
    do: assign(socket, runners: [], steps: %{}, shown: nil, details: nil, pauses: [])

  # The runner whose details are open, read again whenever the list is: a
  # revoked one closes them.
  defp assign_details(%{assigns: %{shown: nil}} = socket), do: assign(socket, details: nil)

  defp assign_details(%{assigns: %{shown: id, runners: runners}} = socket) do
    case Enum.find(runners, &(&1.id == id)) do
      nil -> assign(socket, shown: nil, details: nil)
      runner -> assign(socket, details: Runners.runner_details(runner))
    end
  end

  ## Events ------------------------------------------------------------------

  @impl true
  def handle_event(event, _params, socket) when event not in @events,
    do: {:noreply, flash(socket, :error, "That isn't something this page can do.")}

  def handle_event(_event, _params, %{assigns: %{can_manage: false}} = socket),
    do: {:noreply, flash(socket, :error, "Only the board's owner can do that.")}

  def handle_event("open_wizard", params, socket) do
    # The daemon is offered first (#2572).
    scenario = params["scenario"] || "daemon"

    answers =
      Map.merge(Setup.defaults(), %{"scenario" => scenario, "cwd" => Setup.default_cwd(scenario)})

    {:noreply, assign(socket, wizard: wizard(answers), wizard_error: nil, setup: nil, token: nil)}
  end

  def handle_event("close_wizard", _params, socket),
    do: {:noreply, assign(socket, wizard: nil, wizard_error: nil)}

  def handle_event("wizard_change", %{"wizard" => params}, socket) do
    params = push_needs_commit(params)
    {:noreply, assign(socket, wizard: wizard(params), wizard_error: nil)}
  end

  def handle_event("connect", %{"wizard" => params}, socket) do
    %{board: board, current_user: user, base_url: base_url} = socket.assigns

    case Setup.connect(board, sends(params), user, base_url) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(wizard: nil, setup: result.setup, setup_runner: nil, token: nil)
         |> assign_runners()
         |> refresh_automations(result.rule || result.alert_rule)}

      {:error, message} ->
        {:noreply, assign(socket, wizard: wizard(params), wizard_error: message)}
    end
  end

  def handle_event("regenerate", %{"id" => id}, socket) do
    with {:ok, runner} <- Runners.find_runner(socket.assigns.board, id) do
      setup = Setup.regenerate(runner, socket.assigns.board, socket.assigns.base_url)

      {:noreply, assign(socket, wizard: nil, setup: setup, setup_runner: runner, token: nil)}
    else
      _ -> {:noreply, flash(socket, :error, "That runner is gone.")}
    end
  end

  def handle_event("rotate_token", %{"id" => id}, socket) do
    with {:ok, runner} <- Runners.find_runner(socket.assigns.board, id),
         {:ok, runner, token} <- Runners.rotate_token(runner) do
      setup = Setup.regenerate(runner, socket.assigns.board, socket.assigns.base_url, token)

      {:noreply,
       socket
       |> assign(setup: setup, setup_runner: runner, token: token)
       |> flash(:info, "New token made: the old one no longer works.")}
    else
      _ -> {:noreply, flash(socket, :error, "That runner is gone.")}
    end
  end

  def handle_event("revoke_runner", %{"id" => id}, socket) do
    with {:ok, runner} <- Runners.find_runner(socket.assigns.board, id),
         {:ok, _} <- Runners.delete_runner(runner) do
      setup? =
        match?(%Runner{}, socket.assigns.setup_runner) and
          socket.assigns.setup_runner.id == runner.id

      {:noreply,
       socket
       |> assign_runners()
       |> refresh_automations(runner)
       |> then(&if(setup?, do: assign(&1, setup: nil, setup_runner: nil, token: nil), else: &1))
       |> flash(:info, "Runner “#{runner.name}” revoked: its token no longer works.")}
    else
      _ -> {:noreply, flash(socket, :error, "That runner is gone.")}
    end
  end

  # Clicking a runner opens what is known about it under its row; clicking it
  # again closes it.
  # Pausing (#1116): a reason first, always; the button waits for one.
  def handle_event("open_pause", params, socket) do
    pausing = if Enum.member?([nil, ""], params["pool"]), do: :tree, else: params["pool"]
    {:noreply, assign(socket, pausing: pausing, pause_reason: "")}
  end

  def handle_event("pause_change", %{"reason" => reason}, socket),
    do: {:noreply, assign(socket, pause_reason: reason)}

  def handle_event("cancel_pause", _params, socket),
    do: {:noreply, assign(socket, pausing: nil, pause_reason: "")}

  def handle_event("pause", %{"reason" => reason}, %{assigns: %{pausing: pausing}} = socket)
      when not is_nil(pausing) do
    %{board: board, current_user: user} = socket.assigns
    pool = if pausing == :tree, do: nil, else: pausing

    case Runners.pause(
           board,
           %{"pool" => pool, "reason" => reason},
           user,
           Slipdock.Actor.web(user)
         ) do
      {:ok, pause} ->
        send(self(), :reload_board)

        {:noreply,
         socket
         |> assign(pausing: nil, pause_reason: "", pauses: Runners.pauses(board))
         |> flash(:info, "Paused #{Runners.Pause.scope(pause)}.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, flash(socket, :error, "Not paused: #{inspect_errors(changeset)}")}

      {:error, message} ->
        {:noreply, flash(socket, :error, message)}
    end
  end

  def handle_event("pause", _params, socket), do: {:noreply, socket}

  def handle_event("resume", params, socket) do
    %{board: board, current_user: user} = socket.assigns

    case Runners.resume(board, params["pool"], user, Slipdock.Actor.web(user)) do
      {:ok, pause} ->
        send(self(), :reload_board)

        {:noreply,
         socket
         |> assign(pauses: Runners.pauses(board))
         |> flash(:info, "Resumed #{Runners.Pause.scope(pause)}.")}

      {:error, message} ->
        {:noreply, socket |> assign(pauses: Runners.pauses(board)) |> flash(:error, message)}
    end
  end

  def handle_event("show_runner", %{"id" => id}, socket) do
    case Runners.find_runner(socket.assigns.board, id) do
      {:ok, %Runner{id: id}} when id == socket.assigns.shown ->
        {:noreply, assign(socket, shown: nil, details: nil)}

      {:ok, runner} ->
        {:noreply, assign(socket, shown: runner.id, details: Runners.runner_details(runner))}

      _ ->
        {:noreply, flash(socket, :error, "That runner is gone.")}
    end
  end

  def handle_event("close_setup", _params, socket),
    do: {:noreply, assign(socket, setup: nil, setup_runner: nil, token: nil)}

  # The dialog closed itself (Escape, or a click outside): the wizard or the
  # steps, whichever it held, go too.
  def handle_event("close_dialog", _params, socket),
    do:
      {:noreply,
       assign(socket, wizard: nil, wizard_error: nil, setup: nil, setup_runner: nil, token: nil)}

  # "Which cards does it get?" is one select: a list for a new rule, or a
  # rule already there.
  defp sends(params) do
    case params["send"] do
      "column:" <> name -> Map.put(params, "column", name)
      "top:" <> name -> Map.merge(params, %{"column" => name, "feed" => "top"})
      "rule:" <> id -> Map.put(params, "rule_id", id)
      _ -> params
    end
  end

  # A rule the wizard added shows in the panel's list of rules straight away,
  # and a runner made or revoked shows or hides the preset that sends to one.
  defp refresh_automations(socket, nil), do: socket

  defp refresh_automations(socket, _changed) do
    send_update(SlipdockWeb.BoardLive.AutomationsComponent, id: "automations", refresh: true)
    socket
  end

  # Unticking commit unticks push, which is greyed out without it, rather than
  # showing an error for a box that can't be changed. Switching to ChatGPT,
  # which has no repository, unticks both.
  defp push_needs_commit(params) do
    cond do
      not Setup.commits?(params) -> Map.merge(params, %{"commit" => "false", "push" => "false"})
      ticked?(params["commit"]) -> params
      true -> Map.put(params, "push", "false")
    end
  end

  # The six things a job may do to the card, in the order a job meets them.
  # Not assigning it (#2027): while a job holds the card it shows the runner
  # as its loop, and an assignment made with the owner's token would name
  # the owner instead.
  defp toggle_labels do
    [
      {"in_progress", "Move to In Progress when running"},
      {"commit", "Git commit when done"},
      {"push", "Git push when done"},
      {"move_done", "Move to Done when done"},
      {"complete", "Mark as complete when done"},
      {"percent_100", "Mark as 100% when done"}
    ]
  end

  defp ticked?(value), do: Enum.member?([true, "true"], value)

  # The form's values, and the steps they'd give — a preview with the token
  # left out until the runner is made.
  defp wizard(params) do
    %{params: Map.merge(Setup.defaults(), params), preview: Setup.normalise(params)}
  end

  ## Render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    runner_rules = runner_rules(assigns.board)

    assigns =
      assign(assigns,
        runner_rules: runner_rules,
        waiting_pools: waiting_pools(runner_rules, assigns.runners, assigns.can_manage),
        pools: pools(runner_rules, assigns.runners),
        tree_pause: Enum.find(assigns.pauses, &is_nil(&1.pool)),
        preview: preview(assigns)
      )

    ~H"""
    <div id="board-runners" class="space-y-3 border-t border-base-content/10 pt-4">
      <div class="flex items-center justify-between gap-2">
        <div>
          <p class="text-sm font-medium">Runners</p>
          <p class="text-xs text-base-content/60">
            Send cards to a coding agent or LLM on your own machine, to Claude on a schedule, or to ChatGPT
          </p>
        </div>
        <div class="flex shrink-0 items-center gap-1">
          <%!-- Health, Findings and the Ledger are reached from the board's
                Agentic Building page (#2012), not from here. --%>
          <%!-- The whole tree's brake (#1116); a pool's is on its row. --%>
          <button
            :if={@can_manage and is_nil(@tree_pause)}
            phx-target={@myself}
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="open_pause"
            id="pause-tree"
            title="Hold every runner job and list send on this board tree"
          >
            <.icon name="hero-pause" class="size-4" /> Pause
          </button>
          <button
            :if={@can_manage and @tree_pause}
            phx-target={@myself}
            type="button"
            class="btn btn-warning btn-sm"
            phx-click="resume"
            id="resume-tree"
          >
            <.icon name="hero-play" class="size-4" /> Resume
          </button>
          <button
            :if={@can_manage and is_nil(@wizard)}
            phx-target={@myself}
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="open_wizard"
            id="connect-runner"
          >
            <.icon name="hero-plus" class="size-4" /> Connect a runner
          </button>
        </div>
      </div>

      <p :if={@tree_pause} id="runners-tree-paused" class="text-xs text-warning">
        The whole tree is {Runners.Pause.line(@tree_pause)}
      </p>

      <.pause_form
        :if={@pausing}
        pausing={@pausing}
        reason={@pause_reason}
        target={@myself}
      />

      <ul :if={@can_manage and @pools != []} id="runner-pools" class="space-y-1">
        <li
          :for={pool <- @pools}
          id={"runner-pool-#{pool}"}
          class="flex items-center gap-2 rounded-lg px-2 py-1 text-sm odd:bg-base-200/40"
        >
          <% paused = Enum.find(@pauses, &(&1.pool == pool)) %>
          <.icon name="hero-queue-list" class="size-4 shrink-0 text-base-content/50" />
          <span class="min-w-0 flex-1 truncate">
            pool {pool}
            <span :if={paused} class="text-xs text-warning">· {Runners.Pause.line(paused)}</span>
          </span>
          <button
            :if={is_nil(paused)}
            phx-target={@myself}
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="open_pause"
            phx-value-pool={pool}
            id={"pause-pool-#{pool}"}
          >
            Pause
          </button>
          <button
            :if={paused}
            phx-target={@myself}
            type="button"
            class="btn btn-warning btn-xs"
            phx-click="resume"
            phx-value-pool={pool}
            id={"resume-pool-#{pool}"}
          >
            Resume
          </button>
        </li>
      </ul>

      <ul :if={@runners != [] or @waiting_pools != []} id="runner-list" class="space-y-1">
        <%= for runner <- @runners do %>
          <li
            id={"runner-#{runner.id}"}
            class="flex items-center gap-2 rounded-lg px-2 py-1.5 text-sm odd:bg-base-200/40"
          >
            <.icon
              name={
                if Runner.session?(runner), do: "hero-chat-bubble-left-right", else: "hero-server"
              }
              class="size-4 shrink-0 text-base-content/50"
            />
            <button
              type="button"
              phx-target={@myself}
              phx-click="show_runner"
              phx-value-id={runner.id}
              id={"show-runner-#{runner.id}"}
              class="min-w-0 flex-1 cursor-pointer truncate text-left hover:underline"
              aria-expanded={to_string(@shown == runner.id)}
              title="Show what is known about this runner"
            >
              {runner.name}
              <span class="text-xs text-base-content/50">· pool {runner.pool}</span>
            </button>
            <span
              :if={match?({:drifted, _}, drift(runner).skills)}
              id={"runner-#{runner.id}-skills"}
              class="badge badge-warning badge-xs shrink-0"
              title={"Its installed skills differ from this server's: #{Drift.describe(drift(runner).skills)}. Run the install one-liner on its machine again"}
            >
              skills drifted
            </span>
            <span
              :if={drift(runner).cli == :old}
              id={"runner-#{runner.id}-cli"}
              class="badge badge-warning badge-xs shrink-0"
              title="Its slipdock CLI is older than the one this server serves (/cli/SHA256SUMS): install it again"
            >
              old CLI
            </span>
            <span
              :for={kind <- Slipdock.Runners.missing_kinds(runner)}
              id={"runner-#{runner.id}-lacks-#{kind}"}
              class="badge badge-error badge-xs shrink-0"
              title={"This board needs #{kind} jobs, and this runner doesn't take them"}
            >
              no {kind}
            </span>
            <span class="shrink-0 text-xs text-base-content/50">
              <%= cond do %>
                <% runner.current_job_id -> %>
                  job #{runner.current_job_id}
                  <span
                    :if={@steps[runner.id]}
                    id={"runner-#{runner.id}-step"}
                    class="inline-block max-w-48 truncate align-bottom"
                    title={@steps[runner.id]}
                  >
                    · {@steps[runner.id]}
                  </span>
                <% runner.last_seen_at -> %>
                  seen {relative_time(runner.last_seen_at)}
                <% true -> %>
                  never seen
              <% end %>
            </span>
            <%!-- A runner with a token of its own ran a retired script (#2582):
                 its setup is the move onto a machine. --%>
            <button
              :if={Setup.retired?(runner)}
              id={"runner-#{runner.id}-move"}
              phx-target={@myself}
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="regenerate"
              phx-value-id={runner.id}
              title="Its script was retired: the steps to move it onto a machine"
            >
              Move to a machine
            </button>
            <button
              phx-target={@myself}
              type="button"
              class="btn btn-ghost btn-error btn-xs btn-square"
              phx-click="revoke_runner"
              phx-value-id={runner.id}
              data-confirm={"Revoke “#{runner.name}”? Its token stops working at once."}
              title="Revoke"
            >
              <.icon name="hero-trash" class="size-3.5" />
            </button>
          </li>
          <li :if={@shown == runner.id and @details} id={"runner-details-#{runner.id}"}>
            <.runner_details details={@details} />
          </li>
        <% end %>
        <li
          :for={pool <- @waiting_pools}
          id={"waiting-pool-#{pool}"}
          class="flex items-center gap-2 rounded-lg px-2 py-1.5 text-sm text-base-content/60 odd:bg-base-200/40"
        >
          <.icon name="hero-clock" class="size-4 shrink-0 text-base-content/40" />
          <span class="min-w-0 flex-1">
            Waiting for a runner <span class="text-xs">· pool {pool}</span>
            <span class="block text-xs text-base-content/50">
              A rule sends cards here but nothing has taken a job yet. A Claude session shows
              up the first time it takes one.
            </span>
          </span>
        </li>
      </ul>

      <dialog
        :if={@wizard || @setup}
        id="runner-dialog"
        class="modal"
        phx-hook="ModalDialog"
        phx-mounted={JS.ignore_attributes("open")}
        data-close-event="close_dialog"
        phx-target={@myself}
        aria-label={if @wizard, do: "Connect a runner", else: "Set up the runner"}
      >
        <div class="modal-box max-w-2xl p-5">
          <.wizard_form
            :if={@wizard}
            wizard={@wizard}
            error={@wizard_error}
            preview={@preview}
            board={@board}
            runner_rules={@runner_rules}
            base_url={@base_url}
            target={@myself}
          />

          <.setup_steps
            :if={@setup}
            setup={@setup}
            runner={@setup_runner}
            token={@token}
            target={@myself}
          />
        </div>
        <form method="dialog" class="modal-backdrop">
          <button type="submit" aria-label="Close">Close</button>
        </form>
      </dialog>
    </div>
    """
  end

  attr :pausing, :any, required: true
  attr :reason, :string, required: true
  attr :target, :any, required: true

  # The reason is required: Pause stays disabled until there is one.
  defp pause_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:pause}
      id="pause-form"
      phx-target={@target}
      phx-change="pause_change"
      phx-submit="pause"
      class="space-y-2 rounded-lg border border-base-content/10 p-3"
    >
      <p class="text-sm font-medium">
        Pause {if @pausing == :tree, do: "the whole tree", else: "pool #{@pausing}"}
      </p>
      <p class="text-xs text-base-content/60">
        No job is taken and no list sends a card until you resume. Jobs already running finish.
      </p>
      <input
        type="text"
        name="reason"
        id="pause-reason"
        value={@reason}
        required
        maxlength="500"
        placeholder="Why? (shown to everyone, and to the agents)"
        class="input field w-full"
        phx-debounce="100"
      />
      <div class="flex justify-end gap-2">
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="cancel_pause"
          phx-target={@target}
        >
          Cancel
        </button>
        <button
          type="submit"
          id="pause-submit"
          class="btn btn-warning btn-sm"
          disabled={String.trim(@reason) == ""}
        >
          Pause
        </button>
      </div>
    </.form>
    """
  end

  defp inspect_errors(changeset) do
    changeset
    |> SlipdockWeb.API.JSON.errors()
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  # Every pool the tree's runners take from or its rules send to.
  defp pools(rules, runners) do
    rule_pools =
      rules
      |> Enum.flat_map(&Spec.actions(&1.spec))
      |> Enum.filter(&(&1["type"] == "runner"))
      |> Enum.map(&(&1["pool"] |> to_string() |> String.downcase()))

    (Enum.map(runners, & &1.pool) ++ rule_pools)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp preview(%{wizard: %{preview: {:ok, answers}}} = assigns),
    do: Setup.generate(answers, %{base_url: assigns.base_url, board: assigns.board})

  defp preview(_), do: nil

  # Pools a rule sends cards to that no runner takes from yet. A Claude
  # session has no runner until its first claim, so without these a setup
  # that worked would look like it did nothing.
  defp waiting_pools(_rules, _runners, false), do: []

  defp waiting_pools(rules, runners, true) do
    served = MapSet.new(runners, & &1.pool)

    rules
    |> Enum.filter(& &1.enabled)
    |> Enum.flat_map(&Spec.actions(&1.spec))
    |> Enum.filter(&(&1["type"] == "runner"))
    |> Enum.map(&to_string(&1["pool"]))
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(served, &1))
    |> Enum.sort()
  end

  # The board's rules that already send cards to a runner, to link to.
  defp runner_rules(board) do
    board.id
    |> Automations.list_rules()
    |> Enum.filter(fn rule -> Enum.any?(Spec.actions(rule.spec), &(&1["type"] == "runner")) end)
  end

  attr :details, :map, required: true

  # Everything known about one runner, opened by clicking its name.
  defp runner_details(assigns) do
    assigns = assign(assigns, runner: assigns.details.runner, d: assigns.details)

    ~H"""
    <div class="mb-1 ml-6 space-y-2 rounded-lg bg-base-200/40 p-3 text-xs ring-1 ring-base-content/10">
      <dl class="grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1">
        <dt class="text-base-content/60">Kind</dt>
        <dd>
          <%= cond do %>
            <% Runner.session?(@runner) -> %>
              Claude session, taking jobs with an API token
            <% Runner.machine?(@runner) -> %>
              A machine's runner, set on the machine's page
            <% true -> %>
              Runner with a token of its own: a retired shell runner, to move onto a machine
          <% end %>
          <span
            :if={(scenario = @runner.settings["scenario"]) in Setup.scenarios()}
            class="text-base-content/60"
          >
            · {Setup.label(scenario)}
          </span>
        </dd>
        <dt class="text-base-content/60">Pool</dt>
        <dd>{@runner.pool}</dd>
        <dt class="text-base-content/60">Made</dt>
        <dd>
          {relative_time(@runner.inserted_at)}
          <span :if={@d.created_by}>by {@d.created_by.name || @d.created_by.email}</span>
        </dd>
        <dt class="text-base-content/60">Last seen</dt>
        <dd>
          {if @runner.last_seen_at, do: relative_time(@runner.last_seen_at), else: "never"}
        </dd>
        <%= if not Runner.session?(@runner) do %>
          <dt class="text-base-content/60">Skills</dt>
          <dd id={"runner-#{@runner.id}-skills-state"}>{Drift.describe(drift(@runner).skills)}</dd>
          <dt class="text-base-content/60">CLI</dt>
          <dd id={"runner-#{@runner.id}-cli-state"}>{Drift.describe(drift(@runner).cli)}</dd>
        <% end %>
        <%= if @d.api_token do %>
          <dt class="text-base-content/60">API token</dt>
          <dd>
            {@d.api_token.label || "token ##{@d.api_token.id}"}
            <span class="text-base-content/60">· {@d.api_token.scope}</span>
            <span :if={@d.api_token.expires_at} class="text-base-content/60">
              · expires {relative_time(@d.api_token.expires_at)}
            </span>
          </dd>
        <% end %>
        <%= if setting(@runner, "agent") do %>
          <dt class="text-base-content/60">Agent</dt>
          <dd>{setting(@runner, "agent")}</dd>
        <% end %>
        <%= if setting(@runner, "cwd") do %>
          <dt class="text-base-content/60">Works in</dt>
          <dd class="font-mono">{setting(@runner, "cwd")}</dd>
        <% end %>
        <%= if setting(@runner, "repo") do %>
          <dt class="text-base-content/60">Repository</dt>
          <dd class="font-mono">{setting(@runner, "repo")}</dd>
        <% end %>
        <dt class="text-base-content/60">Now</dt>
        <dd id={"runner-now-#{@runner.id}"}>
          <%= if job = @d.current_job do %>
            job #{job.id} ({job.status})
            <%= if job.card_id do %>
              on
              <.link navigate={~p"/boards/#{job.board_id}/cards/#{job.card_id}"} class="link">
                #{job.card_id} {job.card && job.card.title}
              </.link>
            <% else %>
              {job.kind}, checking the runner
            <% end %>
            <span :if={job.step} id={"runner-step-#{@runner.id}"} class="block">
              {job.step}
              <span class="text-base-content/60">· {relative_time(job.step_at)}</span>
            </span>
            <%!-- Watch it (#1871). --%>
            <.live_component
              module={SlipdockWeb.BoardLive.JobLogComponent}
              id={SlipdockWeb.BoardLive.JobLogComponent.id("runner", job.id)}
              job={job}
            />
          <% else %>
            idle
          <% end %>
        </dd>
        <dt class="text-base-content/60">Jobs</dt>
        <dd id={"runner-job-counts-#{@runner.id}"}>
          {@d.jobs_total}
          <span :if={@d.jobs_total > 0} class="text-base-content/60">
            ({@d.job_counts |> Enum.sort() |> Enum.map_join(", ", fn {s, n} -> "#{n} #{s}" end)})
          </span>
        </dd>
        <dt class="text-base-content/60">Rules</dt>
        <dd>
          <%= if @d.rules == [] do %>
            <span class="text-base-content/60">no enabled rule sends cards to this pool</span>
          <% else %>
            {Enum.map_join(@d.rules, ", ", & &1.name)}
          <% end %>
        </dd>
      </dl>
      <div :if={@d.recent_jobs != []}>
        <p class="mb-1 text-base-content/60">Latest jobs</p>
        <ul id={"runner-jobs-#{@runner.id}"} class="space-y-0.5">
          <li :for={job <- @d.recent_jobs} class="flex gap-2">
            <span class="shrink-0 text-base-content/60">#{job.id}</span>
            <span class="shrink-0">{job.status}</span>
            <.link
              :if={job.card_id}
              navigate={~p"/boards/#{job.board_id}/cards/#{job.card_id}"}
              class="link min-w-0 flex-1 truncate"
            >
              #{job.card_id} {job.card && job.card.title}
            </.link>
            <%!-- A probe has no card (#2580). --%>
            <span :if={is_nil(job.card_id)} class="min-w-0 flex-1 truncate">{job.kind}</span>
            <span class="shrink-0 text-base-content/50">
              {relative_time(job.finished_at || job.started_at || job.claimed_at || job.inserted_at)}
            </span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # A saved setup answer worth showing, or nil.
  defp setting(%Runner{settings: settings}, key) do
    case (settings || %{})[key] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  attr :wizard, :map, required: true
  attr :error, :string, default: nil
  attr :preview, :map, default: nil
  attr :board, :any, required: true
  attr :runner_rules, :list, required: true
  attr :base_url, :string, required: true
  attr :target, :any, required: true

  defp wizard_form(assigns) do
    assigns = assign(assigns, p: assigns.wizard.params)

    ~H"""
    <.form
      for={%{}}
      as={:wizard}
      id="runner-wizard"
      phx-target={@target}
      phx-change="wizard_change"
      phx-submit="connect"
      class="space-y-4 rounded-xl bg-base-200/40 p-4 ring-1 ring-base-content/10"
    >
      <fieldset class="space-y-1.5">
        <legend class="text-xs font-medium text-base-content/70">
          Where should the work happen?
        </legend>
        <div class="grid grid-cols-2 gap-2">
          <label
            :for={scenario <- Setup.scenarios()}
            class={[
              "flex cursor-pointer items-center gap-2 rounded-lg px-3 py-2 text-sm ring-1",
              if(@p["scenario"] == scenario,
                do: "bg-primary/10 ring-primary",
                else: "ring-base-content/15 hover:bg-base-200"
              )
            ]}
          >
            <input
              type="radio"
              name="wizard[scenario]"
              value={scenario}
              checked={@p["scenario"] == scenario}
              class="radio"
            />
            {Setup.label(scenario)}
          </label>
        </div>
      </fieldset>

      <div class="grid grid-cols-2 gap-3 text-sm">
        <label class="space-y-1">
          <span class="text-xs text-base-content/70">Pool</span>
          <input name="wizard[pool]" value={@p["pool"]} class="input field w-full" />
        </label>
        <label
          :if={
            not Enum.member?(["chatgpt", "daemon"], @p["scenario"]) and
              (@p["scenario"] != "cloud" or @p["where"] == "desktop")
          }
          class="space-y-1"
        >
          <span class="text-xs text-base-content/70">Working directory</span>
          <input
            name="wizard[cwd]"
            value={@p["cwd"]}
            placeholder="~/src/my-app"
            class="input field w-full field-mono"
          />
        </label>
        <label
          :if={not Enum.member?(["chatgpt", "daemon"], @p["scenario"])}
          class="space-y-1"
        >
          <span class="text-xs text-base-content/70">Permission mode</span>
          <select name="wizard[permission_mode]" class="select field w-full">
            <option
              :for={mode <- Setup.permission_modes()}
              value={mode}
              selected={@p["permission_mode"] == mode}
            >
              {mode}
            </option>
          </select>
        </label>
        <label :if={@p["scenario"] == "cloud"} class="space-y-1">
          <span class="text-xs text-base-content/70">Runs</span>
          <select name="wizard[where]" class="select field w-full">
            <option value="desktop" selected={@p["where"] == "desktop"}>
              On this computer (Claude Desktop)
            </option>
            <option value="cloud" selected={@p["where"] == "cloud"}>In the cloud (routine)</option>
          </select>
        </label>
        <label :if={@p["scenario"] == "cloud" and @p["where"] == "cloud"} class="space-y-1">
          <span class="text-xs text-base-content/70">GitHub repository</span>
          <input
            name="wizard[repo]"
            value={@p["repo"]}
            placeholder="owner/repo"
            class="input field w-full field-mono"
          />
        </label>
        <p
          :if={@p["scenario"] == "daemon"}
          id="wizard-daemon-note"
          class="col-span-2 text-xs text-base-content/70"
        >
          The runner's agent, directory, permission mode, timeout and instructions are set on the
          machine's page once it is enrolled, inside the machine's own limits.
        </p>
        <fieldset
          :if={@p["scenario"] != "daemon"}
          class="col-span-2 space-y-2 rounded-lg p-3 ring-1 ring-base-content/10"
        >
          <legend class="px-1 text-xs font-medium text-base-content/70">
            Instructions for every job
          </legend>
          <label class="block space-y-1">
            <span class="text-xs text-base-content/70">How much to write on the card</span>
            <select name="wizard[verbosity]" class="select field w-full">
              <option value="nothing" selected={@p["verbosity"] == "nothing"}>
                Nothing: no comments at all
              </option>
              <option value="" selected={@p["verbosity"] == ""}>Whatever the skill says</option>
              <option value="quiet" selected={@p["verbosity"] == "quiet"}>
                Quiet: a line at the start and the end
              </option>
              <option value="normal" selected={@p["verbosity"] == "normal"}>
                Normal: at each decision or surprise
              </option>
              <option value="verbose" selected={@p["verbosity"] == "verbose"}>
                Verbose: a running log of every step
              </option>
            </select>
          </label>
          <div id="wizard-toggles" class="space-y-1">
            <span class="text-xs text-base-content/70">
              What a job does to the card (nothing unless ticked)
            </span>
            <div class="grid grid-cols-2 gap-x-3 gap-y-1">
              <label
                :for={{key, label} <- toggle_labels()}
                class={[
                  "flex items-center gap-2 text-sm",
                  off_here?(key, @p) && "opacity-50"
                ]}
              >
                <input type="hidden" name={"wizard[#{key}]"} value="false" />
                <input
                  type="checkbox"
                  id={"wizard-#{key}"}
                  name={"wizard[#{key}]"}
                  value="true"
                  checked={ticked?(@p[key])}
                  disabled={off_here?(key, @p)}
                  class="checkbox"
                />
                <span>{label}</span>
              </label>
            </div>
          </div>
          <label class="block space-y-1">
            <span class="text-xs text-base-content/70">
              Anything else, added after every job's prompt
            </span>
            <textarea
              name="wizard[instructions]"
              rows="2"
              class="textarea field w-full"
              placeholder="Run mix test before committing. Never push to main."
            >{@p["instructions"]}</textarea>
          </label>
        </fieldset>

        <details
          :if={@p["scenario"] != "daemon"}
          id="wizard-advanced"
          class="col-span-2 rounded-lg ring-1 ring-base-content/10"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary class="cursor-pointer select-none px-3 py-2 text-xs font-medium text-base-content/70">
            Advanced
          </summary>
          <fieldset
            id="wizard-hooks"
            class="mx-3 mb-3 space-y-2 rounded-lg p-3 ring-1 ring-base-content/10"
            disabled={not Setup.hooks?(@p)}
          >
            <legend class="px-1 text-xs font-medium text-base-content/70">Hooks</legend>
            <p
              :if={not Setup.hooks?(@p) and @p["scenario"] == "chatgpt"}
              class="text-xs text-base-content/60"
              id="hooks-off"
            >
              ChatGPT runs on OpenAI's machines, not yours, so there is nothing for hooks to run
              on. Instructions still go in its prompt.
            </p>
            <p
              :if={not Setup.hooks?(@p) and @p["scenario"] != "chatgpt"}
              class="text-xs text-base-content/60"
              id="hooks-off"
            >
              A cloud routine runs on Anthropic's machines, not yours, so there is nothing for
              hooks to run on. Instructions still go in its prompt.
            </p>
            <label class="block space-y-1">
              <span class="text-xs text-base-content/70">Before each job (the job runs only if it succeeds)</span>
              <input
                name="wizard[before_job]"
                value={@p["before_job"]}
                placeholder="git pull --ff-only"
                class="input field w-full field-mono"
              />
            </label>
            <label class="block space-y-1">
              <span class="text-xs text-base-content/70">
                After each job, however it ended ($SLIPDOCK_STATUS, $SLIPDOCK_EXIT)
              </span>
              <input
                name="wizard[after_job]"
                value={@p["after_job"]}
                placeholder="notify-send &quot;job $SLIPDOCK_JOB_ID: $SLIPDOCK_STATUS&quot;"
                class="input field w-full field-mono"
              />
            </label>
            <label :if={@p["scenario"] == "loop"} class="block space-y-1">
              <span class="text-xs text-base-content/70">How Claude Code runs them</span>
              <select name="wizard[hooks]" class="select field w-full">
                <option value="prompt" selected={@p["hooks"] == "prompt"}>
                  Asked to in its prompt (best effort)
                </option>
                <option value="hook" selected={@p["hooks"] == "hook"}>
                  As Claude Code hooks (reliable, run by Claude Code itself)
                </option>
              </select>
            </label>
            <p
              :if={@p["scenario"] == "cloud" and @p["where"] == "desktop"}
              class="text-xs text-base-content/60"
            >
              A Desktop task is asked to run them in its prompt: best effort.
            </p>
          </fieldset>
        </details>

        <label class="col-span-2 space-y-1">
          <span class="text-xs text-base-content/70">Which cards does it get?</span>
          <select name="wizard[send]" class="select field w-full">
            <option value="" selected={blank?(@p["send"])}>
              None yet — I'll add a rule myself
            </option>
            <option
              :for={column <- @board.columns}
              value={"column:#{column.name}"}
              selected={@p["send"] == "column:#{column.name}"}
            >
              A new rule: every card arriving in {column.name}
            </option>
            <option
              :for={column <- @board.columns}
              value={"top:#{column.name}"}
              selected={@p["send"] == "top:#{column.name}"}
            >
              A new rule: the top card of {column.name}, one at a time
            </option>
            <option
              :for={rule <- @runner_rules}
              value={"rule:#{rule.id}"}
              selected={@p["send"] == "rule:#{rule.id}"}
            >
              The rule “{rule.name}”
            </option>
          </select>
        </label>

        <label
          :if={String.starts_with?(to_string(@p["send"]), "top:")}
          class="col-span-2 flex items-center gap-2 text-xs"
        >
          <input type="hidden" name="wizard[wait]" value="no" />
          <input
            type="checkbox"
            name="wizard[wait]"
            value="yes"
            checked={@p["wait"] != "no"}
            class="checkbox"
          /> Wait while anything is in progress on the board, so it never starts a card
          beside one being worked
        </label>

        <label
          :if={String.starts_with?(to_string(@p["send"]), "top:")}
          class="col-span-2 flex items-center gap-2 text-xs"
        >
          Put a card its job leaves in progress back on the list
          <input
            type="number"
            name="wizard[requeue]"
            min="0"
            max={Slipdock.Runners.Recovery.max_requeues()}
            value={@p["requeue"] || 1}
            class="input field w-16"
          /> times, then flag it blocked
        </label>

        <label class="col-span-2 flex items-center gap-2 text-xs">
          <input type="hidden" name="wizard[alert]" value="no" />
          <input
            type="checkbox"
            name="wizard[alert]"
            value="yes"
            checked={@p["alert"] == "yes"}
            class="checkbox"
          /> Tell me when a job times out, or a card it left in progress is put back or given up on
        </label>
      </div>

      <p class="rounded-lg bg-base-100 px-3 py-2 text-xs text-base-content/70 ring-1 ring-base-content/10">
        <.icon name="hero-banknotes" class="mr-1 size-3.5 align-text-bottom" />
        {(@preview && @preview.cost) || ""}
      </p>

      <ul :if={@preview && @preview.warnings != []} class="space-y-1">
        <li
          :for={warning <- @preview.warnings}
          class="rounded-lg bg-warning/10 px-3 py-2 text-xs ring-1 ring-warning/30"
        >
          <.icon name="hero-exclamation-triangle" class="mr-1 size-3.5 align-text-bottom" />
          {warning}
        </li>
      </ul>

      <p :if={@error} class="text-sm text-error">{@error}</p>
      <p :if={match?({:error, _}, @wizard.preview)} class="text-sm text-error">
        {elem(@wizard.preview, 1)}
      </p>

      <div class="flex justify-end gap-2">
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-target={@target}
          phx-click="close_wizard"
        >
          Cancel
        </button>
        <button
          type="submit"
          class="btn btn-primary btn-sm"
          disabled={match?({:error, _}, @wizard.preview)}
        >
          Show the steps
        </button>
      </div>
    </.form>
    """
  end

  attr :setup, :map, required: true
  attr :runner, :any, default: nil
  attr :token, :string, default: nil
  attr :target, :any, required: true

  defp setup_steps(assigns) do
    assigns = assign(assigns, indexed: Enum.with_index(assigns.setup.steps, 1))

    ~H"""
    <div id="runner-setup" class="space-y-3">
      <div class="flex items-start justify-between gap-2">
        <div>
          <p class="text-sm font-medium">{@setup.title}{if @runner, do: " — #{@runner.name}"}</p>
          <p class="mt-0.5 text-xs text-base-content/70">{@setup.intro}</p>
        </div>
        <button
          type="button"
          class="btn btn-ghost btn-xs btn-square"
          phx-target={@target}
          phx-click="close_setup"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <p :if={@token} class="rounded-lg bg-warning/10 px-3 py-2 text-xs ring-1 ring-warning/30">
        <.icon name="hero-key" class="mr-1 size-3.5 align-text-bottom" />
        The runner's new token is in the steps below. It is shown this once and not kept:
        copy it now.
      </p>

      <ul class="space-y-3">
        <li :for={{step, n} <- @indexed} class="space-y-1.5 text-sm">
          <p>{step.text}</p>
          <.code_block :if={step[:code]} id={"runner-step-#{n}"} code={step.code} />
        </li>
      </ul>

      <ul :if={@setup.warnings != []} class="space-y-1">
        <li :for={warning <- @setup.warnings} class="text-xs text-warning">{warning}</li>
      </ul>

      <div :if={@runner && is_nil(@token)} class="flex justify-end gap-1">
        <button
          type="button"
          class="btn btn-ghost btn-xs"
          phx-target={@target}
          phx-click="rotate_token"
          phx-value-id={@runner.id}
          data-confirm="Make a new token? The runner stops working until it has the new one."
        >
          <.icon name="hero-arrow-path" class="size-3.5" /> Make a new token
        </button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :code, :string, required: true
  attr :class, :string, default: nil
  attr :wrap, :boolean, default: false, doc: "wrap long lines (prose) rather than scroll"

  # A block of text to paste, with its copy button.
  defp code_block(assigns) do
    ~H"""
    <div class="relative">
      <pre
        id={@id}
        class={[
          "overflow-x-auto rounded-lg bg-base-300/60 p-3 pr-16 font-mono text-xs",
          if(@wrap, do: "whitespace-pre-wrap", else: "whitespace-pre"),
          @class && "overflow-y-auto",
          @class
        ]}
      >{@code}</pre>
      <button
        type="button"
        id={"#{@id}-copy"}
        phx-hook="CopyText"
        data-target={@id}
        class="btn btn-ghost btn-xs absolute right-1.5 top-1.5"
      >
        <span data-label>Copy</span>
      </button>
    </div>
    """
  end

  defp blank?(value), do: Enum.member?([nil, ""], value)

  # A toggle that can't be ticked here: push without commit, and either of
  # them for ChatGPT, which has no repository.
  defp off_here?(key, p) when key in ~w(commit push),
    do: not Setup.commits?(p) or (key == "push" and not ticked?(p["commit"]))

  defp off_here?(_key, _p), do: false

  # Its installed skills and CLI against this server's (#1795).
  defp drift(runner), do: Drift.states(runner)
end

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
  alias Slipdock.Runners.{Runner, Setup}

  @events ~w(open_wizard close_wizard wizard_change connect regenerate rotate_token
    revoke_runner close_setup)

  @doc false
  def events, do: @events

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       runners: [],
       wizard: nil,
       wizard_error: nil,
       setup: nil,
       setup_runner: nil,
       token: nil
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

  defp assign_runners(%{assigns: %{can_manage: true, board: board}} = socket),
    do: assign(socket, runners: Runners.list_runners(board))

  defp assign_runners(socket), do: assign(socket, runners: [])

  ## Events ------------------------------------------------------------------

  @impl true
  def handle_event(event, _params, socket) when event not in @events,
    do: {:noreply, flash(socket, :error, "That isn't something this page can do.")}

  def handle_event(_event, _params, %{assigns: %{can_manage: false}} = socket),
    do: {:noreply, flash(socket, :error, "Only the board's owner can do that.")}

  def handle_event("open_wizard", params, socket) do
    answers = Map.put(Setup.defaults(), "scenario", params["scenario"] || "server")
    {:noreply, assign(socket, wizard: wizard(answers), wizard_error: nil, setup: nil, token: nil)}
  end

  def handle_event("close_wizard", _params, socket),
    do: {:noreply, assign(socket, wizard: nil, wizard_error: nil)}

  def handle_event("wizard_change", %{"wizard" => params}, socket),
    do: {:noreply, assign(socket, wizard: wizard(params), wizard_error: nil)}

  def handle_event("connect", %{"wizard" => params}, socket) do
    %{board: board, current_user: user, base_url: base_url} = socket.assigns

    case Setup.connect(board, sends(params), user, base_url) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(
           wizard: nil,
           setup: result.setup,
           setup_runner: result.runner,
           token: result.token
         )
         |> assign_runners()
         |> refresh_rules(result.rule)}

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
       |> then(&if(setup?, do: assign(&1, setup: nil, setup_runner: nil, token: nil), else: &1))
       |> flash(:info, "Runner “#{runner.name}” revoked: its token no longer works.")}
    else
      _ -> {:noreply, flash(socket, :error, "That runner is gone.")}
    end
  end

  def handle_event("close_setup", _params, socket),
    do: {:noreply, assign(socket, setup: nil, setup_runner: nil, token: nil)}

  # "Which cards does it get?" is one select: a list for a new rule, or a
  # rule already there.
  defp sends(params) do
    case params["send"] do
      "column:" <> name -> Map.put(params, "column", name)
      "rule:" <> id -> Map.put(params, "rule_id", id)
      _ -> params
    end
  end

  # A rule the wizard added shows in the panel's list of rules straight away.
  defp refresh_rules(socket, nil), do: socket

  defp refresh_rules(socket, _rule) do
    send_update(SlipdockWeb.BoardLive.AutomationsComponent, id: "automations", refresh: true)
    socket
  end

  # The form's values, and the steps they'd give — a preview with the token
  # left out until the runner is made.
  defp wizard(params) do
    %{params: Map.merge(Setup.defaults(), params), preview: Setup.normalise(params)}
  end

  ## Render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        runner_rules: runner_rules(assigns.board),
        preview: preview(assigns)
      )

    ~H"""
    <div id="board-runners" class="space-y-3 border-t border-base-content/10 pt-4">
      <div class="flex items-center justify-between gap-2">
        <div>
          <p class="text-sm font-medium">Runners</p>
          <p class="text-xs text-base-content/60">
            Send cards to a coding agent on your own machine, or to Claude on a schedule.
          </p>
        </div>
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

      <ul :if={@runners != []} id="runner-list" class="space-y-1">
        <li
          :for={runner <- @runners}
          id={"runner-#{runner.id}"}
          class="flex items-center gap-2 rounded-lg px-2 py-1.5 text-sm odd:bg-base-200/40"
        >
          <.icon
            name={if Runner.session?(runner), do: "hero-chat-bubble-left-right", else: "hero-server"}
            class="size-4 shrink-0 text-base-content/50"
          />
          <span class="min-w-0 flex-1 truncate">
            {runner.name}
            <span class="text-xs text-base-content/50">· pool {runner.pool}</span>
          </span>
          <span class="shrink-0 text-xs text-base-content/50">
            <%= cond do %>
              <% runner.current_job_id -> %>
                job #{runner.current_job_id}
              <% runner.last_seen_at -> %>
                seen {relative_time(runner.last_seen_at)}
              <% true -> %>
                never seen
            <% end %>
          </span>
          <button
            :if={not Runner.session?(runner)}
            phx-target={@myself}
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="regenerate"
            phx-value-id={runner.id}
            title="Show the setup steps again"
          >
            Setup
          </button>
          <button
            phx-target={@myself}
            type="button"
            class="btn btn-ghost btn-xs btn-square text-error"
            phx-click="revoke_runner"
            phx-value-id={runner.id}
            data-confirm={"Revoke “#{runner.name}”? Its token stops working at once."}
            title="Revoke"
          >
            <.icon name="hero-trash" class="size-3.5" />
          </button>
        </li>
      </ul>

      <.wizard_form
        :if={@wizard}
        wizard={@wizard}
        error={@wizard_error}
        preview={@preview}
        board={@board}
        runner_rules={@runner_rules}
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
    """
  end

  defp preview(%{wizard: %{preview: {:ok, answers}}} = assigns),
    do: Setup.generate(answers, %{base_url: assigns.base_url, board: assigns.board})

  defp preview(_), do: nil

  # The board's rules that already send cards to a runner, to link to.
  defp runner_rules(board) do
    board.id
    |> Automations.list_rules()
    |> Enum.filter(fn rule -> Enum.any?(Spec.actions(rule.spec), &(&1["type"] == "runner")) end)
  end

  attr :wizard, :map, required: true
  attr :error, :string, default: nil
  attr :preview, :map, default: nil
  attr :board, :any, required: true
  attr :runner_rules, :list, required: true
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
              class="radio radio-xs"
            />
            {Setup.label(scenario)}
          </label>
        </div>
      </fieldset>

      <div class="grid grid-cols-2 gap-3 text-sm">
        <label :if={Setup.needs_token?(@p["scenario"])} class="space-y-1">
          <span class="text-xs text-base-content/70">Name</span>
          <input
            name="wizard[name]"
            value={@p["name"]}
            placeholder={"#{@p["pool"]} runner"}
            class="input input-sm w-full"
          />
        </label>
        <label class="space-y-1">
          <span class="text-xs text-base-content/70">Pool</span>
          <input name="wizard[pool]" value={@p["pool"]} class="input input-sm w-full" />
        </label>
        <label :if={Setup.needs_token?(@p["scenario"])} class="space-y-1">
          <span class="text-xs text-base-content/70">Agent</span>
          <select name="wizard[agent]" class="select select-sm w-full">
            <option value="claude" selected={@p["agent"] == "claude"}>Claude Code</option>
            <option value="codex" selected={@p["agent"] == "codex"}>Codex</option>
            <option value="custom" selected={@p["agent"] == "custom"}>A command of my own</option>
          </select>
        </label>
        <label
          :if={Setup.needs_token?(@p["scenario"]) and @p["agent"] == "custom"}
          class="col-span-2 space-y-1"
        >
          <span class="text-xs text-base-content/70">
            Command (run with sh -c; the prompt is in $SLIPDOCK_PROMPT)
          </span>
          <input
            name="wizard[command]"
            value={@p["command"]}
            class="input input-sm w-full font-mono"
          />
        </label>
        <label :if={@p["scenario"] != "cloud" or @p["where"] == "desktop"} class="space-y-1">
          <span class="text-xs text-base-content/70">Working directory</span>
          <input
            name="wizard[cwd]"
            value={@p["cwd"]}
            placeholder="~/src/my-app"
            class="input input-sm w-full font-mono"
          />
        </label>
        <label
          :if={@p["agent"] == "claude" or not Setup.needs_token?(@p["scenario"])}
          class="space-y-1"
        >
          <span class="text-xs text-base-content/70">Permission mode</span>
          <select name="wizard[permission_mode]" class="select select-sm w-full">
            <option
              :for={mode <- Setup.permission_modes()}
              value={mode}
              selected={@p["permission_mode"] == mode}
            >
              {mode}
            </option>
          </select>
        </label>
        <label :if={Setup.needs_token?(@p["scenario"])} class="space-y-1">
          <span class="text-xs text-base-content/70">Longest a job may run (seconds)</span>
          <input
            name="wizard[timeout]"
            value={@p["timeout"]}
            type="number"
            min="60"
            class="input input-sm w-full"
          />
        </label>
        <label :if={@p["scenario"] == "server"} class="space-y-1">
          <span class="text-xs text-base-content/70">Keep it running with</span>
          <select name="wizard[service]" class="select select-sm w-full">
            <option value="auto" selected={@p["service"] == "auto"}>systemd or launchd</option>
            <option value="systemd" selected={@p["service"] == "systemd"}>systemd (Linux)</option>
            <option value="launchd" selected={@p["service"] == "launchd"}>launchd (macOS)</option>
            <option value="none" selected={@p["service"] == "none"}>Nothing: I'll start it</option>
          </select>
        </label>
        <label :if={@p["scenario"] == "cloud"} class="space-y-1">
          <span class="text-xs text-base-content/70">Runs</span>
          <select name="wizard[where]" class="select select-sm w-full">
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
            class="input input-sm w-full font-mono"
          />
        </label>
        <label class="col-span-2 space-y-1">
          <span class="text-xs text-base-content/70">Which cards does it get?</span>
          <select name="wizard[send]" class="select select-sm w-full">
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
              :for={rule <- @runner_rules}
              value={"rule:#{rule.id}"}
              selected={@p["send"] == "rule:#{rule.id}"}
            >
              The rule “{rule.name}”
            </option>
          </select>
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
          {if Setup.needs_token?(@p["scenario"]), do: "Make the runner", else: "Show the steps"}
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
    <div id="runner-setup" class="space-y-3 rounded-xl p-4 ring-1 ring-primary/30">
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
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <p :if={@token} class="rounded-lg bg-warning/10 px-3 py-2 text-xs ring-1 ring-warning/30">
        <.icon name="hero-key" class="mr-1 size-3.5 align-text-bottom" />
        The runner's token is in the command below. It is shown this once and not kept:
        copy it now.
      </p>

      <ol class="space-y-3">
        <li :for={{step, n} <- @indexed} class="space-y-1.5 text-sm">
          <p><span class="font-medium text-base-content/50">{n}.</span> {step.text}</p>
          <div :if={step[:code]} class="relative">
            <pre
              id={"runner-step-#{n}"}
              class="overflow-x-auto whitespace-pre rounded-lg bg-base-300/60 p-3 pr-16 font-mono text-xs"
            >{step.code}</pre>
            <button
              type="button"
              id={"runner-step-#{n}-copy"}
              phx-hook="CopyText"
              data-target={"runner-step-#{n}"}
              class="btn btn-ghost btn-xs absolute right-1.5 top-1.5"
            >
              <span data-label>Copy</span>
            </button>
          </div>
        </li>
      </ol>

      <ul :if={@setup.warnings != []} class="space-y-1">
        <li :for={warning <- @setup.warnings} class="text-xs text-warning">{warning}</li>
      </ul>

      <div :if={@runner && is_nil(@token)} class="flex justify-end">
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

  defp blank?(value), do: value in [nil, ""]
end

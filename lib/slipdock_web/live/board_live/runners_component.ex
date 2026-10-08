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
    revoke_runner close_setup edit_answers close_dialog reveal)

  # What the setup steps keep behind a link until it's clicked.
  @reveals ~w(script config verify)

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
       token: nil,
       diff: nil,
       editing: nil,
       revealed: MapSet.new()
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
    scenario = params["scenario"] || "server"

    answers =
      Map.merge(Setup.defaults(), %{"scenario" => scenario, "cwd" => Setup.default_cwd(scenario)})

    {:noreply,
     assign(socket,
       wizard: wizard(answers),
       wizard_error: nil,
       setup: nil,
       token: nil,
       diff: nil,
       editing: nil
     )}
  end

  def handle_event("close_wizard", _params, socket),
    do: {:noreply, assign(socket, wizard: nil, wizard_error: nil, editing: nil)}

  # The wizard again, filled in with a runner's saved answers; saving shows
  # what changes.
  def handle_event("edit_answers", %{"id" => id}, socket) do
    with {:ok, runner} <- Runners.find_runner(socket.assigns.board, id) do
      {:noreply,
       assign(socket,
         wizard: wizard(Setup.saved(runner)),
         wizard_error: nil,
         editing: runner,
         setup: nil,
         diff: nil,
         token: nil
       )}
    else
      _ -> {:noreply, flash(socket, :error, "That runner is gone.")}
    end
  end

  def handle_event("wizard_change", %{"wizard" => params}, socket) do
    params = follow_default_cwd(params, socket.assigns.wizard)
    {:noreply, assign(socket, wizard: wizard(params), wizard_error: nil)}
  end

  def handle_event(
        "connect",
        %{"wizard" => params},
        %{assigns: %{editing: %Runner{} = runner}} = socket
      ) do
    %{board: board, base_url: base_url} = socket.assigns

    case Setup.update(runner, board, params, base_url) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(
           wizard: nil,
           editing: nil,
           setup: result.setup,
           setup_runner: result.runner,
           token: nil,
           diff: result.diff,
           revealed: MapSet.new()
         )
         |> assign_runners()}

      {:error, message} ->
        {:noreply, assign(socket, wizard: wizard(params), wizard_error: message)}
    end
  end

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
           token: result.token,
           revealed: MapSet.new()
         )
         |> assign_runners()
         |> refresh_automations(result.runner || result.rule)}

      {:error, message} ->
        {:noreply, assign(socket, wizard: wizard(params), wizard_error: message)}
    end
  end

  def handle_event("regenerate", %{"id" => id}, socket) do
    with {:ok, runner} <- Runners.find_runner(socket.assigns.board, id) do
      setup = Setup.regenerate(runner, socket.assigns.board, socket.assigns.base_url)

      {:noreply,
       assign(socket,
         wizard: nil,
         setup: setup,
         setup_runner: runner,
         token: nil,
         diff: nil,
         revealed: MapSet.new()
       )}
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

  def handle_event("close_setup", _params, socket),
    do: {:noreply, assign(socket, setup: nil, setup_runner: nil, token: nil, diff: nil)}

  # The dialog closed itself (Escape, or a click outside): the wizard or the
  # steps, whichever it held, go too.
  def handle_event("close_dialog", _params, socket),
    do:
      {:noreply,
       assign(socket,
         wizard: nil,
         wizard_error: nil,
         editing: nil,
         setup: nil,
         setup_runner: nil,
         token: nil,
         diff: nil
       )}

  def handle_event("reveal", %{"part" => part}, socket) when part in @reveals do
    revealed = socket.assigns.revealed

    revealed =
      if MapSet.member?(revealed, part),
        do: MapSet.delete(revealed, part),
        else: MapSet.put(revealed, part)

    {:noreply, assign(socket, revealed: revealed)}
  end

  def handle_event("reveal", _params, socket), do: {:noreply, socket}

  # Switching scenario takes that scenario's default working directory with
  # it, unless one was typed in.
  defp follow_default_cwd(%{"scenario" => new} = params, %{params: %{"scenario" => old}})
       when new != old do
    if params["cwd"] in [nil, Setup.default_cwd(old)],
      do: Map.put(params, "cwd", Setup.default_cwd(new)),
      else: params
  end

  defp follow_default_cwd(params, _wizard), do: params

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
            Send cards to a coding agent or LLM on your own machine, or to Claude on a schedule
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
            editing={@editing}
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
            diff={@diff}
            revealed={@revealed}
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
  attr :editing, :any, default: nil
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
      <p :if={@editing} class="text-sm font-medium">Changing “{@editing.name}”</p>
      <fieldset :if={is_nil(@editing)} class="space-y-1.5">
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
        <label :if={Setup.needs_token?(@p["scenario"]) and is_nil(@editing)} class="space-y-1">
          <span class="text-xs text-base-content/70">
            Name <span class="text-base-content/50">(optional)</span>
          </span>
          <input
            name="wizard[name]"
            value={@p["name"]}
            placeholder={"#{@p["pool"]} runner"}
            class="input input-sm w-full"
          />
        </label>
        <input :if={@editing} type="hidden" name="wizard[scenario]" value={@p["scenario"]} />
        <label :if={is_nil(@editing)} class="space-y-1">
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
        <div
          :if={Setup.needs_token?(@p["scenario"]) and @p["agent"] == "claude"}
          id="wizard-slipdock-tools"
          class="col-span-2 space-y-1.5 rounded-lg p-3 ring-1 ring-base-content/10"
        >
          <label class="flex items-center gap-2">
            <input type="hidden" name="wizard[slipdock_tools]" value="false" />
            <input
              type="checkbox"
              name="wizard[slipdock_tools]"
              value="true"
              checked={@p["slipdock_tools"] in [true, "true"]}
              class="checkbox checkbox-xs"
            />
            <span class="font-medium">Let it use the Slipdock tools</span>
          </label>
          <p class="text-xs text-base-content/60">
            Claude runs each job with nobody there to approve a tool, so without this it can't
            read the card or the wiki, comment, move or complete anything: it gets no access to
            the board. Ticked, every tool of the Slipdock MCP servers named here is allowed
            (--allowedTools), and nothing else.
          </p>
          <label :if={@p["slipdock_tools"] in [true, "true"]} class="block space-y-1">
            <span class="text-xs text-base-content/70">
              Its name on that machine (the claude.ai connector is claude_ai_Slipdock; one added
              with claude mcp add is the name you gave it)
            </span>
            <input
              name="wizard[mcp_servers]"
              value={@p["mcp_servers"]}
              class="input input-sm w-full font-mono"
            />
          </label>
        </div>
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
        <fieldset class="col-span-2 space-y-2 rounded-lg p-3 ring-1 ring-base-content/10">
          <legend class="px-1 text-xs font-medium text-base-content/70">
            Instructions for every job
          </legend>
          <label class="block space-y-1">
            <span class="text-xs text-base-content/70">How much to write on the card</span>
            <select name="wizard[verbosity]" class="select select-sm w-full">
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
          <label class="block space-y-1">
            <span class="text-xs text-base-content/70">
              Anything else, added after every job's prompt
            </span>
            <textarea
              name="wizard[instructions]"
              rows="2"
              class="textarea textarea-sm w-full"
              placeholder="Run mix test before committing. Never push to main."
            >{@p["instructions"]}</textarea>
          </label>
        </fieldset>

        <details
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
            <p :if={not Setup.hooks?(@p)} class="text-xs text-base-content/60" id="hooks-off">
              A cloud routine runs on Anthropic's machines, not yours, so there is nothing for
              hooks to run on. Instructions still go in its prompt.
            </p>
            <label class="block space-y-1">
              <span class="text-xs text-base-content/70">Before each job (the job runs only if it succeeds)</span>
              <input
                name="wizard[before_job]"
                value={@p["before_job"]}
                placeholder="git pull --ff-only"
                class="input input-sm w-full font-mono"
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
                class="input input-sm w-full font-mono"
              />
            </label>
            <label :if={@p["scenario"] == "loop"} class="block space-y-1">
              <span class="text-xs text-base-content/70">How Claude Code runs them</span>
              <select name="wizard[hooks]" class="select select-sm w-full">
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

        <label :if={is_nil(@editing)} class="col-span-2 space-y-1">
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
          :if={is_nil(@editing) and String.starts_with?(to_string(@p["send"]), "top:")}
          class="col-span-2 flex items-center gap-2 text-xs"
        >
          <input type="hidden" name="wizard[wait]" value="no" />
          <input
            type="checkbox"
            name="wizard[wait]"
            value="yes"
            checked={@p["wait"] != "no"}
            class="checkbox checkbox-xs"
          /> Wait while anything is in progress on the board, so it never starts a card
          beside one being worked
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
          {cond do
            @editing -> "Save and show the steps"
            Setup.needs_token?(@p["scenario"]) -> "Make the runner"
            true -> "Show the steps"
          end}
        </button>
      </div>
    </.form>
    """
  end

  attr :setup, :map, required: true
  attr :runner, :any, default: nil
  attr :token, :string, default: nil
  attr :diff, :list, default: nil
  attr :revealed, :any, default: MapSet.new()
  attr :target, :any, required: true

  defp setup_steps(assigns) do
    named = Map.new(for step <- assigns.setup.steps, step[:id], do: {step.id, step})

    assigns =
      assign(assigns,
        named: named,
        # A runner of its own: the command, with what it installs behind links.
        installer?: Map.has_key?(named, :command),
        indexed: Enum.with_index(assigns.setup.steps, 1),
        script: runner_script(assigns.setup.scenario)
      )

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
        The runner's token is in the command below. It is shown this once and not kept:
        copy it now.
      </p>

      <div :if={@diff} id="runner-diff" class="space-y-1">
        <p class="text-xs font-medium text-base-content/70">
          {if Enum.all?(@diff, &match?({:eq, _}, &1)),
            do: "Nothing changes on the machine.",
            else: "What changes — run the command again on the machine to put it in place:"}
        </p>
        <pre
          :if={Enum.any?(@diff, &(not match?({:eq, _}, &1)))}
          class="max-h-64 overflow-auto rounded-lg bg-base-300/60 p-3 font-mono text-xs"
        ><span
          :for={{op, line} <- @diff}
          :if={op != :eq}
          class={["block", if(op == :ins, do: "text-success", else: "text-error")]}
        >{if op == :ins, do: "+ ", else: "- "}{line}</span></pre>
      </div>

      <div :if={@installer?} class="space-y-3 text-sm">
        <div class="space-y-1.5">
          <p>{@named.command.text}</p>
          <.code_block id="runner-command" code={@named.command.code} />
        </div>

        <p id="runner-installs">
          That command will install
          <button
            type="button"
            class="link link-primary"
            phx-target={@target}
            phx-click="reveal"
            phx-value-part="script"
            id="reveal-script"
          >a runner script</button>
          and
          <button
            type="button"
            class="link link-primary"
            phx-target={@target}
            phx-click="reveal"
            phx-value-part="config"
            id="reveal-config"
          >a config file</button>
        </p>

        <div :if={MapSet.member?(@revealed, "script")} class="space-y-1.5">
          <p class="text-xs text-base-content/70">
            The runner, the same for everybody: it asks for a job, runs the config's function for
            its kind, and reports back.
          </p>
          <.code_block id="runner-script" code={@script} class="max-h-80" />
        </div>

        <div :if={MapSet.member?(@revealed, "config") and @named[:config]} class="space-y-1.5">
          <p class="text-xs text-base-content/70">{@named.config.text}</p>
          <.code_block :if={@named.config[:code]} id="runner-config" code={@named.config.code} />
        </div>

        <div :if={@named[:checksums]} class="space-y-1.5">
          <button
            type="button"
            class="link text-xs text-base-content/70"
            phx-target={@target}
            phx-click="reveal"
            phx-value-part="verify"
            id="reveal-verify"
          >
            Verify the script
          </button>
          <div :if={MapSet.member?(@revealed, "verify")} class="space-y-1.5">
            <p class="text-xs text-base-content/70">{@named.checksums.text}</p>
            <.code_block id="runner-checksums" code={@named.checksums.code} />
          </div>
        </div>

        <p :if={@named[:rule]} id="runner-rule">
          <%= if @named.rule[:pool] do %>
            Nothing is sent until a rule sends it: add one under
            <button
              type="button"
              class="link link-primary"
              phx-target={@target}
              phx-click="close_dialog"
              id="runner-to-automations"
            >Automations</button>
            with the Send cards to a runner preset (pool {@named.rule.pool}, kind {@named.rule.kind}).
          <% else %>
            {@named.rule.text}
          <% end %>
        </p>
      </div>

      <ul :if={not @installer?} class="space-y-3">
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
          phx-click="edit_answers"
          phx-value-id={@runner.id}
        >
          <.icon name="hero-pencil-square" class="size-3.5" /> Change the answers
        </button>
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

  # A block of text to paste, with its copy button.
  defp code_block(assigns) do
    ~H"""
    <div class="relative">
      <pre
        id={@id}
        class={[
          "overflow-x-auto whitespace-pre rounded-lg bg-base-300/60 p-3 pr-16 font-mono text-xs",
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

  # What the installer puts on the machine as the runner itself.
  defp runner_script("windows"),
    do: SlipdockWeb.RunnerInstallController.files()["slipdock-runner.ps1"]

  defp runner_script(_scenario),
    do: SlipdockWeb.RunnerInstallController.files()["slipdock-runner"]

  defp blank?(value), do: value in [nil, ""]
end

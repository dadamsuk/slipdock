defmodule SlipdockWeb.MachinesLive.Show do
  @moduledoc """
  `/machines/:id` — one machine running the runner daemon (#2572, epic
  #2569, W-2544 §4): whether it is online, its system, the executors and
  the ceiling it reported (read-only: only a person at the machine changes
  it), its runners with their state and current job, the rejections with
  their reasons and the limits, and the log of accepted and rejected
  changes, and each runner's latest probe (#2580): green with when it
  passed, red with the log it sent. Last, the trust contract
  (`SlipdockWeb.TrustContract`, #2581).

  Its owner adds, changes, pauses, probes and removes runners here, renames
  the machine (#2666; its hostname stays as the daemon reported it), asks it
  to update now, and revokes it. A field set outside the ceiling is marked
  with the limit; the page still saves it, since the daemon is what
  refuses (`Slipdock.Runners.Ceiling`), and its refusal then shows here.
  A member of a board the machine serves sees the page and changes nothing.

  It follows the machine's config topic, so a change made elsewhere (the
  CLI, the API) and the daemon's reports show without a reload.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents, only: [timestamp: 1]
  import SlipdockWeb.TrustContract, only: [trust_contract: 1]

  alias Slipdock.{Access, Machines}
  alias Slipdock.Machines.Machine
  alias Slipdock.Runners.{Ceiling, Config, MachineRunners, MachineSetup, Probe}

  @config_fields ~w(agent directory permission_mode timeout_minutes model worktree verbosity
                    instructions executor before_hook after_hook probe_hook image network)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Machines.get_visible_machine(socket.assigns.current_user, id) do
      {:ok, machine, role} ->
        if connected?(socket), do: MachineRunners.subscribe(machine)

        {:ok,
         socket
         |> assign(page_title: machine.name, role: role, form: nil, editing: nil, notice: nil)
         |> load(machine)}

      {:error, :not_found, _} ->
        {:ok,
         socket
         |> put_flash(:error, "No machine of yours, or of a board you're on, has that number.")
         |> push_navigate(to: ~p"/account/machines")}
    end
  end

  defp load(socket, machine) do
    machine = Slipdock.Repo.reload!(machine) |> Slipdock.Repo.preload(:user)
    reachable = Access.list_boards(socket.assigns.current_user, archived: :all)

    # A board member sees only the runners of boards they're on, and their
    # changes: the rest of the owner's work isn't theirs to read.
    runners =
      MachineRunners.list_runners(machine)
      |> visible(socket.assigns.role, Enum.map(reachable, & &1.id))

    runner_ids = Enum.map(runners, & &1.id)

    assign(socket,
      machine: machine,
      rename_form: to_form(%{"name" => machine.name}, as: :machine),
      runners: runners,
      jobs: MachineRunners.running_jobs(runners),
      probes: Probe.latest(runners),
      changes:
        machine
        |> MachineRunners.reports()
        |> Enum.filter(&(socket.assigns.role == :owner or Enum.member?(runner_ids, &1.runner_id))),
      board_names: Map.new(reachable, &{&1.id, &1.name}),
      boards: Enum.filter(reachable, &Enum.member?(machine.board_ids, &1.id)),
      setup_prompt: setup_prompt(socket, machine)
    )
  end

  # Set up this machine with Claude (#2579): its owner's, while it's enrolled.
  defp setup_prompt(%{assigns: %{role: :owner}} = socket, %{revoked_at: nil} = machine),
    do: MachineSetup.prompt(machine, SlipdockWeb.BaseURL.from_socket(socket))

  defp setup_prompt(_socket, _machine), do: nil

  defp visible(runners, :owner, _board_ids), do: runners

  defp visible(runners, :member, board_ids),
    do: Enum.filter(runners, &Enum.member?(board_ids, &1.board_id))

  ## Events --------------------------------------------------------------------

  @impl true
  def handle_event(_event, _params, %{assigns: %{role: :member}} = socket),
    do: {:noreply, notice(socket, :error, "Only the machine's owner changes it.")}

  def handle_event("new_runner", _params, socket) do
    board = List.first(socket.assigns.boards)

    params =
      Config.load(%{})
      |> Config.dump()
      |> Map.merge(%{
        "board" => board && to_string(board.id),
        "pool" => "default",
        "name" => "",
        "directory" => List.first(ceiling_list(socket.assigns.machine, "roots")) || ""
      })

    {:noreply, assign(socket, form: params, editing: nil, notice: nil)}
  end

  def handle_event("edit_runner", %{"id" => id}, socket) do
    case find_runner(socket, id) do
      nil ->
        {:noreply, socket}

      runner ->
        params =
          runner.config
          |> Config.load()
          |> Config.dump()
          |> Map.merge(%{"pool" => runner.pool, "name" => runner.name})

        {:noreply, assign(socket, form: params, editing: runner, notice: nil)}
    end
  end

  def handle_event("cancel_form", _params, socket),
    do: {:noreply, assign(socket, form: nil, editing: nil)}

  def handle_event("form_change", %{"runner" => params}, socket),
    do: {:noreply, assign(socket, form: merge_form(socket.assigns.form, params))}

  def handle_event("save_runner", %{"runner" => params}, socket) do
    attrs = %{
      "pool" => params["pool"],
      "name" => blank(params["name"]),
      "config" => Map.take(params, @config_fields)
    }

    result =
      case socket.assigns.editing do
        nil -> add_runner(socket, params["board"], attrs)
        runner -> MachineRunners.set_runner(runner, attrs)
      end

    case result do
      {:ok, runner} ->
        {:noreply,
         socket
         |> assign(form: nil, editing: nil)
         |> notice(:info, "#{runner.name} saved. The machine has it within seconds.")
         |> load(socket.assigns.machine)}

      {:error, :invalid, message} ->
        {:noreply,
         socket
         |> assign(form: merge_form(socket.assigns.form, params))
         |> notice(:error, message)}
    end
  end

  def handle_event(event, %{"id" => id}, socket)
      when event in ["pause_runner", "resume_runner", "remove_runner"] do
    with runner when not is_nil(runner) <- find_runner(socket, id),
         {:ok, _} <- runner_action(event, runner) do
      {:noreply,
       socket |> notice(:info, done_text(event, runner)) |> load(socket.assigns.machine)}
    else
      nil -> {:noreply, socket}
      {:error, :invalid, message} -> {:noreply, notice(socket, :error, message)}
    end
  end

  def handle_event("probe_runner", %{"id" => id}, socket) do
    with runner when not is_nil(runner) <- find_runner(socket, id),
         {:ok, _job} <- Probe.send_probe(socket.assigns.machine, runner) do
      {:noreply,
       socket
       |> notice(:info, "Probe sent to #{runner.name}. Its result shows here when it ends.")
       |> load(socket.assigns.machine)}
    else
      nil -> {:noreply, socket}
      {:error, :invalid, message} -> {:noreply, notice(socket, :error, message)}
    end
  end

  def handle_event("update_now", _params, socket) do
    case MachineRunners.request_update(socket.assigns.machine) do
      {:ok, machine} ->
        {:noreply,
         socket
         |> notice(:info, "Asked. #{machine.name} looks for a newer signed release at once.")
         |> load(machine)}

      {:error, :invalid, message} ->
        {:noreply, notice(socket, :error, message)}
    end
  end

  def handle_event("rename", %{"machine" => %{"name" => name}}, socket) do
    case Machines.rename_machine(socket.assigns.machine, name) do
      {:ok, machine} ->
        {:noreply,
         socket
         |> assign(page_title: machine.name)
         |> notice(:info, "Renamed: the machine is now #{machine.name}.")
         |> load(machine)}

      {:error, :invalid, message} ->
        {:noreply, notice(socket, :error, message)}
    end
  end

  def handle_event("revoke", _params, socket) do
    {:ok, machine} = Machines.revoke_machine(socket.assigns.machine)

    {:noreply,
     socket
     |> notice(:info, "#{machine.name} is revoked: its key no longer works.")
     |> load(machine)}
  end

  # The form's values so far with the new ones. The browser's `_unused_`
  # markers are dropped: a field's limit shows whether or not it has been
  # touched yet, and a stale marker would hide it once it had.
  defp merge_form(form, params) do
    form
    |> Map.merge(params)
    |> Map.reject(fn {key, _} -> String.starts_with?(key, "_unused_") end)
  end

  defp add_runner(socket, board_ref, attrs) do
    case Enum.find(socket.assigns.boards, &(to_string(&1.id) == to_string(board_ref))) do
      nil -> {:error, :invalid, "choose one of the boards the machine serves"}
      board -> MachineRunners.add_runner(socket.assigns.machine, board, attrs)
    end
  end

  defp runner_action("pause_runner", runner), do: MachineRunners.pause_runner(runner)
  defp runner_action("resume_runner", runner), do: MachineRunners.resume_runner(runner)
  defp runner_action("remove_runner", runner), do: MachineRunners.remove_runner(runner)

  defp done_text("pause_runner", r), do: "#{r.name} is paused: it takes no job until resumed."
  defp done_text("resume_runner", r), do: "#{r.name} takes jobs again."

  defp done_text("remove_runner", r),
    do: "#{r.name} is removed. The machine finishes the job it holds, then stops it."

  defp find_runner(socket, id),
    do: Enum.find(socket.assigns.runners, &(to_string(&1.id) == to_string(id)))

  # What an action says goes at the top of the page, where it was done.
  defp notice(socket, kind, text), do: assign(socket, notice: {kind, text})

  # A container runner's network, said only when it is off.
  defp network_note(%{"network" => "off"}), do: ", network off"
  defp network_note(_config), do: ""

  defp blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank(value), do: value

  ## The daemon's reports and changes made elsewhere ------------------------------

  @impl true
  def handle_info({event, _machine_id}, socket)
      when event in [:config_changed, :config_reported, :probe_changed],
      do: {:noreply, load(socket, socket.assigns.machine)}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Helpers for the template -----------------------------------------------------

  defp ceiling_list(%Machine{ceiling: %{} = c}, key), do: c[key] || []
  defp ceiling_list(_machine, _key), do: []

  # Where the form's values fall outside the ceiling, field by field, for
  # marking each with its limit as it is typed.
  defp outside(machine, params, board_id) do
    config = Config.load(%{}) |> Config.dump() |> Map.merge(Map.take(params, @config_fields))
    config = Map.update!(config, "timeout_minutes", &to_int/1)
    config |> Ceiling.outside(machine.ceiling, board_id) |> Map.new()
  end

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp form_board_id(%{editing: %{board_id: id}}), do: id
  defp form_board_id(%{form: %{"board" => ref}}), do: to_int(ref)
  defp form_board_id(_), do: nil

  defp runner_outside(machine, runner) do
    case MachineRunners.outside_ceiling(machine, runner) do
      :ok -> []
      {:error, reasons} -> reasons
    end
  end

  defp runner_state(runner, jobs) do
    cond do
      runner.paused_at -> {"paused", "bg-warning/15 text-warning"}
      runner.rejected_version -> {"rejected", "bg-error/10 text-error"}
      Map.has_key?(jobs, runner.id) -> {"working", "bg-success/15 text-success"}
      runner.accepted_version == runner.config_version -> {"ready", "bg-base-200"}
      true -> {"waiting for the machine", "bg-base-200 text-base-content/60"}
    end
  end

  defp board_name(names, id), do: Map.get(names, id, "board ##{id}")

  ## Render ------------------------------------------------------------------------

  attr :runner, :map, required: true
  attr :probe, :map, required: true

  # A runner's latest probe: waiting or running, green with when it
  # passed, or red with the log it sent.
  defp probe_result(assigns) do
    assigns = assign(assigns, result: Probe.result(assigns.probe), log: Probe.log(assigns.probe))

    ~H"""
    <div id={"machine-runner-#{@runner.id}-probe"} data-result={@result} class="text-xs">
      <p :if={@result == :pending} class="text-base-content/60">
        Probe #{@probe.id} {if @probe.status == "queued",
          do: "sent, waiting for the machine to take it",
          else: "running"} · <.timestamp at={@probe.inserted_at} />
      </p>
      <p :if={@result == :green} class="text-success">
        <.icon name="hero-check-circle" class="size-3.5 align-text-bottom" /> Probe passed
        · <.timestamp at={@probe.finished_at} />
      </p>
      <details :if={@result == :red} open class="text-error">
        <summary class="cursor-pointer">
          <.icon name="hero-x-circle" class="size-3.5 align-text-bottom" />
          Probe {probe_end(@probe)} · <.timestamp at={@probe.finished_at || @probe.updated_at} />
        </summary>
        <pre
          data-role="probe-log"
          class="field-mono mt-1 max-h-64 overflow-auto whitespace-pre-wrap rounded bg-base-200 p-2 text-base-content"
        >{if @log == "", do: @probe.error || "No log was sent.", else: @log}</pre>
      </details>
      <details :if={@result != :red and @log != ""} class="text-base-content/60">
        <summary class="cursor-pointer">Its log</summary>
        <pre
          data-role="probe-log"
          class="field-mono mt-1 max-h-64 overflow-auto whitespace-pre-wrap rounded bg-base-200 p-2 text-base-content"
        >{@log}</pre>
      </details>
    </div>
    """
  end

  defp probe_end(%{status: "failed"}), do: "failed"
  defp probe_end(%{status: "timeout"}), do: "timed out"
  defp probe_end(%{status: "cancelled"}), do: "was cancelled"
  defp probe_end(%{status: status}), do: "ended #{status}"

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        outside:
          if(assigns.form,
            do: outside(assigns.machine, assigns.form, form_board_id(assigns)),
            else: %{}
          ),
        online: Machines.online?(assigns.machine),
        revoked: Machine.revoked?(assigns.machine)
      )

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
      nav_active={:account}
    >
      <div class="kanban-scroll h-full overflow-y-auto">
        <.page width="standard" class="space-y-6">
          <.page_header title={@machine.name} class="">
            <:meta>
              <span id="machine-state">
                <span :if={@revoked} class="font-medium text-error">revoked</span>
                <span :if={!@revoked and @online} class="font-medium text-success">online</span>
                <span :if={!@revoked and !@online}>offline</span>
              </span>
              · {@machine.os} {@machine.arch}
              <span :if={@machine.last_seen_at}>
                · seen <.timestamp at={@machine.last_seen_at} />
              </span>
              <span :if={@role == :member} id="machine-owner">
                · {Slipdock.Accounts.User.display_name(@machine.user)}'s machine: you see it as a member of a board it serves
              </span>
            </:meta>
            <:actions>
              <.link navigate={~p"/account/machines"} class="btn btn-ghost btn-sm">All machines</.link>
              <button
                :if={@role == :owner and !@revoked}
                id="machine-update-now"
                type="button"
                class="btn btn-sm"
                phx-click="update_now"
              >
                Update now
              </button>
              <button
                :if={@role == :owner and !@revoked}
                id="machine-revoke"
                type="button"
                class="btn btn-ghost btn-error btn-sm"
                phx-click="revoke"
                data-confirm={"Revoke #{@machine.name}? Its key stops working at once."}
              >
                Revoke
              </button>
            </:actions>
          </.page_header>

          <.callout
            :if={@notice}
            id="machine-notice"
            kind={if elem(@notice, 0) == :error, do: :error, else: :info}
          >
            {elem(@notice, 1)}
          </.callout>

          <p
            :if={@machine.update_requested_at}
            id="machine-update-asked"
            class="text-xs text-base-content/60"
          >
            Update asked for <.timestamp at={@machine.update_requested_at} />.
          </p>

          <.form
            :if={@role == :owner}
            for={@rename_form}
            id="machine-rename"
            phx-submit="rename"
            class="field-row gap-2 text-sm"
          >
            <div class="min-w-40">
              <.input
                field={@rename_form[:name]}
                id="machine-rename-name"
                label="Name"
                maxlength="60"
                autocomplete="off"
              />
            </div>
            <button type="submit" class="btn btn-sm">Rename</button>
            <span
              :if={@machine.hostname != @machine.name}
              class="pb-1 text-xs text-base-content/50"
            >
              hostname {@machine.hostname}
            </span>
          </.form>

          <details
            :if={@setup_prompt}
            id="machine-setup"
            class="rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/10"
          >
            <summary class="cursor-pointer select-none px-6 py-4 text-sm font-semibold">
              Set up this machine with Claude
            </summary>
            <div class="space-y-3 px-6 pb-6">
              <p class="text-sm text-base-content/70">
                Paste this into Claude Code on the machine, as the account its jobs run as
                (<code>slipdock-runner setup</code> launches it for you). It reads each board's
                machine-setup page, checks what's there, installs what's missing, proves it by
                cloning the repository and running its suite, and corrects the page where it was wrong.
              </p>
              <div class="relative">
                <pre
                  id="machine-setup-prompt"
                  class="max-h-80 overflow-y-auto whitespace-pre-wrap rounded-lg bg-base-300/60 p-3 pr-16 font-mono text-xs"
                >{@setup_prompt}</pre>
                <button
                  type="button"
                  id="machine-setup-prompt-copy"
                  phx-hook="CopyText"
                  data-target="machine-setup-prompt"
                  class="btn btn-ghost btn-xs absolute right-1.5 top-1.5"
                >
                  <span data-label>Copy</span>
                </button>
              </div>
            </div>
          </details>

          <section
            id="machine-ceiling"
            class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
          >
            <h2 class="section-title">Ceiling</h2>
            <p class="mt-1 text-sm text-base-content/60">
              The machine's own limits on what this page may set, from a file on the machine.
              Only someone at the machine changes them; a setting outside them is refused there.
            </p>
            <.empty_state
              :if={is_nil(@machine.ceiling)}
              id="machine-ceiling-none"
              icon="hero-shield-check"
              title="Not reported yet"
              class="mt-3"
              compact
            >
              The daemon sends it when it next starts.
            </.empty_state>
            <dl
              :if={@machine.ceiling}
              class="mt-4 grid grid-cols-1 gap-x-6 gap-y-2 text-sm sm:grid-cols-2"
            >
              <div class="flex gap-3">
                <dt class="w-36 shrink-0 text-base-content/60">Directories under</dt>
                <dd class="field-mono break-all">{Enum.join(@machine.ceiling["roots"], ", ")}</dd>
              </div>
              <div class="flex gap-3">
                <dt class="w-36 shrink-0 text-base-content/60">Agents</dt>
                <dd>{Enum.join(@machine.ceiling["agents"], ", ")}</dd>
              </div>
              <div class="flex gap-3">
                <dt class="w-36 shrink-0 text-base-content/60">Highest mode</dt>
                <dd>{@machine.ceiling["max_permission_mode"]}</dd>
              </div>
              <div class="flex gap-3">
                <dt class="w-36 shrink-0 text-base-content/60">Longest job</dt>
                <dd>{@machine.ceiling["max_timeout_minutes"]} minutes</dd>
              </div>
              <div class="flex gap-3">
                <dt class="w-36 shrink-0 text-base-content/60">Executors</dt>
                <dd id="machine-executors">{Enum.join(@machine.ceiling["executors"], ", ")}</dd>
              </div>
              <div class="flex gap-3">
                <dt class="w-36 shrink-0 text-base-content/60">Boards</dt>
                <dd>
                  {Enum.map_join(@machine.ceiling["boards"], ", ", &board_name(@board_names, &1))}
                </dd>
              </div>
            </dl>
          </section>

          <section
            id="machine-runners"
            class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
          >
            <div class="flex items-baseline justify-between gap-3">
              <h2 class="section-title">Runners</h2>
              <button
                :if={@role == :owner and !@revoked and is_nil(@form)}
                id="machine-add-runner"
                type="button"
                class="btn btn-primary btn-sm"
                phx-click="new_runner"
              >
                Add a runner
              </button>
            </div>

            <.runner_form
              :if={@form}
              form={@form}
              editing={@editing}
              boards={@boards}
              outside={@outside}
            />

            <ul class="mt-4 divide-y divide-base-content/10">
              <li :for={r <- @runners} id={"machine-runner-#{r.id}"} class="space-y-2 py-3 text-sm">
                <% {state, tone} = runner_state(r, @jobs) %>
                <% limits = runner_outside(@machine, r) %>
                <% job = @jobs[r.id] %>
                <div class="flex flex-wrap items-center gap-2">
                  <span class="font-medium">{r.name}</span>
                  <span
                    data-role="runner-state"
                    class={["rounded px-1.5 py-0.5 text-2xs font-medium", tone]}
                  >{state}</span>
                  <span class="text-xs text-base-content/60">
                    {board_name(@board_names, r.board_id)} · pool {r.pool} · v{r.config_version}
                  </span>
                  <span class="flex-1" />
                  <span :if={@role == :owner and !@revoked} class="flex gap-1">
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs"
                      phx-click="edit_runner"
                      phx-value-id={r.id}
                    >Edit</button>
                    <button
                      :if={is_nil(r.paused_at)}
                      type="button"
                      class="btn btn-ghost btn-xs"
                      data-role="probe-runner"
                      phx-click="probe_runner"
                      phx-value-id={r.id}
                    >Probe</button>
                    <button
                      :if={is_nil(r.paused_at)}
                      type="button"
                      class="btn btn-ghost btn-xs"
                      phx-click="pause_runner"
                      phx-value-id={r.id}
                    >Pause</button>
                    <button
                      :if={r.paused_at}
                      type="button"
                      class="btn btn-ghost btn-xs"
                      phx-click="resume_runner"
                      phx-value-id={r.id}
                    >Resume</button>
                    <button
                      type="button"
                      class="btn btn-ghost btn-error btn-xs"
                      phx-click="remove_runner"
                      phx-value-id={r.id}
                      data-confirm={"Remove #{r.name}? The machine finishes the job it holds, then stops it."}
                    >Remove</button>
                  </span>
                </div>
                <p class="text-xs text-base-content/60">
                  {r.config["agent"]} in <span class="field-mono">{r.config["directory"]}</span>
                  · {r.config["permission_mode"]} · {r.config["timeout_minutes"]} min · runs as {r.config[
                    "executor"
                  ]}
                  <span :if={r.config["executor"] == "container"} data-role="runner-image">
                    from <span class="field-mono">{r.config["image"]}</span>{network_note(r.config)}
                  </span>
                </p>
                <p :if={job} class="text-xs" data-role="runner-job">
                  Working on job #{job.id}<span :if={job.card}>:
                  <.link navigate={~p"/boards/#{job.card.board_id}/cards/#{job.card.id}"} class="link">#{job.card.id} {job.card.title}</.link></span>
                </p>
                <.probe_result :if={@probes[r.id]} runner={r} probe={@probes[r.id]} />
                <.callout
                  :if={r.rejected_version}
                  id={"machine-runner-#{r.id}-rejection"}
                  kind={:error}
                  title={"The machine refused v#{r.rejected_version}"}
                >
                  <p>{r.rejection}</p>
                  <p :if={limits != []} class="mt-1">
                    The ceiling: {Enum.join(limits, "; ")}.
                  </p>
                  <p class="mt-1 text-base-content/60">
                    {if r.accepted_version,
                      do: "It still runs v#{r.accepted_version}, the last it accepted.",
                      else: "It has accepted no settings for this runner yet, so it runs nothing."}
                  </p>
                </.callout>
                <.callout
                  :if={is_nil(r.rejected_version) and limits != []}
                  id={"machine-runner-#{r.id}-outside"}
                  kind={:warning}
                >
                  Outside the ceiling, so the machine will refuse it: {Enum.join(limits, "; ")}.
                </.callout>
              </li>
            </ul>
            <.empty_state
              :if={@runners == []}
              id="machine-runners-none"
              icon="hero-cpu-chip"
              title="No runners yet"
              class="mt-3"
              compact
            >
              {if @role == :owner and !@revoked,
                do: "Add one to have this machine take a pool's jobs.",
                else: "Its owner adds them here."}
            </.empty_state>
          </section>

          <section
            id="machine-log"
            class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
          >
            <h2 class="section-title">Changes</h2>
            <p class="mt-1 text-sm text-base-content/60">
              What the machine said of each setting it was sent.
            </p>
            <ul class="mt-3 space-y-1 text-sm">
              <li :for={c <- @changes} class="flex flex-wrap gap-2">
                <span class={if c.outcome == "rejected", do: "text-error", else: "text-success"}>{c.outcome}</span>
                <span>{c.runner_name} v{c.version}</span>
                <span :if={c.reason} class="text-base-content/70">— {c.reason}</span>
                <span class="text-xs text-base-content/60"><.timestamp at={c.inserted_at} /></span>
              </li>
            </ul>
            <.empty_state
              :if={@changes == []}
              id="machine-log-none"
              icon="hero-clock"
              title="Nothing yet"
              class="mt-3"
              compact
            >
              Each setting the machine accepts or refuses is listed here.
            </.empty_state>
          </section>

          <section
            id="machine-trust-contract"
            class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
          >
            <h2 class="section-title">What the server can and cannot do</h2>
            <p class="mt-1 text-sm text-base-content/60">
              The trust contract. On the machine, <code>slipdock-runner show</code>
              prints it after this machine's own limits.
            </p>
            <.trust_contract class="mt-3 text-sm" />
          </section>
        </.page>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :map, required: true
  attr :editing, :any, required: true
  attr :boards, :list, required: true
  attr :outside, :map, required: true

  defp runner_form(assigns) do
    # Each field outside the ceiling carries its limit as the field's error.
    errors = for {key, line} <- assigns.outside, do: {String.to_existing_atom(key), {line, []}}

    assigns =
      assign(assigns,
        f: to_form(assigns.form, as: :runner, errors: errors),
        hooks: [
          {:before_hook, "Before hook"},
          {:after_hook, "After hook"},
          {:probe_hook, "Probe hook"}
        ]
      )

    ~H"""
    <.form
      for={@f}
      id="machine-runner-form"
      phx-change="form_change"
      phx-submit="save_runner"
      class="mt-4 space-y-4 rounded-xl bg-base-200/40 p-4 ring-1 ring-base-content/10"
    >
      <p class="text-sm font-medium">
        {if @editing, do: "Changing #{@editing.name}", else: "A new runner"}
      </p>
      <.callout :if={@outside != %{}} id="machine-runner-form-outside" kind={:warning}>
        Outside this machine's ceiling: it will refuse this and keep the runner's last accepted
        settings.
      </.callout>
      <div class="grid grid-cols-1 gap-x-3 text-sm sm:grid-cols-2">
        <.input
          :if={is_nil(@editing)}
          field={@f[:board]}
          type="select"
          label="Board"
          options={Enum.map(@boards, &{&1.name, &1.id})}
        />
        <.input field={@f[:pool]} label="Pool" />
        <.input field={@f[:name]} label="Name" placeholder="the machine's name and the pool" />
        <.input field={@f[:agent]} label="Agent" />
        <div class="sm:col-span-2">
          <.input
            field={@f[:directory]}
            label="Working directory"
            class="w-full input field field-mono"
          />
        </div>
        <.input
          field={@f[:permission_mode]}
          type="select"
          label="Permission mode"
          options={Config.permission_modes()}
        />
        <.input field={@f[:timeout_minutes]} type="number" min="1" label="Timeout (minutes)" />
        <.input field={@f[:executor]} type="select" label="Runs as" options={Config.executors()} />
        <.input
          field={@f[:image]}
          label="Container image (container only; the machine's allow-list decides)"
          placeholder="slipdock-agent:1"
          class="w-full input field field-mono"
        />
        <.input
          field={@f[:network]}
          type="select"
          label="Network (container only)"
          options={Config.networks()}
        />
        <.input field={@f[:model]} label="Model (optional)" />
        <.input
          field={@f[:worktree]}
          type="select"
          label="Worktree per job"
          options={~w(auto on off)}
        />
        <.input
          field={@f[:verbosity]}
          type="select"
          label="How much it writes"
          options={~w(quiet normal verbose)}
        />
        <.input
          :for={{key, label} <- @hooks}
          field={@f[key]}
          label={"#{label} (a name the machine defines)"}
        />
        <div class="sm:col-span-2">
          <.input
            field={@f[:instructions]}
            type="textarea"
            rows="3"
            label="Standing instructions"
          />
        </div>
      </div>
      <div class="flex gap-2">
        <button type="submit" class="btn btn-primary btn-sm">Save</button>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_form">Cancel</button>
      </div>
    </.form>
    """
  end
end

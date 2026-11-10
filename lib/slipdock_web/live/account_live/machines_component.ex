defmodule SlipdockWeb.AccountLive.MachinesComponent do
  @moduledoc """
  Account › Machines (#2570): the computers enrolled to run the runner
  daemon for this account, each revocable, and the one-time enrolment keys
  for a machine with nobody at its screen (`slipdock-runner init --key`).
  A key is shown once.

  Each machine opens its own page (`SlipdockWeb.MachinesLive.Show`, #2572),
  where its runners are managed. The machines of other people that serve a
  board you're on are listed too, to see, not to change.
  """
  use SlipdockWeb, :live_component

  alias Slipdock.{Access, Machines}
  alias Slipdock.Machines.{EnrolmentKey, Machine}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Loaded once, so a later update can't drop a key waiting to be copied.
    if Map.has_key?(socket.assigns, :machines),
      do: {:ok, socket},
      else: {:ok, socket |> assign(new_key: nil, key_error: nil, form_key: 0) |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_user
    boards = Access.list_boards(user)

    assign(socket,
      machines: Machines.list_machines(user),
      shared: Machines.list_shared_machines(user),
      keys: Machines.list_enrolment_keys(user),
      boards: boards,
      board_names: Map.new(Access.list_boards(user, archived: :all), &{&1.id, &1.name})
    )
  end

  @impl true
  def handle_event("create_key", params, socket) do
    case Machines.create_enrolment_key(
           socket.assigns.current_user,
           Map.get(params, "boards", []),
           params["label"]
         ) do
      {:ok, key, _record} ->
        {:noreply,
         socket
         |> assign(new_key: key, key_error: nil)
         |> update(:form_key, &(&1 + 1))
         |> load()}

      {:error, :invalid, message} ->
        {:noreply, assign(socket, key_error: message)}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    with id when not is_nil(id) <- SlipdockWeb.Params.id(id),
         {:ok, machine} <- Machines.get_machine(socket.assigns.current_user, id),
         {:ok, _} <- Machines.revoke_machine(machine) do
      send(self(), {:flash, :info, "#{machine.name} is revoked: its key no longer works."})
    end

    {:noreply, load(socket)}
  end

  def handle_event("dismiss_key", _, socket), do: {:noreply, assign(socket, new_key: nil)}

  defp relative_time(dt), do: SlipdockWeb.SlipdockComponents.relative_time(dt)

  defp board_list(ids, names) do
    case Enum.map(ids, &Map.get(names, &1)) |> Enum.reject(&is_nil/1) do
      [] -> "no boards you can still reach"
      list -> Enum.join(list, ", ")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <p class="text-sm text-base-content/60">
          Computers running the runner daemon for you. Run <code>slipdock-runner init</code>
          on one: it shows a code to approve at <.link
            navigate={~p"/account/machines/approve"}
            class="link"
          >Approve a machine</.link>. A machine key only lets it take and report on jobs for
          its own runners; it is not an API token. Revoking a machine stops its key at once.
        </p>

        <ul id="machines" class="mt-4 divide-y divide-base-content/10">
          <li
            :for={m <- @machines}
            id={"machine-#{m.id}"}
            class="flex items-center gap-3 py-2 text-sm"
          >
            <.icon name="hero-computer-desktop" class="size-4 text-base-content/40" />
            <span class="flex min-w-0 flex-1 flex-col">
              <span class="flex items-center gap-2">
                <.link navigate={~p"/machines/#{m.id}"} class="link truncate font-medium">
                  {m.name}
                </.link>
                <span
                  :if={Machines.online?(m)}
                  class="rounded bg-success/15 px-1.5 py-0.5 text-2xs font-medium text-success"
                >online</span>
                <span class="text-xs text-base-content/50">{m.os} {m.arch}</span>
                <span
                  :if={Machine.revoked?(m)}
                  class="rounded bg-error/10 px-1.5 py-0.5 text-[11px] font-medium text-error"
                >revoked</span>
              </span>
              <span class="text-xs text-base-content/50">
                serves {board_list(m.board_ids, @board_names)} · enrolled {relative_time(
                  m.inserted_at
                )}<span :if={m.last_seen_at}> · seen {relative_time(m.last_seen_at)}</span>
              </span>
              <span :if={m.fingerprint} class="font-mono text-[11px] text-base-content/40">
                {m.fingerprint}
              </span>
            </span>
            <button
              :if={!Machine.revoked?(m)}
              type="button"
              class="btn btn-ghost btn-error btn-xs"
              phx-click="revoke"
              phx-target={@myself}
              phx-value-id={m.id}
              data-confirm={"Revoke #{m.name}? Its key stops working at once."}
            >Revoke</button>
          </li>
        </ul>
        <.empty_state
          :if={@machines == []}
          id="machines-empty"
          icon="hero-computer-desktop"
          title="No machines yet"
          class="mt-3"
          compact
        >
          Run <code>slipdock-runner init</code> on a computer, or make an enrolment key below.
        </.empty_state>
      </section>

      <section
        :if={@shared != []}
        id="shared-machines"
        class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
      >
        <h3 class="font-medium">Serving your boards</h3>
        <p class="mt-1 text-sm text-base-content/60">
          Other people's machines that take work from boards you're on. You can see them;
          only their owners change them.
        </p>
        <ul class="mt-3 divide-y divide-base-content/10">
          <li
            :for={m <- @shared}
            id={"shared-machine-#{m.id}"}
            class="flex items-center gap-3 py-2 text-sm"
          >
            <.icon name="hero-computer-desktop" class="size-4 text-base-content/40" />
            <.link navigate={~p"/machines/#{m.id}"} class="link font-medium">{m.name}</.link>
            <span class="text-xs text-base-content/60">
              {Slipdock.Accounts.User.display_name(m.user)}'s · serves {board_list(
                m.board_ids,
                @board_names
              )}
            </span>
          </li>
        </ul>
      </section>

      <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <h3 class="font-medium">Enrolment key</h3>
        <p class="mt-1 text-sm text-base-content/60">
          For a machine with nobody at its screen: <code>slipdock-runner init --key &lt;key&gt;</code>.
          It works once, within {EnrolmentKey.validity_hours()} hours, for the boards you tick.
        </p>
        <div :if={@new_key} class="mt-4 rounded-xl bg-warning/10 p-4 text-sm">
          <p class="font-medium">Copy this key now — it won't be shown again.</p>
          <code
            id="new-enrolment-key"
            class="mt-2 block select-all break-all rounded bg-base-200 px-2 py-1 font-mono text-xs"
          >slipdock-runner init --key {@new_key}</code>
          <button
            type="button"
            class="btn btn-ghost btn-xs mt-2"
            phx-click="dismiss_key"
            phx-target={@myself}
          >Done</button>
        </div>
        <form
          id={"enrolment-key-form-#{@form_key}"}
          phx-submit="create_key"
          phx-target={@myself}
          class="mt-4 space-y-3"
        >
          <fieldset class="flex flex-wrap gap-x-4 gap-y-1 text-sm">
            <legend class="mb-1 text-xs text-base-content/50">Boards it may serve</legend>
            <label :for={b <- @boards} class="flex items-center gap-1.5">
              <input type="checkbox" name="boards[]" value={b.id} class="checkbox" />
              {b.name}
            </label>
          </fieldset>
          <p :if={@key_error} id="enrolment-key-error" class="text-sm text-error">{@key_error}</p>
          <div class="flex flex-wrap items-center gap-2">
            <input
              type="text"
              name="label"
              placeholder="Machine name (default: its hostname)"
              aria-label="The name the machine enrols under; without one, its hostname"
              class="input field min-w-40 flex-1"
              autocomplete="off"
            />
            <button type="submit" class="btn btn-primary btn-sm">Make enrolment key</button>
          </div>
        </form>
        <p :if={@keys != []} class="mt-3 text-xs text-base-content/50">
          Unused: {Enum.map_join(@keys, ", ", &(&1.label || "unlabelled"))}
        </p>
      </section>
    </div>
    """
  end
end

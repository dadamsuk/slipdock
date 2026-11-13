defmodule SlipdockWeb.AccountLive.MachineApprove do
  @moduledoc """
  `/account/machines/approve` — where a person approves a machine's
  enrolment (#2570, W-2544 §1): `slipdock-runner init` prints a short code
  and the machine's fingerprint, and this page, looked up by the code, shows
  the hostname, OS, architecture and the same fingerprint, so the person
  can see it is the machine in front of them before it is bound to their
  account. They choose the boards it may serve, from those they can write to.

  As on `/activate`: opening the link only fills the code in, never decides;
  approving is a deliberate event, and code lookups are rate limited per
  person, since the code is short.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Machines, RateLimit}
  alias Slipdock.Machines.Enrolment

  @lookups_per_hour 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Approve a machine",
       boards: Machines.servable_boards(socket.assigns.current_user),
       user_code: nil,
       enrolment: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"user_code" => code}, _uri, socket) when is_binary(code) and code != "" do
    if RateLimit.hit(
         "machine:lookup:#{socket.assigns.current_user.id}",
         @lookups_per_hour,
         3_600_000
       ) ==
         :ok do
      {:noreply,
       assign(socket,
         user_code: code,
         enrolment: Machines.enrolment_by_user_code(code),
         error: nil
       )}
    else
      {:noreply,
       assign(socket,
         user_code: nil,
         enrolment: nil,
         error: "Too many codes tried. Wait a while before trying another."
       )}
    end
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, assign(socket, user_code: nil, enrolment: nil)}

  @impl true
  def handle_event("lookup", %{"user_code" => code}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/account/machines/approve?#{[user_code: code]}")}

  def handle_event("approve", params, socket) do
    with %Enrolment{} = enrolment <- current(socket),
         {:ok, _} <-
           Machines.approve_enrolment(
             enrolment,
             socket.assigns.current_user,
             Map.get(params, "boards", [])
           ) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Approved. #{enrolment.hostname} should be enrolled within a few seconds."
       )
       |> push_navigate(to: ~p"/account/machines")}
    else
      {:error, :invalid, message} -> {:noreply, assign(socket, error: message)}
      _ -> {:noreply, gone(socket)}
    end
  end

  def handle_event("deny", _params, socket) do
    with %Enrolment{} = enrolment <- current(socket),
         {:ok, _} <- Machines.deny_enrolment(enrolment) do
      {:noreply,
       socket
       |> put_flash(:info, "Refused. The machine has been told.")
       |> push_patch(to: ~p"/account/machines/approve")}
    else
      _ -> {:noreply, gone(socket)}
    end
  end

  # Looked up again at the moment of deciding: it may have expired, or been
  # decided elsewhere, since the page drew it.
  defp current(socket),
    do: socket.assigns.user_code && Machines.enrolment_by_user_code(socket.assigns.user_code)

  defp gone(socket) do
    socket
    |> put_flash(
      :error,
      "That enrolment was decided or expired. Run init again for a fresh code."
    )
    |> push_patch(to: ~p"/account/machines/approve")
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
      nav_active={:account}
    >
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-lg px-4 py-10">
          <h1 class="page-title">Approve a machine</h1>
          <p class="mt-1 text-sm text-base-content/60">
            <code>slipdock-runner init</code>
            shows a code and the machine's fingerprint. Type the code here to decide whether
            the machine may run jobs for you.
          </p>

          <form id="machine-code-form" phx-submit="lookup" class="mt-6 flex gap-2">
            <input
              type="text"
              name="user_code"
              value={@user_code}
              placeholder="XXXX-XXXX"
              autocomplete="off"
              autocapitalize="characters"
              spellcheck="false"
              class="input field flex-1 field-mono tracking-widest"
            />
            <button type="submit" class="btn">Look it up</button>
          </form>

          <p :if={@error} id="machine-approve-error" class="mt-4 text-sm text-error">{@error}</p>

          <div
            :if={@user_code && is_nil(@enrolment)}
            id="machine-code-unknown"
            class="mt-6 rounded-xl bg-error/10 p-4 text-sm text-error"
          >
            No pending machine with that code. Codes last {Enrolment.validity_minutes()} minutes and
            work once — run <code>slipdock-runner init</code> again.
          </div>

          <div
            :if={@enrolment}
            id="machine-enrolment"
            class="mt-6 rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
          >
            <p class="text-sm text-base-content/60">This machine asks to run jobs for you:</p>
            <dl class="mt-4 space-y-3 text-sm">
              <div class="flex gap-3">
                <dt class="w-28 shrink-0 text-base-content/50">Hostname</dt>
                <dd class="font-medium">{@enrolment.hostname}</dd>
              </div>
              <div class="flex gap-3">
                <dt class="w-28 shrink-0 text-base-content/50">System</dt>
                <dd>{@enrolment.os || "unknown"} · {@enrolment.arch || "unknown"}</dd>
              </div>
              <div class="flex gap-3">
                <dt class="w-28 shrink-0 text-base-content/50">Fingerprint</dt>
                <dd class="break-all font-mono text-xs">{@enrolment.fingerprint || "none given"}</dd>
              </div>
              <div class="flex gap-3">
                <dt class="w-28 shrink-0 text-base-content/50">Asked from</dt>
                <dd class="font-mono text-xs">{@enrolment.client_ip || "unknown"}</dd>
              </div>
            </dl>

            <p class="mt-4 rounded-lg bg-warning/10 p-3 text-xs">
              Check the fingerprint matches the one <code>init</code>
              printed. If you didn't just start this yourself, refuse it. Approving binds the
              machine to your account: it can take jobs from the boards you tick, and nothing
              else, until you revoke it under Account → Machines.
            </p>

            <form id="machine-approve-form" phx-submit="approve" class="mt-5 space-y-4">
              <fieldset class="space-y-1 text-sm">
                <legend class="mb-1 text-xs text-base-content/50">Boards it may serve</legend>
                <label :for={b <- @boards} class="flex items-center gap-2">
                  <input type="checkbox" name="boards[]" value={b.id} class="checkbox" />
                  {b.name}
                </label>
              </fieldset>
              <div class="flex gap-2">
                <button type="button" phx-click="deny" class="btn btn-ghost flex-1">Refuse</button>
                <button type="submit" class="btn btn-primary flex-1">Approve</button>
              </div>
            </form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

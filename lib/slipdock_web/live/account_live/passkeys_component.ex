defmodule SlipdockWeb.AccountLive.PasskeysComponent do
  @moduledoc """
  The passkeys on the Account tab (#828): adding one, and the list to remove
  them from. Adding needs the authenticator, so the `PasskeyRegister` hook
  runs it against `SlipdockWeb.PasskeyController` and reports back here;
  listing and removing are this component's own.
  """
  use SlipdockWeb, :live_component

  alias Slipdock.Accounts.{Passkey, Passkeys}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if Map.has_key?(socket.assigns, :passkeys),
      do: {:ok, socket},
      else: {:ok, socket |> assign(supported?: nil) |> load()}
  end

  defp load(socket),
    do: assign(socket, passkeys: Passkeys.list(socket.assigns.current_user))

  @impl true
  def handle_event("passkey_support", %{"supported" => supported}, socket),
    do: {:noreply, assign(socket, supported?: supported == true)}

  def handle_event("passkey_added", %{"name" => name}, socket) do
    send(self(), {:flash, :info, "Passkey “#{name}” added. You can sign in with it now."})
    {:noreply, load(socket)}
  end

  def handle_event("passkey_failed", %{"message" => message}, socket) do
    send(self(), {:flash, :error, String.slice(to_string(message), 0, 200)})
    {:noreply, socket}
  end

  def handle_event("delete_passkey", %{"id" => id}, socket) do
    with id when is_integer(id) <- SlipdockWeb.Params.id(id),
         :ok <- Passkeys.delete(socket.assigns.current_user, id) do
      send(self(), {:flash, :info, "Passkey removed. It can't sign in any more."})
    end

    {:noreply, load(socket)}
  end

  defp relative_time(dt), do: SlipdockWeb.SlipdockComponents.relative_time(dt)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, full?: length(assigns.passkeys) >= Passkeys.max_per_user())

    ~H"""
    <section
      id="passkeys"
      phx-hook="PasskeyRegister"
      phx-target={@myself}
      class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
    >
      <h2 class="text-lg font-semibold">Passkeys</h2>
      <p class="text-sm text-base-content/60">
        Sign in with your fingerprint, face or device PIN instead of an emailed link.
        The email link keeps working too.
      </p>

      <p
        :if={@supported? == false}
        id="passkeys-unsupported"
        class="mt-4 rounded-xl bg-base-200 p-3 text-sm text-base-content/70"
      >
        This browser can't make passkeys. Try a current Chrome, Safari, Firefox or Edge,
        on an https address.
      </p>
      <p :if={@supported? && @full?} class="mt-4 text-sm text-base-content/60">
        That's {Passkeys.max_per_user()} passkeys, the most an account can have. Remove one to add another.
      </p>

      <form
        :if={@supported? && !@full?}
        id="passkey-add-form"
        data-passkey-add
        class="mt-4 flex flex-wrap items-center gap-2"
      >
        <input
          type="text"
          name="name"
          placeholder="Name (e.g. work laptop)"
          maxlength={Passkey.name_max()}
          class="input input-sm min-w-40 flex-1"
          autocomplete="off"
        />
        <button type="submit" class="btn btn-primary btn-sm">
          <.icon name="hero-finger-print" class="size-4" /> Add a passkey
        </button>
      </form>

      <ul class="mt-4 divide-y divide-base-content/10">
        <li :for={p <- @passkeys} id={"passkey-#{p.id}"} class="flex items-center gap-3 py-2 text-sm">
          <.icon name="hero-finger-print" class="size-4 text-base-content/40" />
          <span class="flex min-w-0 flex-1 flex-col">
            <span class="truncate font-medium">{p.name}</span>
            <span class="text-xs text-base-content/50">
              added {relative_time(p.inserted_at)} · {if p.last_used_at,
                do: "used " <> relative_time(p.last_used_at),
                else: "not used yet"}
            </span>
          </span>
          <button
            type="button"
            class="btn btn-ghost btn-xs text-error"
            phx-click="delete_passkey"
            phx-target={@myself}
            phx-value-id={p.id}
            data-confirm={"Remove the passkey “#{p.name}”? It won't be able to sign in any more."}
          >Remove</button>
        </li>
      </ul>
      <p :if={@passkeys == []} id="passkeys-empty" class="mt-3 text-sm text-base-content/50">
        No passkeys yet.
      </p>
    </section>
    """
  end
end

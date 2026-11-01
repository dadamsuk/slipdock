defmodule SlipdockWeb.VaultLive.Index do
  @moduledoc """
  The vault's page (W-2201): the one vault its owner has, with a link to its
  tree, its name and keys, its recordings folder and the folders it is synced
  to. There is nothing to lay out here: every board its owner has is a folder
  of it already.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.Vaults
  alias SlipdockWeb.SlipdockComponents

  @impl true
  def mount(params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Vault",
        google: Slipdock.Google.status(socket.assigns.current_user)
      )

    case params["vault"] do
      nil ->
        {:ok, load(socket)}

      # Reached from the vault's view (#752).
      ref ->
        case Vaults.get_vault(socket.assigns.current_user, ref) do
          {:ok, vault} ->
            {:ok, socket |> assign(page_title: "#{vault.name} · Settings") |> load()}

          _ ->
            {:ok,
             socket
             |> put_flash(:error, "There's no vault of yours by that name.")
             |> push_navigate(to: ~p"/vaults")}
        end
    end
  end

  defp load(socket) do
    user = socket.assigns.current_user
    vault = Vaults.root(user)

    assign(socket,
      vault: vault,
      pages: Vaults.page_count(vault),
      mirrors: Vaults.mirrors(vault),
      hotkeys: Slipdock.Hotkeys.list(user)
    )
  end

  @impl true
  def handle_event("rename", %{"vault_id" => id, "name" => name}, socket) do
    with {:ok, vault} <- own_vault(socket, id),
         {:ok, _} <- Vaults.update_vault(vault, %{"name" => name}) do
      {:noreply, socket |> clear_flash(:error) |> load()}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, flash(socket, :error, "Vault name #{name_error(cs)}.")}

      _ ->
        {:noreply, flash(socket, :error, "That vault isn't there any more.")}
    end
  end

  # Its key in the board switcher and its Ctrl+Shift digit (#1204), saved
  # together. A blank key takes a fresh one from the name.
  def handle_event("keys", %{"vault_id" => id} = params, socket) do
    user = socket.assigns.current_user

    with {:ok, vault} <- own_vault(socket, id),
         {:ok, _} <- Slipdock.Hotkeys.parse(params["hotkey"]),
         {:ok, vault} <- Vaults.set_shortcut(vault, params["shortcut"]),
         {:ok, digit} <- Slipdock.Hotkeys.put(user, vault, params["hotkey"]) do
      message =
        "Press b then #{vault.shortcut} to open #{vault.name}" <>
          if(digit, do: ", or Ctrl+Shift+#{digit} from any page.", else: ".")

      {:noreply, socket |> flash(:info, message) |> load()}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, flash(socket, :error, "Shortcut key #{shortcut_error(cs)}.")}

      {:error, message} when is_binary(message) ->
        {:noreply, flash(socket, :error, "Hotkey #{message}.")}

      _ ->
        {:noreply, flash(socket, :error, "That vault isn't there any more.")}
    end
  end

  def handle_event("recordings_folder", %{"vault_id" => id, "folder" => folder}, socket) do
    with {:ok, vault} <- own_vault(socket, id),
         {:ok, vault} <- Vaults.set_recordings_folder(vault, folder) do
      message =
        if vault.recordings_folder,
          do:
            "#{vault.name} plays its recordings from #{vault.recordings_folder} on Google Drive.",
          else: "#{vault.name} has no recordings folder now."

      {:noreply, socket |> flash(:info, message) |> load()}
    else
      {:error, reason} when is_atom(reason) ->
        {:noreply, flash(socket, :error, folder_error(reason, folder))}

      _ ->
        {:noreply, flash(socket, :error, "That vault isn't there any more.")}
    end
  end

  # One outcome on screen at a time: a save that works clears the error an
  # earlier one left, and the reverse (#783).
  defp flash(socket, :info, message),
    do: socket |> clear_flash(:error) |> put_flash(:info, message)

  defp flash(socket, :error, message),
    do: socket |> clear_flash(:info) |> put_flash(:error, message)

  # Only ever one of the reader's own: somebody else's is not found, as in
  # the API.
  defp own_vault(socket, id) do
    case SlipdockWeb.Params.id(id) do
      id when is_integer(id) ->
        case Vaults.get_vault(socket.assigns.current_user, id) do
          {:ok, vault} -> {:ok, vault}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp folder_error(:not_connected, _),
    do: "Connect Google Drive on your account's Settings first."

  defp folder_error(:revoked, _),
    do:
      "Google no longer accepts your Drive connection. Connect it again on your account's Settings."

  defp folder_error(:invalid, _), do: "That isn't a folder path."
  defp folder_error(:not_found, folder), do: "There's no folder \"#{folder}\" in your My Drive."
  defp folder_error(_, _), do: "Google Drive couldn't be asked just now. Try again."

  defp name_error(cs), do: cs.errors[:name] |> Kernel.||({"is invalid", []}) |> elem(0)

  defp shortcut_error(cs),
    do: cs.errors[:shortcut] |> Kernel.||({"is invalid", []}) |> elem(0)

  defp mirror_name(mirror), do: mirror.label || "an unnamed token"

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
      nav_active={:vaults}
    >
      <:nav><span class="font-semibold">Vault</span></:nav>
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl space-y-6 px-4 py-6 sm:py-10 sm:px-6">
          <div>
            <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Your vault</h1>
            <p id="vaults-what" class="mt-1 text-sm text-base-content/60">
              Your whole wiki as one Obsidian-style tree of notes. Every board you own is a
              folder at the top of it, archived ones too, and a sub-board sits in its epic's
              folder. Each page stays on its board.
            </p>
          </div>

          <div
            id={"vault-#{@vault.id}"}
            class="rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <div class="flex items-center gap-3">
              <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary">
                <.icon name="hero-rectangle-stack" class="size-5" />
              </span>
              <form phx-submit="rename" class="flex flex-1 gap-2">
                <input type="hidden" name="vault_id" value={@vault.id} />
                <input
                  type="text"
                  name="name"
                  value={@vault.name}
                  class="input input-sm flex-1 font-semibold"
                  aria-label="Vault name"
                  maxlength={Slipdock.Vaults.Vault.name_length()}
                />
                <button type="submit" class="btn btn-sm">Rename</button>
              </form>
              <.link
                id={"open-vault-#{@vault.id}"}
                navigate={SlipdockWeb.VaultUrls.url(@vault)}
                class="btn btn-ghost btn-sm"
                title="Open the vault: its tree and its pages at their vault paths"
              >
                <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open
              </.link>
            </div>
            <p id={"vault-pages-#{@vault.id}"} class="mt-2 text-xs text-base-content/50">
              {pages(@pages)}
            </p>

            <.vault_keys vault={@vault} hotkeys={@hotkeys} />

            <.recordings_folder :if={@google != :not_configured} vault={@vault} google={@google} />

            <h2 class="mt-4 text-xs font-semibold uppercase tracking-wide text-base-content/50">
              Synced to
            </h2>
            <ul class="mt-1 space-y-1">
              <li
                :for={mirror <- @mirrors}
                id={"mirror-#{mirror.id}"}
                class="flex items-center gap-2 px-2 py-1 text-sm"
              >
                <.icon name="hero-computer-desktop" class="size-4 text-base-content/50" />
                <span>{mirror_name(mirror)}</span>
                <span class="ml-auto text-xs text-base-content/50">
                  last synced {SlipdockComponents.relative_time(mirror.last_synced_at)}
                </span>
              </li>
            </ul>
            <p :if={@mirrors == []} class="mt-1 px-2 text-xs text-base-content/50">
              Not synced to a folder yet:
              <code>slipdock sync init ~/Notes --vault {@vault.name}</code>
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # The keys that open it (#1204): b then its shortcut, as a board's, and the
  # owner's own Ctrl+Shift digit.
  attr :vault, :map, required: true
  attr :hotkeys, :list, required: true

  defp vault_keys(assigns) do
    assigns =
      assign(assigns,
        hotkey:
          Enum.find_value(assigns.hotkeys, fn
            {digit, %Slipdock.Vaults.Vault{id: id}} when id == assigns.vault.id -> digit
            _ -> nil
          end)
      )

    ~H"""
    <form
      id={"vault-keys-#{@vault.id}"}
      phx-submit="keys"
      class="mt-4 flex flex-wrap items-center gap-2 text-sm"
    >
      <input type="hidden" name="vault_id" value={@vault.id} />
      <label for={"vault-shortcut-#{@vault.id}"} class="text-base-content/60">
        <.icon name="hero-command-line" class="size-4" /> Shortcut key
      </label>
      <input
        type="text"
        id={"vault-shortcut-#{@vault.id}"}
        name="shortcut"
        value={@vault.shortcut}
        maxlength={Slipdock.Boards.Board.shortcut_length()}
        class="input input-sm w-16 font-mono"
      />
      <label for={"vault-hotkey-#{@vault.id}"} class="text-base-content/60">Hotkey</label>
      <select id={"vault-hotkey-#{@vault.id}"} name="hotkey" class="select select-sm w-auto">
        <option
          :for={{label, value} <- Slipdock.Hotkeys.choices(@hotkeys, @vault)}
          value={value}
          selected={value == to_string(@hotkey || "")}
        >
          {label}
        </option>
      </select>
      <button type="submit" class="btn btn-sm">Save</button>
      <p class="w-full text-xs text-base-content/50">
        Press <kbd class="kbd kbd-xs">b</kbd>
        anywhere, then the key, to open this vault, as you would a board; clear it to take a
        fresh one from the name. The hotkey opens it from any page with
        <kbd class="kbd kbd-xs">Ctrl</kbd>
        + <kbd class="kbd kbd-xs">Shift</kbd>
        + the digit.
      </p>
    </form>
    """
  end

  # Where on the owner's Drive its meeting recordings are (W-1690). Only
  # settable with a connection, since saving checks the folder is there.
  attr :vault, :map, required: true
  attr :google, :any, required: true

  defp recordings_folder(assigns) do
    ~H"""
    <form
      id={"recordings-folder-#{@vault.id}"}
      phx-submit="recordings_folder"
      class="mt-4 flex flex-wrap items-center gap-2 text-sm"
    >
      <input type="hidden" name="vault_id" value={@vault.id} />
      <label for={"recordings-folder-input-#{@vault.id}"} class="text-base-content/60">
        <.icon name="hero-microphone" class="size-4" /> Recordings folder on Google Drive
      </label>
      <input
        type="text"
        id={"recordings-folder-input-#{@vault.id}"}
        name="folder"
        value={@vault.recordings_folder}
        placeholder="e.g. Meeting Recordings"
        disabled={not match?({:connected, _}, @google)}
        class="input input-sm flex-1 font-mono text-xs"
      />
      <button type="submit" class="btn btn-sm" disabled={not match?({:connected, _}, @google)}>
        Save
      </button>
      <p
        :if={not match?({:connected, _}, @google)}
        class="w-full text-xs text-base-content/50"
      >
        <.link navigate={~p"/account/settings"} class="link">Connect Google Drive</.link>
        to play this vault's meeting recordings from it.
      </p>
    </form>
    """
  end

  defp pages(1), do: "1 page"
  defp pages(n), do: "#{n} pages"
end

defmodule SlipdockWeb.VaultLive.Index do
  @moduledoc """
  The vaults screen (W-103 R1.1): your vaults, what each maps where and how
  many pages each mapping holds, and the folders each is synced to. Make,
  rename and delete vaults here as `slipdock vault ls|new|rename|rm` does;
  the rules are `Slipdock.Vaults`'s, nothing new.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.Vaults
  alias Slipdock.Vaults.Mapping
  alias SlipdockWeb.SlipdockComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Vaults", form_key: 0) |> load()}
  end

  defp load(socket) do
    vaults =
      socket.assigns.current_user
      |> Vaults.list_vaults()
      |> Enum.map(fn vault ->
        %{vault: vault, counts: Vaults.page_counts(vault), mirrors: Vaults.mirrors(vault)}
      end)

    assign(socket, vaults: vaults)
  end

  @impl true
  def handle_event("create", %{"name" => name}, socket) do
    case Vaults.create_vault(socket.assigns.current_user, %{"name" => name}) do
      {:ok, vault} ->
        {:noreply,
         socket
         |> update(:form_key, &(&1 + 1))
         |> put_flash(:info, "Made #{vault.name}. Map a board onto it to give it pages.")
         |> load()}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, "Vault name #{name_error(cs)}.")}
    end
  end

  def handle_event("rename", %{"vault_id" => id, "name" => name}, socket) do
    with {:ok, vault} <- own_vault(socket, id),
         {:ok, _} <- Vaults.update_vault(vault, %{"name" => name}) do
      {:noreply, load(socket)}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, "Vault name #{name_error(cs)}.")}

      _ ->
        {:noreply, put_flash(socket, :error, "That vault isn't there any more.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case own_vault(socket, id) do
      {:ok, vault} ->
        {:ok, _} = Vaults.delete_vault(vault)

        {:noreply,
         socket
         |> put_flash(:info, "Deleted #{vault.name}. Its pages are still on their boards.")
         |> load()}

      _ ->
        {:noreply, put_flash(socket, :error, "That vault isn't there any more.")}
    end
  end

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

  defp name_error(cs), do: cs.errors[:name] |> Kernel.||({"is invalid", []}) |> elem(0)

  @doc """
  What deleting a vault does, in words, for its confirmation: the pages stay,
  the layout goes, and the synced folders named stop getting changes.
  """
  def delete_confirm(vault, mirrors) do
    base =
      "Delete the vault “#{vault.name}”? Every page stays on its board; " <>
        "only the layout (its mappings) goes."

    case mirrors do
      [] ->
        base

      mirrors ->
        names = Enum.map_join(mirrors, ", ", &mirror_name/1)
        base <> " These synced folders will stop getting changes: #{names}."
    end
  end

  defp mirror_name(mirror), do: mirror.label || "an unnamed token"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:vaults}
    >
      <:nav><span class="font-semibold">Vaults</span></:nav>
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl space-y-6 px-4 py-6 sm:py-10 sm:px-6">
          <div>
            <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Vaults</h1>
            <p id="vaults-what" class="mt-1 text-sm text-base-content/60">
              A vault lays several boards' wikis out as one Obsidian-style tree of notes.
              It owns no pages: each page stays on its board, and the vault only says
              which board's wiki (or folder) appears at which path.
            </p>
          </div>

          <form id={"new-vault-#{@form_key}"} phx-submit="create" class="flex gap-2">
            <input
              type="text"
              name="name"
              placeholder="New vault name"
              class="input flex-1"
              autocomplete="off"
              maxlength={Slipdock.Vaults.Vault.name_length()}
              required
            />
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-plus" class="size-4" /> Make vault
            </button>
          </form>

          <div
            :if={@vaults == []}
            id="vaults-empty"
            class="rounded-2xl border border-dashed border-base-content/20 p-6 text-sm text-base-content/60"
          >
            <p class="font-medium text-base-content/80">You have no vaults yet.</p>
            <p class="mt-1">
              Make one, then map boards onto it — say KnowledgeBase at <code>/</code>
              and Job Hunt at <code>/Jobs</code>
              — and the wiki can show them as one tree, <code>[[links]]</code>
              find pages across them, and <code>slipdock sync</code>
              can keep the whole vault in a folder on your computer.
            </p>
          </div>

          <div
            :for={%{vault: vault, counts: counts, mirrors: mirrors} <- @vaults}
            id={"vault-#{vault.id}"}
            class="rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <div class="flex items-center gap-3">
              <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary">
                <.icon name="hero-rectangle-stack" class="size-5" />
              </span>
              <form phx-submit="rename" class="flex flex-1 gap-2">
                <input type="hidden" name="vault_id" value={vault.id} />
                <input
                  type="text"
                  name="name"
                  value={vault.name}
                  class="input input-sm flex-1 font-semibold"
                  aria-label="Vault name"
                  maxlength={Slipdock.Vaults.Vault.name_length()}
                />
                <button type="submit" class="btn btn-sm">Rename</button>
              </form>
              <button
                type="button"
                id={"delete-vault-#{vault.id}"}
                class="btn btn-ghost btn-sm text-error"
                phx-click="delete"
                phx-value-id={vault.id}
                data-confirm={delete_confirm(vault, mirrors)}
                title="Delete vault"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>

            <h2 class="mt-4 text-xs font-semibold uppercase tracking-wide text-base-content/50">
              Mappings
            </h2>
            <ul class="mt-1 space-y-1">
              <li
                :for={mapping <- vault.mappings}
                id={"mapping-#{mapping.id}"}
                class="flex items-center gap-2 rounded-lg px-2 py-1 text-sm hover:bg-base-200/60"
              >
                <code class="font-mono text-xs">{Mapping.display_path(mapping)}</code>
                <.icon name="hero-arrow-right" class="size-3.5 text-base-content/40" />
                <.link navigate={~p"/boards/#{mapping.board_id}/wiki"} class="link link-hover">
                  {mapping.board.name}
                </.link>
                <span :if={mapping.folder} class="text-base-content/60">
                  · folder {Slipdock.Wiki.folder_path(mapping.folder)}
                </span>
                <span class="ml-auto text-xs text-base-content/50">
                  {pages(Map.get(counts, mapping.id, 0))}
                </span>
              </li>
            </ul>
            <p :if={vault.mappings == []} class="mt-1 px-2 text-xs text-base-content/50">
              Nothing mapped yet, so the vault is empty.
            </p>

            <h2 class="mt-4 text-xs font-semibold uppercase tracking-wide text-base-content/50">
              Synced to
            </h2>
            <ul class="mt-1 space-y-1">
              <li
                :for={mirror <- mirrors}
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
            <p :if={mirrors == []} class="mt-1 px-2 text-xs text-base-content/50">
              Not synced to a folder yet: <code>slipdock sync init ~/Notes --vault {vault.name}</code>
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp pages(1), do: "1 page"
  defp pages(n), do: "#{n} pages"
end

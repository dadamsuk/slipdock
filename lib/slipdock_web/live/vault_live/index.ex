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
  def mount(params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Vaults",
        form_key: 0,
        drafts: %{},
        only: nil,
        google: Slipdock.Google.status(socket.assigns.current_user)
      )

    case params["vault"] do
      nil ->
        {:ok, load(socket)}

      # One vault's settings, reached from its view (#752).
      ref ->
        case Vaults.get_vault(socket.assigns.current_user, ref) do
          {:ok, vault} ->
            {:ok,
             socket |> assign(only: vault.id, page_title: "#{vault.name} · Settings") |> load()}

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

    vaults =
      user
      |> Vaults.list_vaults()
      |> Enum.filter(&(is_nil(socket.assigns.only) or &1.id == socket.assigns.only))
      |> Enum.map(fn vault ->
        %{
          vault: vault,
          counts: Vaults.page_counts(vault),
          mirrors: Vaults.mirrors(vault),
          overlaps: Vaults.overlaps(vault),
          candidates: Vaults.mapping_candidates(vault, user),
          # What taking each mapping out would do, for its confirmation.
          removals:
            Map.new(vault.mappings, fn m ->
              {:ok, preview} = Vaults.preview_unmapping(vault, m.id)
              {m.id, preview}
            end)
        }
      end)

    assign(socket, vaults: vaults)
  end

  @impl true
  # With "Make a board to hold its pages" ticked, the vault comes with a
  # board named after it, mapped at / and kept inside it (#757).
  def handle_event("create", %{"name" => name} = params, socket) do
    user = socket.assigns.current_user

    {result, made} =
      if params["with_board"] == "true",
        do:
          {Vaults.create_vault_with_board(user, %{"name" => name}),
           &"Made #{&1.name}, with a board of the same name holding its pages, kept inside it."},
        else:
          {Vaults.create_vault(user, %{"name" => name}),
           &"Made #{&1.name}. Map a board onto it to give it pages."}

    case result do
      {:ok, vault} ->
        {:noreply,
         socket
         |> update(:form_key, &(&1 + 1))
         |> put_flash(:info, made.(vault))
         |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, "Vault name #{name_error(cs)}.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, "That vault couldn't be made: #{inspect(message)}.")}
    end
  end

  # A board mapped whole kept inside the vault, or let out onto the home
  # page again (#757).
  def handle_event("toggle_inside", %{"vault_id" => id, "mapping_id" => mapping_id}, socket) do
    with {:ok, vault} <- own_vault(socket, id),
         {:ok, mapping} <- Vaults.find_mapping(vault, mapping_id),
         {:ok, mapping} <- Vaults.set_inside(vault, mapping.id, not mapping.inside) do
      message =
        if mapping.inside,
          do:
            "#{mapping.board.name} is kept inside #{vault.name}: it's on the vault's tile now, not among your boards.",
          else: "#{mapping.board.name} is back among your boards."

      {:noreply, socket |> put_flash(:info, message) |> load()}
    else
      {:error, _status, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, String.capitalize(message) <> ".")}

      _ ->
        {:noreply, put_flash(socket, :error, "That mapping isn't there any more.")}
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

  def handle_event("recordings_folder", %{"vault_id" => id, "folder" => folder}, socket) do
    with {:ok, vault} <- own_vault(socket, id),
         {:ok, vault} <- Vaults.set_recordings_folder(vault, folder) do
      message =
        if vault.recordings_folder,
          do:
            "#{vault.name} plays its recordings from #{vault.recordings_folder} on Google Drive.",
          else: "#{vault.name} has no recordings folder now."

      {:noreply, socket |> put_flash(:info, message) |> load()}
    else
      {:error, reason} when is_atom(reason) ->
        {:noreply, put_flash(socket, :error, folder_error(reason, folder))}

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

  # The map-a-path form: every change re-reads the folders of the board
  # picked and previews what the mapping would do, before anything is saved.
  def handle_event("draft_mapping", %{"vault_id" => id} = params, socket) do
    with {:ok, vault} <- own_vault(socket, id) do
      {:noreply, update(socket, :drafts, &Map.put(&1, vault.id, draft(socket, vault, params)))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("add_mapping", %{"vault_id" => id} = params, socket) do
    user = socket.assigns.current_user

    with {:ok, vault} <- own_vault(socket, id),
         {:ok, attrs} <- mapping_attrs(socket, params),
         {:ok, mapping} <- Vaults.add_mapping(vault, user, attrs) do
      {:noreply,
       socket
       |> update(:drafts, &Map.delete(&1, vault.id))
       |> put_flash(:info, "Mapped #{Mapping.display_path(mapping)} onto #{attrs.board.name}.")
       |> load()}
    else
      {:error, _status, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, "Not mapped: #{message}.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, "Not mapped: #{changeset_error(cs)}.")}

      _ ->
        {:noreply, put_flash(socket, :error, "That vault isn't there any more.")}
    end
  end

  def handle_event("remove_mapping", %{"vault_id" => id, "mapping_id" => mapping_id}, socket) do
    with {:ok, vault} <- own_vault(socket, id),
         {:ok, mapping} <- Vaults.remove_mapping(vault, mapping_id) do
      {:noreply,
       socket
       |> put_flash(:info, "Took #{Mapping.display_path(mapping)} out of #{vault.name}.")
       |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, "That mapping isn't there any more.")}
    end
  end

  # The form as it stands: what was typed and picked, the picked board's
  # folders, and the preview (or why it can't be mapped).
  defp draft(socket, vault, params) do
    base = %{
      path: params["path"] || "",
      board_id: SlipdockWeb.Params.id(params["board_id"]),
      folder_id: SlipdockWeb.Params.id(params["folder_id"]),
      folders: [],
      preview: nil,
      error: nil
    }

    case mapping_attrs(socket, params) do
      {:ok, attrs} ->
        folders = attrs.board |> Slipdock.Wiki.Folders.list() |> Slipdock.Wiki.Folders.outline()

        case Vaults.preview_mapping(vault, socket.assigns.current_user, attrs) do
          {:ok, preview} -> %{base | folders: folders, preview: preview}
          {:error, _, message} -> %{base | folders: folders, error: message}
        end

      {:error, :no_board} ->
        base

      {:error, _, message} ->
        %{base | error: message}
    end
  end

  # The board and folder the form names, looked up among the boards the
  # reader can see: one they can't is not found, never mapped.
  defp mapping_attrs(socket, params) do
    user = socket.assigns.current_user

    with id when is_integer(id) <-
           SlipdockWeb.Params.id(params["board_id"]) || {:error, :no_board},
         {:ok, board} <- Slipdock.Access.find_board(user, id) |> found("board"),
         {:ok, folder} <- folder(board, params["folder_id"]) do
      {:ok, %{path: params["path"], board: board, folder: folder}}
    end
  end

  defp found({:ok, _} = ok, _what), do: ok
  defp found(_, what), do: {:error, :not_found, "that #{what} isn't there"}

  defp folder(_board, id) when id in [nil, ""], do: {:ok, nil}

  defp folder(board, id) do
    case SlipdockWeb.Params.id(id) do
      nil -> {:ok, nil}
      id -> board |> Slipdock.Wiki.find_folder(id) |> found("folder")
    end
  end

  defp changeset_error(cs) do
    cs.errors |> Enum.map_join(", ", fn {_field, {message, _}} -> message end)
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

  defp folder_error(:not_connected, _),
    do: "Connect Google Drive on your account's Settings first."

  defp folder_error(:revoked, _),
    do:
      "Google no longer accepts your Drive connection. Connect it again on your account's Settings."

  defp folder_error(:invalid, _), do: "That isn't a folder path."
  defp folder_error(:not_found, folder), do: "There's no folder \"#{folder}\" in your My Drive."
  defp folder_error(_, _), do: "Google Drive couldn't be asked just now. Try again."

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

  @doc """
  What taking a mapping out does, in words, for its confirmation: which
  files leave the synced folders (the pages stay on their board), and which
  move to another path.
  """
  def remove_confirm(preview) do
    leaving =
      case preview.leaving.count do
        0 ->
          "No page leaves the vault"

        n ->
          "#{pages(n)} #{verb(n, "leaves", "leave")} the vault#{examples(preview.leaving.sample)}"
      end

    moving =
      case preview.moving.count do
        0 -> ""
        n -> " #{pages(n)} #{verb(n, "moves", "move")} to another path under an outer mapping."
      end

    synced =
      case {preview.leaving.count, preview.mirrors} do
        {0, _} -> ""
        {_, []} -> ""
        {_, names} -> " Their files go from the synced folders (#{Enum.join(names, ", ")})."
      end

    "Take #{preview.path} out of the vault? #{leaving}; the pages stay on their board." <>
      moving <> synced
  end

  defp verb(1, one, _many), do: one
  defp verb(_n, _one, many), do: many

  defp examples([]), do: ""
  defp examples(sample), do: " (" <> Enum.join(Enum.take(sample, 3), ", ") <> ", …)"

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
            <h1 :if={!@only} class="text-2xl font-bold tracking-tight sm:text-3xl">Vaults</h1>
            <h1 :if={@only} class="text-2xl font-bold tracking-tight sm:text-3xl">
              Vault settings
            </h1>
            <p id="vaults-what" class="mt-1 text-sm text-base-content/60">
              A vault lays several boards' wikis out as one Obsidian-style tree of notes.
              It owns no pages: each page stays on its board, and the vault only says
              which board's wiki (or folder) appears at which path.
            </p>
          </div>

          <form
            :if={!@only}
            id={"new-vault-#{@form_key}"}
            phx-submit="create"
            class="flex flex-wrap items-center gap-2"
          >
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
            <label class="flex cursor-pointer items-center gap-1.5 text-xs text-base-content/70">
              <input
                type="checkbox"
                name="with_board"
                value="true"
                class="checkbox checkbox-xs"
                title="Pages live on a board: this makes one named after the vault, maps it at / and keeps it inside the vault"
              /> Make a board to hold its pages
            </label>
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
            :for={
              %{
                vault: vault,
                counts: counts,
                mirrors: mirrors,
                candidates: candidates,
                removals: removals,
                overlaps: overlaps
              } <-
                @vaults
            }
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
              <.link
                id={"open-vault-#{vault.id}"}
                navigate={SlipdockWeb.VaultUrls.url(vault)}
                class="btn btn-ghost btn-sm"
                title="Open the vault: its tree and its pages at their vault paths"
              >
                <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open
              </.link>
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

            <.recordings_folder :if={@google != :not_configured} vault={vault} google={@google} />

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
                <button
                  :if={is_nil(mapping.folder_id)}
                  type="button"
                  id={"inside-mapping-#{mapping.id}"}
                  class={[
                    "btn btn-xs",
                    if(mapping.inside, do: "btn-primary btn-soft", else: "btn-ghost")
                  ]}
                  phx-click="toggle_inside"
                  phx-value-vault_id={vault.id}
                  phx-value-mapping_id={mapping.id}
                  aria-pressed={to_string(mapping.inside)}
                  title={
                    if mapping.inside,
                      do:
                        "Kept inside #{vault.name}: named on its tile, not among your boards. Click to put it back among your boards.",
                      else:
                        "Keep #{mapping.board.name} inside #{vault.name}: named on its tile rather than among your boards"
                  }
                >
                  <.icon name="hero-archive-box-arrow-down" class="size-3.5" />
                  {if mapping.inside, do: "Inside", else: "Keep inside"}
                </button>
                <button
                  type="button"
                  id={"remove-mapping-#{mapping.id}"}
                  class="btn btn-ghost btn-xs"
                  phx-click="remove_mapping"
                  phx-value-vault_id={vault.id}
                  phx-value-mapping_id={mapping.id}
                  data-confirm={remove_confirm(removals[mapping.id])}
                  title="Take this mapping out"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </li>
            </ul>
            <p :if={vault.mappings == []} class="mt-1 px-2 text-xs text-base-content/50">
              Nothing mapped yet, so the vault is empty.
            </p>

            <div
              :if={overlaps != []}
              id={"overlaps-#{vault.id}"}
              class="mt-2 rounded-lg bg-warning/10 px-3 py-2 text-xs text-base-content/80"
            >
              <p class="font-semibold">
                <.icon name="hero-exclamation-triangle" class="size-4 text-warning" />
                {pages(length(overlaps))} {verb(length(overlaps), "sits", "sit")} at paths another mapping owns
              </p>
              <p class="mt-1">
                Two boards claim the same paths, so a synced edit to one of these files would go to
                the inner mapping's board. Move the pages to that board, or take a mapping out.
              </p>
              <ul class="mt-1 ml-4 list-disc font-mono">
                <li :for={o <- Enum.take(overlaps, 5)}>
                  {o.path}
                  <span class="font-sans text-base-content/60">
                    — on {o.board}, under {o.under} ({o.owner})
                  </span>
                </li>
              </ul>
            </div>

            <.map_form
              vault={vault}
              candidates={candidates}
              draft={Map.get(@drafts, vault.id)}
            />

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

  attr :vault, :any, required: true
  attr :candidates, :list, required: true
  attr :draft, :map, default: nil

  # Map a vault path onto a board's wiki, or one folder of it, with a
  # preview of where things land before it is saved.
  defp map_form(assigns) do
    assigns =
      assign(
        assigns,
        :draft,
        assigns.draft ||
          %{path: "", board_id: nil, folder_id: nil, folders: [], preview: nil, error: nil}
      )

    ~H"""
    <form
      id={"map-form-#{@vault.id}"}
      phx-change="draft_mapping"
      phx-submit="add_mapping"
      class="mt-3 space-y-2 rounded-xl bg-base-200/50 p-3"
    >
      <input type="hidden" name="vault_id" value={@vault.id} />
      <p class="text-xs font-semibold text-base-content/70">
        Mount a board's wiki at a path
      </p>
      <div class="flex flex-wrap gap-2">
        <input
          type="text"
          name="path"
          value={@draft.path}
          placeholder="/ or /Jobs"
          class="input input-sm w-32 font-mono"
          aria-label="Vault path"
          autocomplete="off"
          phx-debounce="300"
        />
        <select name="board_id" class="select select-sm flex-1" aria-label="Board">
          <option value="">Board…</option>
          <option
            :for={{board, reason} <- @candidates}
            value={board.id}
            disabled={not is_nil(reason)}
            selected={@draft.board_id == board.id}
          >
            {board.name}{if reason, do: " — #{reason}"}
          </option>
        </select>
        <select
          :if={@draft.board_id}
          name="folder_id"
          class="select select-sm flex-1"
          aria-label="Folder"
        >
          <option value="">The whole wiki</option>
          <option
            :for={f <- @draft.folders}
            value={f.folder.id}
            selected={@draft.folder_id == f.folder.id}
          >
            {String.duplicate("  ", f.depth)}{f.path}
          </option>
        </select>
        <button type="submit" class="btn btn-sm btn-primary" disabled={is_nil(@draft.preview)}>
          Map
        </button>
      </div>
      <p :if={@draft.error} id={"map-error-#{@vault.id}"} class="text-xs text-error">
        {@draft.error}
      </p>
      <div :if={@draft.preview} id={"map-preview-#{@vault.id}"} class="text-xs text-base-content/70">
        <% p = @draft.preview %>
        <p>
          {p.path} would bring <strong>{pages(p.arriving.count)}</strong>
          into the vault<span :if={p.moving.count > 0}>, and take over <strong>{pages(p.moving.count)}</strong> already in it from an outer mapping</span>.
        </p>
        <ul :if={p.arriving.sample != []} class="ml-4 list-disc font-mono">
          <li :for={path <- p.arriving.sample}>{path}</li>
          <li
            :if={p.arriving.count > length(p.arriving.sample)}
            class="list-none text-base-content/50"
          >
            … {p.arriving.count - length(p.arriving.sample)} more
          </li>
        </ul>
        <ul :if={p.moving.sample != []} class="ml-4 list-disc font-mono">
          <li :for={m <- p.moving.sample}>
            {m.from}<span :if={m.from != m.to}> → {m.to}</span>
          </li>
        </ul>
        <p :if={p.mirrors != [] and p.arriving.count > 0}>
          The synced folders ({Enum.join(p.mirrors, ", ")}) will get these files.
        </p>
      </div>
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
        placeholder="e.g. Manuel2 Recordings"
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

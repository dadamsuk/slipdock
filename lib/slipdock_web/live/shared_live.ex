defmodule SlipdockWeb.SharedLive do
  @moduledoc """
  **Shared with me** (#817): the wiki pages and folders other people have
  shared with you, with nothing of the boards they are on.

  A share is of a page or a folder, not of its board, so this view never
  names the board, its cards or its other pages: the tree down the side is
  `Slipdock.Wiki.SharedTree`'s, a page is rendered with `shared: true` (a
  link to anything you can't open reads "a page you can't see"), and files
  and drawings open in their own views as ever. What a writer of the share
  can do here is what `Slipdock.Wiki.Sharing` lets them: edit and rename a
  page, and make pages, drawings and folders inside a shared folder.

  The editor keeps unsaved work as the wiki's does (#1534,
  `Slipdock.Wiki.Autosaves`), and takes pasted images. A writer here may not be
  able to read the board, so what they left unsaved is listed on this view's
  front page. The editor has no `[[` picker: that searches the whole board.

  It follows the shares live: a grant given or taken back
  (`Slipdock.Access.subscribe_shares/1`) redraws the tree, and the page
  being read goes away with a word if it is no longer shared.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Access, Boards, Wiki}
  alias Slipdock.Boards.{Attachment, Board}
  alias Slipdock.Wiki.{Autosaves, Drawings, Folder, Page, SharedTree}
  alias SlipdockWeb.BoardLive.Helpers
  alias SlipdockWeb.SharedComponents
  alias SlipdockWeb.Wiki.Renderer

  @autosave_after_ms Application.compile_env(:slipdock, :wiki_autosave_after_ms, 3000)
  @form_fields ~w(title body)

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    if connected?(socket), do: Access.subscribe_shares(user.id)

    {:ok,
     socket
     |> allow_upload(:page_image,
       accept: ~w(.png .jpg .jpeg .gif .webp image/png image/jpeg image/gif image/webp),
       max_entries: 5,
       max_file_size: Attachment.image_max_size(),
       auto_upload: true,
       progress: &handle_upload/3
     )
     |> assign(
       tree: SharedTree.for_user(user),
       page: nil,
       folder: nil,
       node: nil,
       can_write: false,
       html: "",
       form: nil,
       base_hash: nil,
       conflict: nil,
       # Auto-save (#1534): the row for what is open, the form waiting for the
       # timer, whether it has landed, and what the editor was restored from.
       autosave: nil,
       autosave_pending: nil,
       autosave_timer: false,
       autosaved?: false,
       restored_from: nil,
       unsaved: [],
       # "Also file in…" (#818): folders of the reader's own to file it in.
       also_targets: nil,
       page_title: "Shared with me"
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Before anything moves: what is waiting belongs to the page being left.
    socket = flush_autosave(socket)
    {:noreply, socket |> show(socket.assigns.live_action, params) |> assign_unsaved()}
  end

  defp show(socket, :index, _params),
    do: assign(socket, page: nil, folder: nil, node: nil, form: nil, page_title: "Shared with me")

  defp show(socket, action, %{"id" => id}) when action in [:page, :edit] do
    with %Page{} = page <- Wiki.get_page(id),
         level = Access.page_permission(socket.assigns.current_user, page),
         true <- is_nil(page.archived_at) and Wiki.visible?(page, level) do
      # A share changing under an open editor leaves what is being typed alone.
      open? = action == :edit and socket.assigns.form != nil and same_page?(socket, page)

      socket =
        assign(socket,
          page: page,
          folder: nil,
          node: nil,
          can_write: Access.can_write?(level),
          page_title: page.title
        )

      cond do
        action == :page ->
          assign(socket, form: nil, html: render_body(socket, page))

        socket.assigns.can_write and open? ->
          socket

        socket.assigns.can_write ->
          open_editor(socket, page)

        true ->
          socket
          |> put_flash(:error, "That was shared with you to read, not to change.")
          |> push_patch(to: ~p"/shared/pages/#{page.id}")
      end
    else
      _ -> gone(socket)
    end
  end

  defp show(socket, :folder, %{"id" => id}) do
    with %Folder{} = folder <- Wiki.get_folder(id),
         level = Access.folder_permission(socket.assigns.current_user, folder),
         true <- Access.can_read?(level),
         %{} = node <- find_node(socket.assigns.tree, folder.id) do
      assign(socket,
        folder: folder,
        node: node,
        page: nil,
        form: nil,
        can_write: Access.can_write?(level),
        page_title: folder.name
      )
    else
      _ -> gone(socket)
    end
  end

  defp same_page?(%{assigns: %{page: %Page{id: id}}}, %Page{id: id}), do: true
  defp same_page?(_socket, _page), do: false

  # What they typed and never saved comes back by itself, against the hash it
  # was typed on, so a change made since is still caught.
  defp open_editor(socket, page) do
    autosave = Autosaves.for_page(socket.assigns.current_user, page)
    kept = Map.take((autosave && autosave.attrs) || %{}, @form_fields)

    assign(socket,
      form: to_form(Map.merge(%{"title" => page.title, "body" => page.body}, kept), as: :page),
      base_hash: (autosave && autosave.base_hash) || page.content_hash,
      conflict: nil,
      autosave: autosave,
      autosave_pending: nil,
      autosaved?: false,
      restored_from: autosave && autosave.updated_at
    )
  end

  defp gone(socket) do
    socket
    |> put_flash(:error, "That isn't shared with you, or not any more.")
    |> push_navigate(to: ~p"/shared")
  end

  defp render_body(socket, page),
    do:
      Renderer.to_html(page.body || "", page: page, as: socket.assigns.current_user, shared: true)

  ## Auto-save ------------------------------------------------------------------
  #
  # As in the wiki's editor: the form comes to the server as it is typed, each
  # one is noted, and a timer writes the latest. See `Slipdock.Wiki.Autosaves`.

  defp queue_autosave(socket, params) do
    socket = assign(socket, autosave_pending: params)

    if socket.assigns.autosave_timer do
      socket
    else
      Process.send_after(self(), :autosave, @autosave_after_ms)
      assign(socket, autosave_timer: true)
    end
  end

  defp flush_autosave(%{assigns: %{autosave_pending: nil}} = socket), do: socket

  defp flush_autosave(socket) do
    %{autosave_pending: params, autosave: autosave, page: page} = socket.assigns
    socket = assign(socket, autosave_pending: nil)

    cond do
      not Autosaves.unchanged?(page, params) -> write_autosave(socket, params)
      # Back to what the page says: there is nothing left to keep.
      autosave -> clear_autosave(socket)
      true -> socket
    end
  end

  defp write_autosave(socket, params) do
    %{current_user: user, page: page, autosave: autosave, base_hash: base} = socket.assigns

    # Merged: the same row may hold what the wiki's editor keeps besides these.
    attrs = Map.merge((autosave && autosave.attrs) || %{}, params)

    case Autosaves.save(user, %Board{id: page.board_id}, page, autosave, attrs, base) do
      {:ok, saved} -> assign(socket, autosave: saved, autosaved?: true)
      {:error, _} -> socket
    end
  end

  defp clear_autosave(socket) do
    Autosaves.discard(socket.assigns.autosave)
    assign(socket, autosave: nil, autosave_pending: nil, autosaved?: false, restored_from: nil)
  end

  defp assign_unsaved(socket) do
    %{current_user: user, live_action: action} = socket.assigns
    assign(socket, unsaved: if(action == :index, do: Autosaves.shared_with(user), else: []))
  end

  ## Uploads ---------------------------------------------------------------------

  defp handle_upload(name, entry, socket) do
    cond do
      not entry.done? ->
        {:noreply, socket}

      socket.assigns.form && socket.assigns.can_write ->
        meta = %{
          filename: entry.client_name,
          content_type: entry.client_type,
          size: entry.client_size
        }

        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:ok, Wiki.add_attachment(socket.assigns.page, meta, path)}
          end)

        {:noreply, uploaded(socket, result)}

      true ->
        {:noreply,
         socket
         |> cancel_upload(name, entry.ref)
         |> Helpers.image_failed(name)
         |> put_flash(:error, "That was shared with you to read, not to change.")}
    end
  end

  defp uploaded(socket, {:ok, %Attachment{} = attachment}) do
    push_event(socket, "image_uploaded", %{
      upload: "page_image",
      markdown: "![#{attachment.filename}](#{Boards.attachment_url(attachment)})"
    })
  end

  defp uploaded(socket, _other) do
    socket
    |> put_flash(:error, "That image could not be stored.")
    |> Helpers.image_failed(:page_image)
  end

  ## Events ---------------------------------------------------------------------

  defp form_params(params) do
    params
    |> Map.take(@form_fields)
    |> Map.update("body", nil, &Helpers.strip_upload_placeholder/1)
  end

  @impl true
  def handle_event("validate", %{"page" => params}, socket) do
    if socket.assigns.form && socket.assigns.can_write do
      # An upload refused (too big, not an image) would otherwise sit in the
      # form with its error, and LiveView won't submit a form with one in it.
      socket = Helpers.drop_invalid_uploads(socket, :page_image)
      params = form_params(params)
      {:noreply, socket |> assign(form: to_form(params, as: :page)) |> queue_autosave(params)}
    else
      {:noreply, socket}
    end
  end

  # Cancel means it: what was typed goes, auto-save and all.
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> clear_autosave()
     |> push_patch(to: ~p"/shared/pages/#{socket.assigns.page.id}")}
  end

  # From the banner over a restored editor: start again from the page.
  def handle_event("discard_autosave", params, socket) when not is_map_key(params, "id") do
    {:noreply,
     socket
     |> clear_autosave()
     |> push_navigate(to: ~p"/shared/pages/#{socket.assigns.page.id}/edit")}
  end

  # From the list of unsaved work.
  def handle_event("discard_autosave", %{"id" => id}, socket) do
    socket.assigns.current_user
    |> Autosaves.shared_with()
    |> Enum.find(&(to_string(&1.id) == id))
    |> Autosaves.discard()

    {:noreply, assign_unsaved(socket)}
  end

  def handle_event("dismiss_conflict", _params, socket),
    do: {:noreply, assign(socket, conflict: nil)}

  def handle_event("save", %{"page" => params}, socket) do
    %{page: page, current_user: user, base_hash: base} = socket.assigns
    params = form_params(params)

    with true <- socket.assigns.can_write,
         {:ok, page} <-
           Wiki.update_page(page, params, user: user, via: "web", base_hash: base) do
      {:noreply,
       socket
       |> clear_autosave()
       |> assign(tree: SharedTree.for_user(user))
       |> put_flash(:info, "Saved.")
       |> push_patch(to: ~p"/shared/pages/#{page.id}")}
    else
      {:error, :conflict, current} ->
        # Re-based on the version now shown, so saving after merging is a save.
        # Copying the text and reopening can't do it: the auto-save comes back.
        {:noreply,
         socket
         |> put_flash(:error, "Somebody changed it while you were writing.")
         |> assign(
           form: to_form(params, as: :page),
           conflict: current,
           base_hash: current.content_hash
         )}

      error ->
        {:noreply, put_flash(socket, :error, refusal(error))}
    end
  end

  def handle_event("new_page", %{"title" => title}, socket) do
    with %Folder{} = folder <- socket.assigns.folder,
         {:ok, page} <-
           Wiki.create_page(board_of(folder), %{"title" => title, "folder_id" => folder.id},
             user: socket.assigns.current_user,
             via: "web"
           ) do
      {:noreply,
       socket
       |> assign(tree: SharedTree.for_user(socket.assigns.current_user))
       |> push_patch(to: ~p"/shared/pages/#{page.id}/edit")}
    else
      error -> {:noreply, put_flash(socket, :error, refusal(error))}
    end
  end

  def handle_event("new_folder", %{"name" => name}, socket) do
    with %Folder{} = folder <- socket.assigns.folder,
         {:ok, made} <-
           Wiki.create_folder(board_of(folder), %{"name" => name, "parent_id" => folder.id},
             user: socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> assign(tree: SharedTree.for_user(socket.assigns.current_user))
       |> push_patch(to: ~p"/shared/folders/#{made.id}")}
    else
      error -> {:noreply, put_flash(socket, :error, refusal(error))}
    end
  end

  def handle_event("new_drawing", _params, socket) do
    with %Folder{} = folder <- socket.assigns.folder,
         {:ok, page} <-
           Drawings.create(board_of(folder), folder,
             user: socket.assigns.current_user,
             via: "web"
           ) do
      {:noreply, push_navigate(socket, to: ~p"/drawings/page/#{page.id}")}
    else
      error -> {:noreply, put_flash(socket, :error, refusal(error))}
    end
  end

  def handle_event("also_open", _params, socket),
    do: {:noreply, assign(socket, also_targets: also_targets(socket))}

  def handle_event("also_close", _params, socket),
    do: {:noreply, assign(socket, also_targets: nil)}

  def handle_event("also_file", %{"folder" => ref}, socket) do
    user = socket.assigns.current_user

    with %Folder{} = target <- Wiki.get_folder(ref),
         item when not is_nil(item) <- socket.assigns.page || socket.assigns.folder,
         {:ok, _} <- also_file(item, target, user) do
      {:noreply,
       socket
       |> assign(also_targets: nil)
       |> put_flash(:info, "Also filed in #{Wiki.folder_path(target)}.")}
    else
      {:error, _status, message} -> {:noreply, put_flash(socket, :error, message)}
      _ -> {:noreply, put_flash(socket, :error, "Couldn't file it there.")}
    end
  end

  defp also_file(%Page{} = page, target, user), do: Wiki.Placements.add(page, target, user)

  defp also_file(%Folder{} = folder, target, user),
    do: Wiki.FolderPlacements.add(folder, target, user)

  # Folders on boards the reader writes to, other than the owner's: where a
  # share of somebody else's can be filed (#818). With the board's name —
  # these are the reader's own boards.
  defp also_targets(socket) do
    %{current_user: user} = socket.assigns
    item = socket.assigns.page || socket.assigns.folder

    user
    |> Access.list_boards()
    |> Enum.filter(&Access.can_write?(Access.board_permission(user, &1)))
    |> Enum.filter(&Slipdock.Wiki.SharedPlacements.cross_owner?(&1.id, item.board_id))
    |> Enum.flat_map(fn board ->
      board |> Wiki.folders() |> Enum.map(&{"#{board.name} · #{Wiki.folder_path(&1)}", &1.id})
    end)
  end

  defp board_of(%Folder{board_id: id}), do: Boards.get_board!(id)

  defp refusal({:error, :shared, _code, message}), do: message

  defp refusal({:error, %Ecto.Changeset{} = cs}) do
    case SlipdockWeb.API.JSON.errors(cs) do
      %{base: [message | _]} -> message
      _ -> "Couldn't save that."
    end
  end

  defp refusal(_), do: "You can't do that here."

  ## Live -----------------------------------------------------------------------

  @impl true
  def handle_info(:autosave, socket) do
    {:noreply, socket |> assign(autosave_timer: false) |> flush_autosave()}
  end

  def handle_info({:put_flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  def handle_info({:shares_changed}, socket) do
    socket =
      socket
      |> flush_autosave()
      |> assign(tree: SharedTree.for_user(socket.assigns.current_user))

    # What is open may have been the share that went.
    {:noreply,
     socket |> show(socket.assigns.live_action, current_params(socket)) |> assign_unsaved()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp current_params(%{assigns: %{page: %Page{id: id}}}), do: %{"id" => to_string(id)}
  defp current_params(%{assigns: %{folder: %Folder{id: id}}}), do: %{"id" => to_string(id)}
  defp current_params(_socket), do: %{}

  defp find_node(groups, folder_id) do
    groups
    |> Enum.flat_map(& &1.items)
    |> Enum.find_value(&find_in(&1, folder_id))
  end

  defp find_in(%{kind: :folder, folder: %{id: id}} = node, id), do: node
  defp find_in(%{kind: :folder, folders: inner}, id), do: Enum.find_value(inner, &find_in(&1, id))
  defp find_in(_node, _id), do: nil

  ## Rendering ------------------------------------------------------------------

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
      nav_active={:wiki}
      page_jumps={@page_jumps}
    >
      <div id="shared-view" class="flex h-full min-h-0">
        <aside class="hidden w-72 shrink-0 overflow-y-auto border-r border-base-300 p-3 md:block">
          <SharedComponents.shared_tree groups={@tree} current={current_key(assigns)} />
          <p :if={@tree == []} id="shared-empty" class="px-2 text-sm text-base-content/60">
            Nothing has been shared with you yet.
          </p>
        </aside>
        <main class="min-w-0 flex-1 overflow-y-auto p-6">
          <.index :if={@live_action == :index} tree={@tree} unsaved={@unsaved} />
          <.page_view
            :if={@live_action == :page and @page}
            page={@page}
            html={@html}
            can_write={@can_write}
            also_targets={@also_targets}
          />
          <.page_edit
            :if={@live_action == :edit and @form}
            page={@page}
            form={@form}
            uploads={@uploads}
            conflict={@conflict}
            autosaved?={@autosaved?}
            restored_from={@restored_from}
          />
          <.folder_view
            :if={@live_action == :folder and @node}
            node={@node}
            can_write={@can_write}
            also_targets={@also_targets}
          />
        </main>
      </div>
    </Layouts.app>
    """
  end

  defp current_key(%{page: %Page{id: id}}), do: "page:#{id}"
  defp current_key(%{folder: %Folder{id: id}}), do: "folder:#{id}"
  defp current_key(_), do: nil

  attr :tree, :list, required: true
  attr :unsaved, :list, required: true

  defp index(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl space-y-4">
      <h1 class="text-2xl font-bold tracking-tight">Shared with me</h1>
      <p class="text-base-content/60">
        Pages and folders other people have shared with you. You see what they shared and nothing
        else of where it is kept.
      </p>
      <section
        :if={@unsaved != []}
        id="unsaved-pages"
        class="rounded-xl border border-base-300 bg-base-200/40 px-4 py-3 text-sm"
      >
        <h2 class="font-medium">Unsaved work</h2>
        <p class="text-xs text-base-content/60">
          Only you can see this. It is kept for {Autosaves.ttl_days()} days.
        </p>
        <ul class="mt-2 space-y-1">
          <li :for={autosave <- @unsaved} class="flex items-center justify-between gap-2">
            <.link
              navigate={~p"/shared/pages/#{autosave.page.id}/edit"}
              class="link min-w-0 truncate"
            >
              Editing {autosave.page.title}
            </.link>
            <span class="flex shrink-0 items-center gap-2 text-xs text-base-content/50">
              {SlipdockWeb.SlipdockComponents.relative_time(autosave.updated_at)}
              <button
                type="button"
                phx-click="discard_autosave"
                phx-value-id={autosave.id}
                class="btn btn-ghost btn-xs"
              >
                Discard
              </button>
            </span>
          </li>
        </ul>
      </section>
      <div class="md:hidden">
        <SharedComponents.shared_tree groups={@tree} id="shared-tree-mobile" />
      </div>
    </div>
    """
  end

  attr :page, :any, required: true
  attr :html, :string, required: true
  attr :can_write, :boolean, required: true
  attr :also_targets, :any, default: nil

  defp page_view(assigns) do
    ~H"""
    <article id="shared-page" class="mx-auto max-w-3xl">
      <div class="flex items-start justify-between gap-3">
        <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">{@page.title}</h1>
        <div class="flex shrink-0 items-center gap-1">
          <.link
            :if={Slipdock.Wiki.Excalidraw.page?(@page)}
            navigate={~p"/drawings/page/#{@page.id}"}
            class="btn btn-primary btn-sm"
          >
            {if @can_write, do: "Edit drawing", else: "Open drawing"}
          </.link>
          <.link
            :if={@can_write}
            id="shared-edit"
            patch={~p"/shared/pages/#{@page.id}/edit"}
            class="btn btn-sm gap-1.5"
          >
            <.icon name="hero-pencil-square" class="size-4" /> Edit
          </.link>
          <button
            id="shared-also"
            type="button"
            phx-click="also_open"
            class="btn btn-ghost btn-sm gap-1.5"
          >
            <.icon name="hero-link" class="size-4" /> Also file in…
          </button>
        </div>
      </div>
      <.also_form targets={@also_targets} />
      <p :if={@page.summary} class="mt-1 text-base-content/60">{@page.summary}</p>
      <p class="mt-2 text-xs text-base-content/50">
        {if @can_write, do: "Shared with you to edit.", else: "Shared with you to read."}
      </p>
      <div class="wiki-prose mt-6">{Phoenix.HTML.raw(@html)}</div>
    </article>
    """
  end

  attr :page, :any, required: true
  attr :form, :any, required: true
  attr :uploads, :any, required: true
  attr :conflict, :any, default: nil
  attr :autosaved?, :boolean, default: false
  attr :restored_from, :any, default: nil

  defp page_edit(assigns) do
    ~H"""
    <.form
      for={@form}
      id="shared-edit-form"
      phx-change="validate"
      phx-submit="save"
      class="mx-auto max-w-3xl space-y-4"
    >
      <div
        :if={@restored_from}
        id="autosave-restored"
        class="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-sky-500/40 bg-sky-500/10 px-4 py-2 text-sm"
      >
        <span>
          Restored your unsaved work from {SlipdockWeb.SlipdockComponents.relative_time(
            @restored_from
          )}.
        </span>
        <button type="button" phx-click="discard_autosave" class="btn btn-ghost btn-xs">
          Discard it
        </button>
      </div>
      <div
        :if={@conflict}
        id="shared-conflict"
        class="rounded-xl border border-rose-500/40 bg-rose-500/10 p-4 text-sm"
      >
        <div class="flex items-start gap-3">
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-rose-600" />
          <div class="min-w-0 flex-1">
            <p class="font-medium">
              This page changed while you were writing. Nothing has been overwritten.
            </p>
            <p class="mt-1 text-base-content/70">
              Below is the page as it now stands. Merge what you need into your text, then save
              again.
            </p>
            <pre
              class="kanban-scroll mt-3 max-h-64 overflow-auto rounded-lg bg-base-100 p-3 text-xs"
              phx-no-curly-interpolation
            ><%= @conflict.body %></pre>
          </div>
          <button type="button" phx-click="dismiss_conflict" class="btn btn-ghost btn-xs btn-square">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </div>
      <.input field={@form[:title]} label="Title" />
      <div id="shared-body-paste" phx-hook="PasteImage" data-upload="page_image">
        <label for="page_body" class="mb-1 block text-sm font-medium">
          Text
          <span class="ml-1 font-normal text-base-content/50">— paste or drop an image to attach it</span>
        </label>
        <div
          id={"shared-body-editor-#{@page.id}"}
          phx-hook="MarkdownEditor"
          phx-update="ignore"
          data-editor-class="md-editor-page"
        >
          <textarea
            id="page_body"
            name="page[body]"
            rows="20"
            class="textarea w-full font-mono"
            phx-debounce="200"
          ><%= Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value) %></textarea>
        </div>
        <.live_file_input upload={@uploads.page_image} class="hidden" />
      </div>
      <div class="flex items-center gap-2">
        <button type="submit" class="btn btn-primary btn-sm">Save</button>
        <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">Cancel</button>
        <span
          :if={@autosaved?}
          id="autosave-status"
          role="status"
          class="text-xs text-base-content/50"
        >
          Auto-saved
        </span>
      </div>
    </.form>
    """
  end

  attr :targets, :any, required: true

  # Where to also file it: a folder of one of the reader's own boards. The
  # placement shows only to people who can read what was shared.
  defp also_form(assigns) do
    ~H"""
    <form
      :if={@targets}
      id="shared-also-form"
      phx-submit="also_file"
      class="mt-3 flex flex-wrap items-center gap-2 rounded-xl border border-base-300 p-3 text-sm"
    >
      <span :if={@targets == []} class="text-base-content/60">
        You have no folders of your own to file it in yet.
      </span>
      <select :if={@targets != []} name="folder" class="select select-sm">
        <option :for={{label, id} <- @targets} value={id}>{label}</option>
      </select>
      <button :if={@targets != []} type="submit" class="btn btn-sm btn-primary">File it there</button>
      <button type="button" phx-click="also_close" class="btn btn-ghost btn-sm">Cancel</button>
    </form>
    """
  end

  attr :node, :map, required: true
  attr :can_write, :boolean, required: true
  attr :also_targets, :any, default: nil

  defp folder_view(assigns) do
    ~H"""
    <div id="shared-folder" class="mx-auto max-w-3xl space-y-4">
      <div class="flex items-center justify-between gap-3">
        <h1 class="flex items-center gap-2 text-2xl font-bold tracking-tight">
          <.icon name="hero-folder" class="size-6" /> {@node.folder.name}
        </h1>
        <button
          id="shared-also"
          type="button"
          phx-click="also_open"
          class="btn btn-ghost btn-sm gap-1.5"
        >
          <.icon name="hero-link" class="size-4" /> Also file in…
        </button>
      </div>
      <.also_form targets={@also_targets} />
      <ul class="space-y-1">
        <li :for={inner <- @node.folders}>
          <.link
            navigate={~p"/shared/folders/#{inner.folder.id}"}
            class="link flex items-center gap-1.5"
          >
            <.icon name="hero-folder" class="size-4" /> {inner.folder.name}
          </.link>
        </li>
        <li :for={page <- @node.pages}>
          <.link navigate={~p"/shared/pages/#{page.id}"} class="link flex items-center gap-1.5">
            <.icon name="hero-document-text" class="size-4" /> {page.title}
          </.link>
        </li>
        <li :for={file <- @node.files}>
          <.link navigate={Slipdock.Wiki.Files.open_path(file)} class="link flex items-center gap-1.5">
            <.icon name="hero-paper-clip" class="size-4" /> {file.name}
          </.link>
        </li>
      </ul>
      <p
        :if={@node.folders == [] and @node.pages == [] and @node.files == []}
        class="text-sm text-base-content/60"
      >
        Nothing in it yet.
      </p>
      <div :if={@can_write} class="flex flex-wrap items-end gap-3 border-t border-base-300 pt-4">
        <form id="shared-new-page" phx-submit="new_page" class="flex items-center gap-1.5">
          <input name="title" required placeholder="New page title" class="input input-sm" />
          <button type="submit" class="btn btn-sm">New page</button>
        </form>
        <form id="shared-new-folder" phx-submit="new_folder" class="flex items-center gap-1.5">
          <input name="name" required placeholder="New folder name" class="input input-sm" />
          <button type="submit" class="btn btn-sm">New folder</button>
        </form>
        <button id="shared-new-drawing" type="button" phx-click="new_drawing" class="btn btn-sm">
          New drawing
        </button>
      </div>
    </div>
    """
  end
end

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

  It follows the shares live: a grant given or taken back
  (`Slipdock.Access.subscribe_shares/1`) redraws the tree, and the page
  being read goes away with a word if it is no longer shared.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Access, Boards, Wiki}
  alias Slipdock.Wiki.{Drawings, Folder, Page, SharedTree}
  alias SlipdockWeb.SharedComponents
  alias SlipdockWeb.Wiki.Renderer

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    if connected?(socket), do: Access.subscribe_shares(user.id)

    {:ok,
     assign(socket,
       tree: SharedTree.for_user(user),
       page: nil,
       folder: nil,
       node: nil,
       can_write: false,
       html: "",
       form: nil,
       base_hash: nil,
       page_title: "Shared with me"
     )}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, show(socket, socket.assigns.live_action, params)}

  defp show(socket, :index, _params),
    do: assign(socket, page: nil, folder: nil, node: nil, form: nil, page_title: "Shared with me")

  defp show(socket, action, %{"id" => id}) when action in [:page, :edit] do
    with %Page{} = page <- Wiki.get_page(id),
         level = Access.page_permission(socket.assigns.current_user, page),
         true <- is_nil(page.archived_at) and Wiki.visible?(page, level) do
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

        socket.assigns.can_write ->
          assign(socket,
            form: to_form(%{"title" => page.title, "body" => page.body}, as: :page),
            base_hash: page.content_hash
          )

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

  defp gone(socket) do
    socket
    |> put_flash(:error, "That isn't shared with you, or not any more.")
    |> push_navigate(to: ~p"/shared")
  end

  defp render_body(socket, page),
    do:
      Renderer.to_html(page.body || "", page: page, as: socket.assigns.current_user, shared: true)

  ## Events ---------------------------------------------------------------------

  @impl true
  def handle_event("save", %{"page" => params}, socket) do
    %{page: page, current_user: user, base_hash: base} = socket.assigns

    with true <- socket.assigns.can_write,
         {:ok, page} <-
           Wiki.update_page(page, Map.take(params, ["title", "body"]),
             user: user,
             via: "web",
             base_hash: base
           ) do
      {:noreply,
       socket
       |> assign(tree: SharedTree.for_user(user))
       |> put_flash(:info, "Saved.")
       |> push_patch(to: ~p"/shared/pages/#{page.id}")}
    else
      {:error, :conflict, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Somebody changed it while you were writing. Copy your text, then open it again."
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
  def handle_info({:shares_changed}, socket) do
    socket = assign(socket, tree: SharedTree.for_user(socket.assigns.current_user))

    # What is open may have been the share that went.
    {:noreply, show(socket, socket.assigns.live_action, current_params(socket))}
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
          <.index :if={@live_action == :index} tree={@tree} />
          <.page_view
            :if={@live_action == :page and @page}
            page={@page}
            html={@html}
            can_write={@can_write}
          />
          <.page_edit :if={@live_action == :edit and @form} page={@page} form={@form} />
          <.folder_view :if={@live_action == :folder and @node} node={@node} can_write={@can_write} />
        </main>
      </div>
    </Layouts.app>
    """
  end

  defp current_key(%{page: %Page{id: id}}), do: "page:#{id}"
  defp current_key(%{folder: %Folder{id: id}}), do: "folder:#{id}"
  defp current_key(_), do: nil

  attr :tree, :list, required: true

  defp index(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl space-y-4">
      <h1 class="text-2xl font-bold tracking-tight">Shared with me</h1>
      <p class="text-base-content/60">
        Pages and folders other people have shared with you. You see what they shared and nothing
        else of where it is kept.
      </p>
      <div class="md:hidden">
        <SharedComponents.shared_tree groups={@tree} id="shared-tree-mobile" />
      </div>
    </div>
    """
  end

  attr :page, :any, required: true
  attr :html, :string, required: true
  attr :can_write, :boolean, required: true

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
        </div>
      </div>
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

  defp page_edit(assigns) do
    ~H"""
    <.form for={@form} id="shared-edit-form" phx-submit="save" class="mx-auto max-w-3xl space-y-4">
      <.input field={@form[:title]} label="Title" />
      <.input
        field={@form[:body]}
        type="textarea"
        label="Text"
        rows="20"
        class="textarea w-full font-mono"
      />
      <div class="flex gap-2">
        <button type="submit" class="btn btn-primary btn-sm">Save</button>
        <.link patch={~p"/shared/pages/#{@page.id}"} class="btn btn-ghost btn-sm">Cancel</.link>
      </div>
    </.form>
    """
  end

  attr :node, :map, required: true
  attr :can_write, :boolean, required: true

  defp folder_view(assigns) do
    ~H"""
    <div id="shared-folder" class="mx-auto max-w-3xl space-y-4">
      <h1 class="flex items-center gap-2 text-2xl font-bold tracking-tight">
        <.icon name="hero-folder" class="size-6" /> {@node.folder.name}
      </h1>
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

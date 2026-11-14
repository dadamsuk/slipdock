defmodule SlipdockWeb.WikiLive.Modals do
  @moduledoc """
  The wiki view's dialogs (`WikiLive.Index`): sharing, a folder's
  name and icon, deleting a folder, and the file shown beside the page.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.FolderPicker

  import SlipdockWeb.SlipdockComponents,
    only: [modal: 1]

  import SlipdockWeb.WikiLive.Format
  alias Slipdock.Palette
  alias Slipdock.Wiki.{Folder, Icons, Page}

  attr :modal, :map, required: true

  # Who a page (or folder) is shared with, and a form to share it with
  # somebody else: the board views' own panel, aimed at this view.
  def share_modal(assigns) do
    ~H"""
    <.modal id="share-modal" on_close={JS.push("close_share")} size="md">
      <div class="space-y-4 p-6">
        <h2 class="section-title">Share “{share_title(@modal.item)}”</h2>
        <p class="text-sm text-base-content/60">
          {share_help(@modal.kind)}
        </p>
        <SlipdockWeb.ShareComponents.share_panel
          resource={@modal.kind}
          grants={@modal.grants}
          groups={@modal.groups}
          can_manage={true}
          form_key={@modal.key}
        />
      </div>
    </.modal>
    """
  end

  defp share_title(%Page{title: title}), do: title
  defp share_title(%Folder{name: name}), do: name

  defp share_help("page"),
    do:
      "People you share this page with see it under Shared with me. " <>
        "They don't see the board, its cards or its other pages, and they can't pass it on."

  defp share_help("folder"),
    do:
      "Sharing a folder shares everything in it, subfolders and all. " <>
        "People you share it with don't see the rest of the board, and they can't pass it on."

  attr :modal, :map, required: true
  attr :outline, :list, required: true

  @doc false
  # One dialog for both making and renaming a folder: the two differ only in
  # whether there is a folder to start from, and a rename that can also move
  # is one form rather than two.
  def folder_modal(assigns) do
    ~H"""
    <.modal id="folder-modal" on_close={JS.push("close_folder_modal")} size="sm">
      <div class="space-y-5 p-6">
        <h2 class="section-title">
          {if @modal.folder, do: "Edit folder", else: "New folder"}
        </h2>
        <form id="folder-form" phx-submit="save_folder" class="space-y-4">
          <label class="block space-y-1.5">
            <span class="text-sm font-medium">Name</span>
            <input
              type="text"
              name="name"
              value={@modal.name}
              autofocus
              required
              maxlength={Slipdock.Wiki.Folder.name_length()}
              placeholder="Design decisions"
              class="input field w-full"
            />
            <span :if={is_nil(@modal.folder)} class="block text-xs text-base-content/50">
              A name with slashes makes the whole path: “Design/Decisions” makes both.
            </span>
          </label>
          <%!-- A tree you type at rather than a flat select: see
                `SlipdockWeb.FolderPicker`. The folder being moved and anything
                inside it are shown greyed, because "you cannot file it in
                itself" is worth saying rather than hiding. --%>
          <.folder_picker
            id="folder-parent-picker"
            label="Inside"
            name="parent_id"
            outline={@outline}
            selected={
              (@modal.folder && @modal.folder.parent_id) || (@modal.parent && @modal.parent.id)
            }
            exclude={@modal.folder && @modal.folder.id}
          />
          <.dress_picker
            id="folder-dress"
            kind={:folder}
            icon_name="icon"
            color_name="color"
            icon={@modal.folder && @modal.folder.icon}
            color={@modal.folder && @modal.folder.color}
          />
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="close_folder_modal" class="btn btn-ghost btn-sm">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary btn-sm">
              {if @modal.folder, do: "Save", else: "Make folder"}
            </button>
          </div>
        </form>
      </div>
    </.modal>
    """
  end

  attr :shown, :map, required: true

  # A file in the page's place (#768, #773): on a wide screen the whole of
  # the wiki beside the tree, on a phone over it. Escape or the X puts it
  # away and the page comes back; the arrow opens it on a page of its own,
  # which is also where a new tab goes.
  def file_panel(assigns) do
    ~H"""
    <aside
      id="wiki-file-panel"
      data-kind={@shown.kind}
      aria-label={@shown.file.name}
      phx-window-keydown="close_file"
      phx-key="Escape"
      class="fixed inset-0 z-40 flex min-h-0 flex-col bg-base-100 lg:static lg:z-auto lg:min-w-0 lg:flex-1"
    >
      <div class="flex items-center gap-2 border-b border-base-300 px-3 py-2">
        <.icon name="hero-paper-clip" class="size-4 shrink-0 text-base-content/50" />
        <h2 class="min-w-0 flex-1 truncate text-sm font-semibold" title={@shown.file.name}>
          {@shown.file.name}
        </h2>
        <span id="wiki-file-size" class="text-xs text-base-content/60">
          {file_size(@shown.file.size)}
        </span>
        <a
          href={Slipdock.Wiki.Files.url(@shown.file)}
          class="btn btn-ghost btn-sm btn-square"
          id="wiki-file-download"
          title="Download"
          download
        >
          <.icon name="hero-arrow-down-tray" class="size-4" />
        </a>
        <a
          href={~p"/files/#{@shown.file.id}"}
          class="btn btn-ghost btn-sm btn-square"
          id="wiki-file-full"
          data-own-page
          title="Open on a page of its own"
        >
          <.icon name="hero-arrows-pointing-out" class="size-4" />
        </a>
        <button
          type="button"
          id="wiki-file-close"
          phx-click="close_file"
          class="btn btn-ghost btn-sm btn-square"
          title="Close (Esc)"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
      <div class="kanban-scroll min-h-0 flex-1 overflow-auto p-4">
        <SlipdockWeb.FileViewer.viewer
          kind={@shown.kind}
          file={@shown.file}
          {Map.take(@shown, [:tree, :text, :table, :transcript, :problem])}
        />
      </div>
    </aside>
    """
  end

  attr :folder, :map, required: true
  attr :owner, :boolean, default: false, doc: "the board's owner, who alone may purge (#733)"

  @doc false
  # Deleting a folder that has something in it: the two answers are offered
  # side by side with what each one costs, because "delete" on a folder is
  # ambiguous in a way "delete" on a page is not.
  def folder_delete_modal(assigns) do
    ~H"""
    <.modal id="folder-delete-modal" on_close={JS.push("close_folder_delete")} size="sm">
      <div class="space-y-5 p-6">
        <div class="space-y-1">
          <h2 class="section-title">Delete “{@folder.folder.name}”?</h2>
          <p class="text-sm text-base-content/60">
            {@folder.path} holds {count(@folder.counts.pages, "page")}<span :if={
              @folder.counts.folders > 0
            }>
              in {count(@folder.counts.folders, "folder")}</span>.
          </p>
        </div>

        <div class="space-y-2">
          <button
            type="button"
            phx-click="delete_folder"
            phx-value-how="keep"
            class="w-full rounded-xl border border-base-300 p-3 text-left hover:border-primary hover:bg-base-200"
          >
            <span class="flex items-center gap-2 text-sm font-medium">
              <.icon name="hero-folder-minus" class="size-4" /> Delete the folder only
            </span>
            <span class="mt-1 block text-xs text-base-content/60">
              Its pages go back to the top of the wiki and any folders inside it move up. Nothing
              written is lost.
            </span>
          </button>
          <button
            :if={@owner}
            type="button"
            phx-click="delete_folder"
            phx-value-how="purge"
            class="w-full rounded-xl border border-error/40 p-3 text-left hover:bg-error/10"
          >
            <span class="flex items-center gap-2 text-sm font-medium text-error">
              <.icon name="hero-trash" class="size-4" /> Delete the folder and everything in it
            </span>
            <span class="mt-1 block text-xs text-base-content/60">
              {count(@folder.counts.pages, "page")} deleted for good, history and all — this
              cannot be undone. Pages filed elsewhere that are children of these are left
              behind.
            </span>
          </button>
          <p :if={!@owner} id="folder-purge-owner-only" class="text-xs text-base-content/60">
            Only the board's owner can delete the folder and everything in it.
          </p>
        </div>

        <div class="flex justify-end">
          <button type="button" phx-click="close_folder_delete" class="btn btn-ghost btn-sm">
            Cancel
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  attr :id, :string, required: true
  attr :kind, :atom, required: true, values: [:folder, :page]
  attr :icon_name, :string, required: true, doc: "the form field the icon goes in"
  attr :color_name, :string, required: true, doc: "the form field the colour goes in"
  attr :icon, :string, default: nil
  attr :color, :string, default: nil

  # Choosing what a folder or page wears (#792): an icon from the set and a
  # colour from the palette, each with a None. Radios, so the form sends the
  # choice like any other field and the dialog needs no state of its own.
  def dress_picker(assigns) do
    ~H"""
    <fieldset id={@id} class="space-y-3">
      <legend class="text-sm font-medium">Icon and colour</legend>
      <div class="flex flex-wrap gap-1" role="radiogroup" aria-label="Icon">
        <label
          class="btn btn-ghost btn-xs btn-square has-[:checked]:bg-primary/15 has-[:checked]:ring-1 has-[:checked]:ring-primary"
          title="The plain icon"
        >
          <input type="radio" name={@icon_name} value="" checked={is_nil(@icon)} class="sr-only" />
          <.wiki_icon kind={@kind} class="size-4" />
        </label>
        <label
          :for={name <- Icons.names()}
          class="btn btn-ghost btn-xs btn-square has-[:checked]:bg-primary/15 has-[:checked]:ring-1 has-[:checked]:ring-primary"
          title={String.replace(name, "-", " ")}
        >
          <input
            type="radio"
            name={@icon_name}
            value={name}
            checked={@icon == name}
            class="sr-only"
          />
          <.wiki_icon kind={@kind} icon={name} color={@color} class="size-4" />
        </label>
      </div>
      <div class="flex flex-wrap items-center gap-1.5" role="radiogroup" aria-label="Colour">
        <label
          class="flex size-6 cursor-pointer items-center justify-center rounded-full ring-1 ring-base-300 has-[:checked]:ring-2 has-[:checked]:ring-primary"
          title="No colour"
        >
          <input type="radio" name={@color_name} value="" checked={is_nil(@color)} class="sr-only" />
          <.icon name="hero-no-symbol" class="size-4 text-base-content/40" />
        </label>
        <label
          :for={{name, label} <- Palette.all()}
          class="flex size-6 cursor-pointer items-center justify-center rounded-full has-[:checked]:ring-2 has-[:checked]:ring-primary has-[:checked]:ring-offset-1"
          title={label}
        >
          <input
            type="radio"
            name={@color_name}
            value={name}
            checked={@color == name}
            class="sr-only"
          />
          <span class={["size-4 rounded-full", Palette.dot(name)]}></span>
        </label>
      </div>
    </fieldset>
    """
  end
end

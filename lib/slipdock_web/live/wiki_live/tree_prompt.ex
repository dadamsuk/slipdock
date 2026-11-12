defmodule SlipdockWeb.WikiLive.TreePrompt do
  @moduledoc """
  The tree's dialogs (`WikiLive.Index`'s `@tree_prompt`): rename,
  archive, delete, move to, file in, a cross-board move's warnings and
  Organise….
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents,
    only: [modal: 1]

  import SlipdockWeb.WikiLive.Format
  alias Slipdock.Palette
  alias Slipdock.Wiki.AutoOrganise

  attr :prompt, :map, required: true

  # What the tree's keyboard asks before it changes a page: F2's new title,
  # or Delete's "archive this?".
  def tree_prompt(%{prompt: %{kind: :rename}} = assigns) do
    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <form id="tree-rename-form" phx-submit="save_page_title" class="space-y-4 p-6">
        <h2 class="section-title">Rename page</h2>
        <input
          type="text"
          name="title"
          value={@prompt.page.title}
          autofocus
          required
          class="input field w-full"
        />
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button type="submit" class="btn btn-primary btn-sm">Rename</button>
        </div>
      </form>
    </.modal>
    """
  end

  # "Move to…" and "Also file in…": where, typed at to narrow it.
  def tree_prompt(%{prompt: %{kind: kind}} = assigns) when kind in [:move, :also] do
    assigns =
      assign(assigns,
        targets: visible_targets(assigns.prompt),
        event: if(kind == :move, do: "move_to", else: "also_file_in"),
        heading:
          case {kind, assigns.prompt.items} do
            {:also, [item]} -> "Also file “#{item_name(item)}” in…"
            {:move, [item]} -> "Move “#{item_name(item)}” to…"
            {:move, items} -> "Move #{length(items)} items to…"
          end
      )

    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <div class="space-y-3 p-6">
        <h2 class="section-title">{@heading}</h2>
        <form id="tree-target-filter" phx-change="tree_dialog_filter" phx-submit="tree_dialog_filter">
          <input
            type="text"
            name="q"
            value={@prompt.q}
            autofocus
            autocomplete="off"
            placeholder="Type part of a folder's name…"
            class="input field w-full"
          />
        </form>
        <ul id="tree-targets" class="max-h-80 space-y-0.5 overflow-y-auto">
          <li :for={target <- @targets}>
            <button
              type="button"
              phx-click={@event}
              phx-value-target={target.key}
              class="flex w-full items-center gap-1.5 rounded-lg px-2 py-1.5 text-left text-sm hover:bg-base-200"
              style={"padding-left: #{0.5 + if(@prompt.q == "", do: target.depth, else: 0) * 0.75}rem"}
            >
              <.icon
                name={if target.depth == 0, do: "hero-book-open", else: "hero-folder"}
                class="size-4 shrink-0 text-base-content/50"
              />
              <span class="truncate">{target.label}</span>
            </button>
          </li>
          <li :if={@targets == []} class="px-2 py-4 text-center text-sm text-base-content/50">
            No folder by that name.
          </li>
        </ul>
        <div class="flex justify-end">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  # What a move to another board of the vault carries and what it cannot,
  # before it happens (R11.8).
  def tree_prompt(%{prompt: %{kind: :cross_move}} = assigns) do
    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <div class="space-y-4 p-6">
        <h2 class="section-title">
          <%= case {@prompt.pages, Map.get(@prompt, :folders, [])} do %>
            <% {[page], []} -> %>
              Move “{page.title}” to {@prompt.board.name}?
            <% {[], [folder]} -> %>
              Move the folder “{folder.name}” to {@prompt.board.name}?
            <% {pages, []} -> %>
              Move {length(pages)} pages to {@prompt.board.name}?
            <% {pages, folders} -> %>
              Move {count(length(pages) + length(folders), "item")} to {@prompt.board.name}?
          <% end %>
        </h2>
        <p :if={Map.get(@prompt, :folders, []) == []} class="text-sm text-base-content/70">
          It keeps its code, history, comments, checklist, links and its other folders.
          <span :if={@prompt.report.pages > length(@prompt.pages)}>
            {count(@prompt.report.pages - length(@prompt.pages), "page")} under it come too.
          </span>
        </p>
        <p
          :if={Map.get(@prompt, :folders, []) != []}
          id="cross-move-folders"
          class="text-sm text-base-content/70"
        >
          {count(@prompt.report.folders, "folder")}, {count(@prompt.report.pages, "page")}<span :if={
            @prompt.report.files > 0
          }> and {count(@prompt.report.files, "file")}</span>
          move, keeping their names and order. Every page keeps its code, history, comments,
          checklist and links.
        </p>
        <p
          :if={@prompt.report.title_clashes != []}
          id="cross-move-clashes"
          class="text-sm text-base-content/70"
        >
          Landing beside pages of the same title: {Enum.join(@prompt.report.title_clashes, ", ")}
        </p>
        <ul id="cross-move-report" class="space-y-1 text-sm">
          <li :if={@prompt.report.tags.carried != []}>
            Tags carried across: {Enum.join(@prompt.report.tags.carried, ", ")}
          </li>
          <li :if={@prompt.report.fields.carried != []}>
            Fields carried across: {Enum.join(@prompt.report.fields.carried, ", ")}
          </li>
          <li :if={@prompt.report.pins.carried != []}>
            Still pinned to: {Enum.join(@prompt.report.pins.carried, ", ")}
          </li>
        </ul>
        <div
          :if={cross_losses(@prompt.report) != []}
          class="rounded-lg bg-warning/10 p-3 text-sm"
        >
          <p class="font-medium">{@prompt.board.name} has no match for these, so they stay behind:</p>
          <ul id="cross-move-losses" class="mt-1 list-inside list-disc space-y-0.5">
            <li :for={line <- cross_losses(@prompt.report)}>{line}</li>
          </ul>
        </div>
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button
            id="cross-move-confirm"
            type="button"
            phx-click="confirm_cross_move"
            class="btn btn-primary btn-sm"
          >
            Move
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  # A folder's "Organise…" (#791): how, then where each item would go.
  def tree_prompt(%{prompt: %{kind: :organise}} = assigns) do
    plan = assigns.prompt.plan || []

    assigns =
      assign(assigns,
        picked: Enum.count(plan, &(not MapSet.member?(assigns.prompt.excluded, &1.key))),
        plan: plan
      )

    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="lg">
      <div class="space-y-4 p-6">
        <h2 class="section-title">Organise “{@prompt.folder.name}”</h2>
        <form
          id="organise-form"
          phx-change="organise_draft"
          phx-submit="organise_draft"
          class="space-y-3"
        >
          <div class="grid gap-2 sm:grid-cols-2" role="radiogroup" aria-label="How">
            <label
              :for={
                {mode, title, help} <- [
                  {"date", "By date", "Into a dated folder: Meetings/2026-10"},
                  {"ai", "AI suggestions", "A model reads the titles and the folders"},
                  {"tag", "By tag", "Into a folder named after the first tag"},
                  {"flatten", "Flatten", "Everything in the subfolders, back up here"}
                ]
              }
              class={[
                "flex cursor-pointer gap-2 rounded-lg border p-2.5 text-sm transition-colors",
                if(@prompt.mode == mode,
                  do: "border-primary bg-primary/5",
                  else: "border-base-300 hover:bg-base-200"
                )
              ]}
            >
              <input
                type="radio"
                name="mode"
                value={mode}
                checked={@prompt.mode == mode}
                class="radio mt-0.5"
              />
              <span>
                <span class="block font-medium">{title}</span>
                <span class="block text-xs text-base-content/60">{help}</span>
              </span>
            </label>
          </div>

          <div :if={@prompt.mode == "date"} id="organise-date" class="grid gap-2 sm:grid-cols-3">
            <label class="text-xs text-base-content/70 sm:col-span-3">
              Into folders under
              <input
                type="text"
                name="parent"
                value={@prompt.parent}
                list="organise-paths"
                placeholder="The top of the wiki"
                autocomplete="off"
                phx-debounce="300"
                class="input field mt-1 w-full"
              />
              <datalist id="organise-paths">
                <option :for={path <- @prompt.paths} value={path}></option>
              </datalist>
            </label>
            <label class="text-xs text-base-content/70">
              One folder per
              <select name="granularity" class="select field mt-1 w-full">
                <option
                  :for={
                    {value, label} <- [
                      {"month", "Month (2026-10)"},
                      {"year", "Year (2026)"},
                      {"year_month", "Year, then month (2026/10)"},
                      {"day", "Day (2026-10-12)"}
                    ]
                  }
                  value={value}
                  selected={@prompt.granularity == value}
                >
                  {label}
                </option>
              </select>
            </label>
            <label class="text-xs text-base-content/70 sm:col-span-2">
              Dated by
              <select name="source" class="select field mt-1 w-full">
                <option value="auto" selected={@prompt.source == "auto"}>
                  Its created: or date: front matter, else when it was added
                </option>
                <option value="added" selected={@prompt.source == "added"}>
                  When it was added here
                </option>
              </select>
            </label>
          </div>
        </form>

        <div :if={@prompt.mode == "ai"} id="organise-ai" class="space-y-2 text-sm">
          <p class="text-base-content/70">
            The model sees this board's folders and the titles here (the first {AutoOrganise.ai_limit()}). It may suggest new folders inside existing ones, never a new top-level folder.
          </p>
          <p :if={not @prompt.ai?} class="text-warning">
            AI needs a model to talk to: set one up under Account → AI model.
          </p>
          <button
            :if={@prompt.ai?}
            id="organise-ask"
            type="button"
            phx-click="organise_ask"
            class="btn btn-sm btn-secondary"
            disabled={@prompt.asking}
          >
            <span :if={@prompt.asking} class="loading loading-spinner loading-xs"></span>
            {cond do
              @prompt.asking -> "Asking…"
              @prompt.plan -> "Ask again"
              true -> "Suggest destinations"
            end}
          </button>
        </div>

        <p :if={@prompt.error} id="organise-error" class="text-sm text-error">{@prompt.error}</p>

        <p
          :if={@prompt.plan == [] and is_nil(@prompt.error)}
          id="organise-nothing"
          class="rounded-lg bg-base-200 px-3 py-4 text-center text-sm text-base-content/60"
        >
          Nothing here would move.
        </p>

        <form :if={@plan != []} id="organise-preview" phx-change="organise_pick">
          <input type="hidden" name="include[]" value="" />
          <ul class="max-h-72 divide-y divide-base-200 overflow-y-auto rounded-lg border border-base-300 text-sm">
            <li :for={entry <- @plan} class="flex items-center gap-2 px-2 py-1.5">
              <input
                type="checkbox"
                name="include[]"
                value={entry.key}
                checked={not MapSet.member?(@prompt.excluded, entry.key)}
                class="checkbox"
                aria-label={"Move #{entry.title}"}
              />
              <.icon
                name={if entry.kind == :file, do: "hero-paper-clip", else: "hero-document-text"}
                class="size-4 shrink-0 text-base-content/50"
              />
              <span class="min-w-0 flex-1 truncate">{entry.title}</span>
              <.icon name="hero-arrow-right" class="size-3 shrink-0 text-base-content/40" />
              <span class="max-w-[45%] truncate font-mono text-xs text-base-content/70">
                /{entry.to}
              </span>
            </li>
          </ul>
        </form>

        <div class="flex justify-end gap-2">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button
            id="organise-confirm"
            type="button"
            phx-click="confirm_organise"
            class="btn btn-primary btn-sm"
            disabled={@picked == 0}
          >
            Organise {count(@picked, "item")}
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  def tree_prompt(%{prompt: %{kind: :archive_many}} = assigns) do
    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <div class="space-y-4 p-6">
        <h2 class="section-title">Archive {count(length(@prompt.items), "page")}?</h2>
        <ul class="max-h-48 list-inside list-disc overflow-y-auto text-sm text-base-content/70">
          <li :for={page <- @prompt.items}>{page.title}</li>
        </ul>
        <p class="text-sm text-base-content/60">
          The pages under them go too. Archived pages can be shown again from Display, and restored.
        </p>
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button
            id="bulk-archive-confirm"
            type="button"
            phx-click="bulk_archive"
            class="btn btn-error btn-sm"
          >
            Archive
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  def tree_prompt(%{prompt: %{kind: :tag_many}} = assigns) do
    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <div class="space-y-4 p-6">
        <h2 class="section-title">Tag {count(length(@prompt.items), "page")}</h2>
        <div :if={@prompt.tags == []} class="text-sm text-base-content/60">
          This board has no tags yet; make one in the board's settings.
        </div>
        <div id="bulk-tags" class="flex flex-wrap gap-1.5">
          <button
            :for={tag <- @prompt.tags}
            type="button"
            phx-click="bulk_tag"
            phx-value-tag={tag.id}
            class={["chip cursor-pointer", Palette.chip(tag.color)]}
          >
            {tag.name}
          </button>
        </div>
        <div class="flex justify-end">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  def tree_prompt(%{prompt: %{kind: :archive_file}} = assigns) do
    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <div class="space-y-4 p-6">
        <h2 class="section-title">Archive {@prompt.file.name}?</h2>
        <p class="text-sm text-base-content/60">
          It leaves the tree. Its bytes are kept, and still count towards the board owner's
          storage; deleting it gives that back.
        </p>
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button
            id="tree-archive-file-confirm"
            type="button"
            phx-click="archive_file"
            class="btn btn-error btn-sm"
            autofocus
          >
            Archive
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  def tree_prompt(%{prompt: %{kind: :delete_file}} = assigns) do
    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <div class="space-y-4 p-6">
        <h2 class="section-title">Delete {@prompt.file.name}?</h2>
        <p class="text-sm text-base-content/60">
          It is deleted for good, and its storage given back. This cannot be undone, and a
          synced copy of your wiki takes its copy away too.
        </p>
        <p :if={not @prompt.owner} id="tree-delete-file-owner-only" class="text-sm text-warning">
          Only the board's owner can delete a file for good. Archive puts it away instead.
        </p>
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button
            :if={@prompt.owner}
            id="tree-delete-file-confirm"
            type="button"
            phx-click="delete_file"
            class="btn btn-error btn-sm"
            autofocus
          >
            <.icon name="hero-trash" class="size-4" /> Delete for good
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  def tree_prompt(%{prompt: %{kind: :delete_page}} = assigns) do
    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <div class="space-y-4 p-6">
        <h2 class="section-title">Delete “{@prompt.page.title}”?</h2>
        <p id="tree-delete-page-warning" class="text-sm text-base-content/60">
          {delete_warning(@prompt.page, @prompt.children)}
        </p>
        <p :if={not @prompt.owner} id="tree-delete-page-owner-only" class="text-sm text-warning">
          Only the board's owner can delete a page for good. Archive puts it away instead.
        </p>
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button
            :if={@prompt.owner}
            id="tree-delete-page-confirm"
            type="button"
            phx-click="delete_from_tree"
            class="btn btn-error btn-sm"
          >
            <.icon name="hero-trash" class="size-4" /> Delete for good
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  def tree_prompt(%{prompt: %{kind: :archive}} = assigns) do
    ~H"""
    <.modal id="tree-prompt" on_close={JS.push("close_tree_prompt")} size="sm">
      <div class="space-y-4 p-6">
        <h2 class="section-title">Archive “{@prompt.page.title}”?</h2>
        <p class="text-sm text-base-content/60">
          It leaves the tree, with the pages under it. Archived pages can be shown again from
          Display, and restored.
        </p>
        <div class="flex justify-end gap-2">
          <button type="button" phx-click="close_tree_prompt" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button
            id="tree-archive-confirm"
            type="button"
            phx-click="archive_from_tree"
            class="btn btn-error btn-sm"
            autofocus
          >
            Archive
          </button>
        </div>
      </div>
    </.modal>
    """
  end
end

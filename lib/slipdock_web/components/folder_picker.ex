defmodule SlipdockWeb.FolderPicker do
  @moduledoc """
  One way of being asked "which folder?", wherever the question comes up.

  A wiki with thirty folders four deep cannot be picked from a `<select>`:
  the list is flat, the indentation is a lie, and finding "Decisions" means
  reading every line. So this is a tree you can type at — the whole filing
  shown with its nesting, narrowed as you type, with the full path shown for
  each hit so two folders called "Notes" are told apart.

  It is used in two modes, which differ only in what a click does:

    * **in a form** — give it `name` (and `selected`). A hidden input of that
      name carries the choice, so the picker drops into any form where a
      select would have gone, and an `input` event is dispatched so a
      `phx-change` form still hears about it.

    * **on its own** — give it `event`. Each row is a button that pushes that
      event with `phx-value-folder` set to the folder's id, or `"none"` for
      the root, which is the shape `Slipdock.Wiki.find_folder/2` already reads.

  Filtering, opening, closing and the arrow keys are the `FolderPicker` hook
  in `assets/js/app.js`: narrowing a list that is already on the page is not
  worth a round trip, and it keeps the picker usable inside a form that is
  mid-edit.
  """
  use Phoenix.Component

  import SlipdockWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true

  attr :outline, :list,
    required: true,
    doc: "the board's folders from `Slipdock.Wiki.folder_outline/1`"

  attr :selected, :any, default: nil, doc: "the chosen folder's id, or nil for the root"

  attr :name, :string,
    default: nil,
    doc: "form mode: the name of the hidden input that carries the choice"

  attr :event, :string, default: nil, doc: "standalone mode: the event each row pushes"

  attr :exclude, :any,
    default: nil,
    doc: "a folder that cannot be chosen, nor anything inside it — a folder being moved"

  attr :label, :string, default: nil, doc: "a label above the picker"
  attr :hint, :string, default: nil
  attr :root_label, :string, default: "The top of the wiki"
  attr :allow_root, :boolean, default: true
  attr :new_event, :string, default: nil, doc: "an event for a “New folder…” row at the foot"
  attr :align, :string, default: "start", values: ~w(start end)
  attr :size, :string, default: "sm", values: ~w(sm xs)
  attr :class, :any, default: nil

  def folder_picker(assigns) do
    excluded = excluded_paths(assigns.outline, assigns.exclude)

    assigns =
      assign(assigns,
        excluded: excluded,
        current: current_label(assigns.outline, assigns.selected, assigns.root_label)
      )

    ~H"""
    <div class={["space-y-1.5", @class]}>
      <span :if={@label} class="block text-sm font-medium">{@label}</span>
      <div
        id={@id}
        class="relative"
        phx-hook="FolderPicker"
        data-root-label={@root_label}
        data-mode={if @name, do: "form", else: "event"}
      >
        <input :if={@name} type="hidden" name={@name} value={@selected} data-value />
        <button
          type="button"
          data-toggle
          aria-haspopup="listbox"
          class={[
            "flex w-full items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-3 text-left hover:border-base-content/30",
            @size == "sm" && "py-2 text-sm",
            @size == "xs" && "py-1 text-xs"
          ]}
        >
          <.icon name="hero-folder" class="size-4 shrink-0 text-base-content/50" />
          <span data-label class="min-w-0 flex-1 truncate">{@current}</span>
          <.icon name="hero-chevron-up-down" class="size-4 shrink-0 text-base-content/40" />
        </button>

        <div
          data-panel
          hidden
          role="listbox"
          class={[
            "absolute z-50 mt-1 w-72 max-w-[calc(100vw-2rem)] overflow-hidden rounded-xl bg-base-100 shadow-xl ring-1 ring-base-content/10",
            @align == "end" && "right-0",
            @align == "start" && "left-0"
          ]}
        >
          <div class="border-b border-base-300 p-2">
            <div class="relative">
              <.icon
                name="hero-magnifying-glass"
                class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
              />
              <input
                type="text"
                data-filter
                placeholder="Type to filter folders…"
                autocomplete="off"
                class="w-full rounded-lg border border-base-300 bg-base-100 py-1.5 pl-8 pr-2 text-sm focus:border-primary focus:outline-none"
              />
            </div>
          </div>

          <ul data-list class="kanban-scroll max-h-64 overflow-y-auto p-1">
            <li :if={@allow_root} data-root-row>
              <button
                type="button"
                data-row
                data-id=""
                data-path=""
                data-indent="0.5"
                phx-click={@event}
                phx-value-folder={@event && "none"}
                class={[
                  "flex w-full items-center gap-1.5 rounded-lg py-1.5 pl-2 pr-2 text-left text-sm hover:bg-base-200 data-[on]:bg-base-200",
                  is_nil(@selected) && "font-medium"
                ]}
              >
                <.icon name="hero-book-open" class="size-3.5 shrink-0 text-base-content/40" />
                <span class="min-w-0 flex-1 truncate">{@root_label}</span>
                <.icon
                  :if={is_nil(@selected)}
                  name="hero-check"
                  class="size-3.5 shrink-0 text-primary"
                />
              </button>
            </li>
            <li :for={entry <- @outline}>
              <button
                type="button"
                data-row
                data-id={entry.folder.id}
                data-path={String.downcase(entry.path)}
                data-indent={0.5 + entry.depth * 0.75}
                disabled={entry.path in @excluded}
                phx-click={entry.path not in @excluded && @event}
                phx-value-folder={@event && entry.folder.id}
                style={"padding-left: #{0.5 + entry.depth * 0.75}rem"}
                class={[
                  "flex w-full items-center gap-1.5 rounded-lg py-1.5 pr-2 text-left text-sm hover:bg-base-200 data-[on]:bg-base-200",
                  "disabled:cursor-not-allowed disabled:opacity-40 disabled:hover:bg-transparent",
                  to_string(@selected) == to_string(entry.folder.id) && "font-medium"
                ]}
                title={entry.path}
              >
                <.icon name="hero-folder" class="size-3.5 shrink-0 text-base-content/50" />
                <span class="min-w-0 flex-1 truncate">
                  <span data-name>{entry.folder.name}</span>
                  <%!-- Shown only while filtering, when the indentation no
                        longer says where a folder sits. --%>
                  <span data-full hidden class="text-base-content/50">{entry.path}</span>
                </span>
                <.icon
                  :if={to_string(@selected) == to_string(entry.folder.id)}
                  name="hero-check"
                  class="size-3.5 shrink-0 text-primary"
                />
              </button>
            </li>
            <li :if={@outline == []} class="px-2 py-3 text-sm text-base-content/50">
              No folders on this board yet.
            </li>
            <li data-empty hidden class="px-2 py-3 text-sm text-base-content/50">
              No folder matches that.
            </li>
          </ul>

          <div :if={@new_event} class="border-t border-base-300 p-1">
            <button
              type="button"
              phx-click={@new_event}
              class="flex w-full items-center gap-1.5 rounded-lg px-2 py-1.5 text-left text-sm hover:bg-base-200"
            >
              <.icon name="hero-folder-plus" class="size-4 text-base-content/50" /> New folder…
            </button>
          </div>
        </div>
      </div>
      <span :if={@hint} class="block text-xs text-base-content/50">{@hint}</span>
    </div>
    """
  end

  # A folder cannot be moved inside itself or anything it holds, and the
  # picker says so by greying those rows rather than hiding them: a row that
  # vanishes looks like a bug, a row that is out reads as a reason.
  defp excluded_paths(_outline, nil), do: []

  defp excluded_paths(outline, folder_id) do
    case Enum.find(outline, &(to_string(&1.folder.id) == to_string(folder_id))) do
      nil -> []
      %{path: path} -> Enum.filter(outline, &prefixed?(&1.path, path)) |> Enum.map(& &1.path)
    end
  end

  defp prefixed?(path, path), do: true
  defp prefixed?(path, prefix), do: String.starts_with?(path, prefix <> "/")

  defp current_label(_outline, nil, root_label), do: root_label

  defp current_label(outline, selected, root_label) do
    case Enum.find(outline, &(to_string(&1.folder.id) == to_string(selected))) do
      nil -> root_label
      %{path: path} -> path
    end
  end
end

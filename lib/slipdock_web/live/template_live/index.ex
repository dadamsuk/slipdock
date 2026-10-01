defmodule SlipdockWeb.TemplateLive.Index do
  @moduledoc "Manage board templates: named lists of columns for new boards and sub-boards."
  use SlipdockWeb, :live_view

  alias Slipdock.Boards
  alias Slipdock.Boards.Template
  alias Slipdock.Palette

  @blank_column %{"name" => "", "wip_limit" => "", "color" => ""}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Boards.subscribe_templates()
    {:ok, socket |> assign(page_title: "Templates", editing: nil) |> load()}
  end

  defp load(socket), do: assign(socket, templates: Boards.list_templates())

  @impl true
  def handle_info({:templates_changed}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  ## Events -----------------------------------------------------------------

  @impl true
  def handle_event("new", _, socket) do
    {:noreply, start_editing(socket, %Template{}, [@blank_column, @blank_column, @blank_column])}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    template = Boards.get_template!(id)
    {:noreply, start_editing(socket, template, Enum.map(template.columns, &stringify/1))}
  end

  def handle_event("cancel", _, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("change", params, socket) do
    {:noreply, assign(socket, editing: editing_from_params(socket.assigns.editing, params))}
  end

  def handle_event("add_column", params, socket) do
    editing = editing_from_params(socket.assigns.editing, params)
    {:noreply, assign(socket, editing: %{editing | columns: editing.columns ++ [@blank_column]})}
  end

  def handle_event("remove_column", %{"index" => i} = params, socket) do
    editing = editing_from_params(socket.assigns.editing, params)

    {:noreply,
     assign(socket,
       editing: %{editing | columns: List.delete_at(editing.columns, String.to_integer(i))}
     )}
  end

  def handle_event("move_column", %{"index" => i, "dir" => dir} = params, socket) do
    editing = editing_from_params(socket.assigns.editing, params)
    i = String.to_integer(i)
    j = if dir == "up", do: i - 1, else: i + 1

    columns =
      if j >= 0 and j < length(editing.columns) do
        {col, rest} = List.pop_at(editing.columns, i)
        List.insert_at(rest, j, col)
      else
        editing.columns
      end

    {:noreply, assign(socket, editing: %{editing | columns: columns})}
  end

  def handle_event("save", params, socket) do
    editing = editing_from_params(socket.assigns.editing, params)

    attrs = %{
      "name" => editing.name,
      "description" => editing.description,
      "columns" => editing.columns
    }

    result =
      if editing.template.id,
        do: Boards.update_template(editing.template, attrs),
        else: Boards.create_template(attrs)

    case result do
      {:ok, template} ->
        {:noreply,
         socket |> assign(editing: nil) |> put_flash(:info, "Saved template “#{template.name}”.")}

      {:error, cs} ->
        {:noreply, assign(socket, editing: %{editing | errors: errors(cs)})}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, _} = Boards.delete_template(Boards.get_template!(id))
    {:noreply, assign(socket, editing: nil)}
  end

  defp start_editing(socket, template, columns) do
    assign(socket,
      editing: %{
        template: template,
        name: template.name || "",
        description: template.description || "",
        columns: columns,
        errors: []
      }
    )
  end

  # Keeps whatever is typed in the form when rows are added, removed or moved.
  defp editing_from_params(editing, params) do
    columns =
      case params["columns"] do
        nil ->
          editing.columns

        cols ->
          cols
          |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
          |> Enum.map(fn {_, v} -> stringify(v) end)
      end

    %{
      editing
      | name: Map.get(params, "name", editing.name),
        description: Map.get(params, "description", editing.description),
        columns: columns
    }
  end

  defp stringify(col) do
    col = Map.new(col, fn {k, v} -> {to_string(k), v} end)

    %{
      "name" => col["name"] || "",
      "wip_limit" => to_string(col["wip_limit"] || ""),
      "color" => col["color"] || ""
    }
  end

  defp errors(cs) do
    Enum.map(cs.errors, fn {field, {msg, _}} -> "#{Phoenix.Naming.humanize(field)} #{msg}" end)
  end

  ## Render -----------------------------------------------------------------

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
      nav_active={:templates}
    >
      <:nav>
        <span class="font-semibold">Templates</span>
      </:nav>
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-4xl px-4 py-6 sm:py-10 sm:px-6">
          <div class="mb-8 flex flex-wrap items-end justify-between gap-4">
            <div>
              <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Board templates</h1>
              <p class="mt-1 max-w-xl text-sm text-base-content/60">
                A template is a set of lists. Use one when creating a board, or when turning a card
                into a board of subcards. Any board can save its lists as a template from its settings.
              </p>
            </div>
            <button :if={!@editing} class="btn btn-primary" phx-click="new">
              <.icon name="hero-plus" class="size-4" /> New template
            </button>
          </div>

          <form
            :if={@editing}
            id="template-form"
            phx-change="change"
            phx-submit="save"
            class="kanban-pop mb-8 space-y-4 rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <h2 class="text-lg font-semibold">
              {if @editing.template.id, do: "Edit template", else: "New template"}
            </h2>
            <ul
              :if={@editing.errors != []}
              class="rounded-lg bg-error/10 px-3 py-2 text-sm text-error"
            >
              <li :for={e <- @editing.errors}>{e}</li>
            </ul>
            <div class="flex flex-col gap-4 sm:flex-row">
              <label class="flex-1">
                <span class="mb-1 block text-sm font-medium">Name</span>
                <input
                  type="text"
                  name="name"
                  value={@editing.name}
                  class="input w-full"
                  placeholder="e.g. Sprint"
                  phx-hook="Focus"
                  id="template-name"
                  autocomplete="off"
                  required
                />
              </label>
              <label class="flex-1">
                <span class="mb-1 block text-sm font-medium">Description (optional)</span>
                <input
                  type="text"
                  name="description"
                  value={@editing.description}
                  class="input w-full"
                  placeholder="When to use it"
                />
              </label>
            </div>
            <div class="space-y-2">
              <span class="block text-sm font-medium">Lists, in order</span>
              <div
                :for={{col, i} <- Enum.with_index(@editing.columns)}
                id={"tcol-#{i}"}
                class="flex items-center gap-2"
              >
                <div class="join">
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs join-item"
                    phx-click="move_column"
                    phx-value-index={i}
                    phx-value-dir="up"
                    title="Move up"
                    disabled={i == 0}
                  >
                    <.icon name="hero-chevron-up" class="size-3.5" />
                  </button>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs join-item"
                    phx-click="move_column"
                    phx-value-index={i}
                    phx-value-dir="down"
                    title="Move down"
                    disabled={i == length(@editing.columns) - 1}
                  >
                    <.icon name="hero-chevron-down" class="size-3.5" />
                  </button>
                </div>
                <input
                  type="text"
                  name={"columns[#{i}][name]"}
                  value={col["name"]}
                  placeholder="List name"
                  class="input input-sm flex-1"
                  autocomplete="off"
                />
                <input
                  type="number"
                  name={"columns[#{i}][wip_limit]"}
                  value={col["wip_limit"]}
                  min="1"
                  placeholder="WIP"
                  class="input input-sm w-20"
                  title="WIP limit (optional)"
                />
                <select name={"columns[#{i}][color]"} class="select select-sm w-32" title="Colour">
                  <option value="" selected={col["color"] in ["", nil]}>No colour</option>
                  <option
                    :for={{name, label} <- Palette.all()}
                    value={name}
                    selected={col["color"] == name}
                  >
                    {label}
                  </option>
                </select>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs btn-square text-error"
                  phx-click="remove_column"
                  phx-value-index={i}
                  title="Remove list"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
              <button type="button" class="btn btn-ghost btn-sm" phx-click="add_column">
                <.icon name="hero-plus" class="size-4" /> Add list
              </button>
            </div>
            <div class="flex items-center justify-between gap-2">
              <button
                :if={@editing.template.id}
                type="button"
                class="btn btn-ghost btn-sm text-error"
                phx-click="delete"
                phx-value-id={@editing.template.id}
                data-confirm="Delete this template? Boards already created from it are not affected."
              >
                <.icon name="hero-trash" class="size-4" /> Delete
              </button>
              <div class="ml-auto flex gap-2">
                <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
                <button type="submit" class="btn btn-primary">Save template</button>
              </div>
            </div>
          </form>

          <p :if={@templates == []} class="text-sm text-base-content/60">No templates yet.</p>
          <div class="grid gap-4 sm:grid-cols-2">
            <div
              :for={t <- @templates}
              id={"template-#{t.id}"}
              class="rounded-2xl bg-base-100 p-4 shadow-sm ring-1 ring-base-content/10"
            >
              <div class="flex items-start justify-between gap-2">
                <div class="min-w-0">
                  <h2 class="truncate font-semibold">{t.name}</h2>
                  <p :if={t.description} class="text-sm text-base-content/60">{t.description}</p>
                </div>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="edit"
                  phx-value-id={t.id}
                >
                  <.icon name="hero-pencil-square" class="size-4" /> Edit
                </button>
              </div>
              <ol class="mt-3 flex flex-wrap gap-1.5">
                <li
                  :for={col <- t.columns}
                  class="inline-flex items-center gap-1 rounded-md bg-base-200 px-2 py-1 text-xs"
                >
                  <span :if={col["color"]} class={["size-2 rounded-full", Palette.dot(col["color"])]}></span>
                  {col["name"]}
                  <span :if={col["wip_limit"]} class="font-mono text-base-content/50">/{col[
                    "wip_limit"
                  ]}</span>
                </li>
              </ol>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

defmodule SlipdockWeb.MultiboardLive.Index do
  @moduledoc """
  The multiboard overview (#1479): the top N cards of lists chosen from any
  of your boards, by board, by list, or as a grid of tiles. Reached from the
  home page; the view lives in the URL (`?lists=1,2&top=5&by=grid`) and is
  remembered on the account, so a bare `/multiboard` opens the last one.
  See `Slipdock.Multiboard`.

  A view can be saved under a name and a colour (#1482): it goes on the home
  page among the boards and vaults, and opens at `/multiboard/:id`, where
  changing the lists or the layout changes the saved one.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents

  alias Slipdock.Multiboard
  alias Slipdock.Multiboard.Saved
  alias SlipdockWeb.BoardNotices

  @layouts [
    {"board", "hero-squares-2x2", "By board"},
    {"list", "hero-view-columns", "By list"},
    {"grid", "hero-table-cells", "Grid"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> BoardNotices.subscribe()
     |> assign(page_title: "Multiboard", picking: false, saved: nil)
     |> assign(saving: false, save_color: "indigo")
     |> assign(choices: Multiboard.choices(socket.assigns.current_user))}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    case Multiboard.get_saved(socket.assigns.current_user, id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That multiboard isn't one of yours, or has been deleted.")
         |> push_navigate(to: ~p"/multiboard")}

      saved ->
        keys = Map.take(params, ~w(lists top by))
        view = Multiboard.normalize(keys, stringify(Saved.view(saved)))

        # A view in the link that differs from the saved one changes it.
        saved =
          if keys != %{} and view != Saved.view(saved) do
            {:ok, saved} = Multiboard.save_view(saved, view)
            saved
          else
            saved
          end

        {:noreply,
         socket
         |> assign(saved: saved, view: view, page_title: saved.name)
         |> assign(picking: socket.assigns.picking or view.lists == [])
         |> load()}
    end
  end

  def handle_params(params, _uri, socket) do
    user = socket.assigns.current_user
    keys = Map.take(params, ~w(lists top by))

    # A bare /multiboard opens the last view; a link with a view in it shows
    # that view and becomes the remembered one.
    view =
      if keys == %{},
        do: Multiboard.prefs(user),
        else: Multiboard.normalize(keys, user.multiboard)

    socket =
      if keys != %{} and view != Multiboard.prefs(user) do
        {:ok, user} = Multiboard.save_prefs(user, view)
        assign(socket, current_user: user)
      else
        socket
      end

    {:noreply,
     socket
     |> assign(saved: nil, view: view, page_title: "Multiboard")
     |> assign(picking: socket.assigns.picking or view.lists == [])
     |> load()}
  end

  defp stringify(view), do: Map.new(view, fn {k, v} -> {to_string(k), v} end)

  defp load(socket) do
    entries = Multiboard.entries(socket.assigns.view, socket.assigns.choices)

    assign(socket,
      sections: Multiboard.group(entries, socket.assigns.view.by),
      list_count: length(entries),
      board_count: entries |> Enum.uniq_by(& &1.board.id) |> length()
    )
  end

  defp patch(socket, view) do
    query = [lists: Enum.join(view.lists, ","), top: view.top, by: view.by]

    case socket.assigns.saved do
      nil -> push_patch(socket, to: ~p"/multiboard?#{query}")
      saved -> push_patch(socket, to: ~p"/multiboard/#{saved.id}?#{query}")
    end
  end

  @impl true
  def handle_info({:boards_changed}, socket) do
    Slipdock.Boards.drain_boards_changed()

    {:noreply,
     socket
     |> BoardNotices.resubscribe()
     |> assign(choices: Multiboard.choices(socket.assigns.current_user))
     |> load()}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_picker", _, socket),
    do: {:noreply, assign(socket, picking: not socket.assigns.picking)}

  def handle_event("set_by", %{"by" => by}, socket),
    do: {:noreply, patch(socket, %{socket.assigns.view | by: by})}

  # The picker's checkboxes and the top N, as one form.
  def handle_event("pick", params, socket) do
    view =
      Multiboard.normalize(
        %{
          "lists" => params["lists"] || [],
          "top" => params["top"],
          "by" => socket.assigns.view.by
        },
        %{}
      )

    {:noreply, patch(socket, view)}
  end

  def handle_event("clear", _, socket),
    do: {:noreply, patch(socket, %{socket.assigns.view | lists: []})}

  # Saving (#1482): on the bare page it names the view as a new multiboard;
  # on a saved one it renames and recolours it.
  def handle_event("toggle_save", _, socket) do
    color = if socket.assigns.saved, do: socket.assigns.saved.color, else: "indigo"
    {:noreply, assign(socket, saving: not socket.assigns.saving, save_color: color)}
  end

  def handle_event("save_color", %{"color" => color}, socket),
    do: {:noreply, assign(socket, save_color: color)}

  def handle_event("save", %{"name" => name}, socket) do
    attrs = %{"name" => name, "color" => socket.assigns.save_color}

    result =
      case socket.assigns.saved do
        nil -> Multiboard.create_saved(socket.assigns.current_user, attrs, socket.assigns.view)
        saved -> Multiboard.update_saved(saved, attrs)
      end

    case result do
      {:ok, saved} ->
        {:noreply,
         socket
         |> assign(saving: false)
         |> put_flash(:info, "Saved as “#{saved.name}”. It is on your home page.")
         |> push_patch(to: ~p"/multiboard/#{saved.id}")}

      {:error, changeset} ->
        message =
          changeset.errors
          |> Enum.map_join(", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)

        {:noreply, put_flash(socket, :error, "That couldn't be saved: #{message}.")}
    end
  end

  def handle_event("delete_saved", _, socket) do
    case socket.assigns.saved do
      nil ->
        {:noreply, socket}

      saved ->
        {:ok, _} = Multiboard.delete_saved(saved)

        {:noreply,
         socket
         |> put_flash(:info, "Multiboard “#{saved.name}” deleted.")
         |> push_navigate(to: ~p"/multiboard")}
    end
  end

  defp layouts, do: @layouts

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
    >
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-7xl px-4 py-6 sm:px-6 sm:py-10">
          <div class="mb-6 flex flex-wrap items-end justify-between gap-4">
            <div>
              <h1
                id="multiboard-title"
                class="flex items-center gap-2 text-2xl font-bold tracking-tight sm:text-3xl"
              >
                <span
                  :if={@saved}
                  class={["size-3 shrink-0 rounded-full", Slipdock.Palette.dot(@saved.color)]}
                ></span>
                {if @saved, do: @saved.name, else: "Multiboard"}
              </h1>
              <p id="multiboard-summary" class="mt-1 text-sm text-base-content/60">
                <%= if @list_count == 0 do %>
                  Pick lists from any of your boards to see their top cards here.
                <% else %>
                  The top {@view.top} of {@list_count} {if @list_count == 1,
                    do: "list",
                    else: "lists"} across {@board_count} {if @board_count == 1,
                    do: "board",
                    else: "boards"}.
                <% end %>
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <div class="join" role="group" aria-label="Layout">
                <button
                  :for={{key, icon, label} <- layouts()}
                  id={"multiboard-by-#{key}"}
                  type="button"
                  class={["btn btn-sm join-item", @view.by == key && "btn-active"]}
                  phx-click="set_by"
                  phx-value-by={key}
                  value={key}
                  title={label}
                  aria-pressed={to_string(@view.by == key)}
                >
                  <.icon name={icon} class="size-4" />
                  <span class="hidden sm:inline">{label}</span>
                </button>
              </div>
              <button
                id="multiboard-choose"
                type="button"
                class={["btn btn-sm", if(@picking, do: "btn-active", else: "btn-ghost")]}
                phx-click="toggle_picker"
                aria-expanded={to_string(@picking)}
              >
                <.icon name="hero-adjustments-horizontal" class="size-4" /> Lists
              </button>
              <button
                id="multiboard-save"
                type="button"
                class={["btn btn-sm", if(@saving, do: "btn-active", else: "btn-ghost")]}
                phx-click="toggle_save"
                aria-expanded={to_string(@saving)}
              >
                <%= if @saved do %>
                  <.icon name="hero-pencil-square" class="size-4" /> Rename
                <% else %>
                  <.icon name="hero-bookmark" class="size-4" /> Save
                <% end %>
              </button>
              <button
                :if={@saved}
                id="multiboard-delete"
                type="button"
                class="btn btn-ghost btn-sm text-error"
                phx-click="delete_saved"
                data-confirm={"Delete the multiboard “#{@saved.name}”? The boards and their cards stay as they are."}
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </div>

          <form
            :if={@saving}
            id="multiboard-save-form"
            phx-submit="save"
            class="kanban-pop mb-8 space-y-4 rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <label class="block">
              <span class="mb-1 block text-sm font-medium">
                {if @saved, do: "Name", else: "Save this view as"}
              </span>
              <input
                type="text"
                name="name"
                id="multiboard-save-name"
                value={@saved && @saved.name}
                maxlength={Saved.name_length()}
                placeholder="e.g. This week"
                required
                phx-hook="Focus"
                class="input w-full max-w-md"
              />
            </label>
            <div>
              <span class="mb-1 block text-sm font-medium">Colour</span>
              <div class="flex flex-wrap gap-2">
                <.color_swatch
                  :for={name <- Slipdock.Palette.names()}
                  id={"multiboard-save-color-#{name}"}
                  color={name}
                  selected={@save_color == name}
                  phx-click="save_color"
                  phx-value-color={name}
                />
              </div>
            </div>
            <p :if={!@saved} class="text-sm text-base-content/60">
              It goes on your home page among your boards, where you can drag it into place.
            </p>
            <div class="flex justify-end gap-2">
              <button type="button" class="btn btn-ghost" phx-click="toggle_save">Cancel</button>
              <button type="submit" class="btn btn-primary">Save</button>
            </div>
          </form>

          <.form
            :if={@picking}
            for={%{}}
            id="multiboard-picker"
            phx-change="pick"
            class="kanban-pop mb-8 space-y-4 rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
          >
            <div class="flex flex-wrap items-center justify-between gap-3">
              <label class="flex items-center gap-2 text-sm">
                Cards from each list
                <input
                  type="number"
                  name="top"
                  value={@view.top}
                  min="1"
                  max={Multiboard.max_top()}
                  class="input input-sm w-20"
                  phx-debounce="300"
                />
              </label>
              <button
                :if={@view.lists != []}
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="clear"
              >
                Clear all
              </button>
            </div>
            <p :if={@choices == []} class="text-sm text-base-content/60">
              You have no boards yet.
            </p>
            <%!-- Sends an empty list when every box is unticked. --%>
            <input type="hidden" name="lists[]" value="" />
            <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
              <fieldset :for={%{board: board, columns: cols} <- @choices} class="min-w-0">
                <legend class="mb-1 flex items-center gap-2 text-sm font-semibold">
                  <span class={["size-2 rounded-full", Slipdock.Palette.dot(board.color)]}></span>
                  <span class="truncate">{board.name}</span>
                </legend>
                <label
                  :for={col <- cols}
                  class="flex cursor-pointer items-center gap-2 py-0.5 text-sm"
                >
                  <input
                    type="checkbox"
                    name="lists[]"
                    value={col.id}
                    id={"multiboard-pick-#{col.id}"}
                    class="checkbox checkbox-xs"
                    checked={col.id in @view.lists}
                  />
                  <span class="truncate">{col.name}</span>
                </label>
              </fieldset>
            </div>
          </.form>

          <div
            :if={@list_count == 0 and not @picking}
            class="rounded-2xl border-2 border-dashed border-base-content/15 p-16 text-center"
          >
            <h2 class="text-lg font-semibold">No lists chosen</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Press <b>Lists</b> to pick them from any of your boards.
            </p>
          </div>

          <%= if @view.by == "grid" do %>
            <div
              :for={section <- @sections}
              id="multiboard-grid"
              class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4"
            >
              <.link
                :for={item <- section.items}
                id={"multiboard-card-#{item.card.id}"}
                navigate={~p"/boards/#{item.card.board_id}/cards/#{item.card.id}"}
                class={[
                  "flex min-h-24 flex-col gap-2 rounded-xl bg-base-100 p-3 shadow-sm ring-1 ring-base-content/10 transition hover:ring-primary/40",
                  item.card.completed && "opacity-60"
                ]}
              >
                <p class="truncate text-xs text-base-content/50">
                  {item.board.name} › {item.column.name}
                </p>
                <p class="line-clamp-3 font-medium">{item.card.title}</p>
                <.card_chips card={item.card} />
              </.link>
            </div>
          <% else %>
            <section :for={section <- @sections} id={"multiboard-#{section.key}"} class="mb-8">
              <h2 class="mb-2 flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-base-content/60">
                <span class={["size-2 rounded-full", Slipdock.Palette.dot(section.board.color)]}></span>
                <.link navigate={~p"/boards/#{section.board}"} class="hover:underline">
                  {section.label}
                </.link>
                <span class="badge badge-ghost badge-sm font-mono">{length(section.items)}</span>
              </h2>
              <p
                :if={section.items == []}
                class="rounded-2xl bg-base-100 px-4 py-3 text-sm text-base-content/50 ring-1 ring-base-content/10"
              >
                No cards.
              </p>
              <ul
                :if={section.items != []}
                class="divide-y divide-base-300/60 overflow-hidden rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/10"
              >
                <li
                  :for={item <- section.items}
                  id={"multiboard-card-#{item.card.id}"}
                  class={[
                    "flex items-center gap-3 px-4 py-2.5 hover:bg-base-200/40",
                    item.card.completed && "opacity-60"
                  ]}
                >
                  <span
                    :if={item.card.color}
                    class={["size-2 shrink-0 rounded-full", Slipdock.Palette.dot(item.card.color)]}
                  ></span>
                  <div class="min-w-0 flex-1">
                    <.link
                      navigate={~p"/boards/#{item.card.board_id}/cards/#{item.card.id}"}
                      class="block truncate font-medium hover:underline"
                    >
                      {item.card.title}
                    </.link>
                    <p :if={@view.by == "board"} class="truncate text-xs text-base-content/50">
                      {item.column.name}
                    </p>
                  </div>
                  <.card_chips card={item.card} />
                </li>
              </ul>
            </section>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :card, :map, required: true

  defp card_chips(assigns) do
    ~H"""
    <span class="flex flex-wrap items-center gap-1">
      <.tag_chip :for={tag <- @card.tags} tag={tag} size="xs" />
      <.flag_icon :for={flag <- @card.flags} flag={flag} class="size-3.5" />
      <.priority_badge priority={@card.priority} />
      <.schedule_badges card={@card} />
    </span>
    """
  end
end

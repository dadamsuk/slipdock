defmodule SlipdockWeb.BoardLive.ColumnComponent do
  @moduledoc """
  A list's settings: its name, WIP limit, meaning, horizon, the order and
  groups it draws its cards in, colour, what the foot of the list offers —
  and deleting it.

  Opened from the list's own menu, which targets this component
  (`#board-column`). It works out for itself whether the reader may write to
  the board it is given, and only ever acts on a list of that board.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.BoardLive.Helpers, only: [flash: 3]

  alias Slipdock.{Access, Boards, Dates, ListOrder, Palette}
  alias Slipdock.Boards.Column

  # The board's own settings that the dialog carries alongside the list's.
  @board_fields ~w(add_card add_page add_document)

  @events ~w(edit_column close_column save_column set_column_color delete_column)
  # Everything here changes the board, but closing the panel.
  @write_events @events -- ~w(close_column)

  @doc false
  # For the test that every `handle_event/3` clause is in the list.
  def events, do: @events

  @impl true
  def mount(socket), do: {:ok, assign(socket, column_modal: nil, column_form: nil)}

  @impl true
  def update(%{board: board, current_user: user}, socket) do
    perm = Access.board_permission(user, board)

    {:ok,
     assign(socket,
       board: board,
       can_write: Access.can_write?(perm),
       # What the foot of every list offers is the board's, not the list's,
       # and only its owner changes the board (as through the API).
       can_manage: perm == :owner
     )}
  end

  @impl true
  def handle_event(event, _params, socket) when event not in @events,
    do: {:noreply, flash(socket, :error, "That isn't something this page can do.")}

  def handle_event(event, _params, %{assigns: %{can_write: false}} = socket)
      when event in @write_events,
      do: {:noreply, flash(socket, :error, "You have read-only access to this board.")}

  def handle_event(event, params, socket), do: event(event, params, socket)

  defp event("edit_column", %{"id" => id}, socket) do
    case board_column(socket, id) do
      nil ->
        {:noreply, socket}

      column ->
        {:noreply,
         assign(socket, column_modal: column, column_form: to_form(Boards.change_column(column)))}
    end
  end

  defp event("close_column", _, socket), do: {:noreply, assign(socket, column_modal: nil)}

  # The list being edited was checked against the board when `edit_column`
  # opened it; without one open there is nothing to save.
  defp event("save_column", _params, %{assigns: %{column_modal: nil}} = socket),
    do: {:noreply, socket}

  defp event("save_column", %{"column" => params}, socket) do
    {board_params, params} = Map.split(params, @board_fields)
    params = Map.update(params, "wip_limit", nil, &if(&1 == "", do: nil, else: &1))

    case Boards.update_column(socket.assigns.column_modal, params) do
      {:ok, _} ->
        save_board_fields(socket, board_params)
        {:noreply, assign(socket, column_modal: nil)}

      {:error, cs} ->
        {:noreply, assign(socket, column_form: to_form(cs))}
    end
  end

  defp event("set_column_color", _params, %{assigns: %{column_modal: nil}} = socket),
    do: {:noreply, socket}

  defp event("set_column_color", %{"color" => color}, socket) do
    color = if color == "", do: nil, else: color
    {:ok, column} = Boards.update_column(socket.assigns.column_modal, %{"color" => color})
    {:noreply, assign(socket, column_modal: column)}
  end

  defp event("delete_column", %{"id" => id}, socket) do
    if column = board_column(socket, id), do: Boards.delete_column(column)
    {:noreply, assign(socket, column_modal: nil)}
  end

  defp save_board_fields(%{assigns: %{can_manage: true, board: board}}, params)
       when params != %{},
       do: Boards.update_board(Boards.get_board!(board.id), params)

  defp save_board_fields(_socket, _params), do: :ok

  # The list `id` on the open board, or nil.
  defp board_column(socket, id), do: Boards.get_board_column(socket.assigns.board.id, id)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-column">
      <.column_modal
        :if={@column_modal}
        column={@column_modal}
        form={@column_form}
        board={@board}
        can_manage={@can_manage}
        target={@myself}
      />
    </div>
    """
  end

  attr :column, Column, required: true
  attr :form, :any, required: true
  attr :board, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :target, :any, required: true

  defp column_modal(assigns) do
    ~H"""
    <.modal id="column-modal" on_close={JS.push("close_column", target: @target)} size="sm">
      <div class="space-y-5 p-6">
        <h2 class="text-lg font-semibold">List settings</h2>
        <.form
          phx-target={@target}
          for={@form}
          id="column-form"
          phx-submit="save_column"
          class="space-y-4"
        >
          <.input field={@form[:name]} label="Name" />
          <.input
            field={@form[:wip_limit]}
            type="number"
            min="1"
            label="WIP limit (leave empty for none)"
            placeholder="e.g. 3"
          />
          <.input
            field={@form[:category]}
            type="select"
            label="Meaning"
            options={Enum.map(Column.categories(), fn {k, l} -> {l, k} end)}
          />
          <p class="-mt-2 text-xs text-base-content/50">
            Cards dropped into a <em>Done</em> list are completed; a <em>Dropped</em> list takes
            them out of progress counts.
          </p>
          <div class="space-y-1.5 rounded-lg bg-base-200/60 p-3">
            <span class="text-sm font-medium">Horizon</span>
            <p class="text-xs text-base-content/50">
              The date range this list stands for. A card dropped here that isn't already
              inside the range is scheduled to its end.
            </p>
            <div class="grid grid-cols-2 gap-2">
              <.input field={@form[:horizon_from]} type="date" label="From" />
              <.input field={@form[:horizon_to]} type="date" label="To" />
            </div>
            <.input
              field={@form[:horizon_unit]}
              type="select"
              label="Schedule dropped cards to the"
              options={[{"Exact day", ""} | Enum.map(Dates.precisions(), fn {k, l} -> {l, k} end)]}
            />
          </div>
          <div class="space-y-1.5 rounded-lg bg-base-200/60 p-3">
            <span class="text-sm font-medium">Order</span>
            <p class="text-xs text-base-content/50">
              How this list draws its cards. Sorted, a list keeps itself in order and
              dragging only moves cards between lists; board order puts back the order
              they were dragged into.
            </p>
            <.input
              field={@form[:sort_by]}
              type="select"
              label="Sort by"
              options={Enum.map(ListOrder.sorts(), fn {k, l} -> {l, k} end)}
            />
            <.input
              field={@form[:sort_dir]}
              type="select"
              label="Direction"
              options={Enum.map(ListOrder.dirs(), fn {k, l} -> {l, k} end)}
            />
            <.input
              field={@form[:group_by]}
              type="select"
              label="Group by"
              options={Enum.map(ListOrder.groups(), fn {k, l} -> {l, k} end)}
            />
          </div>
          <%!-- What the foot of every list offers: the board's setting, so
                only its owner sees it. All three add something to the list;
                a board that never holds documents would rather not look at
                the button. --%>
          <div :if={@can_manage} class="space-y-1.5">
            <span class="text-sm font-medium">At the foot of every list</span>
            <label class="flex cursor-pointer items-center gap-2 text-sm">
              <.input
                id="column-add-card"
                name="column[add_card]"
                value={@board.add_card}
                type="checkbox"
              /> Add a card
            </label>
            <label class="flex cursor-pointer items-center gap-2 text-sm">
              <.input
                id="column-add-page"
                name="column[add_page]"
                value={@board.add_page}
                type="checkbox"
              /> Add a page — a wiki document, placed in the list
            </label>
            <label class="flex cursor-pointer items-center gap-2 text-sm">
              <.input
                id="column-add-document"
                name="column[add_document]"
                value={@board.add_document}
                type="checkbox"
              /> Add a document — a file, on a card of its own
            </label>
          </div>
          <div class="space-y-1.5">
            <span class="text-sm font-medium">Colour</span>
            <div class="flex flex-wrap gap-1.5">
              <button
                phx-target={@target}
                type="button"
                class={[
                  "flex size-6 items-center justify-center rounded-full ring-1 ring-base-content/20 ring-offset-2 ring-offset-base-100",
                  is_nil(@column.color) && "ring-2 ring-base-content"
                ]}
                phx-click="set_column_color"
                phx-value-color=""
                title="None"
              >
                <.icon name="hero-no-symbol" class="size-3.5 opacity-50" />
              </button>
              <.color_swatch
                :for={{name, _} <- Palette.all()}
                phx-target={@target}
                color={name}
                selected={@column.color == name}
                phx-click="set_column_color"
                phx-value-color={name}
              />
            </div>
          </div>
          <div class="flex items-center justify-between pt-2">
            <button
              phx-target={@target}
              type="button"
              class="btn btn-ghost btn-sm text-error"
              phx-click="delete_column"
              phx-value-id={@column.id}
              data-confirm={"Delete “#{@column.name}” and all of its cards?"}
            >
              <.icon name="hero-trash" class="size-4" /> Delete list
            </button>
            <button type="submit" class="btn btn-primary btn-sm">Save</button>
          </div>
        </.form>
      </div>
    </.modal>
    """
  end
end

defmodule SlipdockWeb.BoardLive.ViewEvents do
  @moduledoc """
  The events of the board's other views — swimlanes, table, timeline,
  calendar, outline, narrative and prioritise: the view configuration and
  saved views, dragging and dropping between cells and days, adding in a
  cell or on a day, editing in the table, scoring and voting.

  `BoardLive.Show` hands these over once its access guards have passed
  (`@board_write_events`, `@owner_events`, …), and every card or page an
  event names is still looked up on this board's tree and checked against
  what the reader may do with it (`BoardLive.State.writable_item/2` and
  friends) before it is touched.
  """
  use SlipdockWeb, :verified_routes

  import Phoenix.Component, only: [assign: 2, update: 3]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]
  import SlipdockWeb.BoardLive.Paths
  import SlipdockWeb.BoardLive.Helpers
  import SlipdockWeb.BoardLive.State

  alias Slipdock.{Boards, Fields, Swimlanes, Timeline, Votes}
  alias Slipdock.Boards.{Column, FieldDefinition}
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.Params

  @events ~w(swim_config swim_set swim_clear_filters table_sort table_update prio_field prio_vote
    timeline_move timeline_schedule cal_move cal_quick_add cal_toggle_day swim_toggle_row
    swim_move swim_start_add swim_cancel_add swim_quick_add swim_save_view swim_update_view
    swim_rename_view swim_publish_view swim_unpublish_view swim_delete_view)

  @doc "The events handled here."
  def events, do: @events

  @doc "Handles one of `events/0`, after the board's guards."
  def handle_event("swim_config", params, socket) do
    {:noreply, patch_swim(socket, Config.from_form(params, socket.assigns.swim))}
  end

  def handle_event("swim_set", %{"key" => key, "value" => value}, socket) do
    {:noreply, patch_swim(socket, Config.from_query(%{key => value}, socket.assigns.swim))}
  end

  def handle_event("swim_clear_filters", _, socket) do
    {:noreply, patch_swim(socket, Config.clear_filters(socket.assigns.swim))}
  end

  def handle_event("table_sort", %{"sort" => sort}, socket) do
    config = socket.assigns.swim

    config =
      if config.sort == sort,
        do: %{config | dir: if(config.dir == "asc", do: "desc", else: "asc")},
        else: %{config | sort: sort, dir: "asc"}

    {:noreply, patch_swim(socket, config)}
  end

  # The table's inline editors, which now set a placed wiki page's facets as
  # readily as a card's — the row sends `page-7` where a card sends a number.
  def handle_event("table_update", %{"card_id" => id, "field" => field, "value" => value}, socket)
      when field in ~w(priority start_date due_date percent_complete column_id) do
    case writable_item(socket, id) do
      {:ok, item} when item.board_id == socket.assigns.board.id ->
        case field do
          "column_id" ->
            if column_id = Params.id(value), do: move_in_list(item, column_id, nil)

          _ ->
            update_item(item, %{field => if(value == "", do: nil, else: value)})
        end

        {:noreply, reload_board(socket)}

      _ ->
        {:noreply, put_flash(socket, :error, "You have read-only access to that.")}
    end
  end

  # A scoring field edited in place; `value` "" clears it.
  def handle_event(
        "prio_field",
        %{"card_id" => id, "field_id" => field_id, "value" => value},
        socket
      ) do
    %{board: board} = socket.assigns

    with {:ok, item} <- writable_item(socket, id),
         %FieldDefinition{} = field <-
           Enum.find(board.fields, &(to_string(&1.id) == to_string(field_id))),
         {:ok, _} <- Fields.set_value(item, field, value) do
      {:noreply, socket}
    else
      {:error, message} when is_binary(message) -> {:noreply, put_flash(socket, :error, message)}
      nil -> {:noreply, put_flash(socket, :error, "That field no longer exists.")}
      _ -> {:noreply, put_flash(socket, :error, "You have read-only access to that card.")}
    end
  end

  def handle_event("prio_vote", %{"card_id" => id, "count" => count}, socket) do
    %{current_user: user} = socket.assigns

    case readable_item(socket, id) do
      {:ok, item} ->
        with count when is_integer(count) <- Params.int(count),
             {:ok, _} <- Votes.set(item, user, count) do
          {:noreply, socket}
        else
          nil -> {:noreply, socket}
          {:error, message} -> {:noreply, put_flash(socket, :error, message)}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "You don't have access to that card.")}
    end
  end

  # A bar was dragged: `edge` is "both", "start" or "end"; `delta` is in days.
  def handle_event("timeline_move", %{"id" => id, "edge" => edge, "delta" => delta}, socket)
      when edge in ~w(both start end) and is_integer(delta) do
    # Bars of subcards (nested rows) belong to boards deeper in the tree.
    with {:ok, card} <- writable_card(socket, id),
         true <- in_tree?(socket, card) do
      case Boards.update_card(card, Timeline.shift_attrs(card, edge, delta)) do
        {:ok, _} -> {:noreply, socket}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't move that card.")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "You have read-only access to that card.")}
    end
  end

  # An unscheduled card was dropped on the timeline: `day` is the column index
  # into the current window, and becomes the card's due date.
  def handle_event("timeline_schedule", %{"id" => id, "day" => day}, socket)
      when is_integer(day) do
    %{from: from, days: days} = socket.assigns.timeline.window

    with true <- day >= 0 and day < days,
         {:ok, card} when card.board_id == socket.assigns.board.id <- writable_card(socket, id),
         {:ok, _} <-
           Boards.update_card(card, Slipdock.Calendar.move_attrs(card, Date.add(from, day))) do
      {:noreply, socket}
    else
      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Couldn't schedule that card.")}

      :error ->
        {:noreply, put_flash(socket, :error, "You have read-only access to that card.")}

      _ ->
        {:noreply, socket}
    end
  end

  # A chip was dropped on a day (or back into the "no date" tray).
  def handle_event("cal_move", %{"id" => id, "to" => to}, socket) do
    with {:ok, item} when item.board_id == socket.assigns.board.id <- writable_item(socket, id),
         {:ok, attrs} <- cal_target(item, to, Slipdock.Calendar.place(socket.assigns.swim)),
         {:ok, _} <- update_item(item, attrs) do
      {:noreply, reload_board(socket)}
    else
      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Couldn't move that.")}

      :error ->
        {:noreply, put_flash(socket, :error, "You have read-only access to that.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cal_quick_add", %{"date" => date, "title" => title}, socket) do
    title = String.trim(title)

    with true <- title != "",
         {:ok, date} <- Date.from_iso8601(date),
         %Column{} = column <- List.first(socket.assigns.board.columns) do
      date_field =
        if Slipdock.Calendar.place(socket.assigns.swim) == "start",
          do: "start_date",
          else: "due_date"

      case Boards.create_card(column, %{"title" => title, date_field => date}) do
        {:ok, _} -> {:noreply, socket |> assign(swim_adding: nil) |> update(:form_key, &(&1 + 1))}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't add that card.")}
      end
    else
      nil -> {:noreply, put_flash(socket, :error, "Add a list to the board first.")}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cal_toggle_day", %{"key" => key}, socket) do
    expanded = socket.assigns.cal_expanded

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, assign(socket, cal_expanded: expanded)}
  end

  def handle_event("swim_toggle_row", %{"key" => key}, socket) do
    collapsed = socket.assigns.swim_collapsed

    collapsed =
      if MapSet.member?(collapsed, key),
        do: MapSet.delete(collapsed, key),
        else: MapSet.put(collapsed, key)

    {:noreply, assign(socket, swim_collapsed: collapsed)}
  end

  def handle_event("swim_move", %{"id" => id, "from" => from, "to" => to} = params, socket) do
    %{swim: config, grid: grid} = socket.assigns

    with {:ok, {from_row, from_col}} <- cell_keys(grid, from),
         {:ok, {to_row, to_col}} <- cell_keys(grid, to),
         {:ok, item} <- load_item(socket.assigns.board, id) do
      ops =
        Swimlanes.move_ops(config.rows, item, from_row, to_row, config) ++
          Swimlanes.move_ops(config.cols, item, from_col, to_col, config)

      {:noreply, apply_swim_ops(socket, item, ops, params["before"])}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("swim_start_add", %{"cell" => cell}, socket) do
    {:noreply, assign(socket, swim_adding: cell)}
  end

  def handle_event("swim_cancel_add", _, socket), do: {:noreply, assign(socket, swim_adding: nil)}

  def handle_event("swim_quick_add", %{"cell" => cell, "title" => title}, socket) do
    %{swim: config, grid: grid, board: board} = socket.assigns
    title = String.trim(title)

    with true <- title != "",
         {:ok, {row_key, col_key}} <- cell_keys(grid, cell),
         %Column{} = column <- swim_add_column(board, config, row_key, col_key) do
      ops =
        Swimlanes.move_ops(config.rows, nil, nil, row_key, config) ++
          Swimlanes.move_ops(config.cols, nil, nil, col_key, config)

      attrs = Map.put(swim_attrs(ops), "title", title)

      case Boards.create_card(column, attrs) do
        {:ok, card} ->
          if tag_ids = swim_tag_ids(ops),
            do: Boards.set_card_tags(card, board_tags(board, tag_ids))

          {:noreply, update(socket, :form_key, &(&1 + 1))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Couldn't add that card.")}
      end
    else
      nil -> {:noreply, put_flash(socket, :error, "Add a list to the board first.")}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("swim_save_view", %{"name" => name}, socket) do
    %{board: board, swim: config} = socket.assigns

    config = %{config | mode: mode_name(socket)}

    case Boards.create_saved_view(board, %{"name" => name, "config" => Config.to_map(config)}) do
      {:ok, view} ->
        {:noreply,
         socket
         |> update(:form_key, &(&1 + 1))
         |> reload_board()
         |> push_patch(to: mode_path(socket.assigns, view: view.id))}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, view_error(cs))}
    end
  end

  def handle_event("swim_update_view", _, %{assigns: %{swim_view: %{} = view}} = socket) do
    config = %{socket.assigns.swim | mode: mode_name(socket)}
    {:ok, view} = Boards.update_saved_view(view, %{"config" => Config.to_map(config)})

    {:noreply,
     socket
     |> put_flash(:info, "View “#{view.name}” updated.")
     |> reload_board()
     |> push_patch(to: mode_path(socket.assigns, view: view.id))}
  end

  def handle_event(
        "swim_rename_view",
        %{"name" => name},
        %{assigns: %{swim_view: %{} = view}} = socket
      ) do
    case Boards.update_saved_view(view, %{"name" => name}) do
      {:ok, _} -> {:noreply, socket}
      {:error, cs} -> {:noreply, put_flash(socket, :error, view_error(cs))}
    end
  end

  def handle_event("swim_publish_view", _, %{assigns: %{swim_view: %{} = view}} = socket) do
    {:ok, _} = Boards.publish_saved_view(view)
    {:noreply, put_flash(socket, :info, "Published. Anyone with the link can read this view.")}
  end

  def handle_event("swim_unpublish_view", _, %{assigns: %{swim_view: %{} = view}} = socket) do
    {:ok, _} = Boards.unpublish_saved_view(view)
    {:noreply, put_flash(socket, :info, "The public link no longer works.")}
  end

  def handle_event("swim_delete_view", _, %{assigns: %{swim_view: %{} = view}} = socket) do
    config = socket.assigns.swim
    {:ok, _} = Boards.delete_saved_view(view)
    defaults = Config.defaults(mode_name(socket))

    {:noreply,
     socket
     |> reload_board()
     |> push_patch(to: mode_path(socket.assigns, Config.to_query(config, defaults)))}
  end

  # A saved view's own events, with no saved view loaded: nothing to act on.
  def handle_event(event, _, socket)
      when event in ~w(swim_update_view swim_rename_view swim_delete_view swim_publish_view
                       swim_unpublish_view) do
    {:noreply, socket}
  end

  defp cal_target(_card, "none", _place), do: {:ok, %{"start_date" => nil, "due_date" => nil}}

  defp cal_target(card, iso, place) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> {:ok, Slipdock.Calendar.move_attrs(card, date, place)}
      _ -> :invalid
    end
  end

  # "row:col" cell ids from the grid -> the bucket keys on each axis.
  defp cell_keys(%{rows: rows, cols: cols}, cell) when is_binary(cell) do
    with [r, c] <- String.split(cell, ":"),
         {ri, ""} when ri >= 0 <- Integer.parse(r),
         {ci, ""} when ci >= 0 <- Integer.parse(c),
         %{key: row_key} <- Enum.at(rows, ri),
         %{key: col_key} <- Enum.at(cols, ci) do
      {:ok, {row_key, col_key}}
    else
      _ -> :error
    end
  end

  defp cell_keys(_, _), do: :error

  defp apply_swim_ops(socket, item, ops, before) do
    case Enum.find(ops, &match?({:error, _}, &1)) do
      {:error, message} ->
        put_flash(socket, :error, message)

      nil ->
        %{board: board, swim: config} = socket.assigns

        column_id =
          Enum.find_value(ops, fn
            {:column, id} -> id
            _ -> nil
          end)

        cond do
          # Dropping between two things is only meaningful in board order.
          config.sort == "position" ->
            move_in_list(item, column_id || item.column_id, before)

          column_id ->
            move_in_list(item, column_id, nil)

          true ->
            :ok
        end

        attrs = swim_attrs(ops)
        if attrs != %{}, do: update_item(item, attrs)
        if tag_ids = swim_tag_ids(ops), do: set_item_tags(item, board_tags(board, tag_ids))

        Enum.reduce(ops, socket, fn
          # Custom fields are a card's; a page has none, so dropping one on a
          # custom-field axis moves it and leaves the value alone rather than
          # inventing somewhere to put it.
          {:field, id, raw}, socket ->
            with false <- SlipdockWeb.SlipdockComponents.page?(item),
                 %{} = field <- Enum.find(board.fields, &(&1.id == id)) do
              case Fields.set_value(Boards.get_card!(item.id), field, raw) do
                {:ok, _} -> socket
                {:error, message} -> put_flash(socket, :error, message)
              end
            else
              _ -> socket
            end

          _, socket ->
            socket
        end)
    end
  end

  # The list a card added inside a cell should land in: the list on the
  # column/row axis if there is one, otherwise the first list on the board.
  defp swim_add_column(board, config, row_key, col_key) do
    key =
      cond do
        config.cols == "column" -> col_key
        config.rows == "column" -> row_key
        true -> nil
      end

    case key && Enum.find(board.columns, &(to_string(&1.id) == key)) do
      %Column{} = column -> column
      _ -> List.first(board.columns)
    end
  end
end

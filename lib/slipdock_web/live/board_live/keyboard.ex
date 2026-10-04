defmodule SlipdockWeb.BoardLive.Keyboard do
  @moduledoc """
  The keyboard's place on the board view.

  One notion covers both keyboard moves and stepping through a list: the
  focus is a list, a card in it, and whether that card is being carried.
  "c" puts the focus on a list, "J" puts it on a card and picks it up, and
  the arrows then either walk the focus or carry the card with it.

  `BoardLive.Show` hands these events over once its guards have passed:
  carrying a card moves it, which needs write access to the board
  (`focus_move`, `focus_hold` and `focus_add` are board writes there), and
  only ever moves a card the board view is showing.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_patch: 2]
  import SlipdockWeb.BoardLive.Paths
  import SlipdockWeb.BoardLive.Helpers, only: [to_int: 1]

  alias Slipdock.Boards
  alias Slipdock.Boards.Card

  @events ~w(focus_column focus_card focus_hold focus_add focus_open focus_end focus_move)

  @doc "The events handled here."
  def events, do: @events

  @doc "Handles one of `events/0`, after the board's guards."
  def handle_event("focus_column", %{"id" => id}, %{assigns: %{mode: :board}} = socket) do
    case Enum.find(socket.assigns.columns, &(&1.column.id == to_int(id))) do
      %{column: column, cards: cards} ->
        {:noreply, put_focus(socket, column.id, card_id(List.first(cards)), false)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("focus_card", %{"id" => id} = params, %{assigns: %{mode: :board}} = socket) do
    %{columns: columns} = socket.assigns
    id = to_int(id)

    case id && locate_card(columns, id) do
      {ci, _index} ->
        %{column: column} = Enum.at(columns, ci)
        {:noreply, put_focus(socket, column.id, id, params["hold"] == true)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(event, _params, socket) when event in ~w(focus_column focus_card),
    do: {:noreply, socket}

  def handle_event("focus_hold", _params, socket) do
    case socket.assigns.focus do
      %{card_id: id} = focus when not is_nil(id) ->
        {:noreply, assign(socket, focus: %{focus | holding?: true})}

      _ ->
        {:noreply, socket}
    end
  end

  # "c" again, with the keyboard on a list: open that list's add-a-card row and
  # let go of the board, since the input takes the keyboard from here.
  def handle_event("focus_add", _params, socket) do
    case socket.assigns.focus do
      %{column_id: id} -> {:noreply, assign(socket, adding_to: id, focus: nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("focus_open", _params, socket) do
    case socket.assigns.focus do
      %{card_id: id} when not is_nil(id) ->
        {:noreply, push_patch(socket, to: card_path(socket.assigns, id))}

      _ ->
        {:noreply, socket}
    end
  end

  # Escape, and Enter on a card being carried: put the card down, or — when
  # the keyboard was only pointing at it — leave the board alone entirely.
  def handle_event("focus_end", _params, socket) do
    focus =
      case socket.assigns.focus do
        %{holding?: true} = focus -> %{focus | holding?: false}
        _ -> nil
      end

    {:noreply, assign(socket, focus: focus)}
  end

  # Each arrow moves a carried card for real, so the board the user is looking
  # at is always the board as it stands; a card only pointed at stays put and
  # the focus walks instead.
  def handle_event("focus_move", %{"dir" => dir}, socket)
      when dir in ~w(left right up down) do
    %{columns: columns, focus: focus} = socket.assigns
    {:noreply, assign(socket, focus: move_focus(columns, focus, dir))}
  end

  defp put_focus(socket, column_id, card_id, holding?) do
    assign(socket,
      focus: %{
        column_id: column_id,
        card_id: card_id,
        holding?: holding? and socket.assigns.can_write
      }
    )
  end

  defp move_focus(_columns, nil, _dir), do: nil

  # Carrying: the card moves and the focus goes with it.
  defp move_focus(columns, %{holding?: true, card_id: id} = focus, dir) when not is_nil(id) do
    case locate_card(columns, id) do
      {ci, index} ->
        nudge_card(columns, id, ci, index, dir)
        %{column: column} = Enum.at(columns, sidestep(ci, dir, length(columns)))
        %{focus | column_id: column.id}

      _ ->
        focus
    end
  end

  # Pointing: up and down walk the cards of the list, left and right step to
  # the list either side, keeping as close to the same place in it as it has.
  defp move_focus(columns, focus, dir) do
    case Enum.find_index(columns, &(&1.column.id == focus.column_id)) do
      nil ->
        nil

      ci ->
        index = card_index(Enum.at(columns, ci).cards, focus.card_id)
        ci = sidestep(ci, dir, length(columns))
        %{column: column, cards: cards} = Enum.at(columns, ci)

        index =
          case dir do
            "up" -> max(index - 1, 0)
            "down" -> index + 1
            _ -> index
          end

        index = min(index, max(length(cards) - 1, 0))
        %{focus | column_id: column.id, card_id: card_id(Enum.at(cards, index))}
    end
  end

  defp sidestep(ci, "left", _count), do: max(ci - 1, 0)

  defp sidestep(ci, "right", count), do: min(ci + 1, count - 1)

  defp sidestep(ci, _dir, _count), do: ci

  defp card_index(_cards, nil), do: 0

  defp card_index(cards, id), do: Enum.find_index(cards, &(&1.id == id)) || 0

  # Where a card sits on the board as the user sees it: the index of its list,
  # and its index among the cards that list is actually showing.
  defp locate_card(columns, id) do
    columns
    |> Enum.with_index()
    |> Enum.find_value(fn {%{cards: cards}, ci} ->
      case Enum.find_index(cards, &(&1.id == id)) do
        nil -> nil
        index -> {ci, index}
      end
    end)
  end

  # Left and right carry the card into the neighbouring list, keeping its place
  # in the order as closely as the shorter list allows; up and down shuffle it
  # one place within its own list. Both stop at the ends rather than wrapping.
  defp nudge_card(columns, id, ci, index, "left") when ci > 0,
    do: drop_into(columns, id, ci - 1, index)

  defp nudge_card(columns, id, ci, index, "right") when ci < length(columns) - 1,
    do: drop_into(columns, id, ci + 1, index)

  defp nudge_card(columns, id, ci, index, "up") when index > 0,
    do: reorder_within(columns, id, ci, index - 1)

  defp nudge_card(columns, id, ci, index, "down"),
    do: reorder_within(columns, id, ci, index + 1)

  defp nudge_card(_columns, _id, _ci, _index, _dir), do: :ok

  defp drop_into(columns, id, ci, index) do
    %{column: column, cards: cards} = Enum.at(columns, ci)
    Boards.move_card(id, column.id, before_id(cards, index))
  end

  # The card is already in this list, so it has to come out of the order before
  # the target index means what it looks like it means.
  defp reorder_within(columns, id, ci, index) do
    %{column: column, cards: cards} = Enum.at(columns, ci)
    Boards.move_card(id, column.id, before_id(Enum.reject(cards, &(&1.id == id)), index))
  end

  # The card the moved one lands in front of; nil parks it at the end.
  defp before_id(cards, index), do: card_id(Enum.at(cards, index))

  defp card_id(%Card{id: id}), do: id

  defp card_id(_), do: nil

  @doc "The title of the card the keyboard is on, for the strip that says so."
  def focus_title(_columns, nil), do: nil

  def focus_title(columns, %{card_id: id}) do
    Enum.find_value(columns, fn %{cards: cards} ->
      Enum.find_value(cards, &(&1.id == id && &1.title))
    end)
  end
end

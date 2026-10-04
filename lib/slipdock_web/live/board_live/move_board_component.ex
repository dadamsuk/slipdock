defmodule SlipdockWeb.BoardLive.MoveBoardComponent do
  @moduledoc """
  Moving a card to another board.

  Dragging cannot cross a board — the other board is not on screen — so the
  only way there was to retype the card and delete the original, which loses
  its comments, its history and its subcards. This is a picker: the boards
  you can write to, then that board's lists.

  Boards the user can write to means root boards: a sub-board is reached
  through its card, and moving a card *into* someone's subcards is a
  different intent from moving it to another board.

  Opened from a card's move menu, which targets this component
  (`#board-move`). Every card and board named by id is checked against what
  the reader may write; nothing is taken from the parent but who is asking.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.BoardLive.Helpers, only: [flash: 3]

  alias Slipdock.{Access, Boards, Palette}
  alias Slipdock.Boards.Board
  alias SlipdockWeb.Params

  @events ~w(open_move_board close_move_board move_board_pick move_card_board)

  @doc false
  # For the test that every `handle_event/3` clause is in the list.
  def events, do: @events

  @impl true
  def mount(socket), do: {:ok, assign(socket, move_board: nil, moving: false)}

  @impl true
  def update(assigns, socket) do
    {:ok,
     assign(socket,
       current_user: assigns.current_user,
       # Followed to its new board when it is the card open in the panel.
       open_card_id: assigns.open_card_id
     )}
  end

  @impl true
  def handle_event(event, params, socket) when event in @events do
    {:noreply, socket} = event(event, params, socket)
    {:noreply, tell_moving(socket)}
  end

  def handle_event(_event, _params, socket),
    do: {:noreply, flash(socket, :error, "That isn't something this page can do.")}

  # The card panel stands aside while the picker is open, so the board is
  # told when it opens and closes.
  defp tell_moving(socket) do
    moving = not is_nil(socket.assigns.move_board)
    if moving != socket.assigns.moving, do: send(self(), {:moving_board, moving})
    assign(socket, moving: moving)
  end

  defp event("open_move_board", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    card = Boards.get_card(Params.id(id))

    cond do
      is_nil(card) ->
        {:noreply, socket}

      not Access.can_write?(Access.card_permission(user, card)) ->
        {:noreply, flash(socket, :error, "You have read-only access to that card.")}

      true ->
        boards =
          user
          |> Access.list_boards()
          |> Enum.filter(
            &(&1.id != card.board_id and Access.can_write?(Access.board_permission(user, &1)))
          )

        {:noreply, assign(socket, move_board: %{card: card, boards: boards, target: nil})}
    end
  end

  defp event("close_move_board", _params, socket),
    do: {:noreply, assign(socket, move_board: nil)}

  defp event("move_board_pick", %{"id" => id}, %{assigns: %{move_board: %{} = m}} = socket) do
    target =
      case Enum.find(m.boards, &(to_string(&1.id) == id)) do
        nil -> nil
        board -> Boards.get_board!(board.id)
      end

    {:noreply, assign(socket, move_board: %{m | target: target})}
  end

  defp event(
         "move_card_board",
         %{"column" => column_id},
         %{assigns: %{move_board: %{card: card, target: %Board{} = target}}} = socket
       ) do
    user = socket.assigns.current_user
    column = Enum.find(target.columns, &(to_string(&1.id) == column_id))

    cond do
      is_nil(column) ->
        {:noreply, socket}

      not Access.can_write?(Access.board_permission(user, target)) ->
        {:noreply, flash(socket, :error, "You have read-only access to that board.")}

      true ->
        case Boards.move_card_to_board(card, column) do
          {:ok, summary} ->
            {:noreply,
             socket
             |> assign(move_board: nil)
             |> after_move(card, summary, moved_message(card, target, column, summary))}

          {:error, %Ecto.Changeset{} = refused} ->
            {:noreply,
             socket
             |> assign(move_board: nil)
             |> flash(:error, Slipdock.Quota.refusal_message(refused))}

          {:error, message} ->
            {:noreply, socket |> assign(move_board: nil) |> flash(:error, message)}
        end
    end
  end

  defp event("move_card_board", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-move">
      <.move_board_modal :if={@move_board} move={@move_board} target={@myself} />
    </div>
    """
  end

  # The card is not on this board any more. If it was open, follow it; the
  # alternative is a modal showing a card that is somewhere else now. A flash
  # travels with a navigation from here, and only with one.
  defp after_move(socket, card, summary, message) do
    if socket.assigns.open_card_id == card.id do
      socket
      |> put_flash(:info, message)
      |> push_navigate(to: ~p"/boards/#{summary.card.board_id}/cards/#{card.id}")
    else
      flash(socket, :info, message)
    end
  end

  # Honest about what did not survive the crossing: tags and fields belong to
  # a board, and the far side may not have had them.
  defp moved_message(card, board, column, summary) do
    notes =
      [
        {summary.tags_created, "tag", "added to #{board.name}"},
        {summary.fields_dropped, "field value", "dropped"},
        {summary.milestones_unpinned, "milestone", "unpinned"}
      ]
      |> Enum.reject(fn {n, _, _} -> n == 0 end)
      |> Enum.map_join(", ", fn {n, noun, what} ->
        "#{n} #{noun}#{if n == 1, do: "", else: "s"} #{what}"
      end)

    base = "Moved “#{card.title}” to #{board.name} › #{column.name}."
    if notes == "", do: base, else: base <> " " <> notes <> "."
  end

  attr :move, :map, required: true
  attr :target, :any, required: true

  @doc false
  # "Move to another board": the boards you can write to, then that board's
  # lists. Two taps, and the same two on a phone, where this is the only way
  # to do it at all — dragging cannot cross a board, because the other board
  # is not on the screen.
  #
  # What travels is said here rather than found out afterwards: subcards,
  # comments and history always; tags by name; custom fields only where the
  # other board has the same one.
  defp move_board_modal(assigns) do
    ~H"""
    <.modal id="move-board-modal" on_close={JS.push("close_move_board", target: @target)} size="sm">
      <div class="space-y-4 p-6">
        <div>
          <h2 class="pr-8 text-lg font-bold">Move to another board</h2>
          <p class="mt-0.5 truncate text-sm text-base-content/60">{@move.card.title}</p>
        </div>

        <p :if={@move.boards == []} class="text-sm text-base-content/60">
          There is no other board you can write to.
        </p>

        <div :if={@move.boards != [] and is_nil(@move.target)} class="space-y-1.5">
          <p class="text-2xs font-semibold uppercase tracking-wide text-base-content/60">Board</p>
          <ul class="kanban-scroll max-h-[50vh] divide-y divide-base-300/60 overflow-y-auto rounded-xl ring-1 ring-base-content/10">
            <li :for={board <- @move.boards}>
              <button
                phx-target={@target}
                type="button"
                phx-click="move_board_pick"
                phx-value-id={board.id}
                class="flex w-full items-center gap-2.5 px-3 py-2.5 text-left text-sm hover:bg-base-200/60"
              >
                <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(board.color)]}></span>
                <span class="min-w-0 flex-1 truncate font-medium">{board.name}</span>
                <.icon name="hero-chevron-right" class="size-4 shrink-0 text-base-content/30" />
              </button>
            </li>
          </ul>
        </div>

        <div :if={@move.target} class="space-y-1.5">
          <button
            phx-target={@target}
            type="button"
            phx-click="move_board_pick"
            phx-value-id=""
            class="flex items-center gap-1 text-2xs font-semibold uppercase tracking-wide text-base-content/60 hover:text-base-content"
          >
            <.icon name="hero-chevron-left" class="size-3.5" /> {@move.target.name} · list
          </button>
          <p :if={@move.target.columns == []} class="text-sm text-warning">
            That board has no lists yet.
          </p>
          <ul class="kanban-scroll max-h-[50vh] divide-y divide-base-300/60 overflow-y-auto rounded-xl ring-1 ring-base-content/10">
            <li :for={column <- @move.target.columns}>
              <button
                phx-target={@target}
                type="button"
                phx-click="move_card_board"
                phx-value-column={column.id}
                class="flex w-full items-center gap-2.5 px-3 py-2.5 text-left text-sm hover:bg-base-200/60"
              >
                <span
                  :if={column.color}
                  class={["size-2 shrink-0 rounded-full", Palette.dot(column.color)]}
                ></span>
                <span class="min-w-0 flex-1 truncate">{column.name}</span>
                <.icon name="hero-arrow-right-circle" class="size-4 shrink-0 text-base-content/30" />
              </button>
            </li>
          </ul>
        </div>

        <p class="text-2xs leading-relaxed text-base-content/50">
          Subcards, comments and history go with the card. Tags travel by name, and are made on
          the other board where they are new. Custom fields survive only where that board has the
          same field; a pinned milestone stays behind.
        </p>
      </div>
    </.modal>
    """
  end
end

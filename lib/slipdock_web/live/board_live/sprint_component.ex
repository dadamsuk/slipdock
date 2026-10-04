defmodule SlipdockWeb.BoardLive.SprintComponent do
  @moduledoc """
  Sprints, from a board: New sprint, the picker that fills a sprint with
  cards from the boards the person can write to, and the sprint charts.

  On a sprint board (`Board.sprints?/1`) New sprint makes the next sprint
  card, and Add cards… on a sprint opens a picker over the boards the person
  can write to: tick cards list by list — stepping into a card's subcards
  where the work is broken down — and they are all moved into the sprint at
  once. The ticks survive switching boards, so one sitting can draw from
  several; and the picker opens again whenever there is more to add.

  The buttons that open these live on the board's header and the card panel
  and target this component (`#board-sprints`). It works out the reader's
  access to the board for itself, and checks every card and sprint named by
  id against what that reader may write.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.SprintChartComponents
  import SlipdockWeb.BoardLive.Helpers, only: [flash: 3]

  alias Slipdock.{Access, Boards, Palette, Sprints}
  alias Slipdock.Boards.{Board, Card}
  alias SlipdockWeb.Params

  @events ~w(open_new_sprint close_new_sprint create_sprint open_sprint_picker close_sprint_picker
    sprint_source sprint_into sprint_up sprint_toggle sprint_toggle_list sprint_clear sprint_add
    open_sprint_charts close_sprint_charts pick_chart_sprint)

  @doc false
  # For the test that every `handle_event/3` clause is in the list.
  def events, do: @events

  @impl true
  def mount(socket) do
    {:ok, assign(socket, new_sprint: nil, sprint_picker: nil, sprint_charts: nil, picking: false)}
  end

  @impl true
  def update(assigns, socket) do
    %{board: board, current_user: user} = assigns
    perm = Access.board_permission(user, board)

    {:ok,
     assign(socket,
       board: board,
       current_user: user,
       can_write: Access.can_write?(perm),
       # A guest shown one card has not been shown the board's sprints.
       card_only: perm == :none
     )}
  end

  @impl true
  def handle_event(event, params, socket) when event in @events do
    {:noreply, socket} = event(event, params, socket)
    {:noreply, tell_picking(socket)}
  end

  def handle_event(_event, _params, socket),
    do: {:noreply, flash(socket, :error, "That isn't something this page can do.")}

  # The card panel stands aside while the picker is open (see the board's
  # render), so the board is told when it opens and closes.
  defp tell_picking(socket) do
    picking = not is_nil(socket.assigns.sprint_picker)

    if picking != socket.assigns.picking,
      do: send(self(), {:sprint_picking, picking})

    assign(socket, picking: picking)
  end

  # On a sprint board (`Board.sprints?/1`) New sprint makes the next sprint
  # card, and Add cards… on a sprint opens a picker over the boards the person
  # can write to: tick cards list by list — stepping into a card's subcards
  # where the work is broken down — and they are all moved into the sprint at
  # once. The ticks survive switching boards, so one sitting can draw from
  # several; and the picker opens again whenever there is more to add.

  defp event("open_new_sprint", _params, socket) do
    board = socket.assigns.board

    if socket.assigns.can_write and Board.sprints?(board) do
      next = Sprints.next_sprint(board)

      form =
        to_form(
          %{
            "name" => next.name,
            "start" => Date.to_iso8601(next.start),
            "days" => to_string(next.days),
            "goal" => ""
          },
          as: :sprint
        )

      {:noreply, assign(socket, new_sprint: %{form: form, error: nil})}
    else
      {:noreply, socket}
    end
  end

  defp event("close_new_sprint", _params, socket),
    do: {:noreply, assign(socket, new_sprint: nil)}

  defp event("create_sprint", %{"sprint" => params}, socket) do
    user = socket.assigns.current_user

    if socket.assigns.can_write do
      case Sprints.create_sprint(socket.assigns.board, params, by: user) do
        {:ok, sprint} ->
          {:noreply,
           socket
           |> assign(new_sprint: nil)
           |> flash(:info, "#{sprint.title} is ready. Pick the cards that go in it.")
           |> open_sprint_picker(sprint)}

        {:error, error} ->
          form = to_form(params, as: :sprint)

          {:noreply,
           assign(socket, new_sprint: %{form: form, error: Sprints.error_message(error)})}
      end
    else
      {:noreply, flash(socket, :error, "You have read-only access to this board.")}
    end
  end

  defp event("open_sprint_picker", %{"id" => id}, socket) do
    card = Boards.get_card(Params.id(id))
    user = socket.assigns.current_user

    cond do
      is_nil(card) ->
        {:noreply, socket}

      not Access.can_write?(Access.card_permission(user, card)) ->
        {:noreply, flash(socket, :error, "You have read-only access to that sprint.")}

      not Sprints.sprint?(card) ->
        {:noreply, flash(socket, :error, "That card is not a sprint.")}

      true ->
        {:noreply, open_sprint_picker(socket, card)}
    end
  end

  defp event("close_sprint_picker", _params, socket),
    do: {:noreply, assign(socket, sprint_picker: nil)}

  # A board from the list: the start of a fresh path into it.
  defp event("sprint_source", %{"id" => id}, %{assigns: %{sprint_picker: %{} = p}} = socket) do
    case Enum.find(p.boards, &(to_string(&1.id) == id)) do
      nil -> {:noreply, assign(socket, sprint_picker: %{p | path: [], lists: []})}
      board -> {:noreply, assign(socket, sprint_picker: sprint_path(p, [board]))}
    end
  end

  # Into a card's subcards — only one offered by the list on screen, so the
  # path never leaves the boards the person was shown.
  defp event("sprint_into", %{"id" => id}, %{assigns: %{sprint_picker: %{} = p}} = socket) do
    offered =
      p.lists |> Enum.flat_map(& &1.cards) |> Enum.find(&(to_string(&1.sub_board_id) == id))

    case offered && Boards.get_board(offered.sub_board_id) do
      %Board{} = board ->
        {:noreply, assign(socket, sprint_picker: sprint_path(p, p.path ++ [board]))}

      _ ->
        {:noreply, socket}
    end
  end

  defp event("sprint_up", _params, %{assigns: %{sprint_picker: %{} = p}} = socket) do
    case Enum.drop(p.path, -1) do
      [] -> {:noreply, assign(socket, sprint_picker: %{p | path: [], lists: []})}
      path -> {:noreply, assign(socket, sprint_picker: sprint_path(p, path))}
    end
  end

  defp event("sprint_toggle", %{"id" => id}, %{assigns: %{sprint_picker: %{} = p}} = socket) do
    card =
      p.lists
      |> Enum.flat_map(& &1.cards)
      |> Enum.find(&(to_string(&1.id) == id and &1.pickable))

    selected =
      cond do
        is_nil(card) -> p.selected
        Map.has_key?(p.selected, card.id) -> Map.delete(p.selected, card.id)
        true -> Map.put(p.selected, card.id, card.title)
      end

    {:noreply, assign(socket, sprint_picker: %{p | selected: selected})}
  end

  defp event(
         "sprint_toggle_list",
         %{"id" => id},
         %{assigns: %{sprint_picker: %{} = p}} = socket
       ) do
    cards =
      case Enum.find(p.lists, &(to_string(&1.id) == id)) do
        nil -> []
        list -> Enum.filter(list.cards, & &1.pickable)
      end

    selected =
      if cards != [] and Enum.all?(cards, &Map.has_key?(p.selected, &1.id)),
        do: Map.drop(p.selected, Enum.map(cards, & &1.id)),
        else: Map.merge(p.selected, Map.new(cards, &{&1.id, &1.title}))

    {:noreply, assign(socket, sprint_picker: %{p | selected: selected})}
  end

  defp event("sprint_clear", _params, %{assigns: %{sprint_picker: %{} = p}} = socket),
    do: {:noreply, assign(socket, sprint_picker: %{p | selected: %{}})}

  defp event("sprint_add", _params, %{assigns: %{sprint_picker: %{} = p}} = socket) do
    user = socket.assigns.current_user

    cards =
      p.selected
      |> Map.keys()
      |> Enum.map(&Boards.get_card/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&Access.can_write?(Access.card_permission(user, &1)))

    case Sprints.add_cards(p.sprint, cards) do
      {:ok, %{added: added, skipped: skipped}} ->
        {:noreply,
         socket
         |> assign(sprint_picker: nil)
         |> flash(
           if(added == [] and skipped != [], do: :error, else: :info),
           sprint_added_message(p.sprint, added, skipped)
         )}

      {:error, message} ->
        {:noreply, flash(socket, :error, message)}
    end
  end

  defp event("sprint_" <> _, _params, socket), do: {:noreply, socket}

  # Charts: on a sprint board, velocity across its sprints and the burndown of
  # one of them (the running one first); on a sprint's own board, its burndown.
  # A guest shown one card has not been shown the board's sprints either.
  defp event("open_sprint_charts", _params, %{assigns: %{card_only: true}} = socket),
    do: {:noreply, socket}

  defp event("open_sprint_charts", _params, socket) do
    board = socket.assigns.board

    charts =
      cond do
        Board.sprints?(board) ->
          sprint = Sprints.current_sprint(board)

          %{
            velocity: Sprints.velocity(board),
            burndown: sprint && Sprints.burndown(sprint),
            sprint_id: sprint && sprint.id
          }

        sprint = Sprints.sprint_of_board(board) ->
          %{velocity: nil, burndown: Sprints.burndown(sprint), sprint_id: sprint.id}

        true ->
          nil
      end

    {:noreply, assign(socket, sprint_charts: charts)}
  end

  defp event("close_sprint_charts", _params, socket),
    do: {:noreply, assign(socket, sprint_charts: nil)}

  defp event(
         "pick_chart_sprint",
         %{"sprint" => id},
         %{assigns: %{sprint_charts: %{velocity: %{} = v} = charts}} = socket
       ) do
    with {id, ""} <- Integer.parse(id),
         true <- Enum.any?(v.sprints, &(&1.id == id)),
         %Card{} = sprint <- Boards.get_card(id) do
      {:noreply,
       assign(socket,
         sprint_charts: %{charts | burndown: Sprints.burndown(sprint), sprint_id: id}
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  defp event("pick_chart_sprint", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-sprints">
      <.new_sprint_modal :if={@new_sprint} new_sprint={@new_sprint} board={@board} target={@myself} />
      <.sprint_picker_modal :if={@sprint_picker} picker={@sprint_picker} target={@myself} />
      <.sprint_charts_modal :if={@sprint_charts} charts={@sprint_charts} target={@myself} />
    </div>
    """
  end

  defp open_sprint_picker(socket, %Card{} = sprint) do
    boards = Sprints.source_boards(socket.assigns.current_user, sprint)
    picker = %{sprint: sprint, boards: boards, path: [], lists: [], selected: %{}}

    # Straight into the board the sprint is planned from when there is only
    # one other to choose.
    picker =
      case Enum.reject(boards, &Board.sprints?/1) do
        [only] -> sprint_path(picker, [only])
        _ -> picker
      end

    assign(socket, sprint_picker: picker)
  end

  defp sprint_path(picker, path),
    do: %{picker | path: path, lists: Sprints.candidates(List.last(path), picker.sprint)}

  defp sprint_added_message(sprint, added, skipped) do
    n = length(added)

    base =
      if n == 0,
        do: "Nothing added to #{sprint.title}.",
        else: "Added #{n} card#{if n == 1, do: "", else: "s"} to #{sprint.title}."

    notes =
      Enum.map_join(skipped, " ", fn {card, reason} ->
        "“#{(card && card.title) || "A card"}” was left out: #{reason}."
      end)

    String.trim(base <> " " <> notes)
  end

  attr :new_sprint, :map, required: true
  attr :target, :any, required: true
  attr :board, :map, required: true

  # The next sprint, filled in already: named on from the last, starting the
  # day after it ends. Making it goes straight on to picking its cards.
  defp new_sprint_modal(assigns) do
    ~H"""
    <.modal id="new-sprint-modal" on_close={JS.push("close_new_sprint", target: @target)} size="sm">
      <div class="space-y-4 p-6">
        <div>
          <h2 class="pr-8 text-lg font-bold">New sprint</h2>
          <p class="mt-0.5 text-sm text-base-content/60">
            A card on {@board.name} with its own board for the work. You pick the cards next.
          </p>
        </div>
        <.form
          phx-target={@target}
          for={@new_sprint.form}
          id="new-sprint-form"
          phx-submit="create_sprint"
          class="space-y-3"
        >
          <.input field={@new_sprint.form[:name]} label="Name" required />
          <div class="grid grid-cols-2 gap-2">
            <.input field={@new_sprint.form[:start]} type="date" label="Starts" />
            <.input field={@new_sprint.form[:days]} type="number" min="1" max="365" label="Days" />
          </div>
          <.input
            field={@new_sprint.form[:goal]}
            type="textarea"
            label="Goal"
            placeholder="What this sprint is for (optional)"
          />
          <p :if={@new_sprint.error} class="text-sm text-error">{@new_sprint.error}</p>
          <div class="flex items-center justify-end gap-2">
            <button
              phx-target={@target}
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="close_new_sprint"
            >
              Cancel
            </button>
            <button type="submit" class="btn btn-primary btn-sm gap-1.5">
              <.icon name="hero-rocket-launch" class="size-4" /> Create sprint
            </button>
          </div>
        </.form>
      </div>
    </.modal>
    """
  end

  attr :charts, :map, required: true
  attr :target, :any, required: true

  defp sprint_charts_modal(assigns) do
    ~H"""
    <.modal
      id="sprint-charts-modal"
      on_close={JS.push("close_sprint_charts", target: @target)}
      size="md"
    >
      <div class="space-y-6 p-6">
        <h2 class="pr-8 text-lg font-bold">Sprint charts</h2>
        <.velocity_chart :if={@charts.velocity} velocity={@charts.velocity} />
        <form
          :if={@charts.velocity && @charts.velocity.sprints != []}
          phx-target={@target}
          id="chart-sprint-form"
          phx-change="pick_chart_sprint"
        >
          <label class="flex items-center gap-2 text-sm">
            <span class="text-base-content/60">Burndown for</span>
            <select name="sprint" class="select select-sm select-bordered">
              <option
                :for={s <- Enum.reverse(@charts.velocity.sprints)}
                value={s.id}
                selected={s.id == @charts.sprint_id}
              >
                {s.title}
              </option>
            </select>
          </label>
        </form>
        <.burndown_chart :if={@charts.burndown} chart={@charts.burndown} />
      </div>
    </.modal>
    """
  end

  attr :picker, :map, required: true
  attr :target, :any, required: true

  # Picking a sprint's cards: a board, then its lists with a tick by every
  # open card and one per list for the lot. A card with subcards can be
  # stepped into, which is where an epic's tasks are. The count at the foot
  # is everything ticked so far, on whichever boards.
  defp sprint_picker_modal(assigns) do
    assigns =
      assign(assigns,
        count: map_size(assigns.picker.selected),
        source: List.last(assigns.picker.path)
      )

    ~H"""
    <.modal id="sprint-picker" on_close={JS.push("close_sprint_picker", target: @target)} size="md">
      <div class="flex max-h-[85vh] flex-col gap-4 p-6">
        <div>
          <h2 class="pr-8 text-lg font-bold">Add cards to {@picker.sprint.title}</h2>
          <p class="mt-0.5 text-sm text-base-content/60">
            Ticked cards move into the sprint's first list, with their subcards. Tick from as
            many boards as you like, and come back for more later.
          </p>
        </div>

        <div :if={is_nil(@source)} class="min-h-0 flex-1 space-y-1.5 overflow-hidden">
          <p class="text-2xs font-semibold uppercase tracking-wide text-base-content/60">
            Take cards from
          </p>
          <p :if={@picker.boards == []} class="text-sm text-base-content/60">
            There is no other board you can write to.
          </p>
          <ul class="kanban-scroll max-h-[55vh] divide-y divide-base-300/60 overflow-y-auto rounded-xl ring-1 ring-base-content/10">
            <li :for={board <- @picker.boards}>
              <button
                phx-target={@target}
                type="button"
                phx-click="sprint_source"
                phx-value-id={board.id}
                class="flex w-full items-center gap-2.5 px-3 py-2.5 text-left text-sm hover:bg-base-200/60"
              >
                <span class={["size-2.5 shrink-0 rounded-full", Palette.dot(board.color)]}></span>
                <span class="min-w-0 flex-1 truncate font-medium">{board.name}</span>
                <span :if={Board.sprints?(board)} class="badge badge-ghost badge-xs">sprints</span>
                <.icon name="hero-chevron-right" class="size-4 shrink-0 text-base-content/30" />
              </button>
            </li>
          </ul>
        </div>

        <div :if={@source} class="flex min-h-0 flex-1 flex-col gap-2">
          <div class="flex min-w-0 items-center gap-1 text-2xs font-semibold uppercase tracking-wide text-base-content/60">
            <button
              phx-target={@target}
              type="button"
              phx-click="sprint_up"
              class="flex shrink-0 items-center gap-1 hover:text-base-content"
              title="Back"
            >
              <.icon name="hero-chevron-left" class="size-3.5" />
            </button>
            <span
              :for={{b, i} <- Enum.with_index(@picker.path)}
              class="flex min-w-0 items-center gap-1"
            >
              <.icon :if={i > 0} name="hero-chevron-right" class="size-3 shrink-0" />
              <span class="truncate">{b.name}</span>
            </span>
          </div>
          <p :if={Board.sprints?(@source)} class="text-xs text-base-content/60">
            These are sprints. Open one to take what it left unfinished.
          </p>
          <div class="kanban-scroll min-h-0 flex-1 space-y-3 overflow-y-auto pr-1">
            <p
              :if={Enum.all?(@picker.lists, &(&1.cards == []))}
              class="text-sm text-base-content/60"
            >
              Nothing open on this board.
            </p>
            <div :for={list <- @picker.lists} :if={list.cards != []} id={"sprint-list-#{list.id}"}>
              <div class="mb-1 flex items-center gap-1.5 px-1 text-xs font-semibold">
                <span :if={list.color} class={["size-2 rounded-full", Palette.dot(list.color)]}></span>
                <span class="truncate">{list.name}</span>
                <span class="font-mono text-2xs text-base-content/50">{length(list.cards)}</span>
                <button
                  :if={Enum.any?(list.cards, & &1.pickable)}
                  phx-target={@target}
                  type="button"
                  phx-click="sprint_toggle_list"
                  phx-value-id={list.id}
                  class="link link-hover ml-auto text-2xs font-normal text-base-content/60"
                >
                  {if Enum.all?(
                        Enum.filter(list.cards, & &1.pickable),
                        &Map.has_key?(@picker.selected, &1.id)
                      ),
                      do: "untick all",
                      else: "tick all"}
                </button>
              </div>
              <ul class="divide-y divide-base-300/60 rounded-xl ring-1 ring-base-content/10">
                <li :for={card <- list.cards} class="flex items-center gap-2 px-2 py-1.5 text-sm">
                  <input
                    :if={card.pickable}
                    phx-target={@target}
                    type="checkbox"
                    id={"sprint-pick-#{card.id}"}
                    class="checkbox checkbox-sm"
                    checked={Map.has_key?(@picker.selected, card.id)}
                    phx-click="sprint_toggle"
                    phx-value-id={card.id}
                  />
                  <label for={"sprint-pick-#{card.id}"} class="min-w-0 flex-1 cursor-pointer truncate">
                    {card.title}
                  </label>
                  <span :if={card.priority} class="chip chip-line text-2xs">{card.priority}</span>
                  <button
                    :if={card.sub_board_id}
                    phx-target={@target}
                    type="button"
                    phx-click="sprint_into"
                    phx-value-id={card.sub_board_id}
                    class="btn btn-ghost btn-xs gap-1 text-base-content/60"
                    title="Pick from this card's subcards"
                  >
                    subcards <.icon name="hero-chevron-right" class="size-3.5" />
                  </button>
                </li>
              </ul>
            </div>
          </div>
        </div>

        <div class="flex items-center gap-2 border-t border-base-300/60 pt-3">
          <span class="text-sm text-base-content/60">
            {@count} card{if @count == 1, do: "", else: "s"} ticked
          </span>
          <button
            :if={@count > 0}
            phx-target={@target}
            type="button"
            phx-click="sprint_clear"
            class="link link-hover text-xs text-base-content/50"
          >
            clear
          </button>
          <button
            phx-target={@target}
            type="button"
            class="btn btn-ghost btn-sm ml-auto"
            phx-click="close_sprint_picker"
          >
            Cancel
          </button>
          <button
            phx-target={@target}
            id="sprint-add"
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="sprint_add"
            disabled={@count == 0}
          >
            Add to sprint
          </button>
        </div>
      </div>
    </.modal>
    """
  end
end

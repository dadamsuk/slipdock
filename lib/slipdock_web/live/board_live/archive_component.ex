defmodule SlipdockWeb.BoardLive.ArchiveComponent do
  @moduledoc """
  The board's archived cards: find one, restore it, or delete it for good.

  The search box matches a piece of a title, or names one card by its id
  (`#123`) or its link — which is how an archived card's own link lands here
  (`?card=123`, see `SlipdockWeb.BoardLive.Show`).

  Anyone who can read the board can look and search; restoring and deleting need write
  access, which the component works out for itself from the board it is
  given. A card named by id is only ever an archived card of that board.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.{Access, Boards}

  @events ~w(filter_archived restore_card delete_archived)

  @doc false
  # For the test that every `handle_event/3` clause is in the list.
  def events, do: @events

  # Sent by the board when something on it changed.
  @impl true
  def update(%{refresh: true}, socket), do: {:ok, list_archived(socket)}

  def update(%{board: board, current_user: user} = assigns, socket) do
    # The query a link arrived with is taken once, when the panel opens;
    # after that the box is the reader's.
    query =
      if socket.assigns[:board] && socket.assigns.board.id == board.id,
        do: socket.assigns.query,
        else: assigns[:query] || ""

    {:ok,
     socket
     |> assign(
       board: board,
       close_path: assigns.close_path,
       can_write: Access.can_write?(Access.board_permission(user, board)),
       query: query
     )
     |> list_archived()}
  end

  defp list_archived(socket),
    do:
      assign(socket,
        archived: Boards.list_archived_cards(socket.assigns.board.id, socket.assigns.query)
      )

  @impl true
  def handle_event(event, _params, socket) when event not in @events,
    do: {:noreply, flash(socket, :error, "That isn't something this page can do.")}

  # Looking is reading, so searching is open to read-only access too.
  def handle_event("filter_archived", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(query: q) |> list_archived()}

  def handle_event(_event, _params, %{assigns: %{can_write: false}} = socket),
    do: {:noreply, flash(socket, :error, "You have read-only access to this board.")}

  def handle_event(event, params, socket), do: event(event, params, socket)

  defp event("restore_card", %{"id" => id}, socket) do
    case Boards.get_archived_card(socket.assigns.board.id, id) do
      nil ->
        {:noreply, socket}

      card ->
        case Boards.unarchive_card(card) do
          {:ok, _} ->
            {:noreply, socket}

          {:error, refused} ->
            {:noreply, flash(socket, :error, Slipdock.Quota.refusal_message(refused))}
        end
    end
  end

  defp event("delete_archived", %{"id" => id}, socket) do
    if card = Boards.get_archived_card(socket.assigns.board.id, id),
      do: {:ok, _} = Boards.delete_card(card)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-archive">
      <.archive_modal
        board={@board}
        archived={@archived}
        query={@query}
        close_path={@close_path}
        target={@myself}
      />
    </div>
    """
  end

  attr :board, :any, required: true
  attr :archived, :list, required: true
  attr :query, :string, required: true
  attr :close_path, :string, required: true
  attr :target, :any, required: true

  defp archive_modal(assigns) do
    ~H"""
    <.modal id="archive-modal" on_close={JS.patch(@close_path)} size="md">
      <div class="space-y-4 p-6">
        <h2 class="flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-archive-box" class="size-5" /> Archived cards
        </h2>
        <form
          id="archive-search"
          phx-change="filter_archived"
          phx-submit="filter_archived"
          phx-target={@target}
        >
          <label class="input input-sm w-full">
            <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
            <input
              type="search"
              name="q"
              value={@query}
              placeholder="Search by title, #id or card link"
              phx-debounce="200"
              autocomplete="off"
              aria-label="Search archived cards"
            />
          </label>
        </form>
        <p :if={@archived == []} class="text-sm text-base-content/60">
          {if String.trim(@query) == "", do: "No archived cards.", else: "No archived cards match."}
        </p>
        <ul class="max-h-[60vh] space-y-2 overflow-y-auto kanban-scroll pr-1">
          <li
            :for={card <- @archived}
            id={"archived-#{card.id}"}
            class="flex items-center gap-3 rounded-xl bg-base-200/60 px-3 py-2"
          >
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-medium">{card.title}</p>
              <p class="text-xs text-base-content/50">
                #{card.id} · from {card.column.name} · archived {relative_time(card.archived_at)}
              </p>
              <div :if={card.tags != []} class="mt-1 flex flex-wrap gap-1">
                <.tag_chip :for={tag <- card.tags} tag={tag} size="xs" />
              </div>
            </div>
            <button
              phx-target={@target}
              type="button"
              class="btn btn-sm"
              phx-click="restore_card"
              phx-value-id={card.id}
            >
              <.icon name="hero-arrow-uturn-left" class="size-4" /> Restore
            </button>
            <button
              phx-target={@target}
              type="button"
              class="btn btn-ghost btn-sm btn-square text-error"
              phx-click="delete_archived"
              phx-value-id={card.id}
              data-confirm="Delete this card permanently?"
              title="Delete"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </li>
        </ul>
      </div>
    </.modal>
    """
  end
end

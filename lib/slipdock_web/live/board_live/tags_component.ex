defmodule SlipdockWeb.BoardLive.TagsComponent do
  @moduledoc """
  The board's Tags panel: make, rename, recolour and delete the tags of the
  board's tree (they live on its root).

  Anyone who can read the board can open the panel; changing anything needs
  write access, which the component works out for itself from the board it
  is given. A tag named by id is only ever one of that board's.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.BoardLive.Helpers, only: [flash: 3]

  alias Slipdock.{Access, Boards, Palette}
  alias Slipdock.Boards.Tag

  @events ~w(pick_tag_color create_tag set_tag_color rename_tag delete_tag)
  # Picking the new tag's colour changes nothing stored.
  @write_events @events -- ~w(pick_tag_color)

  @doc false
  # For the test that every `handle_event/3` clause is in the list.
  def events, do: @events

  @impl true
  def mount(socket), do: {:ok, assign(socket, tag_form: new_tag_form(), new_tag_color: "sky")}

  @impl true
  def update(%{board: board, current_user: user} = assigns, socket) do
    {:ok,
     assign(socket,
       board: board,
       close_path: assigns.close_path,
       can_write: Access.can_write?(Access.board_permission(user, board))
     )}
  end

  @impl true
  def handle_event(event, _params, socket) when event not in @events,
    do: {:noreply, flash(socket, :error, "That isn't something this page can do.")}

  def handle_event(event, _params, %{assigns: %{can_write: false}} = socket)
      when event in @write_events,
      do: {:noreply, flash(socket, :error, "You have read-only access to this board.")}

  def handle_event(event, params, socket), do: event(event, params, socket)

  defp event("pick_tag_color", %{"color" => color}, socket) do
    {:noreply, assign(socket, new_tag_color: color)}
  end

  defp event("create_tag", %{"tag" => params}, socket) do
    params = Map.put(params, "color", socket.assigns.new_tag_color)

    case Boards.create_tag(socket.assigns.board, params) do
      {:ok, _} -> {:noreply, assign(socket, tag_form: new_tag_form())}
      {:error, cs} -> {:noreply, assign(socket, tag_form: to_form(cs))}
    end
  end

  defp event("set_tag_color", %{"id" => id, "color" => color}, socket) do
    if tag = board_tag(socket, id), do: {:ok, _} = Boards.update_tag(tag, %{"color" => color})
    {:noreply, socket}
  end

  defp event("rename_tag", %{"tag_id" => id, "name" => name}, socket) do
    with %Tag{} = tag <- board_tag(socket, id),
         {:error, _} <- Boards.update_tag(tag, %{"name" => name}) do
      {:noreply, flash(socket, :error, "A tag with that name already exists.")}
    else
      _ -> {:noreply, socket}
    end
  end

  defp event("delete_tag", %{"id" => id}, socket) do
    if tag = board_tag(socket, id), do: {:ok, _} = Boards.delete_tag(tag)
    {:noreply, socket}
  end

  # A tag of this board's tree (they live on the root), or nil.
  defp board_tag(socket, id),
    do: Enum.find(socket.assigns.board.tags, &(to_string(&1.id) == to_string(id)))

  defp new_tag_form, do: to_form(Tag.changeset(%Tag{}, %{}))

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-tags">
      <.tags_modal
        board={@board}
        form={@tag_form}
        color={@new_tag_color}
        close_path={@close_path}
        target={@myself}
      />
    </div>
    """
  end

  attr :board, :any, required: true
  attr :form, :any, required: true
  attr :color, :string, required: true
  attr :close_path, :string, required: true
  attr :target, :any, required: true

  defp tags_modal(assigns) do
    ~H"""
    <.modal id="tags-modal" on_close={JS.patch(@close_path)} size="sm">
      <div class="space-y-5 p-6">
        <h2 class="text-lg font-semibold">Tags</h2>
        <p :if={@board.tags == []} class="text-sm text-base-content/60">
          No tags yet. Create one below.
        </p>
        <ul class="space-y-2">
          <li :for={tag <- @board.tags} id={"tag-row-#{tag.id}"} class="rounded-xl bg-base-200/60 p-3">
            <div class="flex items-center gap-2">
              <.tag_chip tag={tag} />
              <form phx-target={@target} phx-submit="rename_tag" class="flex flex-1 gap-1">
                <input type="hidden" name="tag_id" value={tag.id} />
                <input
                  type="text"
                  name="name"
                  value={tag.name}
                  class="input input-xs flex-1"
                  aria-label="Tag name"
                />
                <button type="submit" class="btn btn-xs">Rename</button>
              </form>
              <button
                phx-target={@target}
                type="button"
                class="btn btn-ghost btn-xs btn-square text-error"
                phx-click="delete_tag"
                phx-value-id={tag.id}
                data-confirm={"Delete tag “#{tag.name}”? It will be removed from all cards."}
                title="Delete tag"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
            <div class="mt-2 flex flex-wrap gap-1">
              <button
                :for={{name, _} <- Palette.all()}
                phx-target={@target}
                type="button"
                class={[
                  "size-4 rounded-full transition hover:scale-125",
                  Palette.dot(name),
                  tag.color == name && "ring-2 ring-base-content ring-offset-1 ring-offset-base-100"
                ]}
                phx-click="set_tag_color"
                phx-value-id={tag.id}
                phx-value-color={name}
                title={Palette.label(name)}
              ></button>
            </div>
          </li>
        </ul>
        <.form
          phx-target={@target}
          for={@form}
          id="tag-form"
          phx-submit="create_tag"
          class="space-y-3 border-t border-base-content/10 pt-4"
        >
          <.input field={@form[:name]} label="New tag" placeholder="e.g. urgent" autocomplete="off" />
          <div class="flex flex-wrap gap-1.5">
            <.color_swatch
              :for={{name, _} <- Palette.all()}
              phx-target={@target}
              color={name}
              selected={@color == name}
              phx-click="pick_tag_color"
              phx-value-color={name}
            />
          </div>
          <button type="submit" class="btn btn-primary btn-sm w-full">Create tag</button>
        </.form>
      </div>
    </.modal>
    """
  end
end

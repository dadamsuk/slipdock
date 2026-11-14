defmodule SlipdockWeb.BoardLive.TagsComponent do
  @moduledoc """
  The board's Tags panel: make, rename, recolour and delete the tags of the
  board's tree (they live on its root).

  A list of compact rows (#1741): a colour dot that opens the palette in a
  popover, the name edited in place (saved on Enter or when the box loses
  focus, Escape puts it back), and Delete in a ⋯ menu behind a confirm. New
  tag is one row at the top.

  Anyone who can read the board can open the panel; changing anything needs
  write access, which the component works out for itself from the board it
  is given. A tag named by id is only ever one of that board's. What goes
  wrong is said inside the panel, never as a toast: a toast dismisses itself
  with a click, which the modal would take as a click-away and close.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.BoardLive.Helpers, only: [tag_by_id: 2]
  import SlipdockWeb.SlipdockComponents

  alias Slipdock.{Access, Boards, Palette}
  alias Slipdock.Boards.Tag

  @events ~w(pick_tag_color create_tag set_tag_color rename_tag delete_tag)
  # Picking the new tag's colour changes nothing stored.
  @write_events @events -- ~w(pick_tag_color)

  @doc false
  # For the test that every `handle_event/3` clause is in the list.
  def events, do: @events

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, tag_form: new_tag_form(), new_tag_color: "sky", error: nil)}

  @impl true
  def update(%{board: board, current_user: user} = assigns, socket) do
    {:ok,
     socket
     |> assign(board: board, current_user: user, close_path: assigns.close_path)
     |> assign_access()}
  end

  # What the reader may do now. `update/2` runs only when the board hands
  # the panel something new, and a lowered grant changes nothing it hands
  # over, so every event asks again before it is let through (#2771).
  defp assign_access(socket) do
    %{board: board, current_user: user} = socket.assigns
    assign(socket, can_write: Access.can_write?(Access.board_permission(user, board)))
  end

  @impl true
  def handle_event(event, _params, socket) when event not in @events,
    do: {:noreply, assign(socket, error: "That isn't something this page can do.")}

  def handle_event(event, params, socket), do: guarded(event, params, assign_access(socket))

  defp guarded(event, _params, %{assigns: %{can_write: false}} = socket)
       when event in @write_events,
       do:
         {:reply, %{ok: false}, assign(socket, error: "You have read-only access to this board.")}

  defp guarded(event, params, socket), do: event(event, params, socket)

  defp event("pick_tag_color", %{"color" => color}, socket) do
    color = if Enum.member?(Palette.names(), color), do: color, else: socket.assigns.new_tag_color
    {:noreply, assign(socket, new_tag_color: color)}
  end

  defp event("create_tag", %{"tag" => params}, socket) do
    params = Map.put(params, "color", socket.assigns.new_tag_color)

    case Boards.Tags.create_tag(socket.assigns.board, params) do
      {:ok, _} -> {:noreply, assign(socket, tag_form: new_tag_form(), error: nil)}
      {:error, cs} -> {:noreply, assign(socket, tag_form: to_form(cs, action: :insert))}
    end
  end

  defp event("set_tag_color", %{"id" => id, "color" => color}, socket) do
    with %Tag{} = tag <- tag_by_id(socket.assigns.board, id),
         {:ok, _} <- Boards.Tags.update_tag(tag, %{"color" => color}) do
      {:noreply, assign(socket, error: nil)}
    else
      _ -> {:noreply, assign(socket, error: "That colour couldn't be set.")}
    end
  end

  # Sent by the name box when it loses focus or takes Enter. The reply tells
  # the box whether to keep what was typed or put the saved name back.
  defp event("rename_tag", %{"tag_id" => id, "name" => name}, socket) do
    case tag_by_id(socket.assigns.board, id) do
      nil ->
        {:reply, %{ok: false}, assign(socket, error: "That tag has gone.")}

      %Tag{name: ^name} ->
        {:reply, %{ok: true}, socket}

      tag ->
        case Boards.Tags.update_tag(tag, %{"name" => name}) do
          {:ok, tag} ->
            {:reply, %{ok: true, name: tag.name}, assign(socket, error: nil)}

          {:error, cs} ->
            {:reply, %{ok: false, name: tag.name},
             assign(socket, error: rename_error(cs, tag.name))}
        end
    end
  end

  defp event("delete_tag", %{"id" => id}, socket) do
    if tag = tag_by_id(socket.assigns.board, id), do: {:ok, _} = Boards.Tags.delete_tag(tag)
    {:noreply, assign(socket, error: nil)}
  end

  defp rename_error(cs, old) do
    case cs.errors[:name] do
      {"can't be blank", _} ->
        "A tag needs a name: “#{old}” is unchanged."

      {"already exists" <> _, _} ->
        "There is already a tag with that name: “#{old}” is unchanged."

      {"should be at most" <> _, _} ->
        "A tag's name is 30 characters at most."

      _ ->
        "“#{old}” couldn't be renamed."
    end
  end

  defp new_tag_form, do: to_form(Tag.changeset(%Tag{}, %{}))

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-tags">
      <.modal id="tags-modal" on_close={JS.patch(@close_path)} size="sm">
        <div class="space-y-4 p-6">
          <div>
            <h2 class="section-title">Tags</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Click a name to rename it. Enter saves it, Escape puts it back.
            </p>
          </div>
          <.callout :if={@error} id="tags-error" kind={:error}>{@error}</.callout>
          <fieldset disabled={!@can_write} class="min-w-0 space-y-3">
            <.new_tag_row form={@tag_form} color={@new_tag_color} target={@myself} />
            <p :if={@board.tags == []} id="tags-empty" class="text-sm text-base-content/60">
              No tags yet.
            </p>
            <ul id="tag-list" class="divide-y divide-base-content/10">
              <.tag_row :for={tag <- @board.tags} tag={tag} target={@myself} />
            </ul>
          </fieldset>
        </div>
      </.modal>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".TagName">
        // A tag's name, edited in place (#1741). Enter and leaving the box
        // save it; Escape puts the saved name back and saves nothing. The
        // modal closes on Escape from the window, so the box keeps it.
        export default {
          mounted() {
            this.el.addEventListener("keydown", (e) => {
              if (e.key === "Enter") {
                e.preventDefault()
                this.el.blur()
              } else if (e.key === "Escape") {
                e.preventDefault()
                e.stopPropagation()
                this.el.value = this.el.dataset.name
                this.el.blur()
              }
            })
            this.el.addEventListener("blur", () => this.save())
          },
          save() {
            const name = this.el.value
            if (name === this.el.dataset.name) return
            this.pushEventTo(this.el, "rename_tag", {tag_id: this.el.dataset.tagId, name}, (reply) => {
              if (reply.name !== undefined) this.el.dataset.name = reply.name
              if (!reply.ok) this.el.value = this.el.dataset.name
            })
          },
        }
      </script>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :color, :string, required: true
  attr :target, :any, required: true

  # New tag: one row, the same shape as a tag's.
  defp new_tag_row(assigns) do
    ~H"""
    <.form
      for={@form}
      id="tag-form"
      phx-target={@target}
      phx-submit="create_tag"
      class="space-y-1"
    >
      <div class="flex items-center gap-2">
        <.dot_button
          id="new-tag-dot"
          palette="new-tag-colors"
          color={@color}
          label="Colour for the new tag"
        />
        <.palette
          id="new-tag-colors"
          anchor="new-tag-dot"
          selected={@color}
          event="pick_tag_color"
          values={%{}}
          target={@target}
        />
        <input
          type="text"
          id="new-tag-name"
          name={@form[:name].name}
          value={@form[:name].value}
          placeholder="New tag"
          aria-label="New tag"
          maxlength="30"
          autocomplete="off"
          class={["input field min-w-0 flex-1", @form[:name].errors != [] && "input-error"]}
        />
        <button type="submit" class="btn btn-primary btn-sm">Add</button>
      </div>
      <p
        :for={msg <- Enum.map(@form[:name].errors, &translate_error/1)}
        id="new-tag-error"
        class="pl-8 text-xs text-error"
      >
        {msg}
      </p>
    </.form>
    """
  end

  attr :tag, Tag, required: true
  attr :target, :any, required: true

  defp tag_row(assigns) do
    ~H"""
    <li id={"tag-row-#{@tag.id}"} class="tag-row flex items-center gap-2 py-1">
      <.dot_button
        id={"tag-dot-#{@tag.id}"}
        palette={"tag-colors-#{@tag.id}"}
        color={@tag.color}
        label={"Colour of “#{@tag.name}”: #{Palette.label(@tag.color)}"}
      />
      <.palette
        id={"tag-colors-#{@tag.id}"}
        anchor={"tag-dot-#{@tag.id}"}
        selected={@tag.color}
        event="set_tag_color"
        values={%{"phx-value-id" => @tag.id}}
        target={@target}
      />
      <input
        type="text"
        id={"tag-name-#{@tag.id}"}
        value={@tag.name}
        data-name={@tag.name}
        data-tag-id={@tag.id}
        phx-hook=".TagName"
        phx-target={@target}
        maxlength="30"
        autocomplete="off"
        aria-label={"Name of the tag “#{@tag.name}”"}
        class="input field-bare min-w-0 flex-1"
      />
      <button
        type="button"
        id={"tag-more-#{@tag.id}"}
        popovertarget={"tag-menu-#{@tag.id}"}
        class="btn btn-ghost btn-xs btn-square"
        title="More"
        aria-label={"More for “#{@tag.name}”"}
      >
        <.icon name="hero-ellipsis-horizontal" class="size-4" />
      </button>
      <div
        id={"tag-menu-#{@tag.id}"}
        popover
        phx-hook="AnchoredPopover"
        data-anchor={"tag-more-#{@tag.id}"}
        class="pop-menu"
      >
        <ul class="menu w-40 rounded-xl bg-base-100 p-1 text-sm shadow-xl ring-1 ring-base-content/10">
          <li>
            <button
              type="button"
              id={"delete-tag-#{@tag.id}"}
              phx-target={@target}
              phx-click="delete_tag"
              phx-value-id={@tag.id}
              data-confirm={"Delete the tag “#{@tag.name}”? It comes off every card."}
              class="text-error"
            >
              <.icon name="hero-trash" class="size-4" /> Delete
            </button>
          </li>
        </ul>
      </div>
    </li>
    """
  end

  attr :id, :string, required: true
  attr :palette, :string, required: true, doc: "the id of the palette it opens"
  attr :color, :string, required: true
  attr :label, :string, required: true

  # The colour dot: a 28px target round a 14px dot, opening the palette.
  defp dot_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      popovertarget={@palette}
      class="tag-dot grid size-7 shrink-0 place-items-center rounded-full hover:bg-base-200"
      title={@label}
      aria-label={@label}
    >
      <span class={["size-3.5 rounded-full", Palette.dot(@color)]}></span>
    </button>
    """
  end

  attr :id, :string, required: true
  attr :anchor, :string, required: true
  attr :selected, :string, required: true
  attr :event, :string, required: true
  attr :values, :map, required: true
  attr :target, :any, required: true

  # The 12 swatches in a popover beside the dot. Picking one closes it.
  defp palette(assigns) do
    ~H"""
    <div
      id={@id}
      popover
      phx-hook="AnchoredPopover"
      data-anchor={@anchor}
      data-align="start"
      class="pop-menu"
    >
      <div
        role="group"
        aria-label="Colour"
        class="grid w-44 grid-cols-6 gap-1.5 rounded-xl bg-base-100 p-2 shadow-xl ring-1 ring-base-content/10"
      >
        <button
          :for={{name, _} <- Palette.all()}
          type="button"
          id={"#{@id}-#{name}"}
          class={[
            "size-5 rounded-full ring-offset-2 ring-offset-base-100 transition hover:scale-110",
            Palette.dot(name),
            @selected == name && "ring-2 ring-base-content"
          ]}
          title={Palette.label(name)}
          aria-label={Palette.label(name)}
          aria-pressed={to_string(@selected == name)}
          popovertarget={@id}
          popovertargetaction="hide"
          phx-target={@target}
          phx-click={@event}
          phx-value-color={name}
          {@values}
        ></button>
      </div>
    </div>
    """
  end
end

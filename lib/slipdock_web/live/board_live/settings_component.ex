defmodule SlipdockWeb.BoardLive.SettingsComponent do
  @moduledoc """
  The board's settings panel: name, code, colour and kind; custom fields and
  their presets; milestones; who the board is shared with; saving it as a
  template; archiving and deleting it.

  Only the board's owner gets this panel, and the component decides that for
  itself from the board it is given: every event is refused otherwise. A
  field, milestone or grant named by id is only ever one of this board's.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.ShareComponents
  import SlipdockWeb.SprintPlanComponents, only: [sources_fields: 1, parse_sources: 2, chosen: 1]
  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.{Access, Boards, Fields, Palette, Sprints}
  alias Slipdock.Boards.{Board, FieldDefinition}
  alias SlipdockWeb.BoardLive.Sharing

  @events ~w(validate_board save_board set_board_color add_field delete_field toggle_field_sum
    install_preset add_milestone delete_milestone delete_board archive_board unarchive_board
    save_as_template share revoke_grant set_sprint_sources)

  @doc false
  # For the test that every `handle_event/3` clause is in the list.
  def events, do: @events

  @impl true
  def mount(socket), do: {:ok, assign(socket, board_form: nil, form_key: 0, share_key: 0)}

  @impl true
  def update(%{board: board, current_user: user} = assigns, socket) do
    can_manage = Access.board_permission(user, board) == :owner

    socket =
      assign(socket,
        board: board,
        current_user: user,
        groups: assigns.groups,
        close_path: assigns.close_path,
        can_manage: can_manage,
        grants: if(can_manage, do: Access.list_grants(board), else: []),
        # Where a sprint board's sprints are planned from (see Sprints.sources/2).
        source_choices:
          if(can_manage and Board.sprints?(board),
            do: Sprints.source_choices(user, board),
            else: []
          )
      )

    # The form is made once, when the panel opens; the board changing
    # underneath (somebody else's edit) doesn't throw away what is typed.
    socket =
      if socket.assigns.board_form,
        do: socket,
        else: assign(socket, board_form: to_form(Boards.change_board(board)))

    {:ok, socket}
  end

  @impl true
  def handle_event(event, _params, socket) when event not in @events,
    do: {:noreply, flash(socket, :error, "That isn't something this page can do.")}

  def handle_event(_event, _params, %{assigns: %{can_manage: false}} = socket),
    do: {:noreply, flash(socket, :error, "Only the board's owner can do that.")}

  def handle_event(event, params, socket), do: event(event, params, socket)

  # Sharing the board. Who it is shared with decides who can be put on its
  # cards, so the board is told to look again.
  defp event("share", %{"level" => _} = params, socket) do
    %{board: board, groups: groups, current_user: user} = socket.assigns

    case Sharing.share(board, params, groups, user) do
      {:ok, _} ->
        send(self(), :refresh_assignable)

        {:noreply,
         socket |> update(:share_key, &(&1 + 1)) |> assign(grants: Access.list_grants(board))}

      {:error, message} ->
        {:noreply, flash(socket, :error, message)}
    end
  end

  defp event("revoke_grant", %{"id" => id}, socket) do
    board = socket.assigns.board

    case Sharing.revoke(id, board) do
      {:ok, _} ->
        send(self(), :refresh_assignable)
        {:noreply, assign(socket, grants: Access.list_grants(board))}

      _ ->
        {:noreply, flash(socket, :error, "Couldn't remove that access.")}
    end
  end

  defp event("save_as_template", _, socket) do
    board = socket.assigns.board

    case Boards.create_template(Boards.template_attrs_from_board(board)) do
      {:ok, template} ->
        {:noreply,
         flash(
           socket,
           :info,
           "Saved the lists of this board as the “#{template.name}” template."
         )}

      {:error, cs} ->
        {:noreply,
         flash(
           socket,
           :error,
           "Couldn't save a template: name #{elem(cs.errors[:name] || {"is invalid", []}, 0)}."
         )}
    end
  end

  defp event("validate_board", %{"board" => params}, socket) do
    board = socket.assigns.board
    params = suggest_board_code(params, board)
    cs = board |> Boards.change_board(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, board_form: to_form(cs))}
  end

  defp event("save_board", %{"board" => params}, socket) do
    case Boards.update_board(socket.assigns.board, params) do
      {:ok, _} -> {:noreply, push_patch(socket, to: socket.assigns.close_path)}
      {:error, cs} -> {:noreply, assign(socket, board_form: to_form(cs))}
    end
  end

  # Saved as they are ticked, like the colour.
  defp event("set_sprint_sources", params, socket) do
    %{board: board, current_user: user, source_choices: choices} = socket.assigns
    parsed = parse_sources(params["sources"], choices)

    case Sprints.put_sources(board, user, parsed) do
      {:ok, board} -> {:noreply, assign(socket, board: board)}
      {:error, message} -> {:noreply, flash(socket, :error, message)}
    end
  end

  defp event("set_board_color", %{"color" => color}, socket) do
    {:ok, _} = Boards.update_board(socket.assigns.board, %{"color" => color})
    {:noreply, socket}
  end

  defp event("add_field", params, socket) do
    attrs = %{
      "name" => params["name"],
      "kind" => params["kind"],
      "sum" => params["sum"] == "true",
      "options" => parse_options(params["options"]),
      "config" =>
        if(params["kind"] == "formula",
          do: %{"mode" => "expression", "expression" => params["expression"]},
          else: %{}
        )
    }

    case Fields.create_field(socket.assigns.board, attrs) do
      {:ok, _} ->
        {:noreply, update(socket, :form_key, &(&1 + 1))}

      {:error, cs} ->
        {:noreply, flash(socket, :error, "Couldn't add the field: #{field_errors(cs)}")}
    end
  end

  defp event("delete_field", %{"id" => id}, socket) do
    field = Fields.get_field!(id)

    if field.board_id == Slipdock.Boards.Board.root_id(socket.assigns.board) do
      {:ok, _} = Fields.delete_field(field)
    end

    {:noreply, socket}
  end

  defp event("toggle_field_sum", %{"id" => id}, socket) do
    field = Fields.get_field!(id)

    if field.board_id == Slipdock.Boards.Board.root_id(socket.assigns.board) do
      {:ok, _} = Fields.update_field(field, %{"sum" => not field.sum})
    end

    {:noreply, socket}
  end

  defp event("install_preset", %{"key" => key}, socket) do
    case Fields.install_preset(socket.assigns.board, key) do
      {:ok, _} ->
        {:noreply, flash(socket, :info, "Preset added. Fill the inputs on each card.")}

      {:error, _} ->
        {:noreply, flash(socket, :error, "Unknown preset.")}
    end
  end

  defp event("add_milestone", params, socket) do
    case Boards.create_milestone(socket.assigns.board, Map.take(params, ~w(name date color))) do
      {:ok, _} ->
        {:noreply, update(socket, :form_key, &(&1 + 1))}

      {:error, _cs} ->
        {:noreply, flash(socket, :error, "A milestone needs a name and a date.")}
    end
  end

  defp event("delete_milestone", %{"id" => id}, socket) do
    milestone = Boards.get_milestone!(id)

    if milestone.board_id == Slipdock.Boards.Board.root_id(socket.assigns.board) do
      {:ok, _} = Boards.delete_milestone(milestone)
    end

    {:noreply, socket}
  end

  defp event("delete_board", _, socket) do
    {:ok, _} = Boards.delete_board(socket.assigns.board)
    {:noreply, socket |> put_flash(:info, "Board deleted.") |> push_navigate(to: ~p"/")}
  end

  defp event("archive_board", _, socket) do
    case Boards.archive_board(socket.assigns.board) do
      {:ok, board} ->
        {:noreply,
         socket
         |> put_flash(:info, "“#{board.name}” archived. Find it under Archived on your boards.")
         |> push_navigate(to: ~p"/")}

      {:error, :sub_board} ->
        {:noreply, flash(socket, :error, "Subcard boards go away with their card.")}
    end
  end

  defp event("unarchive_board", _, socket) do
    case Boards.unarchive_board(socket.assigns.board) do
      {:ok, board} ->
        send(self(), :reload_board)
        {:noreply, socket |> assign(board: board) |> flash(:info, "Board restored.")}

      {:error, refused} ->
        {:noreply, flash(socket, :error, Slipdock.Quota.refusal_message(refused))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-settings">
      <.settings_modal
        form_key={@form_key}
        board={@board}
        form={@board_form}
        close_path={@close_path}
        grants={@grants}
        groups={@groups}
        share_key={@share_key}
        source_choices={@source_choices}
        target={@myself}
      />
    </div>
    """
  end

  # Emptying the code field asks for a fresh one off the name.
  defp suggest_board_code(params, board) do
    if String.trim(to_string(params["code"] || "")) == "" do
      name =
        case String.trim(to_string(params["name"] || "")) do
          "" -> board.name
          name -> name
        end

      Map.put(params, "code", Boards.suggest_code(name, board.id))
    else
      params
    end
  end

  attr :board, :any, required: true
  attr :form, :any, required: true
  attr :close_path, :string, required: true
  attr :grants, :list, required: true
  attr :pages, :list, default: [], doc: "the wiki pages that talk about this card"
  attr :groups, :list, required: true
  attr :share_key, :integer, required: true

  attr :form_key, :integer, default: 0
  attr :source_choices, :list, default: []
  attr :target, :any, required: true

  defp settings_modal(assigns) do
    ~H"""
    <.modal id="settings-modal" on_close={JS.patch(@close_path)} size="sm">
      <div class="space-y-5 p-6">
        <h2 class="text-lg font-semibold">Board settings</h2>
        <.form
          phx-target={@target}
          for={@form}
          id="board-form"
          phx-change="validate_board"
          phx-submit="save_board"
          class="space-y-4"
        >
          <.input field={@form[:name]} label="Name" />
          <div>
            <.input
              field={@form[:code]}
              label="Code"
              maxlength={Board.code_length()}
              class="w-full input font-mono"
            />
            <p class="-mt-1 text-xs text-base-content/50">
              A short, unique handle for this board — up to {Board.code_length()} characters, used
              in links and on the command line. Clear it to take a fresh one from the name.
            </p>
          </div>
          <div :if={is_nil(@board.parent_card_id)}>
            <.input
              field={@form[:shortcut]}
              label="Shortcut key"
              maxlength={Board.shortcut_length()}
              class="w-24 input font-mono"
            />
            <p class="-mt-1 text-xs text-base-content/50">
              What jumps to this board from the switcher: press <kbd class="kbd kbd-xs">b</kbd>
              anywhere, then this. One or two letters or digits, unique across your boards.
              Clear it to take a fresh one from the name.
            </p>
          </div>
          <.input field={@form[:description]} type="textarea" label="Description" />
          <div :if={is_nil(@board.parent_card_id)} class="grid grid-cols-2 gap-2">
            <.input field={@form[:vote_budget]} type="number" min="0" label="Votes per person" />
            <.input field={@form[:vote_max]} type="number" min="1" label="Max votes per card" />
          </div>
          <%!-- A sprint board's cards are sprints: it gains New sprint, and
                each sprint Add cards…. Unticked, the hidden field sends "". --%>
          <div :if={is_nil(@board.parent_card_id)} class="space-y-1">
            <input type="hidden" name={@form[:kind].name} value="" />
            <label class="flex cursor-pointer items-start gap-2 text-sm">
              <input
                type="checkbox"
                id="board-kind-sprints"
                name={@form[:kind].name}
                value="sprints"
                checked={@form[:kind].value == "sprints"}
                class="checkbox checkbox-sm mt-0.5"
              />
              <span>
                <span class="font-medium">Sprint board</span>
                <span class="block text-xs text-base-content/50">
                  Every card is a sprint, with its work as subcards. Adds New sprint, and Add
                  cards… to pick work from your other boards into a sprint.
                </span>
              </span>
            </label>
          </div>
          <%!-- A plain to-do list: the tracking details stay out of sight
                (`Board.simple?/1`). Hidden, not removed. --%>
          <div class="space-y-1">
            <input type="hidden" name={@form[:simple].name} value="false" />
            <label class="flex cursor-pointer items-start gap-2 text-sm">
              <input
                type="checkbox"
                id="board-simple"
                name={@form[:simple].name}
                value="true"
                checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:simple].value)}
                class="checkbox checkbox-sm mt-0.5"
              />
              <span>
                <span class="font-medium">Simple board</span>
                <span class="block text-xs text-base-content/50">
                  For a plain to-do list. Hides % complete, start dates, health, time tracking,
                  votes and dependencies on its cards, and the Timeline and Prioritise views.
                  Nothing is deleted; untick it to bring them back.
                </span>
              </span>
            </label>
          </div>
          <div class="space-y-1.5">
            <span class="text-sm font-medium">Colour</span>
            <div class="flex flex-wrap gap-1.5">
              <.color_swatch
                :for={{name, _} <- Palette.all()}
                phx-target={@target}
                color={name}
                selected={@board.color == name}
                phx-click="set_board_color"
                phx-value-color={name}
              />
            </div>
          </div>
          <button
            phx-target={@target}
            type="button"
            class="btn btn-sm w-full justify-start"
            phx-click="save_as_template"
            title="Create a template from this board's lists"
          >
            <.icon name="hero-view-columns" class="size-4" /> Save lists as a template
          </button>
          <button
            :if={is_nil(@board.parent_card_id) and is_nil(@board.archived_at)}
            phx-target={@target}
            type="button"
            class="btn btn-sm w-full justify-start"
            phx-click="archive_board"
            data-confirm={"Archive “#{@board.name}”? It comes off your boards and the switcher, but nothing on it is lost."}
            title="Put this board away without deleting anything"
          >
            <.icon name="hero-archive-box" class="size-4" /> Archive board
          </button>
          <button
            :if={not is_nil(@board.archived_at)}
            phx-target={@target}
            type="button"
            class="btn btn-sm w-full justify-start"
            phx-click="unarchive_board"
            title="Put this board back on your boards"
          >
            <.icon name="hero-archive-box-arrow-down" class="size-4" /> Restore board
          </button>
          <div class="flex items-center justify-between pt-2">
            <button
              phx-target={@target}
              type="button"
              class="btn btn-ghost btn-sm text-error"
              phx-click="delete_board"
              data-confirm={"Delete “#{@board.name}” and everything on it? This cannot be undone."}
            >
              <.icon name="hero-trash" class="size-4" /> Delete board
            </button>
            <button type="submit" class="btn btn-primary btn-sm">Save</button>
          </div>
        </.form>
        <%!-- What Add cards… on a sprint shows side by side (Sprints.sources/2). --%>
        <form
          :if={Board.sprints?(@board) and is_nil(@board.parent_card_id)}
          id="sprint-sources-form"
          phx-target={@target}
          phx-change="set_sprint_sources"
          class="space-y-2 border-t border-base-content/10 pt-4"
        >
          <span class="text-sm font-medium">Plan sprints from</span>
          <p class="text-xs text-base-content/50">
            The boards, and lists on them, that Add cards… on a sprint shows side by side, with
            their scores, estimates and running totals. No list ticked means every open list.
          </p>
          <.sources_fields choices={@source_choices} chosen={chosen(@board)} />
        </form>
        <div class="space-y-2 border-t border-base-content/10 pt-4" id="board-fields">
          <span class="text-sm font-medium">Fields</span>
          <p class="text-xs text-base-content/50">
            Custom fields for every card in this tree. Start from a scoring preset, or add
            your own; a formula refers to fields as <code class="font-mono">{"{key}"}</code>.
          </p>
          <ul :if={@board.fields != []} class="space-y-1">
            <li
              :for={f <- @board.fields}
              id={"field-#{f.id}"}
              class="flex items-center gap-2 text-sm"
            >
              <span class="chip chip-line shrink-0 text-2xs">{FieldDefinition.kind_label(f.kind)}</span>
              <span class="min-w-0 flex-1 truncate">
                {f.name}
                <span class="font-mono text-2xs text-base-content/50">{"{#{f.key}}"}</span>
              </span>
              <span
                :if={f.kind == "formula"}
                class="max-w-40 truncate font-mono text-2xs text-base-content/60"
                title={f.config["expression"] || "weighted score"}
              >
                {f.config["expression"] || "weighted"}
              </span>
              <label
                :if={f.kind in ~w(number rating)}
                class="flex cursor-pointer items-center gap-1 text-2xs"
                title="Roll totals up the tree and show sums in table groups"
              >
                <input
                  phx-target={@target}
                  type="checkbox"
                  class="checkbox checkbox-xs"
                  phx-click="toggle_field_sum"
                  phx-value-id={f.id}
                  checked={f.sum}
                /> Σ
              </label>
              <button
                phx-target={@target}
                type="button"
                class="btn btn-ghost btn-xs btn-square text-error"
                phx-click="delete_field"
                phx-value-id={f.id}
                data-confirm={"Delete the field “#{f.name}” and every value of it?"}
                title="Delete"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </li>
          </ul>
          <div class="flex flex-wrap items-center gap-1">
            <span class="text-xs text-base-content/60">Presets:</span>
            <button
              :for={preset <- Fields.presets()}
              phx-target={@target}
              type="button"
              class="btn btn-xs"
              phx-click="install_preset"
              phx-value-key={preset.key}
              title={preset.blurb}
            >
              + {preset.name}
            </button>
          </div>
          <form
            phx-target={@target}
            id={"field-form-#{@form_key}"}
            phx-submit="add_field"
            class="space-y-1.5"
          >
            <div class="flex gap-1">
              <input
                type="text"
                name="name"
                placeholder="Field name"
                class="input input-sm min-w-0 flex-1"
                required
                autocomplete="off"
              />
              <select name="kind" class="select select-sm w-28" title="Kind">
                <option :for={{k, l} <- FieldDefinition.kinds()} value={k}>{l}</option>
              </select>
            </div>
            <input
              type="text"
              name="options"
              placeholder="Choices, e.g. Small=1, Medium=2, Large=3"
              class="input input-sm w-full"
              autocomplete="off"
            />
            <input
              type="text"
              name="expression"
              placeholder="Formula, e.g. {value} / {effort}"
              class="input input-sm w-full font-mono"
              autocomplete="off"
            />
            <div class="flex items-center justify-between">
              <label class="flex cursor-pointer items-center gap-1 text-xs">
                <input type="checkbox" name="sum" value="true" class="checkbox checkbox-xs" />
                Roll up totals
              </label>
              <button type="submit" class="btn btn-primary btn-sm">Add field</button>
            </div>
          </form>
        </div>
        <div class="space-y-2 border-t border-base-content/10 pt-4">
          <span class="text-sm font-medium">Milestones</span>
          <p class="text-xs text-base-content/50">
            Named dates drawn on the timeline and calendar of every board in this tree.
          </p>
          <ul :if={@board.milestones != []} class="space-y-1" id="milestone-list">
            <li
              :for={m <- @board.milestones}
              id={"milestone-#{m.id}"}
              class="flex items-center gap-2 text-sm"
            >
              <span class={["size-2.5 shrink-0 rotate-45", Palette.dot(m.color || "indigo")]}></span>
              <span class="min-w-0 flex-1 truncate" title={m.name}>{m.name}</span>
              <span class="text-xs text-base-content/60">{fmt_date(m.date)}</span>
              <button
                phx-target={@target}
                type="button"
                class="btn btn-ghost btn-xs btn-square text-error"
                phx-click="delete_milestone"
                phx-value-id={m.id}
                data-confirm={"Remove milestone “#{m.name}”?"}
                title="Remove"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </li>
          </ul>
          <form
            phx-target={@target}
            id={"milestone-form-#{@form_key}"}
            phx-submit="add_milestone"
            class="flex items-end gap-2"
          >
            <input
              type="text"
              name="name"
              placeholder="Milestone, e.g. Launch"
              class="input input-sm min-w-0 flex-1"
              required
              autocomplete="off"
            />
            <input type="date" name="date" class="input input-sm w-36" required />
            <select name="color" class="select select-sm w-28" title="Colour">
              <option value="">Colour</option>
              <option :for={{n, l} <- Palette.all()} value={n}>{l}</option>
            </select>
            <button type="submit" class="btn btn-primary btn-sm">Add</button>
          </form>
        </div>
        <div class="space-y-1.5 border-t border-base-content/10 pt-4">
          <span class="text-sm font-medium">Sharing</span>
          <p class="text-xs text-base-content/50">
            People and groups with access to this board and every card on it.
          </p>
          <.share_panel
            resource="board"
            grants={@grants}
            groups={@groups}
            can_manage={true}
            form_key={@share_key}
            target={@target}
          />
        </div>
      </div>
    </.modal>
    """
  end
end

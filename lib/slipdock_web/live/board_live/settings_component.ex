defmodule SlipdockWeb.BoardLive.SettingsComponent do
  @moduledoc """
  The board's settings panel: name, code, colour and kind; custom fields and
  their presets; milestones; who the board is shared with; saving it as a
  template; archiving and deleting it.

  Only the board's owner gets this panel, and the component decides that for
  itself from the board it is given: every event is refused otherwise. A
  field, milestone or grant named by id is only ever one of this board's.

  It is split into tabs (`tabs/0`), and `?tab=<key>` on the settings URL
  opens on one of them. Every tab is drawn and the others hidden, so the
  board's form, which spans General and Features, keeps what was typed.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.SprintPlanComponents, only: [parse_sources: 2]
  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.{Access, Boards, Fields, Gardener, Hotkeys, Sprints}
  alias Slipdock.Boards.Board
  alias SlipdockWeb.BoardLive.SettingsComponent.Panels
  alias SlipdockWeb.BoardLive.Sharing

  @events ~w(validate_board save_board set_board_color add_field delete_field toggle_field_sum
    install_preset add_milestone delete_milestone delete_board archive_board unarchive_board
    save_as_template share revoke_grant set_sprint_sources set_gardening deploy_setup
    deploy_prompt settings_tab)

  @doc false
  # For the test that every `handle_event/3` clause is in the list.
  def events, do: @events

  @tabs [
    {"general", "General", "hero-adjustments-horizontal"},
    {"features", "Features", "hero-squares-plus"},
    {"planning", "Planning", "hero-calendar-days"},
    {"deploys", "Deploys", "hero-rocket-launch"},
    {"gardening", "Gardening", "hero-sparkles"},
    {"sharing", "Sharing", "hero-user-group"},
    {"manage", "Manage", "hero-archive-box"}
  ]
  @tab_keys Enum.map(@tabs, &elem(&1, 0))

  @doc "The tabs, as `{key, label, icon}`, in the order they are shown."
  def tabs, do: @tabs

  # A tab there is no such thing as opens the first.
  defp tab(key) when key in @tab_keys, do: key
  defp tab(_), do: "general"

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         board_form: nil,
         tab: "general",
         url_tab: nil,
         form_key: 0,
         share_key: 0,
         hotkey: nil,
         hotkeys: [],
         # "Track deployments" (#1134): what was generated (the token shown
         # this once), the prompt asked for, and the first deploy arriving.
         deploy_setup: nil,
         deploy_prompt: nil,
         deploy_arrived: nil
       )}

  # A deploy arrived on this board while the panel is open (the board page
  # forwards it): the wizard turns green.
  @impl true
  def update(%{deployment_arrived: deployment}, socket),
    do: {:ok, assign(socket, deploy_arrived: deployment)}

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
        else:
          assign(socket,
            board_form: to_form(Boards.change_board(board)),
            hotkey: Hotkeys.get(user, board),
            hotkeys: Hotkeys.list(user)
          )

    {:ok, open_tab(socket, assigns[:tab])}
  end

  # `?tab=` chooses the tab when the panel opens, and again whenever the URL
  # names a different one; a board update in between leaves the tab alone.
  defp open_tab(%{assigns: %{url_tab: tab}} = socket, tab), do: socket
  defp open_tab(socket, tab), do: assign(socket, tab: tab(tab), url_tab: tab)

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

  defp event("settings_tab", params, socket),
    do: {:noreply, assign(socket, tab: tab(params["tab"]))}

  defp event("save_as_template", _, socket) do
    board = socket.assigns.board

    case Boards.Templates.create_template(
           socket.assigns.current_user,
           Boards.Templates.template_attrs_from_board(board)
         ) do
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

  # Gardening (W-1807): each check on or off, and its thresholds. A change
  # to one check is saved as it is made.
  defp event("set_gardening", %{"gardening" => params}, socket) do
    result =
      Enum.reduce_while(params, {:ok, socket.assigns.board}, fn {key, attrs}, {:ok, board} ->
        case Gardener.check(key) do
          nil ->
            {:cont, {:ok, board}}

          check ->
            case Gardener.Settings.put(board, check, attrs) do
              {:ok, saved} -> {:cont, {:ok, %{board | gardening: saved.gardening}}}
              {:error, message} -> {:halt, {:error, "#{check.label()}: #{message}"}}
            end
        end
      end)

    case result do
      {:ok, board} -> {:noreply, assign(socket, board: board)}
      {:error, message} -> {:noreply, flash(socket, :error, message)}
    end
  end

  defp event("set_gardening", _params, socket), do: {:noreply, socket}

  # Turns delivery metrics on, issues the deploy token and shows what to
  # paste (`Slipdock.Deployments.Setup`), then waits for the first deploy.
  defp event("deploy_setup", %{"do" => "prompt"} = params, socket),
    do: event("deploy_prompt", params, socket)

  defp event("deploy_setup", %{"deploy" => answers}, socket) do
    base_url = Slipdock.Automations.Runner.base_url()

    case Slipdock.Deployments.Setup.connect(socket.assigns.board, answers, base_url) do
      {:ok, board, generated} ->
        {:noreply,
         assign(socket,
           board: board,
           deploy_setup: generated,
           deploy_prompt: nil,
           deploy_arrived: nil,
           board_form: to_form(Boards.change_board(board))
         )}

      {:error, message} when is_binary(message) ->
        {:noreply, flash(socket, :error, message)}

      {:error, _} ->
        {:noreply, flash(socket, :error, "Couldn't set deploys up.")}
    end
  end

  # The paste-into-Claude-Code prompt, which changes nothing.
  defp event("deploy_prompt", %{"deploy" => answers}, socket) do
    alias Slipdock.Deployments.Setup

    case Setup.normalise(answers) do
      {:ok, a} ->
        prompt =
          Setup.prompt(a, %{
            board: socket.assigns.board,
            base_url: Slipdock.Automations.Runner.base_url()
          })

        {:noreply, assign(socket, deploy_prompt: prompt)}

      {:error, message} ->
        {:noreply, flash(socket, :error, message)}
    end
  end

  defp event("validate_board", %{"board" => params}, socket) do
    board = socket.assigns.board
    params = suggest_board_code(params, board)
    cs = board |> Boards.change_board(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, board_form: to_form(cs)) |> keep_hotkey(params)}
  end

  # The hotkey rides in the same form but is the owner's own, not the board's
  # (see Slipdock.Hotkeys), so it is saved alongside rather than through the
  # board's changeset.
  defp event("save_board", %{"board" => params} = all, socket) do
    %{board: board, current_user: user} = socket.assigns

    with {:ok, _} <- Boards.update_board(board, params),
         {:ok, _} <- put_hotkey(user, board, all) do
      {:noreply, push_patch(socket, to: socket.assigns.close_path)}
    else
      {:error, %Ecto.Changeset{} = cs} -> {:noreply, assign(socket, board_form: to_form(cs))}
      {:error, message} -> {:noreply, flash(socket, :error, "Hotkey #{message}.")}
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
    case Boards.Milestones.create_milestone(
           socket.assigns.board,
           Map.take(params, ~w(name date color))
         ) do
      {:ok, _} ->
        {:noreply, update(socket, :form_key, &(&1 + 1))}

      {:error, _cs} ->
        {:noreply, flash(socket, :error, "A milestone needs a name and a date.")}
    end
  end

  defp event("delete_milestone", %{"id" => id}, socket) do
    milestone = Boards.Milestones.get_milestone!(id)

    if milestone.board_id == Slipdock.Boards.Board.root_id(socket.assigns.board) do
      {:ok, _} = Boards.Milestones.delete_milestone(milestone)
    end

    {:noreply, socket}
  end

  defp event("delete_board", _, socket) do
    {:ok, _} = Boards.delete_board(socket.assigns.board)
    {:noreply, socket |> put_flash(:info, "Board deleted.") |> push_navigate(to: ~p"/")}
  end

  defp event("archive_board", _, socket) do
    case Boards.Arrangement.archive_board(socket.assigns.board) do
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
    case Boards.Arrangement.unarchive_board(socket.assigns.board) do
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
        can_manage={@can_manage}
        hotkey={@hotkey}
        hotkeys={@hotkeys}
        deploy_setup={@deploy_setup}
        deploy_prompt={@deploy_prompt}
        deploy_arrived={@deploy_arrived}
        tab={@tab}
        target={@myself}
      />
    </div>
    """
  end

  defp put_hotkey(user, board, %{"hotkey" => value}) when is_nil(board.parent_card_id),
    do: Hotkeys.put(user, board, value)

  defp put_hotkey(_user, _board, _params), do: {:ok, nil}

  # What was picked, kept across the form's re-renders.
  defp keep_hotkey(socket, %{"hotkey" => value}) do
    case Hotkeys.parse(value) do
      {:ok, digit} -> assign(socket, hotkey: digit)
      _ -> socket
    end
  end

  defp keep_hotkey(socket, _params), do: socket

  # The digits, 1–9 then 0 as on the keyboard, each saying which of the
  # owner's other boards already has it — choosing it moves it here.
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
  attr :can_manage, :boolean, default: false
  attr :source_choices, :list, default: []
  attr :hotkey, :integer, default: nil
  attr :hotkeys, :list, default: []
  attr :target, :any, required: true
  attr :tab, :string, default: "general", doc: "the tab showing; see `tabs/0`"
  attr :deploy_setup, :map, default: nil, doc: "what Track deployments generated, token and all"
  attr :deploy_prompt, :string, default: nil, doc: "the paste-into-Claude-Code prompt, when asked"
  attr :deploy_arrived, :any, default: nil, doc: "the first deploy, once it has arrived"

  defp settings_modal(assigns) do
    ~H"""
    <.modal id="settings-modal" on_close={JS.patch(@close_path)} size="lg">
      <div class="space-y-5 p-6">
        <h2 class="section-title">Board settings</h2>
        <.tabs id="settings-tabs" label="Board settings" stretch>
          <:tab
            :for={{key, label, icon} <- tabs()}
            id={"settings-tab-#{key}"}
            active={@tab == key}
            icon={icon}
            controls={"settings-panel-#{key}"}
            phx-target={@target}
            phx-click="settings_tab"
            phx-value-tab={key}
          >
            {label}
          </:tab>
        </.tabs>
        <%!-- One form across General and Features. Every panel stays in the
              page and the others are only hidden, so what is typed on one
              tab is still there, and saved, from the other. --%>
        <.form
          phx-target={@target}
          for={@form}
          id="board-form"
          phx-change="validate_board"
          phx-submit="save_board"
          class="space-y-4"
        >
          <Panels.general_panel
            board={@board}
            form={@form}
            tab={@tab}
            hotkey={@hotkey}
            hotkeys={@hotkeys}
            target={@target}
          />
          <Panels.features_panel board={@board} form={@form} tab={@tab} />
          <div
            id="board-form-save"
            class={[
              "flex justify-end pt-2",
              @tab not in ~w(general features) && "hidden"
            ]}
          >
            <button type="submit" class="btn btn-primary btn-sm">Save</button>
          </div>
        </.form>
        <Panels.deploys_panel
          board={@board}
          tab={@tab}
          target={@target}
          deploy_setup={@deploy_setup}
          deploy_prompt={@deploy_prompt}
          deploy_arrived={@deploy_arrived}
        />
        <Panels.planning_panel
          board={@board}
          tab={@tab}
          target={@target}
          source_choices={@source_choices}
          form_key={@form_key}
        />
        <Panels.gardening_panel board={@board} tab={@tab} target={@target} />
        <Panels.sharing_panel
          tab={@tab}
          grants={@grants}
          groups={@groups}
          share_key={@share_key}
          target={@target}
        />
        <Panels.manage_panel board={@board} tab={@tab} target={@target} />
      </div>
    </.modal>
    """
  end
end

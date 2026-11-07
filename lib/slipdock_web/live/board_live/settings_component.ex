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
  import SlipdockWeb.ShareComponents
  import SlipdockWeb.SprintPlanComponents, only: [sources_fields: 1, parse_sources: 2, chosen: 1]
  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.{Access, Boards, Fields, Gardener, Hotkeys, Palette, Sprints}
  alias Slipdock.Boards.{Board, FieldDefinition}
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

  # Every panel is the one form column (#1741): at most 40rem, whatever the
  # modal's width, so a field never runs wider than what it holds.
  defp panel_class(tab, key), do: ["settings-column space-y-4", tab != key && "hidden"]

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

    case Boards.create_template(
           socket.assigns.current_user,
           Boards.template_attrs_from_board(board)
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

    with {:ok, board} <- save_routes(board, params["wait_routes"]),
         {:ok, _} <- Boards.update_board(board, Map.delete(params, "wait_routes")),
         {:ok, _} <- put_hotkey(user, board, all) do
      {:noreply, push_patch(socket, to: socket.assigns.close_path)}
    else
      {:error, :routes, message} -> {:noreply, assign(socket, routes_error: message)}
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

  # Each check with what it runs with on this board.
  defp gardening(board) do
    for check <- Gardener.checks() do
      settings = Gardener.Settings.for(board, check)

      %{
        key: check.key(),
        label: check.label(),
        enabled: settings["enabled"],
        thresholds: settings |> Map.delete("enabled") |> Enum.sort()
      }
    end
  end

  defp threshold_label("days"), do: "days"
  defp threshold_label("similarity"), do: "similarity"
  defp threshold_label("max_cards"), do: "up to"
  defp threshold_label("max_distance"), do: "edits"
  defp threshold_label(other), do: other

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
        routes={Slipdock.WaitRoutes.routes(@board)}
        routes_error={assigns[:routes_error]}
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

  # Who each kind of question goes to (#1949), from the five rows; only the
  # owner sees them, and a refusal is said above them (UX-29).
  defp save_routes(board, %{} = routes) do
    case Slipdock.WaitRoutes.set(board, routes) do
      {:ok, board} -> {:ok, board}
      {:error, message} -> {:error, :routes, message}
    end
  end

  defp save_routes(board, _routes), do: {:ok, board}

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
  attr :routes, :map, default: %{}, doc: "the board's wait routes, as people (#1949)"
  attr :routes_error, :string, default: nil
  attr :source_choices, :list, default: []
  attr :hotkey, :integer, default: nil
  attr :hotkeys, :list, default: []
  attr :target, :any, required: true
  attr :tab, :string, default: "general", doc: "the tab showing; see `tabs/0`"
  attr :deploy_setup, :map, default: nil, doc: "what Track deployments generated, token and all"
  attr :deploy_prompt, :string, default: nil, doc: "the paste-into-Claude-Code prompt, when asked"
  attr :deploy_arrived, :any, default: nil, doc: "the first deploy, once it has arrived"

  # The views a board can open on, less the ones it hides (a simple board's
  # Timeline and Prioritise). "board" first, as it is what nil means.
  defp default_view_options(board) do
    hidden = Enum.map(Board.hidden_views(board), &Atom.to_string/1)
    for view <- Board.default_views(), view not in hidden, do: {String.capitalize(view), view}
  end

  defp route_text(routes, kind),
    do: routes |> Map.get(kind, []) |> Enum.map_join(", ", & &1.email)

  defp route_label("product"), do: "Product questions"
  defp route_label("ux"), do: "UX questions"
  defp route_label("security"), do: "Security questions"
  defp route_label("release"), do: "Release questions (and audits that disagree)"
  defp route_label("other"), do: "Any other question"

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
          <div id="settings-panel-general" role="tabpanel" class={panel_class(@tab, "general")}>
            <.input field={@form[:name]} label="Name" />
            <%!-- Short values sit in boxes their own size, in pairs (#1741). --%>
            <div class="space-y-1">
              <div class="settings-pair">
                <.input
                  field={@form[:code]}
                  label="Code"
                  maxlength={Board.code_length()}
                  class="input field field-mono w-36"
                />
                <.input
                  :if={is_nil(@board.parent_card_id)}
                  field={@form[:shortcut]}
                  label="Shortcut key"
                  maxlength={Board.shortcut_length()}
                  class="input field field-mono w-16"
                />
              </div>
              <p class="text-xs text-base-content/60">
                The code is this board's handle in links and on the command line, up to {Board.code_length()} characters.
                <span :if={is_nil(@board.parent_card_id)}>
                  The shortcut key opens it from the switcher: press <kbd class="kbd kbd-xs">b</kbd>, then the key.
                </span>
                Clear one to take a fresh one from the name.
              </p>
            </div>
            <div :if={is_nil(@board.parent_card_id)} class="space-y-1">
              <div class="settings-pair">
                <.input
                  name="hotkey"
                  id="board-hotkey"
                  type="select"
                  label="Hotkey"
                  value={if @hotkey, do: to_string(@hotkey), else: ""}
                  options={Hotkeys.choices(@hotkeys, @board)}
                  class="select field w-44"
                />
                <.input
                  field={@form[:default_view]}
                  id="board-default-view"
                  type="select"
                  label="Default view"
                  options={default_view_options(@board)}
                  class="select field w-36"
                />
              </div>
              <p class="text-xs text-base-content/60">
                The hotkey opens this board from any page: <kbd class="kbd kbd-xs">Ctrl</kbd>
                + <kbd class="kbd kbd-xs">Shift</kbd>
                + the digit. Only you see your digits. Picking one that another board
                or your wiki already has moves it to this board. The default view is what
                opening the board shows.
              </p>
            </div>
            <.input field={@form[:description]} type="textarea" label="Description" />
            <div :if={is_nil(@board.parent_card_id)} class="settings-pair">
              <.input
                field={@form[:vote_budget]}
                type="number"
                min="0"
                label="Votes per person"
                class="input field w-24"
              />
              <.input
                field={@form[:vote_max]}
                type="number"
                min="1"
                label="Max votes per card"
                class="input field w-24"
              />
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
                  class="checkbox mt-0.5"
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
                  class="checkbox mt-0.5"
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
              <span class="field-label">Colour</span>
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
          </div>
          <div id="settings-panel-features" role="tabpanel" class={panel_class(@tab, "features")}>
            <%!-- The board's flow numbers as a strip over the lists (#1113).
                Off by default; the API, MCP and CLI have them either way. --%>
            <div class="space-y-1">
              <input type="hidden" name={@form[:show_pulse].name} value="false" />
              <label class="flex cursor-pointer items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  id="board-show-pulse"
                  name={@form[:show_pulse].name}
                  value="true"
                  checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:show_pulse].value)}
                  class="checkbox mt-0.5"
                />
                <span>
                  <span class="font-medium">Show the board's pulse</span>
                  <span class="block text-xs text-base-content/50">
                    A line over the lists: how many cards are in progress and waiting, how many
                    were done this week, and how long work usually takes to get done.
                  </span>
                </span>
              </label>
            </div>
            <%!-- Deploys and DORA metrics (#1134). Off by default, and while
                off the deploy endpoint refuses posts for the board. --%>
            <div class="space-y-1">
              <input type="hidden" name={@form[:delivery_metrics].name} value="false" />
              <label class="flex cursor-pointer items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  id="board-delivery-metrics"
                  name={@form[:delivery_metrics].name}
                  value="true"
                  checked={
                    Phoenix.HTML.Form.normalize_value("checkbox", @form[:delivery_metrics].value)
                  }
                  class="checkbox mt-0.5"
                />
                <span>
                  <span class="font-medium">Delivery metrics</span>
                  <span class="block text-xs text-base-content/50">
                    Record this project's deploys from CI and show how it delivers: how often it
                    ships, how long a change takes to reach production, how often a deploy fails
                    and how fast it is put right. Nothing is recorded while this is off.
                  </span>
                </span>
              </label>
              <div :if={@board.delivery_metrics} class="settings-pair pl-6">
                <.input
                  field={@form[:incident_tag]}
                  id="board-incident-tag"
                  label="Incident tag"
                  placeholder="incident"
                  class="input field w-36"
                />
                <.input
                  field={@form[:hotfix_window_hours]}
                  id="board-hotfix-hours"
                  type="number"
                  min="0"
                  label="Hotfix window (hours)"
                  class="input field w-24"
                />
                <.input
                  field={@form[:card_ref_pattern]}
                  id="board-card-ref-pattern"
                  label="Card ids in commits"
                  placeholder="#(\d+)"
                  class="input field field-mono w-36"
                />
              </div>
            </div>
            <%!-- WIP limits holding automated work (#1116, KTD11). Off by
                default: people's drags only ever see the badge. --%>
            <div class="space-y-1">
              <input type="hidden" name={@form[:automation_wip].name} value="false" />
              <label class="flex cursor-pointer items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  id="board-automation-wip"
                  name={@form[:automation_wip].name}
                  value="true"
                  checked={
                    Phoenix.HTML.Form.normalize_value("checkbox", @form[:automation_wip].value)
                  }
                  class="checkbox mt-0.5"
                />
                <span>
                  <span class="font-medium">WIP limits hold automated work</span>
                  <span class="block text-xs text-base-content/50">
                    While the first in-progress list is at its WIP limit, runner jobs and lists
                    that send cards wait, unless the card is in progress already. People can
                    still drag cards in.
                  </span>
                </span>
              </label>
            </div>
            <%!-- How long runner job logs stay (#1872). Set on the top
                board: a sub-board's jobs follow it. --%>
            <div :if={is_nil(@board.root_id)} id="board-job-logs" class="space-y-1">
              <span class="text-sm font-medium">Runner job logs</span>
              <p class="text-xs text-base-content/50">
                A job's live log is deleted this long after the job ends, unless someone keeps it
                as a page. Failed, cancelled, stuck or rejected work keeps the second time.
              </p>
              <div class="settings-pair">
                <.input
                  field={@form[:job_log_hours]}
                  id="board-job-log-hours"
                  type="number"
                  min="1"
                  max="8760"
                  label="Keep job logs for (hours)"
                  class="input field w-24"
                />
                <.input
                  field={@form[:failure_log_hours]}
                  id="board-failure-log-hours"
                  type="number"
                  min="1"
                  max="8760"
                  label="Keep failure logs for (hours)"
                  class="input field w-24"
                />
              </div>
            </div>
            <%!-- Verified work (#1620): optional checks on what agents say
                they finished. Every switch is off by default. --%>
            <div id="board-verified-work" class="space-y-1">
              <span class="text-sm font-medium">Verified work</span>
              <p class="text-xs text-base-content/50">
                Checks on agents' work. People complete cards as usual whichever is on.
              </p>
              <input type="hidden" name={@form[:bar_required].name} value="false" />
              <label class="flex cursor-pointer items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  id="board-bar-required"
                  name={@form[:bar_required].name}
                  value="true"
                  checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:bar_required].value)}
                  class="checkbox mt-0.5"
                />
                <span>
                  <span class="font-medium">A bar before work starts</span>
                  <span class="block text-xs text-base-content/50">
                    An agent writes what done means on the card before moving it into an
                    in-progress list, and the bar locks then: only a person can change it after.
                  </span>
                </span>
              </label>
              <input type="hidden" name={@form[:lanes].name} value="false" />
              <label class="flex cursor-pointer items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  id="board-lanes"
                  name={@form[:lanes].name}
                  value="true"
                  checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:lanes].value)}
                  class="checkbox mt-0.5"
                />
                <span>
                  <span class="font-medium">Lanes</span>
                  <span class="block text-xs text-base-content/50">
                    An agent can't start a card whose paths overlap a card in progress, so agents
                    side by side stay out of each other's files. Moving a card yourself overrides it.
                  </span>
                </span>
              </label>
              <%!-- Profiles (#1951): one word for what kind of change a card is. --%>
              <input type="hidden" name={@form[:profiles].name} value="false" />
              <label class="flex cursor-pointer items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  id="board-profiles"
                  name={@form[:profiles].name}
                  value="true"
                  checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:profiles].value)}
                  class="checkbox mt-0.5"
                />
                <span>
                  <span class="font-medium">Profiles</span>
                  <span class="block text-xs text-base-content/50">
                    An agent claiming or starting a card with no profile gives it one, inferred
                    from its paths and tags: security, schema, spike, fix, docs or feature. It is
                    shown on the card; nothing acts on it yet.
                  </span>
                </span>
              </label>
              <input type="hidden" name={@form[:evidence_required].name} value="false" />
              <label class="flex cursor-pointer items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  id="board-evidence-required"
                  name={@form[:evidence_required].name}
                  value="true"
                  checked={
                    Phoenix.HTML.Form.normalize_value("checkbox", @form[:evidence_required].value)
                  }
                  class="checkbox mt-0.5"
                />
                <span>
                  <span class="font-medium">Evidence on completion</span>
                  <span class="block text-xs text-base-content/50">
                    An agent completing a card says what it checked, and the commit it checked
                    at. The evidence is kept on the card and as a comment.
                  </span>
                </span>
              </label>
              <input type="hidden" name={@form[:verify_work].name} value="false" />
              <label class="flex cursor-pointer items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  id="board-verify-work"
                  name={@form[:verify_work].name}
                  value="true"
                  checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:verify_work].value)}
                  class="checkbox mt-0.5"
                />
                <span>
                  <span class="font-medium">A second agent verifies</span>
                  <span class="block text-xs text-base-content/50">
                    An agent completing a card submits it: it waits, flagged for review, until a
                    different agent or a person accepts it (it is then done) or rejects it with
                    the reason.
                  </span>
                </span>
              </label>
              <div :if={@board.verify_work} class="pl-6">
                <.input
                  field={@form[:verify_pool]}
                  id="board-verify-pool"
                  label="Runner pool for verify jobs"
                  placeholder="none: verify by hand"
                />
                <p class="-mt-1 text-xs text-base-content/50">
                  Each submitted card is queued for this pool as a job of kind <code>verify</code>. Blank queues nothing.
                </p>
                <%!-- Repeated rejections go to a person (#1779). --%>
                <.input
                  field={@form[:verify_rejection_limit]}
                  id="board-verify-rejection-limit"
                  type="number"
                  min="0"
                  max="50"
                  label="Rejections before a person decides"
                />
                <p class="-mt-1 text-xs text-base-content/50">
                  The rejection after this many opens a wait on the board's owner: rework the
                  card as rejected, or accept it as is. 0 never asks.
                </p>
                <%!-- Spot-checks of accepted work (#1780). --%>
                <.input
                  field={@form[:verify_audit]}
                  id="board-verify-audit"
                  type="number"
                  min="0"
                  max="1000"
                  label="Audit 1 in N accepted cards"
                />
                <p class="-mt-1 text-xs text-base-content/50">
                  About one card in N that an agent accepted is checked again by another runner
                  in the pool. An audit only comments; one that disagrees alerts you. 0 audits none.
                </p>
                <%!-- How accepted work reaches the default branch (#1654). --%>
                <.input
                  field={@form[:ship_via]}
                  id="board-ship-via"
                  type="select"
                  label="Ship accepted work by"
                  options={[
                    {"Push: the agent pushes the default branch", "push"},
                    {"Pull request: accepting it merges the agent's pull request", "pull_request"}
                  ]}
                />
                <p class="-mt-1 text-xs text-base-content/50">
                  With pull request, an agent pushes a <code>card-&lt;id&gt;</code>
                  branch and opens a pull request, never the default branch. Accepting the card
                  sends a runner a merge job, and the merge deploys.
                </p>
              </div>
            </div>
            <%!-- Promotion by recurrence (#1942, `Slipdock.Findings.Promote`). --%>
            <div class="space-y-1">
              <span class="text-sm font-medium">Findings</span>
              <.input
                field={@form[:findings_propose_at]}
                id="board-findings-propose-at"
                type="number"
                min="0"
                max="100"
                label="Propose a rule when a finding is seen this many times"
              />
              <p class="-mt-1 text-xs text-base-content/50">
                On a board with a handbook, the lesson is drafted as a rule on the Tidy-up page for
                you to apply or dismiss. 0 never proposes.
              </p>
            </div>
            <%!-- Who each kind of question goes to (#1949, `Slipdock.WaitRoutes`). --%>
            <div :if={@can_manage} id="board-wait-routes" class="space-y-1">
              <span class="text-sm font-medium">Who gets asked</span>
              <p class="text-xs text-base-content/60">
                A wait an agent opens with a kind of question goes to the first person named for
                it; the others are told. Emails of people on the board, comma-separated. Blank
                sends it to the board's owner.
              </p>
              <.callout :if={@routes_error} id="board-wait-routes-error" kind={:error}>
                {@routes_error}
              </.callout>
              <.input
                :for={kind <- Slipdock.WaitRoutes.kinds()}
                id={"board-route-#{kind}"}
                name={"board[wait_routes][#{kind}]"}
                value={route_text(@routes, kind)}
                label={route_label(kind)}
                placeholder="the board's owner"
              />
            </div>
            <%!-- What a card's handoff is called on this board, and what the
                AI is told when it drafts one (#1212). Blank is the default. --%>
            <div class="space-y-1">
              <span class="text-sm font-medium">Handoffs</span>
              <p class="text-xs text-base-content/50">
                Where a card was left, for whoever picks it up next. Leave these blank for the
                defaults.
              </p>
              <.input
                field={@form[:handoff_label]}
                id="board-handoff-label"
                label="Label"
                placeholder={Board.default_handoff_label()}
                maxlength={Board.handoff_limits().label}
              />
              <.input
                field={@form[:handoff_prompt]}
                id="board-handoff-prompt"
                type="textarea"
                rows="6"
                label="Instructions for Auto generate"
                placeholder={Slipdock.AI.HandoffDrafter.default_instructions()}
                maxlength={Board.handoff_limits().prompt}
              />
              <p class="-mt-1 text-xs text-base-content/50">
                What the AI model is told when it drafts a handoff from the card. It is always
                asked to answer with a next step and a note, whatever this says.
              </p>
            </div>
            <%!-- Who else may mail the board's card addresses (#1289,
                `Board.permitted_sender?/2`). Only while the server takes mail. --%>
            <div :if={Slipdock.Inbound.enabled?()} class="space-y-1">
              <span class="text-sm font-medium">Permitted senders</span>
              <p class="text-xs text-base-content/50">
                Besides each person's own address, the board's card addresses take mail from these
                addresses, one per line. What they send is added as the address's owner and says
                who sent it. They can't answer a wait, and pages are still yours alone.
              </p>
              <.input
                field={@form[:inbound_senders]}
                id="board-form-inbound-senders"
                type="textarea"
                rows="3"
                value={senders_text(@form[:inbound_senders].value)}
                placeholder="ann@example.com"
              />
            </div>
            <%!-- Every board has a wiki: this is the whole wiki's switch for
                the card contents under a page's prose. Hidden, not removed. --%>
            <div class="space-y-1">
              <input type="hidden" name={@form[:page_card_features].name} value="false" />
              <label class="flex cursor-pointer items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  id="board-page-card-features"
                  name={@form[:page_card_features].name}
                  value="true"
                  checked={
                    Phoenix.HTML.Form.normalize_value("checkbox", @form[:page_card_features].value)
                  }
                  class="checkbox mt-0.5"
                />
                <span>
                  <span class="font-medium">Card features on wiki pages</span>
                  <span class="block text-xs text-base-content/50">
                    Status, checklist, links, fields, votes and comments under every page in this
                    board's wiki. Untick for a wiki that is only documents; nothing is deleted.
                  </span>
                </span>
              </label>
            </div>
          </div>
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
        <%!-- Track deployments (#1134): one generator behind this, the API and
              `slipdock deploy setup` (Slipdock.Deployments.Setup). --%>
        <div id="settings-panel-deploys" role="tabpanel" class={panel_class(@tab, "deploys")}>
          <div id="deploy-setup" class="space-y-2">
            <span class="text-sm font-medium">Track deployments</span>
            <p class="text-xs text-base-content/50">
              Record this project's deploys from CI, for its delivery metrics and a
              “Shipped” line on the cards each deploy names. Setting up turns Delivery metrics on
              and issues a deploy token that can record deploys and nothing else.
            </p>
            <form
              id="deploy-setup-form"
              phx-target={@target}
              phx-submit="deploy_setup"
              class="grid grid-cols-1 gap-2 sm:grid-cols-3"
            >
              <label class="text-xs">
                <span class="field-label">CI</span>
                <select name="deploy[ci]" class="select field w-full">
                  <option :for={ci <- Slipdock.Deployments.Setup.cis()} value={ci}>
                    {Slipdock.Deployments.Setup.label(ci)}
                  </option>
                </select>
              </label>
              <label class="text-xs">
                <span class="field-label">Environments</span>
                <input
                  name="deploy[environments]"
                  value="production"
                  class="input field w-full"
                />
              </label>
              <label class="text-xs">
                <span class="field-label">Card ids in commits</span>
                <input
                  name="deploy[card_ref_pattern]"
                  value={@board.card_ref_pattern}
                  placeholder="#(\d+)"
                  class="input field w-full field-mono"
                />
              </label>
              <div class="flex flex-wrap gap-2 sm:col-span-3">
                <button
                  type="submit"
                  name="do"
                  value="setup"
                  id="deploy-setup-button"
                  class="btn btn-sm btn-primary"
                  data-confirm={
                    Slipdock.Deployments.token?(@board) &&
                      "This issues a new deploy token; the one CI has now stops working."
                  }
                >
                  <.icon name="hero-rocket-launch" class="size-4" />
                  {if Slipdock.Deployments.token?(@board), do: "Set up again", else: "Set up"}
                </button>
                <button
                  type="submit"
                  class="btn btn-sm btn-ghost"
                  name="do"
                  value="prompt"
                  id="deploy-prompt-button"
                >
                  <.icon name="hero-sparkles" class="size-4" />
                  Set this up for me (prompt for Claude Code)
                </button>
              </div>
            </form>
            <div :if={@deploy_setup} id="deploy-setup-result" class="space-y-2">
              <pre class="max-h-96 overflow-auto whitespace-pre-wrap rounded bg-base-200 p-3 text-xs">{@deploy_setup.text}</pre>
              <p
                :if={!@deploy_arrived}
                id="deploy-waiting"
                class="flex items-center gap-2 text-xs text-base-content/60"
              >
                <span class="loading loading-dots loading-xs"></span> Waiting for the first deploy…
              </p>
            </div>
            <p
              :if={@deploy_arrived}
              id="deploy-arrived"
              class="flex items-center gap-2 text-sm text-success"
            >
              <.icon name="hero-check-circle" class="size-4" />
              First deploy arrived: {String.slice(@deploy_arrived.sha, 0, 7)} to {@deploy_arrived.environment}.
            </p>
            <div :if={@deploy_prompt} id="deploy-prompt" class="space-y-1">
              <p class="text-xs text-base-content/60">
                Paste this into Claude Code in the repository. It names the secret to add; the token
                is issued by Set up above, or <code>slipdock deploy token {@board.code}</code>.
              </p>
              <pre class="max-h-96 overflow-auto whitespace-pre-wrap rounded bg-base-200 p-3 text-xs">{@deploy_prompt}</pre>
            </div>
          </div>
        </div>
        <div id="settings-panel-planning" role="tabpanel" class={panel_class(@tab, "planning")}>
          <%!-- What Add cards… on a sprint shows side by side (Sprints.sources/2). --%>
          <form
            :if={Board.sprints?(@board) and is_nil(@board.parent_card_id)}
            id="sprint-sources-form"
            phx-target={@target}
            phx-change="set_sprint_sources"
            class="space-y-2"
          >
            <span class="text-sm font-medium">Plan sprints from</span>
            <p class="text-xs text-base-content/50">
              The boards, and lists on them, that Add cards… on a sprint shows side by side, with
              their scores, estimates and running totals. No list ticked means every open list.
            </p>
            <.sources_fields choices={@source_choices} chosen={chosen(@board)} />
          </form>
          <div class="space-y-2" id="board-fields">
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
                    class="checkbox"
                    phx-click="toggle_field_sum"
                    phx-value-id={f.id}
                    checked={f.sum}
                  /> Σ
                </label>
                <button
                  phx-target={@target}
                  type="button"
                  class="btn btn-ghost btn-error btn-xs btn-square"
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
                  class="input field min-w-0 flex-1"
                  required
                  autocomplete="off"
                />
                <select name="kind" class="select field w-28" title="Kind">
                  <option :for={{k, l} <- FieldDefinition.kinds()} value={k}>{l}</option>
                </select>
              </div>
              <input
                type="text"
                name="options"
                placeholder="Choices, e.g. Small=1, Medium=2, Large=3"
                class="input field w-full"
                autocomplete="off"
              />
              <input
                type="text"
                name="expression"
                placeholder="Formula, e.g. {value} / {effort}"
                class="input field w-full field-mono"
                autocomplete="off"
              />
              <div class="flex items-center justify-between">
                <label class="flex cursor-pointer items-center gap-1 text-xs">
                  <input type="checkbox" name="sum" value="true" class="checkbox" /> Roll up totals
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
                  class="btn btn-ghost btn-error btn-xs btn-square"
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
                class="input field min-w-0 flex-1"
                required
                autocomplete="off"
              />
              <.date_field id="milestone-date" name="date" required aria-label="Milestone date" />
              <select name="color" class="select field w-28" title="Colour">
                <option value="">Colour</option>
                <option :for={{n, l} <- Palette.all()} value={n}>{l}</option>
              </select>
              <button type="submit" class="btn btn-primary btn-sm">Add</button>
            </form>
          </div>
        </div>
        <div id="settings-panel-gardening" role="tabpanel" class={panel_class(@tab, "gardening")}>
          <form
            phx-target={@target}
            id="gardening-form"
            phx-change="set_gardening"
            class="space-y-2"
          >
            <span class="text-sm font-medium">Gardening</span>
            <p class="text-xs text-base-content/50">
              What <.link navigate={~p"/boards/#{@board}/tidy"} class="link">Tidy up…</.link>
              looks for on this board and every board beneath it, and how long before something counts.
            </p>
            <div
              :for={c <- gardening(@board)}
              id={"gardening-#{c.key}"}
              class="flex items-center gap-2 text-sm"
            >
              <input type="hidden" name={"gardening[#{c.key}][enabled]"} value="false" />
              <input
                type="checkbox"
                class="checkbox"
                id={"gardening-#{c.key}-enabled"}
                name={"gardening[#{c.key}][enabled]"}
                value="true"
                checked={c.enabled}
              />
              <label for={"gardening-#{c.key}-enabled"} class="min-w-0 flex-1 truncate">{c.label}</label>
              <label
                :for={{k, v} <- c.thresholds}
                class="flex items-center gap-1 text-xs text-base-content/60"
              >
                {threshold_label(k)}
                <input
                  type="number"
                  name={"gardening[#{c.key}][#{k}]"}
                  value={v}
                  min={if is_float(v), do: "0.5", else: "1"}
                  max={if is_float(v), do: "1"}
                  step={if is_float(v), do: "0.01", else: "1"}
                  class="input field w-20"
                  phx-debounce="500"
                />
              </label>
            </div>
          </form>
        </div>
        <div id="settings-panel-sharing" role="tabpanel" class={panel_class(@tab, "sharing")}>
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
        <div id="settings-panel-manage" role="tabpanel" class={panel_class(@tab, "manage")}>
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
          <div class="pt-2">
            <button
              phx-target={@target}
              type="button"
              class="btn btn-ghost btn-error btn-sm"
              phx-click="delete_board"
              data-confirm={"Delete “#{@board.name}” and everything on it? This cannot be undone."}
            >
              <.icon name="hero-trash" class="size-4" /> Delete board
            </button>
          </div>
        </div>
      </div>
    </.modal>
    """
  end

  # The permitted senders, one per line, as the textarea shows them.
  defp senders_text(senders) when is_list(senders), do: Enum.join(senders, "\n")
  defp senders_text(senders), do: senders
end

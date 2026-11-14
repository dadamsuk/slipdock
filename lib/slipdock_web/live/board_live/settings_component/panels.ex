defmodule SlipdockWeb.BoardLive.SettingsComponent.Panels do
  @moduledoc """
  The panels of the board's settings modal
  (`SlipdockWeb.BoardLive.SettingsComponent`), one per tab. Every panel stays
  in the page and is only hidden while another tab shows. The General and
  Features panels are drawn inside the modal's one form; the others hold
  forms and buttons of their own. Each is given the assigns it reads, by
  name, and sends its events to `target`.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.ShareComponents
  import SlipdockWeb.SprintPlanComponents, only: [sources_fields: 1, chosen: 1]
  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.{Fields, Gardener, Hotkeys, Palette}
  alias Slipdock.Boards.{Board, FieldDefinition}

  # Every panel is the one form column (#1741): at most 40rem, whatever the
  # modal's width, so a field never runs wider than what it holds.
  defp panel_class(tab, key), do: ["settings-column space-y-4", tab != key && "hidden"]

  attr :board, :any, required: true
  attr :form, :any, required: true
  attr :tab, :string, required: true, doc: "the tab showing"
  attr :hotkey, :integer, required: true
  attr :hotkeys, :list, required: true
  attr :target, :any, required: true, doc: "the settings component, which takes the events"

  @doc "The General tab: what the board is called and how it opens. Inside the board form."
  def general_panel(assigns) do
    ~H"""
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
        <.switch_field
          field={@form[:kind]}
          id="board-kind-sprints"
          label="Sprint board"
          value="sprints"
          unchecked=""
          checked={@form[:kind].value == "sprints"}
        >
          Every card is a sprint, with its work as subcards. Adds New sprint, and Add
          cards… to pick work from your other boards into a sprint.
        </.switch_field>
      </div>
      <%!-- A plain to-do list: the tracking details stay out of sight
                (`Board.simple?/1`). Hidden, not removed. --%>
      <div class="space-y-1">
        <.switch_field
          field={@form[:simple]}
          id="board-simple"
          label="Simple board"
        >
          For a plain to-do list. Hides % complete, start dates, health, time tracking,
          votes and dependencies on its cards, and the Timeline and Prioritise views.
          Nothing is deleted; untick it to bring them back.
        </.switch_field>
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
    """
  end

  attr :board, :any, required: true
  attr :form, :any, required: true
  attr :tab, :string, required: true, doc: "the tab showing"

  @doc "The Features tab: what the board switches on. Inside the board form."
  def features_panel(assigns) do
    ~H"""
    <div id="settings-panel-features" role="tabpanel" class={panel_class(@tab, "features")}>
      <%!-- The board's flow numbers as a strip over the lists (#1113).
                Off by default; the API, MCP and CLI have them either way. --%>
      <div class="space-y-1">
        <.switch_field
          field={@form[:show_pulse]}
          id="board-show-pulse"
          label="Show the board's pulse"
        >
          A line over the lists: how many cards are in progress and waiting, how many
          were done this week, and how long work usually takes to get done.
        </.switch_field>
      </div>
      <%!-- Deploys and DORA metrics (#1134). Off by default, and while
                off the deploy endpoint refuses posts for the board. --%>
      <div class="space-y-1">
        <.switch_field
          field={@form[:delivery_metrics]}
          id="board-delivery-metrics"
          label="Delivery metrics"
        >
          Record this project's deploys from CI and show how it delivers: how often it
          ships, how long a change takes to reach production, how often a deploy fails
          and how fast it is put right. Nothing is recorded while this is off.
        </.switch_field>
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
          <%!-- The not-shipped watch (#2819): overseer on or off. --%>
          <.input
            field={@form[:not_shipped_minutes]}
            id="board-not-shipped-minutes"
            type="number"
            min="0"
            label="Not shipped after (minutes)"
            title="A merged card no succeeded deploy names after this long raises an alert and says so on the card. 0: never."
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
      <%!-- Agentic Building (#2011): one switch for the board menu's
                item and page that hold every agent setting. Off hides them
                and changes no setting, so a rule still set is named. --%>
      <div id="board-agentic" class="space-y-2">
        <.switch_field
          field={@form[:agentic_building]}
          id="board-agentic-building"
          label="Agentic Building"
        >
          For a board coding agents work on. Adds Agentic Building to the board menu: one
          page for verified work, lanes, profiles, who gets asked, handoffs, findings and
          runner settings.
        </.switch_field>
        <.link
          :if={@board.agentic_building}
          navigate={~p"/boards/#{@board}/agentic"}
          id="board-agentic-open"
          class="link ml-6 text-sm"
        >
          Open Agentic Building
        </.link>
        <.callout
          :if={agentic_off_warning(@form, @board) != []}
          id="board-agentic-warning"
          kind={:warning}
        >
          These rules still hold with it off, out of sight: {Enum.join(
            agentic_off_warning(@form, @board),
            ", "
          )}. Turn them off on its page first to stop them.
        </.callout>
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
        <.switch_field
          field={@form[:page_card_features]}
          id="board-page-card-features"
          label="Card features on wiki pages"
        >
          Status, checklist, links, fields, votes and comments under every page in this
          board's wiki. Untick for a wiki that is only documents; nothing is deleted.
        </.switch_field>
      </div>
    </div>
    """
  end

  attr :board, :any, required: true
  attr :tab, :string, required: true, doc: "the tab showing"
  attr :target, :any, required: true, doc: "the settings component, which takes the events"
  attr :deploy_setup, :map, required: true, doc: "what Track deployments generated, token and all"

  attr :deploy_prompt, :string,
    required: true,
    doc: "the paste-into-Claude-Code prompt, when asked"

  attr :deploy_arrived, :any, required: true, doc: "the first deploy, once it has arrived"

  @doc "The Deploys tab: setting up deploy tracking from CI."
  def deploys_panel(assigns) do
    ~H"""
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
    """
  end

  attr :board, :any, required: true
  attr :tab, :string, required: true, doc: "the tab showing"
  attr :target, :any, required: true, doc: "the settings component, which takes the events"
  attr :source_choices, :list, required: true
  attr :form_key, :integer, required: true

  @doc "The Planning tab: sprint sources, custom fields and milestones."
  def planning_panel(assigns) do
    ~H"""
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
    """
  end

  attr :board, :any, required: true
  attr :tab, :string, required: true, doc: "the tab showing"
  attr :target, :any, required: true, doc: "the settings component, which takes the events"

  @doc "The Gardening tab: what Tidy up looks for, and its thresholds."
  def gardening_panel(assigns) do
    ~H"""
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
    """
  end

  attr :tab, :string, required: true, doc: "the tab showing"
  attr :grants, :list, required: true
  attr :groups, :list, required: true
  attr :share_key, :integer, required: true
  attr :target, :any, required: true, doc: "the settings component, which takes the events"

  @doc "The Sharing tab: who has access to the board."
  def sharing_panel(assigns) do
    ~H"""
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
    """
  end

  attr :board, :any, required: true
  attr :tab, :string, required: true, doc: "the tab showing"
  attr :target, :any, required: true, doc: "the settings component, which takes the events"

  @doc "The Manage tab: template, archive, restore and delete."
  def manage_panel(assigns) do
    ~H"""
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
    """
  end

  # The views a board can open on, less the ones it hides (a simple board's
  # Timeline and Prioritise). "board" first, as it is what nil means.
  defp default_view_options(board) do
    hidden = Enum.map(Board.hidden_views(board), &Atom.to_string/1)

    for view <- Board.default_views(),
        not Enum.member?(hidden, view),
        do: {String.capitalize(view), view}
  end

  # The agent rules still set while the form turns Agentic Building off
  # (#2011): they hold on, so they are named before it is saved.
  defp agentic_off_warning(form, board) do
    if Phoenix.HTML.Form.normalize_value("checkbox", form[:agentic_building].value),
      do: [],
      else: Slipdock.AgenticBuilding.live_rules(board)
  end

  # The permitted senders, one per line, as the textarea shows them.
  defp senders_text(senders) when is_list(senders), do: Enum.join(senders, "\n")
  defp senders_text(senders), do: senders

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
end

defmodule SlipdockWeb.AgenticLive.Index do
  @moduledoc """
  A board's Agentic Building page (#2011, `Slipdock.AgenticBuilding`): every
  setting about how agents build on the board, in sections, under a strip
  that says at a glance which rules are on.

  The board menu's **Agentic Building** item opens it, while the board's
  switch is on (Board settings, Features). Off, the page sends you back to
  the board: the settings keep their values and go on holding.

  The board's owner changes the settings; anyone else who can read the
  board sees them read-only. On a sub-board the root-only settings (the
  human tier and the job logs) are shown read-only, with a link to the root
  board's page where they are set.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Access, AgenticBuilding, Boards, Profiles, WaitRoutes}
  alias Slipdock.Boards.Board
  alias SlipdockWeb.AgenticLive.Hub

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    with %Board{} = board <- Boards.get_board(id),
         perm = Access.board_permission(user, board),
         true <- Access.can_read?(perm) do
      if AgenticBuilding.on?(board) do
        subscribe_releases(socket, board)

        {:ok,
         socket
         |> assign(
           board: board,
           root: root(board),
           can_manage: perm == :owner,
           routes_error: nil,
           release: release_status(board),
           page_title: "Agentic Building · #{board.name}",
           page_jumps: []
         )
         |> reset_form(board)
         |> load_hub()}
      else
        {:ok, switched_off(socket, board, perm)}
      end
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to that board.")
         |> push_navigate(to: "/")}
    end
  end

  # Off hides the page (#2011): the owner is taken to where it is turned on.
  defp switched_off(socket, board, :owner) do
    socket
    |> put_flash(:info, "Agentic Building is off for this board. Turn it on here to open it.")
    |> push_navigate(to: ~p"/boards/#{board}/settings?tab=features")
  end

  defp switched_off(socket, board, _perm) do
    socket
    |> put_flash(:info, "This board doesn't use Agentic Building.")
    |> push_navigate(to: ~p"/boards/#{board}")
  end

  # The tiles' counts (#2012), read again every half minute so they
  # stay live while the page is open.
  @hub_every 30_000

  defp load_hub(socket) do
    if connected?(socket), do: Process.send_after(self(), :hub, @hub_every)
    assign(socket, hub: Hub.counts(socket.assigns.board))
  end

  @impl true
  def handle_info(:hub, socket), do: {:noreply, load_hub(socket)}

  # A release was asked for, started or ended on this tree (#2835).
  def handle_info({:release_changed, _root_id}, socket),
    do: {:noreply, assign(socket, release: release_status(socket.assigns.board))}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp root(%Board{root_id: nil}), do: nil
  defp root(%Board{root_id: id}), do: Boards.get_board(id)

  defp reset_form(socket, board) do
    assign(socket,
      board: board,
      form: to_form(Boards.change_board(board)),
      routes: WaitRoutes.routes(board)
    )
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{can_manage: false}} = socket),
    do: {:noreply, put_flash(socket, :error, "Only the board's owner can change these.")}

  def handle_event("validate", %{"board" => params}, socket) do
    cs =
      socket.assigns.board
      |> Boards.change_board(Map.delete(params, "wait_routes"))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("save", %{"board" => params}, socket) do
    board = socket.assigns.board
    params = Map.take(params, Enum.map(AgenticBuilding.fields(), &to_string/1))

    with {:ok, board} <- save_routes(board, params["wait_routes"]),
         {:ok, board} <- Boards.update_board(board, Map.delete(params, "wait_routes")) do
      {:noreply,
       socket
       |> assign(routes_error: nil)
       |> reset_form(board)
       |> put_flash(:info, "Saved. Agents pick the new rules up on their next step.")}
    else
      {:error, :routes, message} ->
        {:noreply, assign(socket, routes_error: message)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :validate)))}
    end
  end

  # Release now (#2835): the tree's merged work, in the owner's name.
  def handle_event("release_now", _params, socket) do
    %{board: board, current_user: user} = socket.assigns

    socket =
      case Slipdock.Releases.release_now(board, Slipdock.Accounts.User.display_name(user)) do
        {:ok, how, _request} -> put_flash(socket, :info, Slipdock.Releases.said(how))
        {:error, reason} -> put_flash(socket, :error, Slipdock.Releases.refusal(reason))
      end

    {:noreply, assign(socket, release: release_status(board))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A connected page hears the tree's releases change (#2835).
  defp subscribe_releases(socket, board) do
    if connected?(socket), do: Slipdock.Releases.subscribe(board)
  end

  # Where the tree's releases stand (#2835); nil unless it is batched.
  defp release_status(%Board{} = board) do
    if Slipdock.Releases.batched?(board), do: Slipdock.Releases.status(board)
  end

  defp save_routes(board, %{} = routes) do
    case WaitRoutes.set(board, routes) do
      {:ok, board} -> {:ok, board}
      {:error, message} -> {:error, :routes, message}
    end
  end

  defp save_routes(board, _routes), do: {:ok, board}

  # What the form says now, so a section opens as its switch is ticked.
  defp on?(field), do: Phoenix.HTML.Form.normalize_value("checkbox", field.value)

  @doc false
  # The strip at the top (#2011): each rule with whether it is on and what
  # it is set to, from the saved board, linking to its section.
  def summary(%Board{} = b, routes) do
    # `WaitRoutes.routes/1` lists every kind, an unrouted one with nobody.
    routed = Enum.count(routes, fn {_kind, people} -> people != [] end)
    # A tree's release settings are its root's (#2834).
    release = Slipdock.Releases.settings(b)

    [
      {"bar", "verified", "Bar before work", b.bar_required, nil},
      {"evidence", "verified", "Evidence", b.evidence_required, nil},
      {"verify", "verified", "Second agent verifies", b.verify_work,
       b.verify_work && b.verify_pool && "pool #{b.verify_pool}"},
      {"ship", "verified", "Ships by pull request", b.ship_via == "pull_request", nil},
      {"release", "releases", "Batched releases", release.mode == "batched",
       release.mode == "batched" && release.age_cap_hours &&
         "at most #{release.age_cap_hours}h"},
      {"lanes", "lanes", "Lanes", b.lane_mode != "off", b.lane_mode != "off" && b.lane_mode},
      {"profiles", "profiles", "Profiles", b.profiles, nil},
      {"routes", "questions", "Questions routed", routed > 0,
       routed > 0 && "#{routed} of #{length(WaitRoutes.kinds())}"},
      {"defaults", "questions", "Approvals default", b.wait_default_after != nil,
       b.wait_default_after && "after #{Slipdock.WaitDefaults.format(b.wait_default_after)}"},
      {"findings", "findings", "Findings promoted", b.findings_propose_at > 0,
       b.findings_propose_at > 0 && "at #{b.findings_propose_at}"},
      {"wip", "runners", "WIP holds automation", b.automation_wip, nil}
    ]
  end

  # The root's release settings, read from a sub-board (#2834).
  defp release_text(%Board{release_mode: "batched", release_age_cap_hours: nil}),
    do: "Batched: merges wait for a release, with no age cap."

  defp release_text(%Board{release_mode: "batched", release_age_cap_hours: hours}),
    do: "Batched: merges wait for a release, at most #{hours} hours."

  defp release_text(_root), do: "On merge: each merge deploys."

  # `wait_default_after` (#2096) as typed, else the saved minutes as `4h`.
  defp wait_default_text(form) do
    case form.params do
      %{"wait_default_after" => typed} -> typed
      _ -> Slipdock.WaitDefaults.format(form.data.wait_default_after)
    end
  end

  defp route_text(routes, kind),
    do: routes |> Map.get(kind, []) |> Enum.map_join(", ", & &1.email)

  defp route_label("product"), do: "Product questions"
  defp route_label("ux"), do: "UX questions"
  defp route_label("security"), do: "Security questions"
  defp route_label("release"), do: "Release questions (and audits that disagree)"
  defp route_label("other"), do: "Any other question"

  defp globs_text(nil), do: ""
  defp globs_text(globs) when is_list(globs), do: Enum.join(globs, "\n")
  defp globs_text(text), do: text

  # Each profile's tier as the form has it (#1952): the board's changes, or
  # what was just chosen, over the defaults.
  defp tiers_shown(form), do: Profiles.tiers_with(form[:profile_tiers].value)

  defp tier_text("none"), do: "merged on an agent's acceptance"
  defp tier_text("ledger"), do: "merged, then on the Ledger"
  defp tier_text("before_merge"), do: "a person merges it"
  defp tier_text(other), do: other

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :count, :string, default: nil, doc: "how many of the section's rules are on"
  slot :about, required: true
  slot :inner_block, required: true

  # One section: an icon, a heading and one plain line, then its settings
  # in the 40rem column (#1741).
  defp section(assigns) do
    ~H"""
    <section
      id={"agentic-#{@id}"}
      aria-labelledby={"agentic-#{@id}-title"}
      class="agentic-section scroll-mt-20 rounded-box bg-base-100 p-4 ring-1 ring-base-content/10 sm:p-6"
    >
      <header class="mb-4 flex items-start gap-3">
        <span class="grid size-9 shrink-0 place-items-center rounded-lg bg-primary/10 text-primary">
          <.icon name={@icon} class="size-5" />
        </span>
        <div class="min-w-0 flex-1">
          <h2 id={"agentic-#{@id}-title"} class="flex items-center gap-2 text-base font-semibold">
            {@title}
            <span
              :if={@count}
              class="badge badge-ghost badge-sm tabular-nums"
              data-role="section-count"
            >
              {@count}
            </span>
          </h2>
          <p class="text-sm text-base-content/70">{render_slot(@about)}</p>
        </div>
      </header>
      <div class="settings-column space-y-4 sm:pl-12">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  # A switch named for its setting (UX-37), with a line saying what it does.
  defp switch(assigns) do
    ~H"""
    <div>
      <input type="hidden" name={@field.name} value="false" />
      <label class="flex cursor-pointer items-start gap-3 text-sm">
        <input
          type="checkbox"
          role="switch"
          id={@id}
          name={@field.name}
          value="true"
          checked={on?(@field)}
          class="toggle mt-0.5 shrink-0"
        />
        <span>
          <span class="font-medium">{@label}</span>
          <span class="block text-sm text-base-content/60">{render_slot(@inner_block)}</span>
        </span>
      </label>
    </div>
    """
  end

  attr :root, :any, required: true
  attr :what, :string, required: true

  # A root-only setting seen from a sub-board: where it is set.
  defp set_on_root(assigns) do
    ~H"""
    <p class="flex flex-wrap items-center gap-1 text-xs text-base-content/60" data-role="set-on-root">
      <.icon name="hero-lock-closed" class="size-3.5" />
      {@what} is set for the whole tree on <.link navigate={~p"/boards/#{@root}/agentic"} class="link">{@root.name}</.link>.
    </p>
    """
  end

  defp count_on(rules), do: Enum.count(rules, & &1)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        summary: summary(assigns.board, assigns.routes),
        tier_source: assigns.root || assigns.board
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      waiting_count={@waiting_count}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:boards}
      page_jumps={@page_jumps}
    >
      <:subnav>
        <SlipdockWeb.AgenticLive.Nav.subnav board={@board} back={false} />
      </:subnav>

      <div id="agentic-shell" class="kanban-scroll h-full overflow-y-auto">
        <.page width="standard" class="space-y-6">
          <.page_header id="agentic-title" title="Agentic Building">
            <:meta>
              How agents build on this board: what they write before and after the work,
              how it is checked and shipped, and who they ask.
            </:meta>
            <:actions :if={@can_manage}>
              <.link
                navigate={~p"/boards/#{@board}/settings?tab=features"}
                id="agentic-board-settings"
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-cog-6-tooth" class="size-4" /> Board settings
              </.link>
            </:actions>
          </.page_header>

          <%!-- The developer's daily start (#2012): where each place stands,
                each tile opening it. --%>
          <nav id="agentic-hub" aria-label="Right now, Runners, Findings, Ledger and Health">
            <ul class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
              <li :for={tile <- Hub.tiles(@board, @hub)}>
                <.link
                  navigate={tile.path}
                  id={"agentic-tile-#{tile.key}"}
                  data-attention={tile.attention && to_string(tile.attention)}
                  class={[
                    "agentic-tile group flex h-full flex-col gap-1 rounded-box bg-base-100 p-4 ring-1 transition hover:shadow-md focus-visible:outline-2",
                    tile.attention == :warning && "ring-warning/60 bg-warning/5",
                    tile.attention != :warning && "ring-base-content/10 hover:ring-base-content/20"
                  ]}
                >
                  <span class="flex items-center justify-between gap-2 text-sm font-medium">
                    <span class="flex items-center gap-2">
                      <.icon name={tile.icon} class="size-4 text-primary" />
                      {tile.title}
                    </span>
                    <span
                      :if={tile.attention}
                      class={[
                        "size-2 rounded-full",
                        if(tile.attention == :warning, do: "bg-warning", else: "bg-info")
                      ]}
                      aria-hidden="true"
                    ></span>
                    <.icon
                      :if={!tile.attention}
                      name="hero-arrow-right"
                      class="size-4 text-base-content/60 transition group-hover:translate-x-0.5"
                    />
                  </span>
                  <span class="mt-1 flex items-baseline gap-1.5">
                    <span class="text-2xl font-semibold" data-role="tile-number">{tile.number}</span>
                    <span class="text-sm text-base-content/70">{tile.unit}</span>
                  </span>
                  <span class="text-xs text-base-content/70" data-role="tile-line">{tile.line}</span>
                  <span :if={tile.attention == :warning} class="sr-only">Needs a look.</span>
                </.link>
              </li>
            </ul>
          </nav>

          <%!-- At a glance: which rules hold, each a jump to its section. --%>
          <nav id="agentic-summary" aria-label="Rules on this board">
            <ul class="flex flex-wrap gap-2">
              <li :for={{key, section, label, on, detail} <- @summary}>
                <a
                  href={"#agentic-#{section}"}
                  id={"agentic-rule-#{key}"}
                  data-on={to_string(on == true)}
                  class={[
                    "inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-sm transition-colors",
                    if(on,
                      do:
                        "bg-success/10 text-base-content ring-1 ring-success/30 hover:bg-success/15",
                      else: "text-base-content/60 ring-1 ring-base-content/10 hover:bg-base-200"
                    )
                  ]}
                >
                  <span
                    class={[
                      "size-2 rounded-full",
                      if(on, do: "bg-success", else: "ring-1 ring-inset ring-base-content/40")
                    ]}
                    aria-hidden="true"
                  ></span>
                  {label}
                  <span :if={detail} class="text-base-content/60">· {detail}</span>
                  <span class="sr-only">{if on, do: "(on)", else: "(off)"}</span>
                </a>
              </li>
            </ul>
          </nav>

          <.callout :if={!@can_manage} id="agentic-read-only" kind={:info}>
            Only the board's owner can change these. This is how agents work here now.
          </.callout>

          <.form
            for={@form}
            id="agentic-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-6"
          >
            <fieldset disabled={!@can_manage} class="space-y-6">
              <.section
                id="verified"
                icon="hero-check-badge"
                title="Verified work"
                count={"#{count_on([@board.bar_required, @board.evidence_required, @board.verify_work])} of 3 on"}
              >
                <:about>
                  Checks on what agents say they finished. People complete cards as usual,
                  whichever is on.
                </:about>
                <.switch
                  field={@form[:bar_required]}
                  id="board-bar-required"
                  label="A bar before work starts"
                >
                  An agent writes what done means on the card before moving it into an
                  in-progress list. The bar locks then: only a person can change it after.
                </.switch>
                <.switch
                  field={@form[:evidence_required]}
                  id="board-evidence-required"
                  label="Evidence on completion"
                >
                  An agent completing a card says what it checked, and the commit it checked at.
                  The evidence is kept on the card and as a comment.
                </.switch>
                <.switch
                  field={@form[:verify_work]}
                  id="board-verify-work"
                  label="A second agent verifies"
                >
                  An agent completing a card submits it: it waits, flagged for review, until a
                  different agent or a person accepts it or rejects it with the reason.
                </.switch>
                <div
                  :if={on?(@form[:verify_work])}
                  id="agentic-verify-options"
                  class="space-y-3 border-l-2 border-base-content/10 pl-4 sm:ml-1"
                >
                  <div>
                    <.input
                      field={@form[:verify_pool]}
                      id="board-verify-pool"
                      label="Runner pool for verify jobs"
                      placeholder="none: verify by hand"
                      class="input field field-mono w-56"
                    />
                    <p class="-mt-1 text-xs text-base-content/60">
                      Each submitted card is queued for this pool as a job of kind <code>verify</code>. Blank queues nothing.
                    </p>
                  </div>
                  <div class="space-y-1">
                    <div class="settings-pair">
                      <.input
                        field={@form[:verify_rejection_limit]}
                        id="board-verify-rejection-limit"
                        type="number"
                        min="0"
                        max="50"
                        label="Rejections before a person decides"
                        class="input field w-24"
                      />
                      <.input
                        field={@form[:verify_audit]}
                        id="board-verify-audit"
                        type="number"
                        min="0"
                        max="1000"
                        label="Audit 1 in N accepted cards"
                        class="input field w-24"
                      />
                    </div>
                    <p class="text-xs text-base-content/60">
                      The rejection after the limit opens a wait on the board's owner: rework the card
                      or accept it as is. About one card in N that an agent accepted is checked again
                      by another runner in the pool; an audit that agrees only comments, and one that
                      disagrees alerts you and files a rework card (or comments on the open one).
                      0 turns either off.
                    </p>
                  </div>
                  <div>
                    <.input
                      field={@form[:ship_via]}
                      id="board-ship-via"
                      type="select"
                      label="Ship accepted work by"
                      options={[
                        {"Push: the agent pushes the default branch", "push"},
                        {"Pull request: accepting it merges the agent's pull request", "pull_request"}
                      ]}
                      class="select field w-full"
                    />
                    <p class="-mt-1 text-xs text-base-content/60">
                      With pull request, an agent pushes a <code>card-&lt;id&gt;</code>
                      branch and opens a pull request, never the default branch. Accepting the card
                      sends a runner a merge job, and the merge deploys.
                    </p>
                  </div>
                </div>
              </.section>

              <.section id="releases" icon="hero-rocket-launch" title="Releases">
                <:about>
                  When merged work reaches production: with each merge, or in batches.
                </:about>
                <div id="board-releases" class="space-y-1">
                  <%= if @root do %>
                    <p id="board-releases-read" class="text-sm text-base-content/70">
                      {release_text(@root)}
                    </p>
                    <.set_on_root root={@root} what="How merged work is released" />
                  <% else %>
                    <.input
                      field={@form[:release_mode]}
                      id="board-release-mode"
                      type="select"
                      label="Release merged work"
                      options={[
                        {"On merge: each merge deploys", "on_merge"},
                        {"Batched: merges wait for a release", "batched"}
                      ]}
                      class="select field w-full"
                    />
                    <.input
                      field={@form[:release_age_cap_hours]}
                      id="board-release-age-cap"
                      type="number"
                      min="1"
                      max="8760"
                      label="Release once a merge has waited (hours)"
                      class="input field w-24"
                    />
                    <.input
                      field={@form[:release_command]}
                      id="board-release-command"
                      type="text"
                      maxlength="500"
                      label="Release command"
                      placeholder={Slipdock.Releases.default_command()}
                      class="input field w-full font-mono text-xs"
                    />
                    <p class="text-xs text-base-content/60">
                      Batched, a merged card still completes and unblocks its dependents, and shows
                      <em>merged, awaiting release</em>
                      until a release ships it. Leave the hours
                      blank for no age cap. A release runs when a critical card merges, on <em>Release now</em>, or at the age cap: a runner runs the release
                      command (blank for the default; <code>{"{default_branch}"}</code>
                      is the repository's default branch).
                    </p>
                  <% end %>
                  <div
                    :if={@release}
                    id="board-release-status"
                    class="mt-2 flex flex-wrap items-center gap-2 text-sm"
                  >
                    <span id="board-release-line" class="min-w-0 flex-1">
                      {Slipdock.Releases.line(@release) || "Nothing merged is awaiting release."}
                    </span>
                    <button
                      :if={@can_manage}
                      type="button"
                      id="board-release-now"
                      class="btn btn-sm"
                      phx-click="release_now"
                      data-confirm="Release this board's merged work now?"
                    >
                      Release now
                    </button>
                  </div>
                </div>
              </.section>

              <.section id="lanes" icon="hero-arrows-right-left" title="Lanes">
                <:about>
                  Agents working side by side stay out of each other's files.
                </:about>
                <div>
                  <.input
                    field={@form[:lane_mode]}
                    id="board-lanes"
                    type="select"
                    label="When a card's paths overlap a card in progress"
                    options={[
                      {"Off: nothing is checked", "off"},
                      {"Hold: an agent can't start it", "hold"},
                      {"Advise: start it, and tell the agent", "advise"}
                    ]}
                    class="select field w-full sm:w-80"
                  />
                  <p class="-mt-1 text-xs text-base-content/60">
                    Moving a card yourself overrides a hold.
                  </p>
                </div>
                <div>
                  <.input
                    field={@form[:shared_paths]}
                    id="board-shared-paths"
                    type="textarea"
                    rows="3"
                    label="Shared paths"
                    value={globs_text(@form[:shared_paths].value)}
                    placeholder="docs/manual.md&#10;README.md"
                    class="textarea field field-mono w-full"
                  />
                  <p class="-mt-1 text-xs text-base-content/60">
                    One glob per line. Files nearly every card edits, such as the manual: cards can
                    both declare them without holding each other.
                  </p>
                </div>
              </.section>

              <.section id="profiles" icon="hero-tag" title="Profiles">
                <:about>
                  One word for what kind of change a card is, and what an agent's acceptance does
                  with it.
                </:about>
                <.switch field={@form[:profiles]} id="board-profiles" label="Profiles">
                  An agent claiming or starting a card with no profile gives it one, inferred from
                  its paths and tags: security, schema, spike, fix, docs or feature.
                </.switch>
                <div
                  :if={on?(@form[:profiles])}
                  id="board-profile-tiers"
                  class="space-y-2 border-l-2 border-base-content/10 pl-4 sm:ml-1"
                >
                  <span class="field-label">Human tier, by profile</span>
                  <p class="text-xs text-base-content/60">
                    What an agent's acceptance does on a board that ships by pull request. A
                    person's own acceptance always merges.
                  </p>
                  <%= if @root do %>
                    <dl
                      id="board-profile-tiers-read"
                      class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm"
                    >
                      <%= for {profile, tier} <- Profiles.board_tiers(@tier_source) do %>
                        <dt class="font-medium">{profile}</dt>
                        <dd class="text-base-content/70">{tier_text(tier)}</dd>
                      <% end %>
                    </dl>
                    <.set_on_root root={@root} what="The human tier" />
                  <% else %>
                    <.callout
                      :if={tiers_shown(@form)["security"] == "none"}
                      id="board-profile-tiers-warning"
                      kind={:warning}
                    >
                      Security is set to none: an agent's acceptance merges a security change with no
                      person looking at it first.
                    </.callout>
                    <div class="grid gap-x-4 sm:grid-cols-2">
                      <.input
                        :for={profile <- Profiles.names()}
                        type="select"
                        id={"board-tier-#{profile}"}
                        name={"board[profile_tiers][#{profile}]"}
                        value={tiers_shown(@form)[profile]}
                        options={Profiles.tiers()}
                        label={profile}
                        class="select field w-full"
                      />
                    </div>
                  <% end %>
                </div>
              </.section>

              <.section id="questions" icon="hero-hand-raised" title="Who gets asked">
                <:about>
                  A wait an agent opens goes to the first person named for its kind of question;
                  the others are told. Blank sends it to the board's owner.
                </:about>
                <.callout :if={@routes_error} id="board-wait-routes-error" kind={:error}>
                  {@routes_error}
                </.callout>
                <div id="board-wait-routes" class="space-y-1">
                  <.input
                    :for={kind <- WaitRoutes.kinds()}
                    id={"board-route-#{kind}"}
                    name={"board[wait_routes][#{kind}]"}
                    value={route_text(@routes, kind)}
                    label={route_label(kind)}
                    placeholder="the board's owner"
                    class="input field w-full"
                  />
                  <p class="text-xs text-base-content/60">
                    Emails of people on the board, comma-separated.
                  </p>
                </div>
                <div>
                  <.input
                    field={@form[:wait_default_after]}
                    id="board-wait-default-after"
                    value={wait_default_text(@form)}
                    label="An approval's proposal stands after"
                    placeholder="off"
                    class="input field w-24"
                  />
                  <p class="-mt-1 text-xs text-base-content/60">
                    A question of kind other that offers choices and proposes one, unanswered this
                    long (4h, 90m, 2d), goes ahead with the proposal: the card says so and the
                    person asked is told. Product, UX, security and release questions always wait
                    for a person. Blank or off never does.
                  </p>
                </div>
              </.section>

              <.section id="handoffs" icon="hero-arrow-uturn-right" title="Handoffs">
                <:about>
                  Where a card was left, for whoever picks it up next. Blank keeps the defaults.
                </:about>
                <.input
                  field={@form[:handoff_label]}
                  id="board-handoff-label"
                  label="Label"
                  placeholder={Board.default_handoff_label()}
                  maxlength={Board.handoff_limits().label}
                  class="input field w-56"
                />
                <div>
                  <.input
                    field={@form[:handoff_prompt]}
                    id="board-handoff-prompt"
                    type="textarea"
                    rows="6"
                    label="Instructions for Auto generate"
                    placeholder={Slipdock.AI.HandoffDrafter.default_instructions()}
                    maxlength={Board.handoff_limits().prompt}
                    class="textarea field w-full"
                  />
                  <p class="-mt-1 text-xs text-base-content/60">
                    What the AI model is told when it drafts a handoff from the card. It is always
                    asked to answer with a next step and a note, whatever this says.
                  </p>
                </div>
              </.section>

              <.section id="findings" icon="hero-light-bulb" title="Findings">
                <:about>
                  What agents learn as they work, kept for you to promote into the handbook.
                </:about>
                <div>
                  <.input
                    field={@form[:findings_propose_at]}
                    id="board-findings-propose-at"
                    type="number"
                    min="0"
                    max="100"
                    label="Propose a rule when a finding is seen this many times"
                    class="input field w-24"
                  />
                  <p class="-mt-1 text-xs text-base-content/60">
                    On a board with a handbook, the lesson is drafted as a rule on the Tidy-up page
                    for you to apply or dismiss. 0 never proposes.
                  </p>
                </div>
              </.section>

              <.section id="runners" icon="hero-cpu-chip" title="Runners">
                <:about>
                  How the board's runner jobs wait, and how long their logs stay.
                </:about>
                <.switch
                  field={@form[:automation_wip]}
                  id="board-automation-wip"
                  label="WIP limits hold automated work"
                >
                  While the first in-progress list is at its WIP limit, runner jobs and lists that
                  send cards wait, unless the card is in progress already. People can still drag
                  cards in.
                </.switch>
                <div id="board-job-logs" class="space-y-1">
                  <span class="field-label">Runner job logs</span>
                  <%= if @root do %>
                    <p id="board-job-logs-read" class="text-sm text-base-content/70">
                      Kept {@root.job_log_hours} hours after a job ends, {@root.failure_log_hours} hours
                      when it failed, was cancelled, stuck or rejected.
                    </p>
                    <.set_on_root root={@root} what="How long logs stay" />
                  <% else %>
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
                    <p class="text-xs text-base-content/60">
                      A job's live log is deleted this long after the job ends, unless someone keeps it
                      as a page. Failed, cancelled, stuck or rejected work keeps the second time.
                    </p>
                  <% end %>
                </div>
              </.section>
            </fieldset>

            <div
              :if={@can_manage}
              id="agentic-save"
              class="sticky bottom-0 z-10 -mx-1 flex items-center justify-end gap-3 rounded-box bg-base-100/90 px-4 py-3 ring-1 ring-base-content/10 backdrop-blur"
            >
              <span class="mr-auto text-xs text-base-content/60">
                Agents pick changes up on their next step.
              </span>
              <button type="submit" id="agentic-save-button" class="btn btn-primary btn-sm">
                Save
              </button>
            </div>
          </.form>
        </.page>
      </div>
    </Layouts.app>
    """
  end
end

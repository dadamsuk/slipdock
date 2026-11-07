defmodule SlipdockWeb.CardViewLive.Index do
  @moduledoc """
  Card views (#2031): the editor for what a person sees of a card.

  One page for every level: global (no `?board=`), a board's (`?board=B`)
  and one list's (`?board=B&list=L`), and for each named card view
  (`?view=ID`). Each element is set to inherit, show or hide; a level can
  also apply a named card view. Beside it, a sample card's front as it
  would be drawn, and the opened card's sections and sidebar groups, each
  marked on or off.

  The state lives in `Slipdock.CardViews`; open boards follow a change at
  once, since the context broadcasts it.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.SlipdockComponents

  alias Slipdock.{Boards, CardViews}
  alias Slipdock.CardViews.{CardView, Elements}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: CardViews.subscribe(socket.assigns.current_user)

    {:ok,
     assign(socket,
       page_title: "Card views",
       new_name: "",
       # Which half of the card the element list shows (#2035): its front,
       # or the opened card's sections and sidebar groups.
       tab: "front",
       renaming: false,
       error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = socket.assigns.current_user

    with {:ok, board, column} <- place(user, params),
         {:ok, editing} <- editing(user, params) do
      {:noreply,
       socket
       |> assign(board: board, column: column, editing: editing, renaming: false, error: nil)
       |> load()}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "That board, list or card view isn't one of yours to see.")
         |> push_patch(to: ~p"/card-views")}
    end
  end

  # The board and list from `?board=` and `?list=`; the list must be on the board.
  defp place(user, params) do
    with {:ok, board} <- board(user, params["board"]),
         {:ok, column} <- column(board, params["list"]),
         {:ok, _scope} <- CardViews.scope(user, board, column) do
      {:ok, board, column}
    end
  end

  defp board(_user, blank) when blank in [nil, ""], do: {:ok, nil}

  defp board(_user, id) do
    case CardViews.with_lists(SlipdockWeb.Params.id(id)) do
      %Boards.Board{} = board -> {:ok, board}
      nil -> :error
    end
  end

  defp column(_board, blank) when blank in [nil, ""], do: {:ok, nil}
  defp column(nil, _), do: :error

  defp column(board, id) do
    case Enum.find(board.columns, &(to_string(&1.id) == to_string(id))) do
      nil -> :error
      column -> {:ok, column}
    end
  end

  # `?view=ID` edits a named card view; otherwise the page edits the level.
  defp editing(user, %{"view" => ref}) when ref not in [nil, ""], do: CardViews.get(user, ref)
  defp editing(_user, _params), do: {:ok, :level}

  defp load(socket) do
    %{current_user: user, board: board, column: column, editing: editing} = socket.assigns
    views = CardViews.list(user)
    explained = CardViews.explain(user, board, column)

    {stated, level} =
      case editing do
        %CardView{} = view ->
          {view.elements, nil}

        :level ->
          level = CardViews.level(user, scope(board, column))
          {level.elements, level}
      end

    shown = shown(editing, explained)

    assign(socket,
      views: views,
      level: level,
      stated: stated,
      explained: Map.new(explained, &{&1.key, &1}),
      shown: shown,
      sample: sample_card()
    )
  end

  defp scope(nil, _column), do: :global
  defp scope(board, nil), do: {:board, board}
  defp scope(board, column), do: {:list, board, column}

  # What the preview draws: a level's cascade as it applies, or a named
  # view's own elements on the defaults.
  defp shown(%CardView{elements: elements}, _explained) do
    Elements.defaults()
    |> Map.merge(elements)
    |> Enum.filter(&elem(&1, 1))
    |> MapSet.new(&elem(&1, 0))
  end

  defp shown(:level, explained),
    do: for(%{shown: true, key: k} <- explained, into: MapSet.new(), do: k)

  @impl true
  def handle_info({:card_views_changed, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  # `to`, not `value`: a clicked button sends its own (empty) value (#553).
  def handle_event("set", %{"key" => key, "to" => value}, socket)
      when value in ~w(show hide inherit) do
    change = %{"elements" => %{key => value}}
    {:noreply, save(socket, change)}
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(front card),
    do: {:noreply, assign(socket, tab: tab)}

  def handle_event("apply_view", %{"apply" => %{"card_view" => ref}}, socket),
    do: {:noreply, save(socket, %{"card_view" => ref})}

  def handle_event("reset", _params, %{assigns: %{editing: :level}} = socket) do
    %{current_user: user, board: board, column: column} = socket.assigns
    {:ok, _} = CardViews.clear_level(user, scope(board, column))
    {:noreply, load(socket)}
  end

  def handle_event("reset", _params, socket), do: {:noreply, save(socket, %{"reset" => true})}

  def handle_event("toggle_show_all", _params, %{assigns: %{board: %{}, column: nil}} = socket) do
    on? = not (socket.assigns.level && socket.assigns.level.show_all)
    {:noreply, save(socket, %{"show_all" => on?})}
  end

  def handle_event("new_view", %{"card_view" => %{"name" => name}}, socket) do
    user = socket.assigns.current_user
    # A new view starts as what the reader sees at this level, stated in full.
    elements = Map.new(socket.assigns.explained, fn {k, %{shown: v}} -> {k, v} end)

    case CardViews.create(user, %{"name" => name, "elements" => elements}) do
      {:ok, view} ->
        {:noreply, push_patch(socket, to: editor_path(socket.assigns, view))}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, error: changeset_error(cs), new_name: name)}

      {:error, message} ->
        {:noreply, assign(socket, error: message, new_name: name)}
    end
  end

  def handle_event("start_rename", _params, socket),
    do: {:noreply, assign(socket, renaming: true)}

  def handle_event(
        "rename",
        %{"rename" => %{"name" => name}},
        %{assigns: %{editing: %CardView{}}} = socket
      ) do
    case CardViews.update(socket.assigns.current_user, socket.assigns.editing, %{"name" => name}) do
      {:ok, view} -> {:noreply, socket |> assign(editing: view, renaming: false) |> load()}
      {:error, %Ecto.Changeset{} = cs} -> {:noreply, assign(socket, error: changeset_error(cs))}
    end
  end

  def handle_event("delete_view", _params, %{assigns: %{editing: %CardView{} = view}} = socket) do
    user = socket.assigns.current_user
    used = CardViews.levels_using(user, view)
    {:ok, _} = CardViews.delete(user, view)

    {:noreply,
     socket
     |> put_flash(:info, deleted_message(view, used))
     |> push_patch(to: editor_path(socket.assigns, :level))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp save(%{assigns: assigns} = socket, change) do
    result =
      case assigns.editing do
        %CardView{} = view ->
          CardViews.update(assigns.current_user, view, change)

        :level ->
          CardViews.update_level(
            assigns.current_user,
            scope(assigns.board, assigns.column),
            change
          )
      end

    case result do
      {:ok, %CardView{} = view} -> socket |> assign(editing: view, error: nil) |> load()
      {:ok, _} -> socket |> assign(error: nil) |> load()
      {:error, %Ecto.Changeset{} = cs} -> assign(socket, error: changeset_error(cs))
      {:error, :not_found} -> assign(socket, error: "That card view is gone.")
      {:error, message} when is_binary(message) -> assign(socket, error: message)
    end
  end

  # Levels that applied it keep their own elements and inherit the rest (#2036).
  defp deleted_message(view, 0), do: "Deleted the card view “#{view.name}”."

  defp deleted_message(view, 1),
    do: "Deleted the card view “#{view.name}”. The one level that applied it inherits instead."

  defp deleted_message(view, n),
    do: "Deleted the card view “#{view.name}”. The #{n} levels that applied it inherit instead."

  defp tab_shows?("front", group), do: group == "front"
  defp tab_shows?(_card, group), do: group != "front"

  defp changeset_error(cs) do
    Enum.map_join(cs.errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  ## Paths

  defp editor_path(assigns, :level), do: ~p"/card-views?#{place_query(assigns)}"

  defp editor_path(assigns, %CardView{id: id}),
    do: ~p"/card-views?#{place_query(assigns) ++ [view: id]}"

  defp level_path(nil, nil), do: ~p"/card-views"
  defp level_path(board, nil), do: ~p"/card-views?#{[board: board.id]}"
  defp level_path(board, column), do: ~p"/card-views?#{[board: board.id, list: column.id]}"

  defp place_query(%{board: nil}), do: []
  defp place_query(%{board: b, column: nil}), do: [board: b.id]
  defp place_query(%{board: b, column: c}), do: [board: b.id, list: c.id]

  ## The sample card

  # Every element filled in, so each switch shows what it does.
  defp sample_card do
    today = Date.utc_today()
    owner = %Slipdock.Accounts.User{id: -1, name: "Sam Sample", email: "sam@example.com"}

    %Boards.Card{
      id: 1234,
      board_id: nil,
      column_id: nil,
      title: "Sample card: what your card view shows",
      description: "A description.",
      priority: "high",
      flags: ["blocked"],
      color: "sky",
      border_left: "amber",
      start_date: Date.add(today, -2),
      due_date: Date.add(today, 5),
      percent_complete: 40,
      time_spent: 90,
      time_estimate: 240,
      profile: "feature",
      tags: [%Boards.Tag{id: -1, name: "ux", color: "violet"}],
      assignees: [owner],
      assignee: owner,
      checklist_items: [%{done: true}, %{done: false}, %{done: false}],
      comments: [%{id: -1}, %{id: -2}],
      attachments: [],
      blocks: [%Boards.Card{id: -2, title: "Another card"}],
      blocked_by: [],
      sub_board: %Boards.Board{id: -1, name: "Sample subcards"},
      status_updates: [%{health: "on_track"}],
      handoff: %Boards.Handoff{next_step: "Pick up the review", body: "Left at the second step."},
      state: %Slipdock.CardState{line: "In review · 2d", driver: "human", age: 2}
    }
  end

  # A board that calls its handoff something else (#1214) has that word here too.
  defp label(label, nil), do: label

  defp label(label, board),
    do: String.replace(label, "Handoff", Slipdock.Boards.Board.handoff_label(board))

  defp stated_value(stated, key) do
    case Map.fetch(stated, key) do
      {:ok, true} -> "show"
      {:ok, false} -> "hide"
      :error -> "inherit"
    end
  end

  defp level_name(nil, nil), do: "Global"
  defp level_name(board, nil), do: board.name
  defp level_name(board, column), do: "#{board.name} › #{column.name}"

  @impl true
  def render(assigns) do
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
    >
      <div class="kanban-scroll h-full overflow-y-auto">
        <.page width="full">
          <.page_header
            title="Card views"
            subtitle="Choose what a card shows: for every board, one board, or one list. Each level states only what it changes."
          >
            <:actions>
              <.link :if={@board} navigate={~p"/boards/#{@board}"} class="btn btn-ghost btn-sm">
                <.icon name="hero-arrow-uturn-left" class="size-4" /> Back to {@board.name}
              </.link>
            </:actions>
          </.page_header>

          <nav id="card-view-levels" class="mb-4 flex flex-wrap items-center gap-1 text-sm">
            <span class="section-label mr-1">Level</span>
            <.link
              patch={level_path(nil, nil)}
              id="level-global"
              class={[
                "btn btn-xs",
                if(is_nil(@board) and @editing == :level, do: "btn-primary", else: "btn-ghost")
              ]}
            >
              Global
            </.link>
            <.link
              :if={@board}
              patch={level_path(@board, nil)}
              id="level-board"
              class={[
                "btn btn-xs",
                if(is_nil(@column) and @editing == :level, do: "btn-primary", else: "btn-ghost")
              ]}
            >
              Board: {@board.name}
            </.link>
            <.link
              :if={@column}
              patch={level_path(@board, @column)}
              id="level-list"
              class={["btn btn-xs", if(@editing == :level, do: "btn-primary", else: "btn-ghost")]}
            >
              List: {@column.name}
            </.link>
            <span class="section-label ml-3 mr-1">Named views</span>
            <.link
              :for={view <- @views}
              patch={editor_path(assigns, view)}
              id={"named-view-#{view.id}"}
              class={[
                "btn btn-xs",
                if(match?(%CardView{id: id} when id == view.id, @editing),
                  do: "btn-primary",
                  else: "btn-ghost"
                )
              ]}
            >
              {view.name}
            </.link>
            <.form
              for={to_form(%{"name" => @new_name}, as: :card_view)}
              id="new-card-view"
              phx-submit="new_view"
              class="flex items-center gap-1"
            >
              <.input
                field={to_form(%{"name" => @new_name}, as: :card_view)[:name]}
                placeholder="New card view…"
                class="input field w-44"
                maxlength="60"
                aria-label="New card view's name"
                required
              />
              <button
                class="btn btn-xs btn-ghost"
                title="Save what this level shows as a named card view"
              >
                <.icon name="hero-plus" class="size-3.5" /> Save
              </button>
            </.form>
          </nav>

          <.callout :if={@error} kind={:error} class="mb-4" id="card-view-error">{@error}</.callout>

          <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
            <section id="card-view-editor" class="space-y-5">
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="font-semibold" id="card-view-title">
                  <%= case @editing do %>
                    <% %CardView{name: name} -> %>
                      Card view “{name}”
                    <% :level -> %>
                      {level_name(@board, @column)}
                  <% end %>
                </h2>
                <.form
                  :let={f}
                  :if={@editing == :level}
                  for={to_form(%{"card_view" => @level && @level.card_view_id}, as: :apply)}
                  id="apply-card-view"
                  phx-change="apply_view"
                  class="ml-auto flex items-center gap-2 text-sm"
                >
                  <.input
                    field={f[:card_view]}
                    id="apply-card-view-select"
                    type="select"
                    label="Apply"
                    prompt="No named view"
                    options={Enum.map(@views, &{&1.name, &1.id})}
                    class="select field w-48"
                  />
                </.form>
                <div :if={match?(%CardView{}, @editing)} class="ml-auto flex items-center gap-1">
                  <.form
                    :let={f}
                    :if={@renaming}
                    for={to_form(%{"name" => @editing.name}, as: :rename)}
                    id="rename-card-view"
                    phx-submit="rename"
                    class="flex gap-1"
                  >
                    <.input field={f[:name]} class="input field" maxlength="60" aria-label="New name" />
                    <button class="btn btn-sm btn-primary">Rename</button>
                  </.form>
                  <button
                    :if={!@renaming}
                    type="button"
                    phx-click="start_rename"
                    class="btn btn-sm btn-ghost"
                  >
                    Rename
                  </button>
                  <button
                    type="button"
                    id="delete-card-view"
                    phx-click="delete_view"
                    class="btn btn-sm btn-ghost btn-error"
                    data-confirm={"Delete the card view “#{@editing.name}”? Levels that apply it keep their own elements."}
                  >
                    Delete
                  </button>
                </div>
                <button
                  type="button"
                  id="reset-card-view"
                  phx-click="reset"
                  class="btn btn-sm btn-ghost"
                  title="State nothing: inherit every element"
                >
                  Inherit all
                </button>
              </div>

              <p
                :if={@board && is_nil(@column) && @editing == :level}
                class="flex items-center gap-2 text-sm"
              >
                <button
                  type="button"
                  id="card-view-show-all"
                  phx-click="toggle_show_all"
                  class={[
                    "btn btn-xs",
                    if(@level && @level.show_all, do: "btn-primary", else: "btn-ghost")
                  ]}
                  aria-pressed={to_string(!!(@level && @level.show_all))}
                >
                  Show all
                </button>
                <span class="text-base-content/60">
                  While on, every element of the card front shows on this board.
                </span>
              </p>

              <.tabs id="card-view-tabs" label="Which part of the card">
                <:tab
                  :for={{key, label} <- [{"front", "Card front"}, {"card", "Opened card"}]}
                  id={"card-view-tab-#{key}"}
                  active={@tab == key}
                  phx-click="tab"
                  phx-value-tab={key}
                >
                  {label}
                </:tab>
              </.tabs>

              <div
                :for={{group, title, elements} <- Elements.groups()}
                :if={tab_shows?(@tab, group)}
                id={"card-view-group-#{group}"}
              >
                <h3 class="section-label mb-2">{title}</h3>
                <ul class="divide-y divide-base-300/60 overflow-hidden rounded-2xl bg-base-100 ring-1 ring-base-content/10">
                  <li
                    :for={{key, label} <- elements}
                    id={"element-#{String.replace(key, ".", "-")}"}
                    class="flex flex-wrap items-center gap-2 px-4 py-2"
                  >
                    <span class="min-w-0 flex-1 text-sm">
                      {label(label, @board)}
                      <span
                        :if={@editing == :level && @explained[key]}
                        class="ml-1 text-xs text-base-content/50"
                        data-role="source"
                      >
                        {if @explained[key].shown, do: "shown", else: "hidden"} · {@explained[key].source}
                      </span>
                    </span>
                    <div
                      class="join"
                      role="group"
                      aria-label={"#{label(label, @board)}: inherit, show or hide"}
                    >
                      <button
                        :for={value <- ~w(inherit show hide)}
                        type="button"
                        phx-click="set"
                        phx-value-key={key}
                        phx-value-to={value}
                        data-value={value}
                        aria-pressed={to_string(stated_value(@stated, key) == value)}
                        class={[
                          "btn join-item btn-xs",
                          stated_value(@stated, key) == value && "btn-primary"
                        ]}
                      >
                        {String.capitalize(value)}
                      </button>
                    </div>
                  </li>
                </ul>
              </div>
            </section>

            <aside id="card-view-preview" class="space-y-4 lg:sticky lg:top-4 lg:self-start">
              <h3 class="section-label">Sample card</h3>
              <div class="w-72">
                <.card
                  card={@sample}
                  id="sample-card"
                  show={@shown}
                  handoff_label={
                    if @board, do: Slipdock.Boards.Board.handoff_label(@board), else: "Left off"
                  }
                />
              </div>
              <h3 class="section-label">Opened card</h3>
              <ul id="sample-panel" class="space-y-1 text-sm">
                <li
                  :for={{key, label} <- Elements.open() ++ Elements.side()}
                  data-key={key}
                  data-shown={to_string(MapSet.member?(@shown, key))}
                  class={[
                    "flex items-center gap-2",
                    !MapSet.member?(@shown, key) && "text-base-content/35 line-through"
                  ]}
                >
                  <.icon
                    name={if MapSet.member?(@shown, key), do: "hero-eye", else: "hero-eye-slash"}
                    class="size-3.5"
                  />
                  {label(label, @board)}
                </li>
              </ul>
            </aside>
          </div>
        </.page>
      </div>
    </Layouts.app>
    """
  end
end

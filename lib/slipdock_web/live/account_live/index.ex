defmodule SlipdockWeb.AccountLive.Index do
  use SlipdockWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Slipdock.Accounts
  alias Slipdock.AI
  alias Slipdock.Portable
  alias Slipdock.QuickAdd.Capture

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # Each tab is its own mount (the tab bar navigates rather than patches),
    # so a tab pays only for its own queries — the one-page version ran all
    # of them to show you a fifth of the result.
    {:ok,
     socket
     |> assign(
       page_title: tab_title(socket.assigns.live_action),
       source_url: Application.get_env(:slipdock, :source_url)
     )
     |> mount_tab(socket.assigns.live_action, user)}
  end

  # One limit, with a bar and a sentence when it is close or full. Shared by
  # items, boards and storage so the three never drift apart in wording.
  attr :label, :string, required: true
  attr :status, :map, required: true
  attr :detail, :string, default: nil
  attr :bytes, :boolean, default: false
  attr :full, :string, required: true
  attr :near, :string, required: true

  defp usage(assigns) do
    assigns = assign(assigns, :near?, near?(assigns.status))

    ~H"""
    <div class="mt-4">
      <div class="flex items-baseline justify-between text-sm">
        <span class="font-medium">
          {@label}: {amount(@status.used, @bytes)} of {amount(@status.limit, @bytes)} used
        </span>
        <span class="text-base-content/60">{amount(@status.remaining, @bytes)} left</span>
      </div>
      <progress
        class={[
          "progress mt-2 w-full",
          cond do
            @status.remaining == 0 -> "progress-error"
            @near? -> "progress-warning"
            true -> "progress-primary"
          end
        ]}
        value={@status.used}
        max={@status.limit}
      ></progress>
      <p :if={@detail} class="mt-1 text-xs text-base-content/60">{@detail}</p>
      <p :if={@near?} class="mt-3 rounded-xl bg-warning/10 p-3 text-sm">
        {if @status.remaining == 0, do: @full, else: @near}
      </p>
    </div>
    """
  end

  defp amount(value, true), do: Slipdock.Quota.humanise_bytes(value)
  defp amount(value, _bytes), do: value

  # The same fifth-of-the-limit rule `Slipdock.Quota.warning?/2` uses, applied
  # to a status already in hand rather than by asking the database again.
  defp near?(%{limit: limit, remaining: remaining}),
    do: remaining <= max(div(limit, 5), 1)

  # Whether a bar tells this person anything. Every install has the guardrails
  # on, so without this a self-hoster with four cards would be shown "4 of
  # 250,000" — a number that is true, useless, and slightly alarming. Shown
  # once a hundredth of it is gone, or once it is close.
  defp worth_showing?(%{limited?: false}), do: false

  defp worth_showing?(%{used: used, limit: limit} = status),
    do: used * 100 >= limit or near?(status)

  defp mount_tab(socket, :settings, user) do
    socket
    |> assign_quick_add(Accounts.change_quick_add(user))
    |> assign_ai_key()
  end

  defp mount_tab(socket, :tokens, _user) do
    socket
    |> assign(new_token: nil, form_key: 0)
    |> load_tokens()
  end

  # Everything on this tab is built from one fact: the address this server was
  # reached on. It is the thing people get wrong when they copy setup
  # instructions out of a repository, so the page works it out for them.
  defp mount_tab(socket, :agent, _user) do
    base = SlipdockWeb.BaseURL.from_socket(socket)

    assign(socket,
      base_url: base,
      agent_prompt:
        "Work from my Slipdock board at #{base}. Read #{base}/api/guide and " <>
          "follow it. Nothing about my boards is readable until you sign in, so " <>
          "start with the device flow the guide describes and tell me the code " <>
          "to approve."
    )
  end

  defp mount_tab(socket, :data, user) do
    socket
    |> assign(
      own_boards: own_boards(user),
      picked_boards: [],
      with_archived: false,
      import_report: nil,
      import_error: nil
    )
    |> allow_upload(:board_document,
      accept: ~w(.json application/json),
      max_entries: 1,
      # The same ceiling the API's body parser puts on `POST /api/import`.
      max_file_size: 8_000_000
    )
  end

  defp mount_tab(socket, _index, user) do
    socket
    |> assign(profile_form: to_form(Accounts.change_profile(user)))
    |> assign(quota: Slipdock.Quota.status(user))
    |> assign(limits: Slipdock.Quota.report(user))
    |> assign(support_sessions: Accounts.support_sessions_for(user))
  end

  # The key itself is never sent to the browser — only its shape and when it
  # was set.
  # Still in force, as opposed to merely recorded.
  defp live_support?(session) do
    is_nil(session.ended_at) and DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt
  end

  defp assign_ai_key(socket) do
    user = socket.assigns.current_user
    settings = AI.Keys.settings(user)

    socket
    |> assign(
      ai: settings,
      ai_key: AI.Keys.masked(settings.api_key),
      ai_key_set_at: settings.updated_at,
      ai_key_shared?: AI.configured?(user) and not AI.Keys.own?(user),
      ai_default_endpoint: AI.default_base_url(),
      ai_default_model: AI.model()
    )
    |> assign_new(:ai_key_form_key, fn -> 0 end)
    |> assign_new(:ai_models, fn -> nil end)
    |> assign_new(:ai_models_error, fn -> nil end)
    |> assign_new(:ai_listing?, fn -> false end)
  end

  # The models an endpoint offers, split for the two pickers: anything that
  # looks like an embedding model cannot hold a conversation, and vice versa.
  defp chat_models(models), do: Enum.reject(models, & &1.embedding?)
  defp embedding_models(models), do: Enum.filter(models, & &1.embedding?)

  # A select's options: the stored value stays selectable even when the
  # endpoint no longer lists it, so saving the form does not silently change
  # a model that is merely unlisted today.
  defp model_options(models, current) do
    listed = Enum.map(models, &{&1.name, &1.id})

    if current && current not in Enum.map(models, & &1.id),
      do: listed ++ [{current, current}],
      else: listed
  end

  defp load_tokens(socket),
    do: assign(socket, tokens: Accounts.list_api_tokens(socket.assigns.current_user))

  # The boards that can travel: the ones this person **owns**. A board shared
  # with you is somebody else's to hand on.
  defp own_boards(user) do
    Slipdock.Repo.all(
      from(b in Slipdock.Boards.Board,
        where: b.owner_id == ^user.id and is_nil(b.parent_card_id),
        order_by: [asc: b.name],
        select: %{id: b.id, name: b.name, code: b.code, archived: not is_nil(b.archived_at)}
      )
    )
  end

  # The same refusals the API phrases, phrased for somebody looking at a page
  # rather than reading a response body.
  defp import_error(:not_json), do: "That file is not JSON."

  defp import_error(:not_a_slipdock_export),
    do:
      "That is not a Slipdock export — a board document says so in its first line — " <>
        "nor a Trello board's JSON."

  defp import_error(:not_a_trello_export),
    do: "That is not a Trello board export — it has no lists and cards in it."

  defp import_error({:unsupported_version, version}),
    do:
      "That file is format version #{version}. This server reads version " <>
        "#{Portable.format_version()}, so it was written by a newer Slipdock."

  defp import_error({:card_limit_reached, wanted, remaining}),
    do:
      "That file holds #{wanted} cards and pages and you have room for #{remaining}. " <>
        "Nothing was imported — half a board is worse than none."

  defp import_error({:board_limit_reached, wanted, remaining}),
    do:
      "That file holds #{wanted} boards and you have room for #{remaining}. Nothing " <>
        "was imported."

  defp import_error({:bad_sub_board, ref}),
    do:
      "In that file the sub-board “#{ref}” is the root board or belongs to more than one " <>
        "card, so it can't be built. Nothing was imported."

  defp import_error({:too_many, kind, count, max}),
    do:
      "That file holds #{count} #{Portable.row_kind(kind)}; one import takes at most #{max}. " <>
        "Nothing was imported."

  defp import_error(:trial_expired),
    do: "Your free trial has ended, so nothing new can be added. Nothing was imported."

  defp import_error(other), do: "That file could not be imported: #{inspect(other)}"

  defp upload_error_text(:too_large), do: "That file is too big."
  defp upload_error_text(:not_accepted), do: "A board document is a .json file."
  defp upload_error_text(:too_many_files), do: "One file at a time."
  defp upload_error_text(other), do: "That file could not be read (#{inspect(other)})."

  # The query string behind the download link, so the picker and the link
  # cannot drift apart.
  defp boards_download_path(picked, with_archived?) do
    params =
      %{}
      |> then(&if picked == [], do: &1, else: Map.put(&1, "boards", Enum.join(picked, ",")))
      |> then(&if with_archived?, do: Map.put(&1, "archived", "all"), else: &1)

    ~p"/account/boards.json?#{params}"
  end

  # The quick add settings, with the lists narrowed to the chosen board's.
  defp assign_quick_add(socket, changeset) do
    user = socket.assigns.current_user
    catalogue = Capture.catalogue(user)
    board_id = Ecto.Changeset.get_field(changeset, :quick_add_board_id)

    entry =
      Enum.find(catalogue.boards, &(&1.board.id == board_id)) ||
        Enum.find(catalogue.boards, &(&1.board.id == (catalogue.default_board || %{id: nil}).id))

    columns = (entry && entry.columns) || []

    # A list from another board would silently send cards elsewhere.
    changeset =
      changeset
      |> put_default(:quick_add_board_id, entry && entry.board.id)
      |> then(fn cs ->
        case Ecto.Changeset.get_field(cs, :quick_add_column_id) do
          id when is_integer(id) ->
            if Enum.any?(columns, &(&1.id == id)),
              do: cs,
              else: put_default(cs, :quick_add_column_id, nil)

          _ ->
            put_default(
              cs,
              :quick_add_column_id,
              catalogue.default_column && catalogue.default_column.id
            )
        end
      end)

    assign(socket,
      quick_add_form: to_form(changeset),
      quick_add_boards: catalogue.boards,
      quick_add_columns: columns
    )
  end

  defp put_default(changeset, field, value),
    do: Ecto.Changeset.put_change(changeset, field, value)

  @impl true
  def handle_event("pick_board", %{"id" => id}, socket) do
    id = String.to_integer(id)
    picked = socket.assigns.picked_boards

    picked = if id in picked, do: List.delete(picked, id), else: [id | picked]
    {:noreply, assign(socket, picked_boards: picked)}
  end

  def handle_event("pick_all_boards", _params, socket),
    do: {:noreply, assign(socket, picked_boards: [])}

  def handle_event("toggle_archived", _params, socket),
    do: {:noreply, assign(socket, with_archived: !socket.assigns.with_archived)}

  def handle_event("validate_board_document", _params, socket),
    do: {:noreply, assign(socket, import_error: nil, import_report: nil)}

  def handle_event("cancel_board_document", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :board_document, ref)}

  def handle_event("import_boards", _params, socket) do
    user = socket.assigns.current_user

    case consume_uploaded_entries(socket, :board_document, fn %{path: path}, _entry ->
           {:ok, Slipdock.Importers.import(user, File.read!(path))}
         end) do
      [{:ok, report}] ->
        {:noreply,
         socket
         |> assign(import_report: report, import_error: nil, own_boards: own_boards(user))
         |> put_flash(:info, "Imported #{report.cards} card(s).")}

      [{:error, reason}] ->
        {:noreply, assign(socket, import_error: import_error(reason), import_report: nil)}

      [] ->
        {:noreply, assign(socket, import_error: "Choose a file first.")}
    end
  end

  def handle_event("save_profile", %{"user" => params}, socket) do
    case Accounts.update_profile(socket.assigns.current_user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(current_user: user, profile_form: to_form(Accounts.change_profile(user)))
         |> put_flash(:info, "Profile saved.")}

      {:error, cs} ->
        {:noreply, assign(socket, profile_form: to_form(cs))}
    end
  end

  def handle_event("change_quick_add", %{"user" => params}, socket) do
    user = socket.assigns.current_user
    changeset = Accounts.change_quick_add(user, board_switch(params, user))
    {:noreply, assign_quick_add(socket, changeset)}
  end

  def handle_event("save_quick_add", %{"user" => params}, socket) do
    case Accounts.update_quick_add(socket.assigns.current_user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(current_user: user)
         |> assign_quick_add(Accounts.change_quick_add(user))
         |> put_flash(:info, "Quick add settings saved.")}

      {:error, cs} ->
        {:noreply, assign_quick_add(socket, cs)}
    end
  end

  # Saves the endpoint and, when one was typed, the key. A blank key field
  # leaves the stored key alone — it is a password box, so blank means "not
  # changing this", and the Remove button is how a key goes. A blank endpoint
  # does mean "back to the default", which is the only way to say so.
  def handle_event("save_ai_provider", params, socket) do
    attrs =
      %{base_url: params["base_url"] || ""}
      |> then(fn attrs ->
        case String.trim(params["api_key"] || "") do
          "" -> attrs
          key -> Map.put(attrs, :api_key, key)
        end
      end)

    case AI.Keys.put_settings(socket.assigns.current_user, attrs) do
      :ok ->
        {:noreply,
         socket
         |> assign_ai_key()
         |> update(:ai_key_form_key, &(&1 + 1))
         # The old list belonged to the old endpoint.
         |> assign(ai_models: nil, ai_models_error: nil)
         |> put_flash(:info, "AI settings saved.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("save_ai_model", params, socket) do
    attrs = %{model: params["model"] || "", embed_model: params["embed_model"] || ""}

    case AI.Keys.put_settings(socket.assigns.current_user, attrs) do
      :ok -> {:noreply, socket |> assign_ai_key() |> put_flash(:info, "Model saved.")}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  # Asks the endpoint what it can run. Off the LiveView process, since a model
  # server on the other end of a VPN takes its time, and a slow answer should
  # not hold up the rest of the page.
  def handle_event("list_ai_models", _, socket) do
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(ai_listing?: true, ai_models_error: nil)
     |> start_async(:ai_models, fn -> AI.models(user: user) end)}
  end

  def handle_event("remove_ai_key", _, socket) do
    case AI.Keys.put_settings(socket.assigns.current_user, %{api_key: ""}) do
      :ok -> {:noreply, socket |> assign_ai_key() |> put_flash(:info, "AI key removed.")}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("create_token", params, socket) do
    label = params["label"] |> to_string() |> String.trim()
    label = if label == "", do: "CLI", else: label

    {token, _} =
      Accounts.create_api_token(socket.assigns.current_user, label,
        scope: params["scope"],
        expires_at: Accounts.expiry_in_days(params["expires_in_days"])
      )

    {:noreply,
     socket |> assign(new_token: token) |> update(:form_key, &(&1 + 1)) |> load_tokens()}
  end

  def handle_event("delete_token", %{"id" => id}, socket) do
    :ok = Accounts.delete_api_token(socket.assigns.current_user, String.to_integer(id))
    {:noreply, socket |> assign(new_token: nil) |> load_tokens()}
  end

  def handle_event("dismiss_token", _, socket), do: {:noreply, assign(socket, new_token: nil)}

  @impl true
  def handle_async(:ai_models, {:ok, {:ok, models}}, socket) do
    {:noreply, assign(socket, ai_models: models, ai_models_error: nil, ai_listing?: false)}
  end

  def handle_async(:ai_models, {:ok, {:error, message}}, socket) do
    {:noreply, assign(socket, ai_models: nil, ai_models_error: message, ai_listing?: false)}
  end

  def handle_async(:ai_models, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       ai_models: nil,
       ai_models_error: "Couldn't list the models (#{inspect(reason)}).",
       ai_listing?: false
     )}
  end

  # Switching board drops the list, so the form can't keep pointing at a list
  # that lives somewhere else.
  defp board_switch(%{"quick_add_board_id" => chosen} = params, user) do
    if to_string(user.quick_add_board_id) == chosen,
      do: params,
      else: Map.put(params, "quick_add_column_id", nil)
  end

  defp board_switch(params, _user), do: params

  # One label per tab, used for the title, the breadcrumb and the tab itself,
  # so the three cannot drift apart.
  defp tab_title(:settings), do: "Settings"
  defp tab_title(:tokens), do: "API tokens"
  defp tab_title(:data), do: "Import & export"
  defp tab_title(:agent), do: "Set up an agent"
  defp tab_title(_), do: "Account"

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, default: "Copy"

  # Something to copy, with the button that copies it. The text is selectable
  # too: a copy button that needs JavaScript must not be the only way out.
  defp copy_block(assigns) do
    ~H"""
    <div class="mt-3">
      <code
        id={@id}
        class="block select-all whitespace-pre-wrap break-words rounded-xl bg-base-200 px-3 py-2 font-mono text-xs leading-relaxed"
        phx-no-format
      >{@text}</code>
      <button
        type="button"
        id={"#{@id}-copy"}
        class="btn btn-ghost btn-xs mt-1 gap-1"
        phx-hook="CopyText"
        data-target={@id}
      >
        <.icon name="hero-clipboard" class="size-3.5" /> <span data-label>{@label}</span>
      </button>
    </div>
    """
  end

  attr :to, :string, required: true
  attr :active, :boolean, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp account_tab(assigns) do
    ~H"""
    <.link
      navigate={@to}
      aria-current={@active && "page"}
      class={[
        "flex flex-1 items-center justify-center gap-1.5 whitespace-nowrap rounded-xl px-3 py-2 font-medium",
        (@active && "bg-primary/10 text-primary") ||
          "text-base-content/60 hover:bg-base-200/70 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </.link>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:account}
    >
      <:nav><span class="font-semibold">{tab_title(@live_action)}</span></:nav>
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-2xl space-y-8 px-4 py-6 sm:py-10 sm:px-6">
          <nav
            id="account-tabs"
            aria-label="Account"
            class="flex gap-1 overflow-x-auto rounded-2xl bg-base-100 p-1 text-sm shadow-sm ring-1 ring-base-content/10"
          >
            <.account_tab
              to={~p"/account"}
              active={@live_action == :index}
              icon="hero-user-circle"
              label="Account"
            />
            <.account_tab
              to={~p"/account/settings"}
              active={@live_action == :settings}
              icon="hero-adjustments-horizontal"
              label="Settings"
            />
            <.account_tab
              to={~p"/account/tokens"}
              active={@live_action == :tokens}
              icon="hero-key"
              label="API tokens"
            />
            <.account_tab
              to={~p"/account/data"}
              active={@live_action == :data}
              icon="hero-arrows-right-left"
              label="Import & export"
            />
            <.account_tab
              to={~p"/account/agent"}
              active={@live_action == :agent}
              icon="hero-cpu-chip"
              label="Set up an agent"
            />
          </nav>

          <%!-- Who you are, what you have used, who has been let in, and the
                way out. --%>
          <div :if={@live_action == :index} class="space-y-8">
            <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <h2 class="text-lg font-semibold">Profile</h2>
              <p class="text-sm text-base-content/60">Signed in as {@current_user.email}</p>
              <.form
                for={@profile_form}
                id="profile-form"
                phx-submit="save_profile"
                class="mt-4 flex items-end gap-3"
              >
                <div class="flex-1">
                  <.input field={@profile_form[:name]} label="Display name" placeholder="Your name" />
                </div>
                <button type="submit" class="btn btn-primary">Save</button>
              </.form>
            </section>

            <section
              :if={@limits.trial.applies?}
              class={[
                "rounded-2xl p-6 shadow-sm ring-1",
                if(@limits.trial.expired?,
                  do: "bg-error/10 ring-error/30",
                  else: "bg-base-100 ring-base-content/10"
                )
              ]}
            >
              <h2 class="text-lg font-semibold">
                {if @limits.trial.expired?, do: "Your free trial has ended", else: "Free trial"}
              </h2>
              <p class="mt-1 text-sm text-base-content/60">
                A free account on this server lasts {@limits.trial.days} days from the day
                it was made. Everything you have made stays here and stays editable either
                way — what ends is adding anything new.
              </p>
              <p class="mt-3 text-sm font-medium">
                {if @limits.trial.expired?,
                  do: "Ended #{Calendar.strftime(@limits.trial.ends_at, "%-d %B %Y")}.",
                  else:
                    "#{@limits.trial.days_left} day(s) left — until #{Calendar.strftime(@limits.trial.ends_at, "%-d %B %Y")}."}
              </p>
            </section>

            <section
              :if={Enum.any?([@limits.items, @limits.boards, @limits.storage], &worth_showing?/1)}
              class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
            >
              <h2 class="text-lg font-semibold">What you are using</h2>
              <p class="mt-1 text-sm text-base-content/60">
                Counted across the boards you own. Things on boards other people have shared
                with you cost you nothing; archiving a card or a page frees it up again, and
                a file counts until it is deleted.
              </p>

              <.usage
                :if={worth_showing?(@limits.items)}
                label="Cards, pages and files"
                status={@limits.items}
                detail={"#{@limits.breakdown.cards} cards · #{@limits.breakdown.pages} pages · #{@limits.breakdown.files} files"}
                full="You have used all of them. Archive something you have finished with, or subscribe for more."
                near="You are close to the limit. Archiving something you have finished with frees it up."
              />

              <.usage
                :if={worth_showing?(@limits.boards)}
                label="Boards you own"
                status={@limits.boards}
                full="You own as many boards as this server allows. Archive one, or ask an admin to raise the limit."
                near="You are close to the limit on boards."
              />

              <.usage
                :if={worth_showing?(@limits.storage)}
                label="Files"
                status={@limits.storage}
                bytes={true}
                full="Your files fill the space this server allows. Delete some attachments, or ask an admin to raise the limit."
                near="You are close to the limit on file storage."
              />
            </section>

            <section
              :if={@support_sessions != []}
              class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
            >
              <h2 class="text-lg font-semibold">Support access to your boards</h2>
              <p class="mt-1 text-sm text-base-content/60">
                Every time an admin of this server has been given access to your boards, and why.
                Current ones are marked; the rest are over.
              </p>

              <ul class="mt-4 space-y-2 text-sm">
                <li :for={session <- @support_sessions} class="flex items-start gap-2">
                  <span class={[
                    "badge badge-sm mt-0.5",
                    if(live_support?(session), do: "badge-warning", else: "badge-ghost")
                  ]}>
                    {if live_support?(session), do: "now", else: "ended"}
                  </span>
                  <span>
                    <span class="font-medium">{Accounts.User.display_name(session.admin)}</span>
                    — “{session.reason}”
                    <span class="block text-xs text-base-content/50">
                      from {session.inserted_at}, until {session.expires_at}
                    </span>
                  </span>
                </li>
              </ul>
            </section>

            <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <h2 class="text-lg font-semibold">Session</h2>
              <p class="text-sm text-base-content/60">
                Sign-in links keep you signed in for 30 days on this browser.
              </p>
              <.link href={~p"/logout"} method="delete" class="btn btn-outline btn-sm mt-4">
                <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Sign out
              </.link>
            </section>

            <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <h2 class="text-lg font-semibold">About</h2>
              <p class="text-sm text-base-content/60">
                Slipdock is free software under the <a
                  href="https://www.gnu.org/licenses/agpl-3.0.html"
                  target="_blank"
                  rel="noopener"
                  class="link"
                >GNU AGPL v3</a>. You are using it over a network, so you are entitled to its
                source — including any changes whoever runs this server has made: <a
                  href={@source_url}
                  target="_blank"
                  rel="noopener"
                  class="link break-all"
                >{@source_url}</a>.
              </p>
            </section>
          </div>

          <%!-- The dials: how a quick-added line is read, and the key the AI
                features run on. --%>
          <div :if={@live_action == :settings} class="space-y-8">
            <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <h2 class="text-lg font-semibold">Quick add</h2>
              <p class="text-sm text-base-content/60">
                Where the header's quick add box puts a card when the line doesn't name a board
                or list of its own.
              </p>
              <p :if={@quick_add_boards == []} class="mt-4 text-sm text-base-content/50">
                You have no board you can write to yet.
              </p>
              <.form
                :if={@quick_add_boards != []}
                for={@quick_add_form}
                id="quick-add-form-settings"
                phx-change="change_quick_add"
                phx-submit="save_quick_add"
                class="mt-4 space-y-2"
              >
                <div class="grid gap-3 sm:grid-cols-2">
                  <.input
                    field={@quick_add_form[:quick_add_board_id]}
                    type="select"
                    label="Board"
                    options={Enum.map(@quick_add_boards, &{&1.board.name, &1.board.id})}
                  />
                  <.input
                    field={@quick_add_form[:quick_add_column_id]}
                    type="select"
                    label="List"
                    options={Enum.map(@quick_add_columns, &{&1.name, &1.id})}
                  />
                </div>
                <.input
                  field={@quick_add_form[:quick_add_ai]}
                  type="checkbox"
                  label="Read the line with AI"
                />
                <p class="-mt-1 text-xs text-base-content/50">
                  {if AI.configured?(@current_user),
                    do:
                      "Plain English is turned into a card: “call the printers about banners friday, urgent” becomes a card due Friday at critical priority. Off, only the typed syntax (due: friday, #high, @dan) is read.",
                    else:
                      "Add an AI key below to use this; without one only the typed syntax (due: friday, #high, @dan) is read."}
                </p>
                <button type="submit" class="btn btn-primary btn-sm">Save</button>
              </.form>
            </section>

            <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <h2 class="text-lg font-semibold">AI model</h2>
              <p class="text-sm text-base-content/60">
                The AI features — chat and edits, the narrative, deep search, written
                automations, quick add — need a model to talk to. Either your own <a
                  href="https://openrouter.ai/keys"
                  target="_blank"
                  rel="noopener"
                  class="link"
                >OpenRouter key</a>, billed to your OpenRouter account, or an
                OpenAI-compatible endpoint of your own — LM Studio, Ollama, llama.cpp,
                vLLM, a gateway at work — which usually needs no key at all and sends
                nothing off your network. Either way it is kept on the server and used
                only for your own requests.
              </p>

              <dl class="mt-4 grid gap-x-6 gap-y-2 text-sm sm:grid-cols-[8rem_1fr]">
                <dt class="text-base-content/50">Endpoint</dt>
                <dd class="font-mono text-xs">
                  {@ai.base_url || @ai_default_endpoint}
                  <span :if={!@ai.base_url} class="font-sans text-base-content/50">
                    (this server's default)
                  </span>
                </dd>

                <dt class="text-base-content/50">Key</dt>
                <dd class="flex flex-wrap items-center gap-3">
                  <code :if={@ai_key} class="rounded bg-base-200 px-2 py-1 font-mono text-xs">{@ai_key}</code>
                  <span :if={@ai_key && @ai_key_set_at} class="text-xs text-base-content/50">
                    set {@ai_key_set_at |> String.slice(0, 10)}
                  </span>
                  <button
                    :if={@ai_key}
                    type="button"
                    class="btn btn-ghost btn-xs text-error"
                    phx-click="remove_ai_key"
                    data-confirm="Remove your stored API key?"
                  >Remove</button>
                  <span :if={!@ai_key && @ai.base_url} class="text-base-content/50">
                    none — your endpoint is being asked without one
                  </span>
                  <span
                    :if={!@ai_key && !@ai.base_url && @ai_key_shared?}
                    class="text-base-content/50"
                  >
                    none of your own; this server has a shared key, which is what your
                    requests use for now
                  </span>
                  <span
                    :if={!@ai_key && !@ai.base_url && !@ai_key_shared?}
                    class="text-base-content/50"
                  >
                    none, so AI features are off for you
                  </span>
                </dd>

                <dt class="text-base-content/50">Model</dt>
                <dd class="font-mono text-xs">
                  {@ai.model || @ai_default_model || "whatever the endpoint has loaded"}
                  <span :if={!@ai.model} class="font-sans text-base-content/50">
                    (not picked)
                  </span>
                </dd>

                <dt :if={@ai.embed_model} class="text-base-content/50">Embedding</dt>
                <dd :if={@ai.embed_model} class="font-mono text-xs">{@ai.embed_model}</dd>
              </dl>

              <form
                id={"ai-provider-form-#{@ai_key_form_key}"}
                phx-submit="save_ai_provider"
                class="mt-5 border-t border-base-content/10 pt-5"
              >
                <div class="grid gap-3 sm:grid-cols-2">
                  <div>
                    <.input
                      type="url"
                      name="base_url"
                      value={@ai.base_url}
                      label="Endpoint"
                      placeholder={@ai_default_endpoint}
                      class="w-full input font-mono text-xs"
                      autocomplete="off"
                    />
                    <p class="-mt-1 text-xs text-base-content/50">
                      The API root, the part before <code>/chat/completions</code>: <code>http://llm.local:1234/v1</code>. Empty for this server's default.
                    </p>
                  </div>
                  <div>
                    <.input
                      type="password"
                      name="api_key"
                      value=""
                      label="API key"
                      placeholder={if @ai_key, do: "unchanged", else: "sk-or-v1-… (optional)"}
                      class="w-full input font-mono text-xs"
                      autocomplete="off"
                    />
                    <p class="-mt-1 text-xs text-base-content/50">
                      Empty keeps the key you have, and most local endpoints want none.
                    </p>
                  </div>
                </div>
                <p :if={@ai_key && @ai.base_url} class="mt-1 text-xs text-base-content/50">
                  Your stored key is sent to your own endpoint as well — remove it if it
                  should not be.
                </p>
                <div class="mt-3 flex flex-wrap items-center gap-2">
                  <button type="submit" class="btn btn-primary btn-sm">Save</button>
                  <button
                    type="button"
                    class="btn btn-sm"
                    phx-click="list_ai_models"
                    phx-disable-with="Asking…"
                  >
                    {if @ai_models, do: "Refresh model list", else: "List models"}
                  </button>
                  <span class="text-xs text-base-content/50">
                    {if @ai_listing?,
                      do: "asking #{@ai.base_url || @ai_default_endpoint}…",
                      else: "Save the endpoint first — the list comes from what is stored."}
                  </span>
                </div>
              </form>

              <p :if={@ai_models_error} class="mt-4 rounded-xl bg-error/10 p-3 text-sm">
                {@ai_models_error}
              </p>

              <form
                :if={@ai_models}
                phx-submit="save_ai_model"
                class="mt-4 rounded-xl bg-base-200/60 p-4"
              >
                <p class="text-xs text-base-content/60">
                  {length(@ai_models)} model(s) on {@ai.base_url || @ai_default_endpoint}.
                </p>
                <div class="mt-2">
                  <.input
                    type="select"
                    name="model"
                    value={@ai.model || ""}
                    label="Model"
                    prompt="— this server's default —"
                    options={model_options(chat_models(@ai_models), @ai.model)}
                    class="w-full select font-mono text-xs"
                  />
                </div>
                <div :if={embedding_models(@ai_models) != []}>
                  <.input
                    type="select"
                    name="embed_model"
                    value={@ai.embed_model || ""}
                    label="Embedding model (semantic search)"
                    prompt="— this server's default —"
                    options={model_options(embedding_models(@ai_models), @ai.embed_model)}
                    class="w-full select font-mono text-xs"
                  />
                  <p class="-mt-1 text-xs text-base-content/50">
                    Only read for the account that indexes (SLIPDOCK_AI_SYSTEM_USER), and
                    changing it means a reindex — the old vectors are not comparable.
                  </p>
                </div>
                <input
                  :if={embedding_models(@ai_models) == []}
                  type="hidden"
                  name="embed_model"
                  value={@ai.embed_model}
                />
                <button type="submit" class="btn btn-primary btn-sm">Use this model</button>
              </form>
            </section>
          </div>

          <div :if={@live_action == :tokens} class="space-y-8">
            <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <h2 class="text-lg font-semibold">API tokens</h2>
              <p class="text-sm text-base-content/60">
                For the <code>slipdock</code>
                CLI and scripts. Run <code>slipdock auth &lt;token&gt;</code>
                after creating one.
              </p>
              <div :if={@new_token} class="mt-4 rounded-xl bg-warning/10 p-4 text-sm">
                <p class="font-medium">Copy this token now — it won't be shown again.</p>
                <code
                  id="new-token"
                  class="mt-2 block select-all break-all rounded bg-base-200 px-2 py-1 font-mono text-xs"
                >{@new_token}</code>
                <button type="button" class="btn btn-ghost btn-xs mt-2" phx-click="dismiss_token">Done</button>
              </div>
              <form
                id={"token-form-#{@form_key}"}
                phx-submit="create_token"
                class="mt-4 flex flex-wrap items-center gap-2"
              >
                <input
                  type="text"
                  name="label"
                  placeholder="Label (e.g. laptop)"
                  class="input input-sm min-w-40 flex-1"
                  autocomplete="off"
                />
                <select name="scope" class="select select-sm" aria-label="What this token may do">
                  <option value="write">Read and write</option>
                  <option value="read">Read only</option>
                  <option :if={Accounts.admin?(@current_user)} value="admin">
                    Administer this server
                  </option>
                </select>
                <select name="expires_in_days" class="select select-sm" aria-label="When it expires">
                  <option value="">Never expires</option>
                  <option value="30">Expires in 30 days</option>
                  <option value="90">Expires in 90 days</option>
                  <option value="365">Expires in a year</option>
                </select>
                <button type="submit" class="btn btn-primary btn-sm">Create token</button>
              </form>
              <ul class="mt-4 divide-y divide-base-content/10">
                <li
                  :for={t <- @tokens}
                  id={"token-#{t.id}"}
                  class="flex items-center gap-3 py-2 text-sm"
                >
                  <.icon name="hero-key" class="size-4 text-base-content/40" />
                  <span class="flex min-w-0 flex-1 flex-col">
                    <span class="flex items-center gap-2">
                      <span class="truncate font-medium">{t.label}</span>
                      <span class={[
                        "rounded px-1.5 py-0.5 text-[11px] font-medium",
                        if(t.scope == "read",
                          do: "bg-base-200 text-base-content/70",
                          else: "bg-primary/10 text-primary"
                        )
                      ]}>
                        {case t.scope do
                          "read" -> "read only"
                          "admin" -> "admin"
                          _ -> "read/write"
                        end}
                      </span>
                      <span
                        :if={Slipdock.Accounts.UserToken.expired?(t)}
                        class="rounded bg-error/10 px-1.5 py-0.5 text-[11px] font-medium text-error"
                      >
                        expired
                      </span>
                    </span>
                    <span class="text-xs text-base-content/50">
                      created {relative_time(t.inserted_at)}<span :if={t.last_used_at}> · used {relative_time(
                        t.last_used_at
                      )}<span :if={t.last_used_ip}> from {t.last_used_ip}</span></span><span :if={
                        t.expires_at
                      }> · {if Slipdock.Accounts.UserToken.expired?(t),
                        do: "expired " <> relative_time(t.expires_at),
                        else: "expires " <> relative_time(t.expires_at)}</span><span :if={
                        is_nil(t.expires_at)
                      }> · never expires</span>
                    </span>
                  </span>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs text-error"
                    phx-click="delete_token"
                    phx-value-id={t.id}
                    data-confirm="Revoke this token?"
                  >Revoke</button>
                </li>
              </ul>
              <p :if={@tokens == []} class="mt-3 text-sm text-base-content/50">No tokens yet.</p>
            </section>
          </div>

          <%!-- Pointing an agent at this server. The short version is the first
                section; everything under it is optional, and labelled as such,
                because the thing that goes wrong here is people believing they
                must install something first. --%>
          <div :if={@live_action == :agent} class="space-y-8">
            <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <h2 class="text-lg font-semibold">Set up an agent</h2>
              <p class="mt-1 text-sm text-base-content/60">
                Claude, ChatGPT or anything else that can run a shell command can read and
                write these boards. The agent runs wherever you already use it — your laptop,
                a cloud session, a phone app — and talks to this server over the web. You do
                not need access to the machine this is running on, and there is nothing to
                install first.
              </p>
            </section>

            <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <h2 class="text-lg font-semibold">1 · Tell it where the board is</h2>
              <p class="mt-1 text-sm text-base-content/60">
                Paste this at the start of a session. The address is this server's own, and
                <.link href={~p"/api/guide"} class="link">the guide</.link>
                it names is written for agents: the model, what a card means here, how to pick
                up the next thing, and every call it can make. Read with a token it also ends
                with your own boards and lists, which is why it is worth reading twice.
              </p>
              <.copy_block id="agent-prompt" text={@agent_prompt} label="Copy prompt" />
            </section>

            <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <h2 class="text-lg font-semibold">2 · Approve it, once</h2>
              <p class="mt-1 text-sm text-base-content/60">
                Not optional, and not only about writing: the guide is the one thing an agent
                can read without a token. Your boards need one — listing them, opening a card,
                searching — so it will ask almost straight away. It shows you a short code;
                you approve it here, in this browser, where you are already signed in. The
                agent never sees your password, and a code is only good for a few minutes.
              </p>
              <p class="mt-3 text-sm">
                <.link href={~p"/activate"} class="link font-medium">Approve a code →</.link>
              </p>
              <p class="mt-3 text-sm text-base-content/60">
                What it gets is an API token that acts as you. If you would rather it only
                looked, make a read-only one on the
                <.link navigate={~p"/account/tokens"} class="link">API tokens</.link>
                tab and give the agent that instead. Every token is listed there, with when it
                was last used and from where, and <span class="font-medium">Revoke</span>
                ends its access immediately.
              </p>
            </section>

            <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <h2 class="text-lg font-semibold">
                Optional · install the skills
                <span class="ml-1 align-middle text-xs font-normal text-base-content/50">
                  for Claude Code and anything that reads <code>~/.claude/skills</code>
                </span>
              </h2>
              <p class="mt-1 text-sm text-base-content/60">
                The guide above is enough on its own, and needs no token either. These are
                the longer instructions — the
                wiki, documents, working a backlog unattended — installed where your agent
                looks for them without being asked. The script needs <code>curl</code>
                and <code>tar</code>, nothing else: it writes the skills and
                saves this server's address in <code>~/.config/slipdock/url</code>, and signs
                nothing in.
              </p>
              <.copy_block
                id="agent-install"
                text={"curl -fsSL #{@base_url}/install.sh | sh"}
                label="Copy command"
              />
              <p class="mt-2 text-xs text-base-content/50">
                Rather read it first? <code>curl {@base_url}/install.sh</code>
                prints it. The skills are also
                <.link href={~p"/api/skills.tar.gz"} class="link">a tar.gz</.link>
                and <.link href={~p"/api/skills"} class="link">a JSON listing</.link>, each
                versioned with this server.
              </p>
            </section>

            <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <h2 class="text-lg font-semibold">
                Optional · the <code>slipdock</code>
                CLI
                <span class="ml-1 align-middle text-xs font-normal text-base-content/50">
                  needs Elixir to build
                </span>
              </h2>
              <p class="mt-1 text-sm text-base-content/60">
                A command-line client that wraps every call the agent would otherwise make with <code>curl</code>. Nicer to read in a transcript, and it keeps the token for
                you. Build it from the repository, then point it here:
              </p>
              <.copy_block
                id="agent-cli"
                text={"cd cli && mix escript.build && cp slipdock ~/.local/bin/\nslipdock url #{@base_url}\nslipdock auth"}
                label="Copy commands"
              />
            </section>
          </div>

          <%!-- Work leaving and work arriving: the whole-account zip, and
                boards as files another Slipdock can read. --%>
          <div :if={@live_action == :data} class="space-y-8">
            <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <h2 class="text-lg font-semibold">Your data</h2>
              <p class="mt-1 text-sm text-base-content/60">
                Everything you have here, as a zip: the boards you own with their cards, your wiki
                pages as Markdown, and anything you wrote on other people's boards.
              </p>
              <a href={~p"/account/export.zip"} class="btn btn-primary btn-sm mt-4">
                <.icon name="hero-arrow-down-tray" class="size-4" /> Download everything
              </a>
              <p class="mt-4 text-sm text-base-content/60">
                To close your account, ask an admin. Boards only you can see go with you; a board
                you have shared is handed to whoever else works on it rather than deleted out from
                under them.
              </p>
            </section>

            <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
              <h2 class="text-lg font-semibold">Move boards between servers</h2>
              <p class="mt-1 text-sm text-base-content/60">
                A board as one file that another Slipdock can read back: its lists, cards and
                subcards, tags, checklists, comments, custom fields, what waits on what, and the
                wiki. The zip above is for reading your work somewhere else; this is for moving it.
              </p>

              <h3 class="mt-5 text-sm font-medium">Take boards out</h3>
              <p class="mt-1 text-xs text-base-content/60">
                Only boards you own — a board shared with you is somebody else's to hand on.
              </p>

              <div :if={@own_boards == []} class="mt-3 text-sm text-base-content/50">
                You don't own a board yet, so there is nothing to take.
              </div>

              <div :if={@own_boards != []} class="mt-3 flex flex-wrap gap-2">
                <button
                  type="button"
                  phx-click="pick_all_boards"
                  class={["btn btn-xs", (@picked_boards == [] && "btn-primary") || "btn-outline"]}
                >
                  All of them
                </button>
                <button
                  :for={board <- @own_boards}
                  type="button"
                  phx-click="pick_board"
                  phx-value-id={board.id}
                  class={[
                    "btn btn-xs",
                    (board.id in @picked_boards && "btn-primary") || "btn-outline"
                  ]}
                >
                  {board.name}
                  <span :if={board.archived} class="opacity-60">· archived</span>
                </button>
              </div>

              <label
                :if={@own_boards != []}
                class="mt-3 flex cursor-pointer items-start gap-2 text-sm"
              >
                <input
                  type="checkbox"
                  checked={@with_archived}
                  phx-click="toggle_archived"
                  class="checkbox checkbox-sm mt-0.5"
                />
                <span>
                  <span class="block">Include what is archived</span>
                  <span class="block text-xs text-base-content/60">
                    Archived cards, archived wiki pages and archived boards. Left out otherwise.
                  </span>
                </span>
              </label>

              <a
                :if={@own_boards != []}
                href={boards_download_path(@picked_boards, @with_archived)}
                class="btn btn-primary btn-sm mt-4"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" />
                {if @picked_boards == [],
                  do: "Download every board you own",
                  else: "Download #{length(@picked_boards)} board(s)"}
              </a>

              <div class="mt-6 border-t border-base-content/10 pt-5">
                <h3 class="text-sm font-medium">Bring boards in</h3>
                <p class="mt-1 text-xs text-base-content/60">
                  A file like the one above, from this server or another one — or a Trello
                  board, exported from Trello as JSON (Menu → Print, export and share). It always makes
                  <span class="font-medium">new</span>
                  boards — it never merges into one you already have, because deciding which card
                  is “the same card” is how an import quietly destroys work.
                </p>

                <form
                  id="import-boards"
                  phx-submit="import_boards"
                  phx-change="validate_board_document"
                  class="mt-3"
                >
                  <.live_file_input
                    upload={@uploads.board_document}
                    class="file-input file-input-sm w-full max-w-sm"
                  />

                  <div
                    :for={entry <- @uploads.board_document.entries}
                    class="mt-2 flex items-center gap-3 text-sm"
                  >
                    <span class="font-mono text-xs">{entry.client_name}</span>
                    <button
                      type="button"
                      phx-click="cancel_board_document"
                      phx-value-ref={entry.ref}
                      class="btn btn-ghost btn-xs"
                    >
                      Remove
                    </button>
                  </div>

                  <p
                    :for={error <- upload_errors(@uploads.board_document)}
                    class="mt-2 text-sm text-error"
                  >
                    {upload_error_text(error)}
                  </p>

                  <button
                    type="submit"
                    disabled={@uploads.board_document.entries == []}
                    class="btn btn-primary btn-sm mt-3"
                  >
                    <.icon name="hero-arrow-up-tray" class="size-4" /> Import
                  </button>
                </form>

                <p :if={@import_error} class="mt-3 text-sm text-error">{@import_error}</p>

                <div :if={@import_report} class="mt-3 rounded-xl bg-base-200 p-4 text-sm">
                  <p class="font-medium">
                    {@import_report.cards} card(s) and {@import_report.pages} page(s) came in.
                  </p>
                  <ul class="mt-2 space-y-1">
                    <li :for={board <- @import_report.boards}>
                      <.link navigate={~p"/boards/#{board.id}"} class="link">{board.name}</.link>
                      <span class="font-mono text-xs text-base-content/50">{board.code}</span>
                    </li>
                  </ul>
                  <ul
                    :if={@import_report.skipped != []}
                    class="mt-3 space-y-1 text-xs text-base-content/60"
                  >
                    <li :for={note <- @import_report.skipped}>{note}</li>
                  </ul>
                </div>
              </div>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp relative_time(dt), do: SlipdockWeb.SlipdockComponents.relative_time(dt)
end

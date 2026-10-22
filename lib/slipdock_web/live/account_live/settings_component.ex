defmodule SlipdockWeb.AccountLive.SettingsComponent do
  @moduledoc """
  The Settings tab — the dials: how a quick-added line is read, the model
  the AI features run on, what is on show, and the links pinned to the
  header.
  """
  use SlipdockWeb, :live_component

  alias Slipdock.Accounts
  alias Slipdock.AI
  alias Slipdock.HeaderLinks
  alias Slipdock.QuickAdd.Capture

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Loaded once. The parent hands a fresh `current_user` back down after a
    # save, which must not throw away a model list or a half-edited form.
    if Map.has_key?(socket.assigns, :quick_add_form),
      do: {:ok, socket},
      else:
        {:ok,
         socket
         |> assign_quick_add(Accounts.change_quick_add(socket.assigns.current_user))
         |> assign_ai_key()
         |> assign_header_links()
         |> assign(google_drive: Slipdock.Google.status(socket.assigns.current_user))}
  end

  # The key itself is never sent to the browser — only its shape and when it
  # was set.
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

  # The links pinned to the header, and what could be pinned: boards the
  # person can open and their own vaults, less what is pinned already.
  defp assign_header_links(socket) do
    user = socket.assigns.current_user
    links = HeaderLinks.list(user)
    pinned = MapSet.new(links, &{&1.kind, &1.target.id})

    boards =
      for board <- Slipdock.Access.list_boards(user),
          not MapSet.member?(pinned, {:board, board.id}),
          do: {board.name, "board:#{board.id}"}

    vaults =
      for vault <- Slipdock.Vaults.list_vaults(user),
          not MapSet.member?(pinned, {:vault, vault.id}),
          do: {vault.name, "vault:#{vault.id}"}

    targets =
      [{"Boards", boards}, {"Wiki vaults", vaults}] |> Enum.reject(&(elem(&1, 1) == []))

    socket
    |> assign(header_links: links, header_link_targets: targets)
    |> assign_new(:header_link_icon, fn -> hd(HeaderLinks.icons()) end)
    |> assign_new(:header_link_target, fn -> nil end)
    |> assign_new(:header_link_form_key, fn -> 0 end)
  end

  # The header is the page's, drawn from the hook's assign: tell it.
  defp header_links_changed(socket) do
    send(self(), :header_links_changed)
    assign_header_links(socket)
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

  # Switching board drops the list, so the form can't keep pointing at a list
  # that lives somewhere else.
  defp board_switch(%{"quick_add_board_id" => chosen} = params, user) do
    if to_string(user.quick_add_board_id) == chosen,
      do: params,
      else: Map.put(params, "quick_add_column_id", nil)
  end

  defp board_switch(params, _user), do: params

  # Flashes belong to the page, which draws them, so they go up to it.
  defp flash(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end

  @impl true
  def handle_event("change_quick_add", %{"user" => params}, socket) do
    user = socket.assigns.current_user
    changeset = Accounts.change_quick_add(user, board_switch(params, user))
    {:noreply, assign_quick_add(socket, changeset)}
  end

  # Display: for now, whether meeting capture is out of sight for this person
  # (see `Slipdock.Meetings`). Only offered while the admin lets people choose.
  def handle_event("save_display", %{"display" => params}, socket) do
    case Accounts.update_display(socket.assigns.current_user, params) do
      {:ok, user} ->
        send(self(), {:current_user, user})
        {:noreply, socket |> assign(current_user: user) |> flash(:info, "Display saved.")}

      {:error, _cs} ->
        {:noreply, flash(socket, :error, "Couldn't save that.")}
    end
  end

  def handle_event("save_quick_add", %{"user" => params}, socket) do
    case Accounts.update_quick_add(socket.assigns.current_user, params) do
      {:ok, user} ->
        # The header's quick add box reads the page's user, so it must follow.
        send(self(), {:current_user, user})

        {:noreply,
         socket
         |> assign(current_user: user)
         |> assign_quick_add(Accounts.change_quick_add(user))
         |> flash(:info, "Quick add settings saved.")}

      {:error, cs} ->
        {:noreply, assign_quick_add(socket, cs)}
    end
  end

  def handle_event("pick_header_link_icon", %{"header_link" => params}, socket),
    do:
      {:noreply,
       assign(socket, header_link_icon: params["icon"], header_link_target: params["target"])}

  def handle_event("add_header_link", %{"header_link" => params}, socket) do
    user = socket.assigns.current_user

    with {:ok, target} <- HeaderLinks.resolve(user, params["target"] || ""),
         {:ok, _} <- HeaderLinks.add(user, target, params["icon"]) do
      {:noreply,
       socket
       |> update(:header_link_form_key, &(&1 + 1))
       |> assign(header_link_target: nil)
       |> header_links_changed()
       |> flash(:info, "#{target.name} pinned to the header.")}
    else
      {:error, message} -> {:noreply, flash(socket, :error, "Couldn't pin that: #{message}.")}
    end
  end

  def handle_event("remove_header_link", %{"id" => id}, socket) do
    HeaderLinks.remove(socket.assigns.current_user, String.to_integer(id))
    {:noreply, header_links_changed(socket)}
  end

  def handle_event("move_header_link", %{"id" => id, "direction" => direction}, socket)
      when direction in ["left", "right"] do
    HeaderLinks.move(
      socket.assigns.current_user,
      String.to_integer(id),
      String.to_existing_atom(direction)
    )

    {:noreply, header_links_changed(socket)}
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
         |> flash(:info, "AI settings saved.")}

      {:error, message} ->
        {:noreply, flash(socket, :error, message)}
    end
  end

  def handle_event("save_ai_model", params, socket) do
    attrs = %{model: params["model"] || "", embed_model: params["embed_model"] || ""}

    case AI.Keys.put_settings(socket.assigns.current_user, attrs) do
      :ok -> {:noreply, socket |> assign_ai_key() |> flash(:info, "Model saved.")}
      {:error, message} -> {:noreply, flash(socket, :error, message)}
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
      :ok -> {:noreply, socket |> assign_ai_key() |> flash(:info, "AI key removed.")}
      {:error, message} -> {:noreply, flash(socket, :error, message)}
    end
  end

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

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        meetings_choice?: Slipdock.Meetings.enabled?() and Slipdock.Meetings.hideable?()
      )

    ~H"""
    <div class="space-y-8">
      <section
        :if={@meetings_choice?}
        id="display-settings"
        class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
      >
        <h2 class="text-lg font-semibold">Display</h2>
        <p class="text-sm text-base-content/60">What you see. Nobody else is affected.</p>
        <form
          id="display-form"
          phx-submit="save_display"
          phx-target={@myself}
          class="mt-4 space-y-3"
        >
          <label class="flex cursor-pointer items-start gap-3 text-sm">
            <input type="hidden" name="display[hide_meetings]" value="false" />
            <input
              type="checkbox"
              id="display-hide-meetings"
              name="display[hide_meetings]"
              value="true"
              checked={@current_user.hide_meetings}
              class="checkbox checkbox-sm mt-0.5"
            />
            <span>
              <span class="block font-medium">Hide meetings</span>
              <span class="block text-xs text-base-content/60">
                No Meetings tab and no Capture a meeting in the menus, on any board. What other
                people capture still reaches the boards when they commit it.
              </span>
            </span>
          </label>
          <button type="submit" class="btn btn-primary btn-sm">Save</button>
        </form>
      </section>

      <section
        id="header-links-settings"
        class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
      >
        <h2 class="text-lg font-semibold">Header links</h2>
        <p class="text-sm text-base-content/60">
          Boards and wiki vaults you go to often, pinned to the top right of every page,
          left of quick add, as the icon you choose. Up to {HeaderLinks.max()}.
        </p>
        <ul :if={@header_links != []} class="mt-4 divide-y divide-base-300/60">
          <li
            :for={{link, index} <- Enum.with_index(@header_links)}
            id={"header-link-row-#{link.id}"}
            class="flex items-center gap-3 py-2 text-sm"
          >
            <.icon
              name={Slipdock.Wiki.Icons.class(link.icon) || "hero-link"}
              class="size-5 shrink-0 text-base-content/70"
            />
            <span class="min-w-0 flex-1 truncate">
              {link.name}
              <span class="text-xs text-base-content/50">
                {if link.kind == :vault, do: "vault", else: "board"}
              </span>
            </span>
            <button
              type="button"
              class="btn btn-ghost btn-xs btn-square"
              phx-click="move_header_link"
              phx-value-id={link.id}
              phx-value-direction="left"
              phx-target={@myself}
              disabled={index == 0}
              aria-label={"Move #{link.name} left"}
              title="Move left"
            >
              <.icon name="hero-arrow-left" class="size-4" />
            </button>
            <button
              type="button"
              class="btn btn-ghost btn-xs btn-square"
              phx-click="move_header_link"
              phx-value-id={link.id}
              phx-value-direction="right"
              phx-target={@myself}
              disabled={index == length(@header_links) - 1}
              aria-label={"Move #{link.name} right"}
              title="Move right"
            >
              <.icon name="hero-arrow-right" class="size-4" />
            </button>
            <button
              type="button"
              class="btn btn-ghost btn-xs text-error"
              phx-click="remove_header_link"
              phx-value-id={link.id}
              phx-target={@myself}
            >
              Remove
            </button>
          </li>
        </ul>
        <p
          :if={@header_link_targets == [] and length(@header_links) < HeaderLinks.max()}
          class="mt-4 text-sm text-base-content/50"
        >
          Every board and vault you have is pinned already.
        </p>
        <form
          :if={@header_link_targets != [] and length(@header_links) < HeaderLinks.max()}
          id={"header-link-form-#{@header_link_form_key}"}
          phx-change="pick_header_link_icon"
          phx-submit="add_header_link"
          phx-target={@myself}
          class="mt-4 space-y-3"
        >
          <label class="block text-sm">
            <span class="mb-1 block font-medium">Board or vault</span>
            <select name="header_link[target]" class="select select-sm w-full sm:w-80">
              {Phoenix.HTML.Form.options_for_select(@header_link_targets, @header_link_target)}
            </select>
          </label>
          <fieldset>
            <legend class="mb-1 text-sm font-medium">Icon</legend>
            <div class="flex flex-wrap gap-1" role="radiogroup" aria-label="Icon">
              <label
                :for={name <- HeaderLinks.icons()}
                class="btn btn-ghost btn-xs btn-square has-[:checked]:bg-primary/15 has-[:checked]:ring-1 has-[:checked]:ring-primary"
                title={String.replace(name, "-", " ")}
              >
                <input
                  type="radio"
                  name="header_link[icon]"
                  value={name}
                  checked={@header_link_icon == name}
                  class="sr-only"
                />
                <.icon name={Slipdock.Wiki.Icons.class(name)} class="size-4" />
              </label>
            </div>
          </fieldset>
          <button type="submit" class="btn btn-primary btn-sm">Pin to header</button>
        </form>
      </section>

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
          phx-target={@myself}
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
              phx-target={@myself}
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
          phx-target={@myself}
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
              phx-target={@myself}
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
          phx-target={@myself}
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
              Only read for the account that indexes (Configuration → AI for search), and
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

      <.google_drive status={@google_drive} />
    </div>
    """
  end

  # Not drawn at all on a server with no Google OAuth client (W-1690).
  attr :status, :any, required: true

  defp google_drive(%{status: :not_configured} = assigns), do: ~H""

  defp google_drive(assigns) do
    ~H"""
    <section
      id="google-drive"
      class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
    >
      <h2 class="text-lg font-semibold">Google Drive</h2>
      <p class="text-sm text-base-content/60">
        Meeting recordings stay on your Google Drive. Connect it, read-only, and a
        vault of yours can play them beside their transcripts. Nothing is copied
        here.
      </p>
      <p :if={match?({:connected, _}, @status)} id="google-drive-status" class="mt-4 text-sm">
        <.icon name="hero-check-circle" class="size-4 text-success" /> Connected{google_as(@status)}.
      </p>
      <p :if={@status == :revoked} id="google-drive-status" class="mt-4 text-sm text-warning">
        <.icon name="hero-exclamation-triangle" class="size-4" />
        Google no longer accepts this connection. Connect again to mend it.
      </p>
      <p :if={@status == :not_connected} id="google-drive-status" class="mt-4 text-sm">
        Not connected.
      </p>
      <div class="mt-4 flex gap-2">
        <.link
          :if={@status in [:not_connected, :revoked]}
          href={~p"/account/google/connect"}
          id="google-drive-connect"
          class="btn btn-primary btn-sm"
        >
          Connect Google Drive
        </.link>
        <.link
          :if={@status != :not_connected}
          href={~p"/account/google"}
          method="delete"
          id="google-drive-disconnect"
          data-confirm="Disconnect Google Drive? Recordings in your vaults stop playing until you connect again."
          class="btn btn-ghost btn-sm"
        >
          Disconnect
        </.link>
      </div>
    </section>
    """
  end

  defp google_as({:connected, email}) when is_binary(email), do: " as " <> email
  defp google_as(_), do: ""
end

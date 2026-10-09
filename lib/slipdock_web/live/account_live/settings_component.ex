defmodule SlipdockWeb.AccountLive.SettingsComponent do
  @moduledoc """
  The Settings tab — the dials: how a quick-added line is read, the model
  the AI features run on, and what is on show.
  """
  use SlipdockWeb, :live_component

  alias Slipdock.Accounts
  alias Slipdock.AI
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
         |> assign_ai_key()}
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
    </div>
    """
  end
end

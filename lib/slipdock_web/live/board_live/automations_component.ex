defmodule SlipdockWeb.BoardLive.AutomationsComponent do
  @moduledoc """
  The board's Automations panel: rules picked from the ready-made ones and
  filled in with a short form, or written as sentences and parsed once by the
  model; either way they are then run by the app. Also the log of the
  callbacks those rules have made.

  Owns its state, its events and its authorisation: every event is refused
  unless the reader owns the board, which it works out for itself from the
  board it is given rather than taking the parent's word for it, and every
  rule named by id is looked up on that board.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.BoardLive.Helpers, only: [flash: 3]

  alias Slipdock.{Access, Automations}
  alias Slipdock.Automations.{Callback, Presets, Rule}

  # How many of the board's recent callbacks the panel lists.
  @callbacks_shown 20

  @events ~w(rule_change pick_rule_preset rule_preset_change cancel_rule_preset create_rule_preset
    use_example edit_rule cancel_edit_rule create_rule toggle_rule delete_rule run_rule)

  @doc false
  # For the test that every `handle_event/3` clause is in the list.
  def events, do: @events

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       rules: nil,
       callbacks: [],
       rule_text: "",
       rule_error: nil,
       rule_busy: false,
       editing_rule: nil,
       rule_preset: nil,
       rule_preset_params: %{},
       rule_preset_error: nil
     )}
  end

  # The parent passes `refresh: true` when a callback lands (see
  # `Slipdock.Automations.subscribe_callbacks/1`).
  @impl true
  def update(%{refresh: true}, socket) do
    {:ok,
     socket
     |> assign(callbacks: Automations.list_callbacks(socket.assigns.board.id, @callbacks_shown))
     |> assign_rules()}
  end

  def update(assigns, socket) do
    %{board: board, current_user: user} = assigns

    socket =
      assign(socket,
        board: board,
        current_user: user,
        ai?: assigns.ai?,
        close_path: assigns.close_path,
        can_manage: Access.board_permission(user, board) == :owner
      )

    socket =
      if is_nil(socket.assigns.rules) do
        socket
        |> assign(callbacks: Automations.list_callbacks(board.id, @callbacks_shown))
        |> assign_rules()
      else
        socket
      end

    {:ok, socket}
  end

  ## Events ------------------------------------------------------------------

  @impl true
  def handle_event(event, _params, socket) when event not in @events do
    {:noreply, flash(socket, :error, "That isn't something this page can do.")}
  end

  def handle_event(_event, _params, %{assigns: %{can_manage: false}} = socket) do
    {:noreply, flash(socket, :error, "Only the board's owner can do that.")}
  end

  def handle_event("rule_change", %{"text" => text}, socket),
    do: {:noreply, assign(socket, rule_text: text)}

  # Ready-made rules: pick one, fill in its few fields, add it. No model.
  def handle_event("pick_rule_preset", %{"key" => key}, socket) do
    case {socket.assigns.rule_preset, Presets.get(key)} do
      {^key, _} ->
        {:noreply, assign(socket, rule_preset: nil, rule_preset_error: nil)}

      {_, nil} ->
        {:noreply, socket}

      {_, preset} ->
        {:noreply,
         assign(socket,
           rule_preset: key,
           rule_preset_params: Presets.defaults(preset, socket.assigns.board),
           rule_preset_error: nil
         )}
    end
  end

  def handle_event("rule_preset_change", %{"preset" => params}, socket),
    do: {:noreply, assign(socket, rule_preset_params: params)}

  def handle_event("cancel_rule_preset", _params, socket),
    do: {:noreply, assign(socket, rule_preset: nil, rule_preset_error: nil)}

  def handle_event("create_rule_preset", %{"preset" => params}, socket) do
    %{board: board, current_user: user, rule_preset: key} = socket.assigns

    case Automations.create_rule_from_preset(board, key, params, created_by: user) do
      {:ok, rule} ->
        {:noreply,
         socket
         |> assign(rule_preset: nil, rule_preset_params: %{}, rule_preset_error: nil)
         |> assign_rules()
         |> flash(:info, "“#{rule.name}”: #{Rule.summary(rule)}")}

      {:error, message} ->
        {:noreply, assign(socket, rule_preset_params: params, rule_preset_error: message)}
    end
  end

  def handle_event("use_example", %{"text" => text}, socket),
    do: {:noreply, assign(socket, rule_text: text, rule_error: nil)}

  def handle_event("edit_rule", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.rules, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      rule ->
        {:noreply,
         assign(socket, editing_rule: rule.id, rule_text: rule.source || "", rule_error: nil)}
    end
  end

  def handle_event("cancel_edit_rule", _params, socket),
    do: {:noreply, assign(socket, editing_rule: nil, rule_text: "", rule_error: nil)}

  # Writing the rule means asking the model to turn it into a spec, which
  # takes a second or two; the composer keeps the text and says so meanwhile.
  def handle_event("create_rule", %{"text" => text}, socket) do
    text = String.trim(text)
    board = socket.assigns.board
    user = socket.assigns.current_user
    editing = socket.assigns.editing_rule

    if text == "" do
      {:noreply, assign(socket, rule_error: "Describe the rule first.")}
    else
      {:noreply,
       socket
       |> assign(rule_busy: true, rule_error: nil, rule_text: text)
       |> start_async(:rule, fn ->
         case editing do
           nil -> Automations.create_rule_from_text(board, text, created_by: user)
           id -> Automations.rewrite_rule(Automations.get_rule!(id), text, created_by: user)
         end
       end)}
    end
  end

  def handle_event("toggle_rule", %{"id" => id}, socket) do
    case Automations.get_board_rule(socket.assigns.board.id, id) do
      nil ->
        {:noreply, socket}

      rule ->
        {:ok, _} = Automations.toggle_rule(rule)
        {:noreply, assign_rules(socket)}
    end
  end

  def handle_event("delete_rule", %{"id" => id}, socket) do
    case Automations.get_board_rule(socket.assigns.board.id, id) do
      nil ->
        {:noreply, socket}

      rule ->
        {:ok, _} = Automations.delete_rule(rule)

        {:noreply,
         socket
         |> assign(editing_rule: nil, rule_text: "")
         |> assign_rules()
         |> flash(:info, "Removed “#{rule.name}”.")}
    end
  end

  # Time-based rules remember what they have already acted on; running one by
  # hand forgets that first, so it can act on the same cards again.
  def handle_event("run_rule", %{"id" => id}, socket) do
    case Automations.get_board_rule(socket.assigns.board.id, id) do
      nil ->
        {:noreply, socket}

      rule ->
        message =
          case Automations.run_rule_now(rule) do
            0 -> "Nothing matched “#{rule.name}” right now."
            1 -> "“#{rule.name}” ran once."
            n -> "“#{rule.name}” ran #{n} times."
          end

        send(self(), :reload_board)
        {:noreply, socket |> assign_rules() |> flash(:info, message)}
    end
  end

  ## Async: the model writing a rule ------------------------------------------

  @impl true
  def handle_async(:rule, {:ok, {:ok, %Rule{} = rule}}, socket) do
    {:noreply,
     socket
     |> assign(rule_busy: false, rule_text: "", editing_rule: nil)
     |> assign_rules()
     |> flash(:info, "“#{rule.name}”: #{Rule.summary(rule)}")}
  end

  def handle_async(:rule, {:ok, {:error, message}}, socket),
    do: {:noreply, assign(socket, rule_busy: false, rule_error: message)}

  def handle_async(:rule, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, rule_busy: false, rule_error: "Writing the rule failed: #{inspect(reason)}")}
  end

  # The rules, and the count beside Automations in the board's menu.
  defp assign_rules(socket) do
    rules = Automations.list_rules(socket.assigns.board.id)
    send(self(), {:rules_changed, rules})
    assign(socket, rules: rules)
  end

  ## Render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="board-automations" phx-target={@myself}>
      <.automations_modal
        board={@board}
        rules={@rules}
        callbacks={@callbacks}
        text={@rule_text}
        error={@rule_error}
        busy={@rule_busy}
        editing={@editing_rule}
        preset={@rule_preset}
        preset_params={@rule_preset_params}
        preset_error={@rule_preset_error}
        current_user={@current_user}
        ai?={@ai?}
        close_path={@close_path}
        target={@myself}
      />
    </div>
    """
  end

  attr :board, :any, required: true
  attr :preset, :string, default: nil
  attr :params, :map, default: %{}
  attr :error, :string, default: nil
  attr :current_user, :any, default: nil
  attr :target, :any, required: true

  # The ready-made rules, grouped, with the picked one's form opened beneath.
  defp rule_presets(assigns) do
    presets = Presets.all()

    assigns =
      assign(assigns,
        groups: Enum.chunk_by(presets, & &1.group),
        picked: assigns.preset && Enum.find(presets, &(&1.key == assigns.preset))
      )

    ~H"""
    <div id="rule-presets" class="space-y-2">
      <p class="text-xs font-medium text-base-content/60">Ready-made</p>
      <div :for={group <- @groups} class="flex flex-wrap items-center gap-1.5">
        <span class="w-16 shrink-0 text-2xs uppercase tracking-wide text-base-content/40">
          {hd(group).group}
        </span>
        <button
          :for={p <- group}
          phx-target={@target}
          type="button"
          id={"rule-preset-#{p.key}"}
          class={[
            "chip chip-line text-xs hover:bg-base-200",
            @preset == p.key && "bg-primary/10 ring-1 ring-primary/40"
          ]}
          phx-click="pick_rule_preset"
          phx-value-key={p.key}
          title={p.description}
          aria-pressed={to_string(@preset == p.key)}
        >
          {p.title}
        </button>
      </div>

      <.form
        :if={@picked}
        phx-target={@target}
        for={%{}}
        as={:preset}
        id="rule-preset-form"
        phx-change="rule_preset_change"
        phx-submit="create_rule_preset"
        class="space-y-3 rounded-xl bg-base-200/50 p-3 ring-1 ring-base-content/5"
      >
        <p class="text-sm">
          <span class="font-medium">{@picked.title}.</span>
          <span class="text-base-content/60">{@picked.description}</span>
        </p>
        <div class="grid gap-2 sm:grid-cols-2">
          <label :for={field <- @picked.fields} class="space-y-0.5 text-xs">
            <span class="text-base-content/70">
              {field.label}<span :if={field.required} class="text-error">*</span>
              <span :if={field[:hint]} class="text-base-content/40">— {field.hint}</span>
            </span>
            <.preset_input
              field={field}
              value={@params[field.name]}
              board={@board}
              current_user={@current_user}
            />
          </label>
        </div>
        <p :if={@error} class="text-sm text-error">{@error}</p>
        <div class="flex items-center gap-2">
          <button type="submit" class="btn btn-primary btn-sm gap-1.5">
            <.icon name="hero-plus" class="size-4" /> Add rule
          </button>
          <button
            phx-target={@target}
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="cancel_rule_preset"
          >
            Cancel
          </button>
        </div>
      </.form>
    </div>
    """
  end

  attr :field, :map, required: true
  attr :value, :any, default: nil
  attr :board, :any, required: true
  attr :current_user, :any, default: nil

  @preset_input_class "w-full rounded-lg border-0 bg-base-100 px-2 py-1 text-sm ring-1 ring-base-content/10 focus:ring-2 focus:ring-primary"

  # A board with no tags yet still lets a tag be named.
  defp preset_input(%{field: %{type: "tag"}, board: %{tags: []}} = assigns),
    do: preset_text_input(assigns)

  defp preset_input(%{field: %{type: type}} = assigns)
       when type in ~w(column tag notify field flag priority) do
    options =
      case type do
        "column" -> Enum.map(assigns.board.columns, &{&1.name, &1.name})
        "tag" -> Enum.map(assigns.board.tags, &{&1.name, &1.name})
        "notify" -> Enum.map(Presets.notify_options(), fn {v, l} -> {l, v} end)
        "field" -> Enum.map(assigns.field.options, &{String.replace(&1, "_", " "), &1})
        _ -> Enum.map(assigns.field.options, &{&1, &1})
      end

    blank =
      cond do
        assigns.field.required -> nil
        type == "field" -> "Any field"
        true -> "Any"
      end

    assigns = assign(assigns, options: options, blank: blank, class: @preset_input_class)

    ~H"""
    <select name={"preset[#{@field.name}]"} class={@class}>
      <option :if={@blank} value="">{@blank}</option>
      {Phoenix.HTML.Form.options_for_select(@options, to_string(@value || ""))}
    </select>
    """
  end

  defp preset_input(assigns), do: preset_text_input(assigns)

  defp preset_text_input(assigns) do
    {type, placeholder} =
      case assigns.field.type do
        "number" -> {"number", nil}
        "card" -> {"text", "129"}
        "email" -> {"email", assigns.current_user && assigns.current_user.email}
        "url" -> {"url", "https://example.com/hooks/slipdock"}
        "person" -> {"text", "Name or email"}
        _ -> {"text", nil}
      end

    assigns = assign(assigns, type: type, placeholder: placeholder, class: @preset_input_class)

    ~H"""
    <input
      type={@type}
      name={"preset[#{@field.name}]"}
      value={@value}
      placeholder={@placeholder}
      min={if @type == "number", do: 1}
      class={@class}
    />
    """
  end

  attr :board, :any, required: true
  attr :rules, :list, required: true
  attr :callbacks, :list, default: []
  attr :text, :string, required: true
  attr :error, :string, default: nil
  attr :busy, :boolean, default: false
  attr :editing, :any, default: nil
  attr :preset, :string, default: nil
  attr :preset_params, :map, default: %{}
  attr :preset_error, :string, default: nil
  attr :current_user, :any, default: nil
  attr :ai?, :boolean, default: false
  attr :close_path, :string, required: true
  attr :target, :any, required: true

  # Automations: rules picked from the ready-made ones and filled in with a
  # short form, or written as sentences and parsed once by the model; either
  # way they are then run by the app. The spec underneath is shown, and can be
  # read, but isn't something to fill in by hand.
  defp automations_modal(assigns) do
    assigns = assign(assigns, examples: Automations.examples())

    ~H"""
    <.modal id="automations-modal" on_close={JS.patch(@close_path)} size="lg">
      <div class="space-y-5 p-6">
        <div>
          <h2 class="flex items-center gap-2 text-lg font-semibold">
            <.icon name="hero-cpu-chip" class="size-5 text-primary" /> Automations
          </h2>
          <p class="mt-1 text-sm text-base-content/60">
            Pick a ready-made rule, or describe what should happen and when in your
            own words. Rules run on <strong class="font-medium">{@board.name}</strong>
            as cards change, and on a timer for anything about elapsed time.
          </p>
        </div>

        <.rule_presets
          board={@board}
          preset={@preset}
          params={@preset_params}
          error={@preset_error}
          current_user={@current_user}
          target={@target}
        />

        <p class="pt-1 text-xs font-medium text-base-content/60">Or in your own words</p>

        <div
          :if={!@ai?}
          class="rounded-xl bg-warning/10 px-3 py-2 text-sm text-warning-content ring-1 ring-warning/30"
        >
          <.icon name="hero-exclamation-triangle" class="mr-1 size-4 align-text-bottom" />
          Rules in your own words are written by the AI, which isn't configured: set
          <code class="font-mono text-xs">OPENROUTER_API_KEY</code>
          to use them. Ready-made rules work without it, and existing rules keep running.
        </div>

        <.form
          phx-target={@target}
          for={%{}}
          id="rule-form"
          phx-submit="create_rule"
          phx-change="rule_change"
          class="space-y-2"
        >
          <textarea
            id="rule-text"
            name="text"
            rows="2"
            disabled={!@ai? or @busy}
            phx-debounce="300"
            placeholder="When a card lands in Done, email ops@example.com…"
            class="w-full resize-y rounded-xl border-0 bg-base-200/70 px-3 py-2 text-sm ring-1 ring-base-content/10 placeholder:text-base-content/40 focus:ring-2 focus:ring-primary"
          >{@text}</textarea>
          <div class="flex flex-wrap items-center gap-2">
            <button type="submit" class="btn btn-primary btn-sm gap-1.5" disabled={!@ai? or @busy}>
              <.icon
                name={if @busy, do: "hero-arrow-path", else: "hero-sparkles"}
                class={["size-4", @busy && "motion-safe:animate-spin"]}
              />
              {cond do
                @busy -> "Writing the rule…"
                @editing -> "Rewrite rule"
                true -> "Create rule"
              end}
            </button>
            <button
              :if={@editing}
              phx-target={@target}
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="cancel_edit_rule"
            >
              Cancel
            </button>
            <span class="text-xs text-base-content/50">
              Placeholders like <code class="font-mono">{"{{card.title}}"}</code>
              and <code class="font-mono">{"{{card.url}}"}</code>
              work in emails and alerts.
            </span>
          </div>
        </.form>

        <p
          :if={@error}
          class="rounded-xl bg-error/10 px-3 py-2 text-sm text-error ring-1 ring-error/20"
        >
          {@error}
        </p>

        <div :if={@ai? and @rules == []} class="space-y-1.5">
          <p class="text-xs font-medium text-base-content/60">Try one of these:</p>
          <div class="flex flex-wrap gap-1.5">
            <button
              :for={example <- @examples}
              phx-target={@target}
              type="button"
              class="chip chip-line max-w-full truncate text-left text-xs hover:bg-base-200"
              phx-click="use_example"
              phx-value-text={example}
              title={example}
            >
              {example}
            </button>
          </div>
        </div>

        <div class="space-y-2 border-t border-base-content/10 pt-4">
          <div class="flex items-center justify-between">
            <span class="text-sm font-medium">
              Rules <span :if={@rules != []} class="text-base-content/50">({length(@rules)})</span>
            </span>
          </div>
          <p :if={@rules == []} class="text-sm text-base-content/60">No rules yet.</p>
          <ul class="max-h-[45vh] space-y-2 overflow-y-auto kanban-scroll pr-1">
            <li
              :for={rule <- @rules}
              id={"rule-#{rule.id}"}
              class={[
                "rounded-xl p-3 ring-1 transition-colors",
                rule.enabled && "bg-base-200/50 ring-base-content/5",
                !rule.enabled && "bg-base-200/20 opacity-60 ring-base-content/5"
              ]}
            >
              <div class="flex items-start gap-3">
                <input
                  phx-target={@target}
                  type="checkbox"
                  class="toggle toggle-sm mt-0.5 shrink-0"
                  checked={rule.enabled}
                  phx-click="toggle_rule"
                  phx-value-id={rule.id}
                  aria-label={"Turn “#{rule.name}” " <> if(rule.enabled, do: "off", else: "on")}
                  title={if rule.enabled, do: "Turn off", else: "Turn on"}
                />
                <div class="min-w-0 flex-1 space-y-1">
                  <p class="text-sm font-medium leading-snug">{rule.name}</p>
                  <p class="text-xs leading-snug text-base-content/70">{Rule.summary(rule)}</p>
                  <p
                    :if={rule.source}
                    class="truncate text-2xs italic text-base-content/40"
                    title={rule.source}
                  >
                    “{rule.source}”
                  </p>
                  <div class="flex flex-wrap items-center gap-1.5 pt-0.5 text-2xs text-base-content/50">
                    <span class="chip chip-line">{Rule.trigger_type(rule)}</span>
                    <span
                      :if={Rule.scheduled?(rule)}
                      class="chip chip-line"
                      title="Checked on a timer"
                    >
                      <.icon name="hero-clock" class="size-3" /> timed
                    </span>
                    <span
                      :if={rule.scope == "tree"}
                      class="chip chip-line"
                      title="Also watches subcards"
                    >
                      whole tree
                    </span>
                    <span :if={rule.run_count > 0}>
                      ran {rule.run_count}× · last {relative_time(rule.last_run_at)}
                    </span>
                    <span :if={rule.run_count == 0}>never run</span>
                  </div>
                  <p :if={rule.last_error} class="text-2xs text-error" title={rule.last_error}>
                    <.icon name="hero-exclamation-circle" class="size-3 align-text-bottom" />
                    {rule.last_error}
                  </p>
                  <details class="pt-0.5">
                    <summary class="cursor-pointer text-2xs text-base-content/40 hover:text-base-content/70">
                      What this does, exactly
                    </summary>
                    <pre class="mt-1 overflow-x-auto rounded-lg bg-base-300/50 p-2 font-mono text-2xs leading-relaxed">{Jason.encode!(rule.spec, pretty: true)}</pre>
                  </details>
                </div>
                <div class="flex shrink-0 items-center gap-0.5">
                  <button
                    :if={Rule.scheduled?(rule)}
                    phx-target={@target}
                    type="button"
                    class="btn btn-ghost btn-xs btn-square"
                    phx-click="run_rule"
                    phx-value-id={rule.id}
                    title="Run this rule now"
                  >
                    <.icon name="hero-play" class="size-3.5" />
                  </button>
                  <button
                    :if={@ai?}
                    phx-target={@target}
                    type="button"
                    class="btn btn-ghost btn-xs btn-square"
                    phx-click="edit_rule"
                    phx-value-id={rule.id}
                    title="Reword this rule"
                  >
                    <.icon name="hero-pencil-square" class="size-3.5" />
                  </button>
                  <button
                    phx-target={@target}
                    type="button"
                    class="btn btn-ghost btn-xs btn-square text-error"
                    phx-click="delete_rule"
                    phx-value-id={rule.id}
                    data-confirm={"Delete the rule “#{rule.name}”?"}
                    title="Delete"
                  >
                    <.icon name="hero-trash" class="size-3.5" />
                  </button>
                </div>
              </div>
            </li>
          </ul>
        </div>

        <.callback_log :if={@callbacks != []} callbacks={@callbacks} />
      </div>
    </.modal>
    """
  end

  attr :callbacks, :list, required: true

  # The calls the board's rules have made, newest first, as they land — the
  # only place a callback that failed in the background shows up at all.
  defp callback_log(assigns) do
    ~H"""
    <div id="callback-log" class="space-y-2 border-t border-base-content/10 pt-4">
      <p class="text-sm font-medium">
        Recent callbacks
        <span class="font-normal text-base-content/50">— the newest {length(@callbacks)}</span>
      </p>
      <ul class="max-h-[30vh] space-y-1 overflow-y-auto kanban-scroll pr-1">
        <li
          :for={call <- @callbacks}
          id={"callback-#{call.id}"}
          class="flex items-start gap-2 rounded-lg px-2 py-1.5 text-xs odd:bg-base-200/40"
        >
          <.icon
            name={if Callback.ok?(call), do: "hero-check-circle", else: "hero-exclamation-circle"}
            class={[
              "mt-0.5 size-3.5 shrink-0",
              (Callback.ok?(call) && "text-success") || "text-error"
            ]}
          />
          <div class="min-w-0 flex-1">
            <p class="truncate" title={"#{call.method} #{call.url}"}>
              <span class="font-mono text-2xs font-semibold">{call.method}</span>
              <span class="font-mono text-2xs text-base-content/70">{call.url}</span>
            </p>
            <p class="truncate text-2xs text-base-content/50">
              {call.rule_name || "a deleted rule"}<span :if={call.card_title}> · {call.card_title}</span>
            </p>
          </div>
          <div class="shrink-0 text-right text-2xs">
            <p
              class={["max-w-48 truncate", (Callback.ok?(call) && "text-success") || "text-error"]}
              title={Callback.outcome(call)}
            >
              {Callback.outcome(call)}<span :if={call.duration_ms} class="text-base-content/40"> · {call.duration_ms} ms</span>
            </p>
            <p class="text-base-content/40" title={to_string(call.inserted_at)}>
              {relative_time(call.inserted_at)}
            </p>
          </div>
        </li>
      </ul>
    </div>
    """
  end
end

defmodule SlipdockWeb.AIChatComponent do
  @moduledoc """
  "Chat about this": a conversation with the model about the page the user
  is looking at, in two modes. *Chat* answers questions; *Edit* (for users
  who can write) turns requests into proposed changes that are applied only
  when the user clicks Apply.

  The parent gives it the page as a `source` (see `Slipdock.AI.Context.build/1`)
  and a `scope` for edits (see `Slipdock.AI.Actions.prepare/2`). It renders
  either as a right-hand drawer (`layout="drawer"`, toggled from a button
  elsewhere with `phx-click="toggle" phx-target="#<id>"`) or inline
  (`layout="inline"`, with its own header button).
  """
  use SlipdockWeb, :live_component

  alias Slipdock.AI.{Actions, Assistant, Context}
  alias SlipdockWeb.Markdown

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open: false,
       mode: "chat",
       messages: [],
       busy: false,
       error: nil,
       form_key: 0,
       layout: "drawer",
       title: "Chat about this",
       placeholder: nil,
       can_write: false,
       scope: %{}
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    mode = if socket.assigns.can_write, do: socket.assigns.mode, else: "chat"
    scope = assigns[:scope] || scope_for(socket.assigns.source, socket.assigns[:current_user])
    {:ok, assign(socket, mode: mode, scope: scope)}
  end

  # What edits may touch: every card the model was shown, on the page's board.
  defp scope_for(%{kind: :board} = source, user) do
    open = source[:card]

    subcards =
      if match?(%{sub_board: %{cards: cards}} when is_list(cards), open),
        do: open.sub_board.cards,
        else: []

    cards = Enum.uniq_by((source.cards || []) ++ List.wrap(open) ++ subcards, & &1.id)

    %{
      board: source.board,
      cards: cards,
      # The wiki pages the model was shown; a page action may name one of
      # these and nothing else.
      pages: source[:pages] || [],
      user: user,
      users: source[:users] || []
    }
  end

  defp scope_for(%{kind: :card} = source, user),
    do: %{board: source.board, cards: [source.card], user: user, users: source[:users] || []}

  defp scope_for(%{kind: :work} = source, user) do
    cards = source.sections |> Enum.flat_map(& &1.items) |> Enum.map(& &1.card)
    %{board: nil, cards: cards, user: user, users: []}
  end

  defp scope_for(_, user), do: %{board: nil, cards: [], user: user, users: []}

  ## Events -------------------------------------------------------------------

  @impl true
  def handle_event("toggle", _, socket),
    do: {:noreply, assign(socket, open: not socket.assigns.open)}

  def handle_event("close", _, socket), do: {:noreply, assign(socket, open: false)}

  def handle_event("set_mode", %{"mode" => mode}, socket) when mode in ["chat", "edit"] do
    mode = if mode == "edit" and not socket.assigns.can_write, do: "chat", else: mode
    {:noreply, assign(socket, mode: mode, error: nil)}
  end

  def handle_event("clear", _, socket),
    do:
      {:noreply, assign(socket, messages: [], error: nil, form_key: socket.assigns.form_key + 1)}

  def handle_event("send", %{"message" => text}, socket) do
    text = String.trim(text || "")

    cond do
      text == "" or socket.assigns.busy ->
        {:noreply, socket}

      true ->
        %{mode: mode, source: source, messages: messages} = socket.assigns
        user = socket.assigns.current_user
        history = Enum.map(messages, &history_entry/1)
        user_message = %{id: next_id(), role: "user", content: text, steps: nil, applied: false}

        socket =
          socket
          |> assign(
            messages: messages ++ [user_message],
            busy: true,
            error: nil,
            form_key: socket.assigns.form_key + 1
          )
          |> start_async(:reply, fn ->
            context = Context.build(source)

            if mode == "edit",
              do: {:edit, Assistant.propose(context, history, text, user: user)},
              else: {:chat, Assistant.chat(context, history, text, user: user)}
          end)

        {:noreply, socket}
    end
  end

  def handle_event("apply", %{"id" => id}, socket) do
    id = SlipdockWeb.Params.id(id)

    if socket.assigns.can_write do
      messages =
        Enum.map(socket.assigns.messages, fn
          %{id: ^id, steps: steps, applied: false} = m when is_list(steps) ->
            %{m | steps: Actions.apply(steps), applied: true}

          m ->
            m
        end)

      {:noreply, assign(socket, messages: messages)}
    else
      {:noreply, assign(socket, error: "You have read-only access here.")}
    end
  end

  def handle_event("discard", %{"id" => id}, socket) do
    id = SlipdockWeb.Params.id(id)

    messages =
      Enum.map(socket.assigns.messages, fn
        %{id: ^id, applied: false} = m -> %{m | steps: nil, discarded: true}
        m -> m
      end)

    {:noreply, assign(socket, messages: messages)}
  end

  @impl true
  def handle_async(:reply, {:ok, {:chat, {:ok, text}}}, socket) do
    {:noreply, add_reply(socket, text, nil)}
  end

  def handle_async(:reply, {:ok, {:edit, {:ok, %{reply: reply, actions: actions}}}}, socket) do
    steps = Actions.prepare(actions, socket.assigns.scope)

    reply =
      cond do
        reply != "" -> reply
        steps == [] -> "I couldn't find anything to change."
        true -> "Here's what I propose."
      end

    {:noreply, add_reply(socket, reply, if(steps == [], do: nil, else: steps))}
  end

  def handle_async(:reply, {:ok, {_, {:error, message}}}, socket) do
    {:noreply, assign(socket, busy: false, error: message)}
  end

  def handle_async(:reply, {:exit, reason}, socket) do
    {:noreply, assign(socket, busy: false, error: "The assistant crashed: #{inspect(reason)}")}
  end

  defp add_reply(socket, text, steps) do
    message = %{id: next_id(), role: "assistant", content: text, steps: steps, applied: false}
    assign(socket, messages: socket.assigns.messages ++ [message], busy: false)
  end

  # What the model is told about an earlier turn: proposals and their fate included.
  defp history_entry(%{role: "assistant", steps: steps} = m) when is_list(steps) do
    outcome =
      Enum.map_join(steps, "\n", fn step ->
        status =
          cond do
            m.applied and step.result == :ok -> "done"
            m.applied -> "failed: #{elem(step.result, 1)}"
            step.error -> "rejected: #{step.error}"
            true -> "not applied"
          end

        "- #{step.label} (#{status})"
      end)

    %{role: "assistant", content: m.content <> "\n\nProposed changes:\n" <> outcome}
  end

  defp history_entry(%{discarded: true} = m),
    do: %{role: "assistant", content: m.content <> "\n\n(The user discarded these changes.)"}

  defp history_entry(m), do: %{role: m.role, content: m.content}

  defp next_id, do: System.unique_integer([:positive, :monotonic])

  ## Render -------------------------------------------------------------------

  @impl true
  def render(%{layout: "inline"} = assigns) do
    ~H"""
    <section id={@id} class="border-t border-base-300 bg-base-200/40 px-6 py-4">
      <div class="flex items-center justify-between gap-3">
        <button
          type="button"
          class="flex items-center gap-2 text-sm font-semibold text-base-content/80 hover:text-base-content"
          phx-click="toggle"
          phx-target={@myself}
        >
          <.icon name="hero-sparkles" class="size-4 text-primary" />
          {@title}
          <.icon
            name={if @open, do: "hero-chevron-up", else: "hero-chevron-down"}
            class="size-3.5 text-base-content/40"
          />
        </button>
        <.mode_toggle :if={@open and @can_write} mode={@mode} myself={@myself} />
      </div>
      <div :if={@open} class="mt-3 space-y-3">
        <.log
          id={"#{@id}-log"}
          messages={@messages}
          busy={@busy}
          error={@error}
          mode={@mode}
          can_write={@can_write}
          myself={@myself}
          class="max-h-80 overflow-y-auto pr-1"
        />
        <.composer
          id={@id}
          form_key={@form_key}
          busy={@busy}
          mode={@mode}
          placeholder={@placeholder}
          myself={@myself}
        />
      </div>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <div
        :if={@open}
        class="ai-drawer fixed inset-y-0 right-0 top-12 z-40 flex w-full flex-col border-l border-base-300 bg-base-100 pb-[env(safe-area-inset-bottom)] shadow-2xl sm:w-[26rem] sm:pb-0"
        role="dialog"
        aria-label={@title}
      >
        <header class="flex shrink-0 items-center gap-2 border-b border-base-300 px-4 py-2.5">
          <.icon name="hero-sparkles" class="size-4 shrink-0 text-primary" />
          <h2 class="min-w-0 flex-1 truncate text-sm font-semibold">{@title}</h2>
          <.mode_toggle :if={@can_write} mode={@mode} myself={@myself} />
          <button
            :if={@messages != []}
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            title="Clear the conversation"
            phx-click="clear"
            phx-target={@myself}
          >
            <.icon name="hero-trash" class="size-3.5" />
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            aria-label="Close"
            phx-click="close"
            phx-target={@myself}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </header>
        <.log
          id={"#{@id}-log"}
          messages={@messages}
          busy={@busy}
          error={@error}
          mode={@mode}
          can_write={@can_write}
          myself={@myself}
          class="kanban-scroll min-h-0 flex-1 overflow-y-auto px-4 py-4"
        />
        <div class="shrink-0 border-t border-base-300 p-3">
          <.composer
            id={@id}
            form_key={@form_key}
            busy={@busy}
            mode={@mode}
            placeholder={@placeholder}
            myself={@myself}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :mode, :string, required: true
  attr :myself, :any, required: true

  defp mode_toggle(assigns) do
    ~H"""
    <div class="flex rounded-lg bg-base-200 p-0.5 text-xs" role="tablist" aria-label="Assistant mode">
      <button
        :for={
          {key, label, icon} <- [
            {"chat", "Chat", "hero-chat-bubble-left-right"},
            {"edit", "Edit", "hero-pencil-square"}
          ]
        }
        type="button"
        role="tab"
        aria-selected={to_string(@mode == key)}
        class={[
          "flex items-center gap-1 rounded-md px-2 py-1 font-medium transition",
          if(@mode == key,
            do: "bg-base-100 shadow-sm",
            else: "text-base-content/60 hover:text-base-content"
          )
        ]}
        phx-click="set_mode"
        phx-value-mode={key}
        phx-target={@myself}
      >
        <.icon name={icon} class="size-3.5" /> {label}
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :messages, :list, required: true
  attr :busy, :boolean, required: true
  attr :error, :any, required: true
  attr :mode, :string, required: true
  attr :can_write, :boolean, required: true
  attr :myself, :any, required: true
  attr :class, :string, default: nil

  defp log(assigns) do
    ~H"""
    <div id={@id} class={["space-y-3 text-sm", @class]} phx-hook="ScrollBottom">
      <div
        :if={@messages == [] and not @busy}
        class="space-y-2 rounded-xl bg-base-200/60 p-3 text-xs leading-relaxed text-base-content/70"
      >
        <p :if={@mode == "chat"}>
          Ask anything about what's on this page: what's overdue, what a card says, what to tackle next.
          The cards in the current view are shared with the model each time you send a message.
        </p>
        <p :if={@mode == "edit"}>
          Describe a change in plain words and it becomes a list of edits you can apply, for example
          <em>“Set this due next Tuesday and move it to a suitable priority”</em>
          or <em>“Add a card for the retro in Backlog, tagged ops”</em>. Nothing changes until you click Apply.
        </p>
      </div>
      <div
        :for={m <- @messages}
        id={"#{@id}-m#{m.id}"}
        class={["flex", if(m.role == "user", do: "justify-end", else: "justify-start")]}
      >
        <div
          :if={m.role == "user"}
          class="max-w-[85%] whitespace-pre-wrap break-words rounded-2xl rounded-br-md bg-primary px-3.5 py-2 text-primary-content"
        >
          {m.content}
        </div>
        <div :if={m.role == "assistant"} class="max-w-[95%] space-y-2">
          <div
            class="ai-prose rounded-2xl rounded-bl-md bg-base-200 px-3.5 py-2 leading-relaxed"
            phx-no-format
          >{Markdown.render(m.content)}</div>
          <.steps :if={is_list(m.steps)} message={m} can_write={@can_write} myself={@myself} />
          <p :if={m[:discarded]} class="px-1 text-xs text-base-content/50">Changes discarded.</p>
        </div>
      </div>
      <div :if={@busy} class="flex justify-start">
        <div
          class="ai-thinking flex items-center gap-1.5 rounded-2xl rounded-bl-md bg-base-200 px-3.5 py-2.5"
          aria-label="Thinking"
        >
          <span></span><span></span><span></span>
        </div>
      </div>
      <p
        :if={@error}
        class="flex items-start gap-2 rounded-xl bg-error/10 px-3 py-2 text-xs text-error"
      >
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-3.5 shrink-0" /> {@error}
      </p>
    </div>
    """
  end

  attr :message, :map, required: true
  attr :can_write, :boolean, required: true
  attr :myself, :any, required: true

  defp steps(assigns) do
    m = assigns.message
    runnable = Enum.count(m.steps, &is_nil(&1.error))
    assigns = assign(assigns, runnable: runnable, m: m)

    ~H"""
    <div class="overflow-hidden rounded-xl bg-base-100 ring-1 ring-base-content/10">
      <ul class="divide-y divide-base-300/60">
        <li :for={step <- @m.steps} class="flex items-start gap-2 px-3 py-2 text-xs">
          <.icon
            name={step_icon(step, @m.applied)}
            class={["mt-0.5 size-4 shrink-0", step_tone(step, @m.applied)]}
          />
          <div class="min-w-0 flex-1">
            <p class={["break-words", step.error && "text-base-content/60"]}>{step.label}</p>
            <p :if={step.error} class="text-error">{step.error}</p>
            <p :if={@m.applied and match?({:error, _}, step.result)} class="text-error">
              {elem(step.result, 1)}
            </p>
          </div>
        </li>
      </ul>
      <div
        :if={not @m.applied}
        class="flex items-center justify-between gap-2 border-t border-base-300/60 bg-base-200/40 px-3 py-2"
      >
        <span class="text-xs text-base-content/60">
          {if @runnable == 0,
            do: "Nothing here can be applied.",
            else: "#{@runnable} #{if @runnable == 1, do: "change", else: "changes"} ready"}
        </span>
        <div class="flex gap-1.5">
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="discard"
            phx-value-id={@m.id}
            phx-target={@myself}
          >
            Discard
          </button>
          <button
            :if={@runnable > 0 and @can_write}
            type="button"
            class="btn btn-primary btn-xs gap-1"
            phx-click="apply"
            phx-value-id={@m.id}
            phx-target={@myself}
          >
            <.icon name="hero-check" class="size-3.5" /> Apply
          </button>
        </div>
      </div>
      <p
        :if={@m.applied}
        class="flex items-center gap-1.5 border-t border-base-300/60 bg-base-200/40 px-3 py-1.5 text-xs text-base-content/60"
      >
        <.icon name="hero-check-circle" class="size-3.5 text-success" />
        Applied {Enum.count(@m.steps, &(&1.result == :ok))} of {length(@m.steps)}.
      </p>
    </div>
    """
  end

  defp step_icon(%{error: e}, _) when is_binary(e), do: "hero-x-circle"
  defp step_icon(%{result: :ok}, true), do: "hero-check-circle-solid"
  defp step_icon(%{result: {:error, _}}, true), do: "hero-x-circle"
  defp step_icon(_, _), do: "hero-arrow-right-circle"

  defp step_tone(%{error: e}, _) when is_binary(e), do: "text-error/70"
  defp step_tone(%{result: :ok}, true), do: "text-success"
  defp step_tone(%{result: {:error, _}}, true), do: "text-error"
  defp step_tone(_, _), do: "text-primary"

  attr :id, :string, required: true
  attr :form_key, :integer, required: true
  attr :busy, :boolean, required: true
  attr :mode, :string, required: true
  attr :placeholder, :any, default: nil
  attr :myself, :any, required: true

  defp composer(assigns) do
    ~H"""
    <form
      id={"#{@id}-form-#{@form_key}"}
      phx-submit="send"
      phx-target={@myself}
      class="flex items-end gap-2 rounded-xl bg-base-200/70 p-1.5 ring-1 ring-transparent transition focus-within:ring-primary/40"
    >
      <textarea
        id={"#{@id}-input-#{@form_key}"}
        name="message"
        rows="1"
        phx-hook="AutoGrow"
        data-submit-on-enter
        class="max-h-40 min-h-9 w-full resize-none bg-transparent px-2 py-1.5 text-sm outline-none"
        placeholder={
          if(@mode == "edit",
            do: "Describe the change you want…",
            else: @placeholder || "Ask about this page…"
          )
        }
        disabled={@busy}
        autocomplete="off"
      ></textarea>
      <button
        type="submit"
        class={[
          "btn btn-sm btn-square shrink-0",
          if(@mode == "edit", do: "btn-secondary", else: "btn-primary")
        ]}
        disabled={@busy}
        title={if @mode == "edit", do: "Propose changes", else: "Send"}
      >
        <.icon
          name={if @mode == "edit", do: "hero-pencil-square", else: "hero-paper-airplane"}
          class="size-4"
        />
      </button>
    </form>
    """
  end
end

defmodule SlipdockWeb.BoardLive.WaitComponents do
  @moduledoc """
  The card panel's follow-up questions (#1114, #1220): the open wait as a
  numbered series with an answer box each (and a button to have the
  reader's model suggest one), skipping them all, asking new ones, and the
  questions asked before with their answers. The panel is
  `BoardLive.CardComponent`; these draw what it holds and send their events
  to it (`target`).
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Wait

  attr :wait, :any, required: true
  attr :count, :integer, required: true
  attr :can_write, :boolean, required: true
  attr :answers, :map, default: %{}, doc: "what is typed into each box, by question number"
  attr :suggesting, :map, default: %{}, doc: "a suggestion per box: :running or {:error, why}"
  attr :ai?, :boolean, default: false, doc: "the reader has a model, so suggesting is offered"
  attr :target, :any, required: true

  @doc """
  The card's open wait, beneath the title: what it needs and from whom,
  since when, its questions numbered with a box each, a button for each
  choice, and Answer, Skip and Withdraw.
  """
  def wait_panel(assigns) do
    assigns = assign(assigns, :questions, Wait.questions(assigns.wait))

    ~H"""
    <section id="card-wait" class="ml-1 space-y-2 border-l-2 border-warning/60 pl-3">
      <p class="flex items-start gap-1.5 text-sm">
        <.icon name="hero-hand-raised" class="mt-0.5 size-3.5 shrink-0 text-warning" />
        <span>
          <span class="text-base-content/60">Waiting on {Wait.on_name(@wait)}:</span>
          <span class="font-medium" id="wait-needs">{@wait.needs}</span>
        </span>
      </p>
      <p class="text-2xs text-base-content/50" id="wait-byline">
        {wait_byline(@wait)} · {relative_time(@wait.inserted_at)}
        <span :if={@count > 1}>
          · question {@count} on this card
        </span>
      </p>
      <div :if={@can_write and @wait.choices != []} class="flex flex-wrap gap-1.5">
        <button
          :for={{text, n} <- Enum.with_index(@wait.choices, 1)}
          id={"wait-choice-#{n}"}
          type="button"
          class="btn btn-outline btn-xs"
          phx-click="answer_wait"
          phx-value-choice={n}
          phx-target={@target}
        >
          {text}
        </button>
      </div>
      <ol :if={!@can_write and Wait.series?(@wait)} id="wait-questions" class="space-y-1 text-sm">
        <li :for={{question, n} <- Enum.with_index(@questions, 1)} class="flex gap-1.5">
          <span class="font-semibold text-base-content/60">{n}.</span>
          <span class="whitespace-pre-line">{question}</span>
        </li>
      </ol>
      <form
        :if={@can_write}
        id="wait-answer-form"
        phx-change="wait_change"
        phx-submit="answer_wait"
        phx-target={@target}
        class="space-y-2"
      >
        <ol class="space-y-2">
          <li
            :for={{question, n} <- Enum.with_index(@questions, 1)}
            id={"wait-question-#{n}"}
            class="space-y-1"
          >
            <p :if={Wait.series?(@wait)} class="flex gap-1.5 text-sm">
              <span class="font-semibold text-base-content/60">{n}.</span>
              <span class="whitespace-pre-line">{question}</span>
            </p>
            <div class="flex items-start gap-1.5">
              <textarea
                id={"wait-answer-#{n}"}
                name={"wait[answers][#{n}]"}
                rows="1"
                class="textarea textarea-bordered textarea-xs min-h-0 w-full"
                placeholder={placeholder(@wait, n)}
                maxlength="8000"
                phx-debounce="300"
              >{Map.get(@answers, n, "")}</textarea>
              <button
                :if={@ai?}
                id={"wait-suggest-#{n}"}
                type="button"
                class="btn btn-ghost btn-xs btn-square"
                phx-click="suggest_answer"
                phx-value-n={n}
                phx-target={@target}
                disabled={@suggesting[n] == :running}
                title="Suggest an answer from the card"
                aria-label={"Suggest an answer to question #{n}"}
              >
                <.icon
                  name={if @suggesting[n] == :running, do: "hero-arrow-path", else: "hero-sparkles"}
                  class={["size-3.5", @suggesting[n] == :running && "animate-spin"]}
                />
              </button>
            </div>
            <p
              :if={match?({:error, _}, @suggesting[n])}
              id={"wait-suggest-error-#{n}"}
              class="text-2xs text-error"
            >
              {elem(@suggesting[n], 1)}
            </p>
          </li>
        </ol>
        <div class="flex flex-wrap items-center gap-2">
          <button type="submit" id="wait-answer" class="btn btn-primary btn-xs">
            {if length(@questions) > 1, do: "Send answers", else: "Answer"}
          </button>
          <button
            id="wait-skip"
            type="button"
            class="btn btn-outline btn-xs"
            phx-click="skip_wait"
            phx-target={@target}
            data-confirm="Skip the questions? The card moves on without the answers."
            title="Skip every question and move the card on without answers"
          >
            Skip
          </button>
          <button
            id="wait-withdraw"
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="withdraw_wait"
            phx-target={@target}
            data-confirm="Withdraw the question? Nobody will be asked any more."
          >
            Withdraw
          </button>
        </div>
      </form>
    </section>
    """
  end

  defp placeholder(%Wait{choices: [_ | _]}, 1), do: "Or answer in words"
  defp placeholder(_wait, _n), do: "Your answer"

  @doc false
  def wait_byline(wait) do
    who =
      case wait.opened_by do
        %User{} = u -> User.display_name(u)
        _ -> "someone"
      end

    agent =
      if wait.kind == "agent", do: " (agent#{if wait.agent, do: ": " <> wait.agent})", else: ""

    job = if wait.job_id, do: " · job ##{wait.job_id}", else: ""
    "Asked by #{who}#{agent}#{job}"
  end

  attr :asking, :map, required: true, doc: "%{questions: [...], on: id-or-\"\"}"
  attr :users, :list, required: true
  attr :target, :any, required: true

  @doc "Asking questions on the card (#1220): one box per question, and who they are on."
  def ask_form(assigns) do
    ~H"""
    <form
      id="wait-ask-form"
      phx-change="ask_change"
      phx-submit="ask_save"
      phx-target={@target}
      class="ml-1 space-y-2 border-l-2 border-warning/60 pl-3"
    >
      <p class="flex items-center gap-1.5 text-sm font-medium">
        <.icon name="hero-hand-raised" class="size-3.5 text-warning" /> Ask questions
      </p>
      <ol class="space-y-1.5">
        <li
          :for={{question, n} <- Enum.with_index(@asking.questions, 1)}
          class="flex items-start gap-1.5"
        >
          <span class="mt-1 text-sm font-semibold text-base-content/60">{n}.</span>
          <textarea
            id={"wait-ask-#{n}"}
            name={"ask[questions][#{n}]"}
            rows="1"
            class="textarea textarea-bordered textarea-xs min-h-0 w-full"
            placeholder="A question"
            maxlength="1000"
            phx-debounce="300"
          >{question}</textarea>
          <button
            :if={length(@asking.questions) > 1}
            id={"wait-ask-remove-#{n}"}
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            phx-click="ask_remove"
            phx-value-n={n}
            phx-target={@target}
            aria-label={"Remove question #{n}"}
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </li>
      </ol>
      <div class="flex flex-wrap items-center gap-2">
        <button
          :if={length(@asking.questions) < Wait.max_questions()}
          id="wait-ask-add"
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="ask_add"
          phx-target={@target}
        >
          <.icon name="hero-plus" class="size-3.5" /> Add a question
        </button>
        <label class="flex items-center gap-1.5 text-xs text-base-content/60">
          On
          <select id="wait-ask-on" name="ask[on]" class="select select-xs">
            <option value="" selected={@asking.on in [nil, ""]}>anyone</option>
            <option
              :for={u <- @users}
              value={u.id}
              selected={to_string(u.id) == to_string(@asking.on)}
            >
              {User.display_name(u)}
            </option>
          </select>
        </label>
      </div>
      <div class="flex items-center gap-2">
        <button type="submit" id="wait-ask-save" class="btn btn-primary btn-xs">Ask</button>
        <button
          id="wait-ask-cancel"
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="ask_cancel"
          phx-target={@target}
        >
          Cancel
        </button>
      </div>
    </form>
    """
  end

  attr :waits, :list, required: true, doc: "the closed waits, newest first"

  @doc """
  The questions asked before (#1220), folded away: each with its answers,
  who answered and when, or how it ended without one.
  """
  def wait_history(assigns) do
    ~H"""
    <details id="card-wait-history" class="ml-1 text-xs">
      <summary class="cursor-pointer text-base-content/60 hover:text-primary">
        Questions asked before ({length(@waits)})
      </summary>
      <ol class="mt-2 space-y-3">
        <li
          :for={w <- @waits}
          id={"wait-history-#{w.id}"}
          class="space-y-1 border-l-2 border-base-content/15 pl-3"
        >
          <p class="font-medium">{w.needs}</p>
          <p class="text-2xs text-base-content/50">
            {wait_byline(w)} · {relative_time(w.inserted_at)} · {ended(w)}
          </p>
          <ol :if={Wait.series?(w)} class="space-y-1">
            <li :for={{q, i} <- Enum.with_index(w.questions)} class="space-y-0.5">
              <p class="whitespace-pre-line">{i + 1}. {q}</p>
              <p class="whitespace-pre-line pl-4 text-base-content/70">
                → {answer_at(w, i)}
              </p>
            </li>
          </ol>
          <p
            :if={whole(w) != ""}
            class="whitespace-pre-line text-base-content/70"
          >
            → {whole(w)}
          </p>
        </li>
      </ol>
    </details>
    """
  end

  defp answer_at(%Wait{close_reason: "answered"} = w, i) do
    case Enum.at(w.answers || [], i) do
      a when a in [nil, ""] -> "(not answered)"
      a -> a
    end
  end

  defp answer_at(_w, _i), do: "—"

  defp whole(w) do
    [Wait.choice_text(w, w.choice), w.answer]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" — ")
  end

  defp ended(%Wait{} = w) do
    by = if w.closed_by, do: " by #{User.display_name(w.closed_by)}", else: ""

    what =
      case w.close_reason do
        "answered" -> "answered"
        "skipped" -> "skipped"
        "withdrawn" -> "withdrawn"
        "card_completed" -> "closed when the card was completed"
        "archived" -> "closed when the card was archived"
        other -> other || "closed"
      end

    "#{what}#{by} #{if w.closed_at, do: relative_time(w.closed_at), else: ""}"
    |> String.trim()
  end
end

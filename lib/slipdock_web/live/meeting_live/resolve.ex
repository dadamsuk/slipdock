defmodule SlipdockWeb.MeetingLive.Resolve do
  @moduledoc """
  Resolve mode (screen 6): one question at a time, with everything that
  helps answer it — the passage to replay (at 0.75× and on a loop, where
  there is a recording), the lines around it, what the transcriber and the
  two readings made of it, what else the meeting said, and the model's view
  labelled as a guess — and the answers, each saying what it would do. One
  more answer: *ask the speaker*, which sends them the question and the
  passage, and lets the rest of the capture be committed meanwhile.

  An answer given after replaying the passage is recorded as such
  ("after replaying 7:38–7:44"). Keys: 1–4 answer, N the next question,
  Space replays.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.MeetingLive.Components

  alias Slipdock.Meetings
  alias Slipdock.Meetings.{Question, Review, Utterance}
  alias SlipdockWeb.MeetingLive.Access

  on_mount {SlipdockWeb.MeetingsHook, :require_enabled}

  @impl true
  def mount(%{"id" => id, "capture_id" => capture_id} = params, _session, socket) do
    with {:ok, socket} <- Access.mount_board(socket, id, :read),
         cid when is_integer(cid) <- SlipdockWeb.Params.id(capture_id),
         %Meetings.Capture{board_id: board_id} = capture when board_id == socket.assigns.board.id <-
           Meetings.get_capture(cid) do
      if connected?(socket), do: Meetings.subscribe(capture)

      {:ok,
       socket
       |> assign(page_title: "Resolve · #{capture.title}", replayed: %{}, error: nil)
       |> load(capture, SlipdockWeb.Params.id(params["question_id"]))}
    else
      {:error, socket} -> {:ok, socket}
      _ -> {:ok, push_navigate(socket, to: ~p"/boards/#{socket.assigns.board}/meetings")}
    end
  end

  @impl true
  def handle_params(%{"question_id" => qid}, _uri, socket) do
    {:noreply, load(socket, socket.assigns.capture, SlipdockWeb.Params.id(qid))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # The questions still to settle (open, or waiting on a speaker), and the
  # one shown: the one asked for, else the first.
  defp load(socket, capture, wanted) do
    capture = Meetings.load(capture)
    user = socket.assigns.current_user

    capture = %{
      capture
      | findings: Slipdock.Meetings.Visibility.findings(capture.findings, user),
        questions: Slipdock.Meetings.Visibility.questions(capture.questions, user)
    }

    pending = Enum.filter(capture.questions, &(&1.status in ["open", "waiting"]))

    question =
      Enum.find(capture.questions, &(&1.id == wanted)) || List.first(pending)

    assign(socket,
      capture: capture,
      pending: pending,
      question: question,
      passage: question && passage(capture, question)
    )
  end

  # The line a question is about, its neighbours, and everything said about it.
  defp passage(capture, %Question{} = q) do
    lines = capture.utterances
    finding = q.finding_id && Enum.find(capture.findings, &(&1.id == q.finding_id))

    line_id =
      q.context["line"] ||
        (finding && finding.evidence |> List.first() |> then(&(&1 && &1.line_id)))

    index = line_id && Enum.find_index(lines, &(&1.line_id == line_id))

    case index do
      nil ->
        %{line: nil, around: [], from: nil, to: nil, finding: finding, elsewhere: []}

      i ->
        line = Enum.at(lines, i)
        from = line.start_ms
        to = line.end_ms || (line.start_ms && line.start_ms + 5_000)

        %{
          line: line,
          around: Enum.slice(lines, max(i - 2, 0), 5),
          from: from,
          to: to,
          finding: finding,
          elsewhere: elsewhere(lines, line, q)
        }
    end
  end

  # Other lines that use the words the answers turn on.
  defp elsewhere(lines, line, q) do
    terms =
      q.options
      |> Enum.flat_map(&String.split(&1["label"] || "", ~r/[^\p{L}\p{N}%]+/u))
      |> Enum.map(&String.downcase/1)
      |> Enum.filter(&(String.length(&1) >= 4 or String.ends_with?(&1, "%")))
      |> Enum.uniq()

    lines
    |> Enum.reject(&(&1.id == line.id))
    |> Enum.filter(fn l -> Enum.any?(terms, &String.contains?(String.downcase(l.text), &1)) end)
    |> Enum.take(5)
  end

  @impl true
  def handle_info({:capture_changed, id}, socket) do
    wanted = socket.assigns.question && socket.assigns.question.id
    {:noreply, load(socket, Meetings.get_capture!(id), wanted)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("replayed", %{"from" => from, "to" => to}, socket) do
    case socket.assigns.question do
      nil ->
        {:noreply, socket}

      q ->
        span = "#{clock(round(from))}–#{clock(round(to))}"
        {:noreply, update(socket, :replayed, &Map.put(&1, q.id, span))}
    end
  end

  def handle_event("answer", %{"value" => value}, socket) do
    %{question: shown, current_user: user} = socket.assigns
    # The stored question, not the page's copy with hidden cards' names out.
    q = shown && Slipdock.Repo.get!(Question, shown.id)

    if q && socket.assigns.can_write do
      context = if span = socket.assigns.replayed[q.id], do: %{replayed: span}, else: %{}

      case Review.answer(q, value, user, via: "web", context: context) do
        {:ok, _} -> {:noreply, next(socket)}
        {:error, message} -> {:noreply, assign(socket, error: message)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("ask_speaker", _params, socket) do
    %{question: shown, current_user: user} = socket.assigns
    q = shown && Slipdock.Repo.get!(Question, shown.id)

    if q && socket.assigns.can_write do
      case Review.ask_speaker(q, user) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Asked. The rest can be committed while it waits.")
           |> next()}

        {:error, message} ->
          {:noreply, assign(socket, error: message)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("key", %{"key" => key}, socket) when key in ~w(1 2 3 4) do
    case socket.assigns.question &&
           Enum.at(socket.assigns.question.options, String.to_integer(key) - 1) do
      %{"value" => value} -> handle_event("answer", %{"value" => value}, socket)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("key", %{"key" => k}, socket) when k in ["n", "N"],
    do: {:noreply, next(socket)}

  def handle_event("key", _params, socket), do: {:noreply, socket}

  # On to the next question still open, or back to the review when none is.
  defp next(socket) do
    capture = Meetings.get_capture!(socket.assigns.capture.id)
    current = socket.assigns.question && socket.assigns.question.id

    left =
      capture
      |> Meetings.load()
      |> Map.get(:questions)
      |> Enum.filter(&(&1.status == "open" and &1.id != current))

    case left do
      [] ->
        push_navigate(socket, to: ~p"/boards/#{socket.assigns.board}/meetings/#{capture.id}")

      [q | _] ->
        socket
        |> assign(error: nil)
        |> push_patch(
          to: ~p"/boards/#{socket.assigns.board}/meetings/#{capture.id}/resolve/#{q.id}"
        )
    end
  end

  defp can_ask?(q, capture, user) do
    q.status == "open" and Review.reviewable?(capture) and
      case Review.speaker_of(q) do
        %{id: id} -> id != user.id
        nil -> false
      end
  end

  defp waiting_for_me?(q, user),
    do: q.status == "waiting" and q.context["asked_user_id"] == user.id

  defp no_replay_reason(capture) do
    cond do
      capture.audio_purged_at ->
        "The recording was deleted when its keeping ran out, so there is nothing to replay: the words are what there is."

      true ->
        "There is no recording of this meeting, only its transcript, so there is nothing to replay: the words are what there is."
    end
  end

  defp unsure_words(%Utterance{words: words}) when is_list(words),
    do: words |> Enum.filter(&((&1["confidence"] || 1.0) < 0.6)) |> Enum.map(& &1["word"])

  defp unsure_words(_), do: []

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
      nav_active={:boards}
      page_jumps={@page_jumps}
    >
      <:subnav><.meeting_nav board={@board} capture={@capture} /></:subnav>

      <div class="kanban-scroll h-full overflow-y-auto" phx-window-keydown={@can_write && "key"}>
        <div class="mx-auto max-w-3xl space-y-5 p-4 sm:p-6">
          <header class="flex flex-wrap items-center gap-3">
            <h1 class="flex-1 text-xl font-semibold">Resolve</h1>
            <span :if={@question} class="text-sm text-base-content/60">
              {length(Enum.filter(@pending, &(&1.status == "open")))} left
            </span>
            <.link
              navigate={~p"/boards/#{@board}/meetings/#{@capture.id}"}
              class="btn btn-ghost btn-sm"
            >
              Back to the review
            </.link>
          </header>

          <p
            :if={is_nil(@question)}
            id="nothing-to-resolve"
            class="rounded-xl bg-base-100 p-4 text-sm ring-1 ring-base-content/10"
          >
            Nothing is left to settle.
          </p>

          <p
            :if={@error}
            id="resolve-error"
            role="alert"
            class="rounded-xl bg-error/10 px-4 py-2 text-sm text-error"
          >
            {@error}
          </p>

          <section
            :if={@question}
            id={"resolve-#{@question.id}"}
            data-status={@question.status}
            class="space-y-4"
          >
            <div class="rounded-xl bg-base-100 p-4 ring-1 ring-base-content/10">
              <p class="text-lg font-medium">{@question.prompt}</p>
              <p
                :if={@question.status == "waiting"}
                id="waiting-note"
                class="mt-1 text-sm text-warning"
              >
                Waiting for the speaker's answer{if waiting_for_me?(@question, @current_user),
                  do: " — that's you",
                  else: ""}.
              </p>
            </div>

            <div
              :if={@capture.audio_key && @passage.from}
              id="replay"
              phx-hook="Replay"
              data-src={"/captures/#{@capture.id}/audio"}
              data-from={@passage.from}
              data-to={@passage.to}
              data-duration={@capture.audio_duration_ms}
              class="rounded-xl bg-base-100 p-4 ring-1 ring-base-content/10"
            >
              <canvas width="600" height="56" class="h-14 w-full"></canvas>
              <div class="mt-2 flex flex-wrap items-center gap-2 text-sm">
                <span class="font-mono text-xs text-base-content/60">{clock(@passage.from)}–{clock(
                  @passage.to
                )}</span>
                <button
                  type="button"
                  data-replay="1"
                  class="btn btn-outline btn-xs"
                  id="replay-normal"
                >
                  <.icon name="hero-play" class="size-3.5" /> Replay
                </button>
                <button
                  type="button"
                  data-replay="0.75"
                  class="btn btn-outline btn-xs"
                  id="replay-slow"
                >
                  At 0.75×
                </button>
                <button
                  type="button"
                  data-loop
                  aria-pressed="false"
                  class="btn btn-ghost btn-xs"
                  id="replay-loop"
                >
                  <.icon name="hero-arrow-path" class="size-3.5" /> Loop
                </button>
                <span
                  :if={@replayed[@question.id]}
                  id="replayed-note"
                  class="text-xs text-base-content/60"
                >
                  replayed {@replayed[@question.id]}
                </span>
              </div>
            </div>
            <p
              :if={!(@capture.audio_key && @passage.from)}
              id="replay-missing"
              class="text-sm text-base-content/60"
            >
              {no_replay_reason(@capture)}
            </p>

            <div
              :if={@passage.around != []}
              id="around"
              class="rounded-xl bg-base-100 ring-1 ring-base-content/10"
            >
              <ol class="text-sm">
                <li
                  :for={l <- @passage.around}
                  class={["flex gap-3 px-4 py-1.5", l.id == @passage.line.id && "bg-warning/15"]}
                >
                  <span class="w-12 shrink-0 font-mono text-2xs text-base-content/40">{clock(
                    l.start_ms
                  )}</span>
                  <span><span :if={l.speaker} class="font-medium">{l.speaker}: </span>{l.text}</span>
                </li>
              </ol>
            </div>

            <div class="grid gap-3 sm:grid-cols-2">
              <div
                :if={@passage.line && unsure_words(@passage.line) != []}
                id="transcriber-reading"
                class="rounded-xl bg-base-100 p-3 text-sm ring-1 ring-base-content/10"
              >
                <p class="font-medium">What the transcriber was unsure of</p>
                <p class="mt-1">{Enum.join(unsure_words(@passage.line), ", ")}</p>
              </div>
              <div
                :if={@question.kind == "which_reading"}
                id="readings"
                class="rounded-xl bg-base-100 p-3 text-sm ring-1 ring-base-content/10"
              >
                <p class="font-medium">What each reading heard</p>
                <ul class="mt-1 space-y-0.5">
                  <li :for={o <- Enum.reject(@question.options, &(&1["value"] == "none"))}>
                    {o["label"]} <span class="text-base-content/50">— {o["effect"]}</span>
                  </li>
                </ul>
              </div>
              <div
                :if={@passage.elsewhere != []}
                id="elsewhere"
                class="rounded-xl bg-base-100 p-3 text-sm ring-1 ring-base-content/10"
              >
                <p class="font-medium">Elsewhere in the meeting</p>
                <ul class="mt-1 space-y-0.5">
                  <li :for={l <- @passage.elsewhere}>
                    <span class="font-mono text-2xs text-base-content/40">{l.line_id}</span> {l.text}
                  </li>
                </ul>
              </div>
              <div
                :if={@question.context["model_view"]}
                id="model-view"
                class="rounded-xl bg-base-200/60 p-3 text-sm"
              >
                <p class="font-medium">{@question.context["model_view"]["model"]}'s view — a guess</p>
                <p class="mt-1">It heard “{@question.context["model_view"]["heard"]}”.</p>
              </div>
            </div>

            <div
              :if={@can_write and (@question.status == "open" or @question.status == "waiting")}
              id="answers"
              class="space-y-2"
            >
              <button
                :for={{o, i} <- Enum.with_index(@question.options, 1)}
                id={"choose-#{i}"}
                type="button"
                phx-click="answer"
                phx-value-value={o["value"]}
                class="btn btn-outline btn-block justify-start text-left normal-case"
              >
                <kbd :if={i <= 4} class="mr-2 font-mono text-2xs opacity-60">{i}</kbd>
                <span class="flex-1">{o["label"]}</span>
                <span class="text-xs font-normal text-base-content/50">{o["effect"]}</span>
              </button>
              <button
                :if={can_ask?(@question, @capture, @current_user)}
                id="ask-speaker"
                type="button"
                phx-click="ask_speaker"
                class="btn btn-ghost btn-block justify-start normal-case"
              >
                <.icon name="hero-paper-airplane" class="size-4" />
                Ask the speaker — the rest can be committed meanwhile
              </button>
            </div>
            <p :if={@question.status == "answered"} class="text-sm text-base-content/60">
              Answered: {@question.answer && @question.answer["label"]}.
            </p>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

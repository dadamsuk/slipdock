defmodule SlipdockWeb.MeetingLive.Show do
  @moduledoc """
  One capture: where it has got to (the Analysing screen, screen 3), then
  the review (screen 5) — the transcript on one side, what was found on the
  other — and its record.

  The review's actions are `Slipdock.Meetings.Review`'s; this page only
  draws them and says who did what. Keys, for whoever can write to the
  board: J/K move between findings, 1–4 answer the selected finding's
  question, I/X include or leave it out, Enter edits it, N jumps to the next
  open question.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.MeetingLive.Components

  import SlipdockWeb.MeetingLive.ReviewComponents

  alias Slipdock.Meetings
  alias Slipdock.Meetings.Review
  alias SlipdockWeb.MeetingLive.Access

  on_mount {SlipdockWeb.MeetingsHook, :require_enabled}

  @impl true
  def mount(%{"id" => id, "capture_id" => capture_id}, _session, socket) do
    with {:ok, socket} <- Access.mount_board(socket, id, :read),
         %Meetings.Capture{} = capture <- capture(capture_id, socket.assigns.board) do
      if connected?(socket), do: Meetings.subscribe(capture)

      {:ok,
       socket
       |> assign(
         page_title: capture.title,
         selected: nil,
         editing: nil,
         adding: false,
         show_transcript: false,
         review_error: nil,
         members: Slipdock.Wiki.Links.members(socket.assigns.board),
         lists: Meetings.lists(socket.assigns.board.id)
       )
       |> load(capture)}
    else
      {:error, socket} ->
        {:ok, socket}

      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That capture isn't on this board.")
         |> push_navigate(to: ~p"/boards/#{socket.assigns.board}/meetings")}
    end
  end

  defp capture(id, board) do
    with id when is_integer(id) <- SlipdockWeb.Params.id(id),
         %Meetings.Capture{board_id: board_id} = capture when board_id == board.id <-
           Meetings.get_capture(id) do
      capture
    else
      _ -> nil
    end
  end

  defp load(socket, capture) do
    capture = Meetings.load(capture)
    kept = Enum.filter(capture.findings, &(&1.status == "kept"))
    selected = socket.assigns[:selected]

    assign(socket,
      capture: capture,
      kept: kept,
      dropped: Enum.filter(capture.findings, &(&1.status == "dropped")),
      open_count: Enum.count(capture.questions, &(&1.status == "open" and &1.blocking)),
      selected:
        if(Enum.any?(kept, &(&1.id == selected)),
          do: selected,
          else: kept |> List.first() |> then(&(&1 && &1.id))
        )
    )
  end

  @impl true
  def handle_info({:capture_changed, id}, socket) do
    {:noreply, load(socket, Meetings.get_capture!(id))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry", _params, socket) do
    %{capture: capture, can_write: can_write, current_user: user} = socket.assigns

    if can_write and capture.state == "failed" do
      Slipdock.Meetings.Pipeline.retry(capture, user, via: "web")
      {:noreply, load(socket, Meetings.get_capture!(capture.id))}
    else
      {:noreply, socket}
    end
  end

  ## Review -------------------------------------------------------------------

  def handle_event("select", %{"id" => id}, socket),
    do: {:noreply, assign(socket, selected: SlipdockWeb.Params.id(id), editing: nil)}

  def handle_event("toggle_transcript", _params, socket),
    do: {:noreply, update(socket, :show_transcript, &(not &1))}

  def handle_event("answer", %{"question" => qid, "value" => value}, socket) do
    with_writer(socket, fn user ->
      with %Meetings.Question{} = q <- question(socket, qid) do
        Review.answer(q, value, user, via: "web")
      end
    end)
  end

  def handle_event("unanswer", %{"question" => qid}, socket) do
    with_writer(socket, fn user ->
      with %Meetings.Question{} = q <- question(socket, qid), do: Review.unanswer(q, user)
    end)
  end

  def handle_event("include", %{"id" => id, "included" => included}, socket) do
    with_writer(socket, fn user ->
      with %Meetings.Finding{} = f <- finding(socket, id),
           do: Review.include(f, included == "true", user)
    end)
  end

  def handle_event("edit", %{"id" => id}, socket) do
    if socket.assigns.can_write,
      do:
        {:noreply,
         assign(socket, editing: SlipdockWeb.Params.id(id), selected: SlipdockWeb.Params.id(id))},
      else: {:noreply, socket}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("save_edit", %{"finding" => params}, socket) do
    socket = assign(socket, editing: nil)

    with_writer(socket, fn user ->
      with %Meetings.Finding{} = f <- finding(socket, params["id"]),
           do: Review.edit(f, params, user)
    end)
  end

  def handle_event("start_add", _params, socket),
    do: {:noreply, assign(socket, adding: socket.assigns.can_write)}

  def handle_event("cancel_add", _params, socket), do: {:noreply, assign(socket, adding: false)}

  def handle_event("add", %{"added" => params}, socket) do
    socket = assign(socket, adding: false)
    with_writer(socket, fn user -> Review.add(socket.assigns.capture, params, user) end)
  end

  def handle_event("commit", _params, socket) do
    %{board: board, capture: capture, open_count: open} = socket.assigns

    if socket.assigns.can_write and open == 0 and capture.state == "ready",
      do:
        {:noreply,
         push_navigate(socket, to: "/boards/#{board.id}/meetings/#{capture.id}/preview")},
      else: {:noreply, socket}
  end

  # The keyboard. Off while a form is open, so typing is typing.
  def handle_event("key", %{"key" => key}, %{assigns: %{editing: nil, adding: false}} = socket) do
    keys(String.downcase(key), socket)
  end

  def handle_event("key", _params, socket), do: {:noreply, socket}

  defp keys(key, socket) when key in ["j", "k"] do
    ids = Enum.map(socket.assigns.kept, & &1.id)
    at = Enum.find_index(ids, &(&1 == socket.assigns.selected)) || 0
    next = if key == "j", do: min(at + 1, length(ids) - 1), else: max(at - 1, 0)
    {:noreply, assign(socket, selected: Enum.at(ids, next))}
  end

  defp keys(key, socket) when key in ["i", "x"] do
    case socket.assigns.selected do
      nil ->
        {:noreply, socket}

      id ->
        handle_event(
          "include",
          %{"id" => to_string(id), "included" => to_string(key == "i")},
          socket
        )
    end
  end

  defp keys(key, socket) when key in ["1", "2", "3", "4"] do
    with %Meetings.Finding{} = f <-
           Enum.find(socket.assigns.kept, &(&1.id == socket.assigns.selected)),
         %Meetings.Question{} = q <- Enum.find(open_questions(socket, f.id), & &1),
         %{"value" => value} <- Enum.at(q.options, String.to_integer(key) - 1) do
      handle_event("answer", %{"question" => to_string(q.id), "value" => value}, socket)
    else
      _ -> {:noreply, socket}
    end
  end

  defp keys("n", socket) do
    case Enum.find(socket.assigns.capture.questions, &(&1.status == "open" and &1.finding_id)) do
      nil -> {:noreply, socket}
      q -> {:noreply, assign(socket, selected: q.finding_id)}
    end
  end

  defp keys("enter", socket) do
    case socket.assigns.selected do
      nil -> {:noreply, socket}
      id -> handle_event("edit", %{"id" => to_string(id)}, socket)
    end
  end

  defp keys(_key, socket), do: {:noreply, socket}

  defp open_questions(socket, finding_id),
    do:
      Enum.filter(
        socket.assigns.capture.questions,
        &(&1.finding_id == finding_id and &1.status == "open")
      )

  defp question(socket, id) do
    id = SlipdockWeb.Params.id(id)
    Enum.find(socket.assigns.capture.questions, &(&1.id == id))
  end

  defp finding(socket, id) do
    id = SlipdockWeb.Params.id(id)
    Enum.find(socket.assigns.capture.findings, &(&1.id == id))
  end

  # Writers only; the result reloads the page (everyone else hears it by
  # broadcast) or says what went wrong.
  defp with_writer(socket, fun) do
    if socket.assigns.can_write and Review.reviewable?(socket.assigns.capture) do
      case fun.(socket.assigns.current_user) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(review_error: nil)
           |> load(Meetings.get_capture!(socket.assigns.capture.id))}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply,
           assign(socket, review_error: "That couldn't be saved: #{inspect(cs.errors)}")}

        {:error, message} when is_binary(message) ->
          {:noreply, assign(socket, review_error: message)}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # Where each step stands: done, running now, failed, or still to come.
  defp step_states(capture) do
    done = (capture.progress || %{})["done"] || done_through(capture.step)
    current = Slipdock.Meetings.Pipeline.next_step(capture.step)

    for step <- Slipdock.Meetings.Pipeline.steps() do
      state =
        cond do
          step in done -> :done
          capture.state == "failed" and step == current -> :failed
          capture.state == "reading" and step == current -> :running
          capture.state in ~w(needs_review ready committed discarded) -> :done
          true -> :pending
        end

      {step, state}
    end
  end

  defp done_through(nil), do: []

  defp done_through(step) do
    steps = Slipdock.Meetings.Pipeline.steps()
    Enum.take(steps, Enum.find_index(steps, &(&1 == step)) + 1)
  end

  defp analysing?(capture), do: capture.state in ~w(receiving reading failed)

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

      <div class="flex h-full flex-col">
        <.meeting_toolbar board={@board} marks={@marks} meetings={@meetings}>
          <span id="capture-state" class={["badge badge-sm", state_class(@capture.state)]}>
            {state_label(@capture.state)}
          </span>
        </.meeting_toolbar>

        <div class="kanban-scroll min-h-0 flex-1 overflow-y-auto">
          <div class={[
            "mx-auto space-y-6 p-4 sm:p-6",
            if(analysing?(@capture), do: "max-w-3xl", else: "max-w-6xl")
          ]}>
            <header>
              <h1 class="text-xl font-semibold">{@capture.title}</h1>
              <p class="mt-1 text-sm text-base-content/60">
                Sent by {(@capture.owner && (@capture.owner.name || @capture.owner.email)) ||
                  "somebody"}
                <span :if={@capture.started_at}>
                  · met {Calendar.strftime(@capture.started_at, "%d %b %Y, %H:%M")}
                </span>
                <span :if={@capture.attendees != []}>
                  · {Enum.map_join(@capture.attendees, ", ", &(&1["name"] || &1["email"]))}
                </span>
              </p>
            </header>

            <section
              :if={analysing?(@capture)}
              id="capture-analysing"
              class="rounded-xl bg-base-100 p-4 ring-1 ring-base-content/10"
            >
              <h2 class="text-sm font-medium">
                {if @capture.state == "failed", do: "Stopped", else: "Reading the meeting"}
              </h2>
              <p :if={@capture.state != "failed"} class="mt-1 text-xs text-base-content/60">
                You can leave this page: {(@capture.owner && @capture.owner.email) ||
                  "whoever sent it"} is emailed when it is ready.
              </p>
              <ol class="mt-3 space-y-1.5 text-sm">
                <li
                  :for={{step, state} <- step_states(@capture)}
                  id={"step-#{step}"}
                  data-state={state}
                  class="flex items-center gap-2"
                >
                  <.icon :if={state == :done} name="hero-check-circle" class="size-4 text-success" />
                  <span
                    :if={state == :running}
                    class="loading loading-spinner loading-xs text-primary"
                  ></span>
                  <.icon :if={state == :failed} name="hero-x-circle" class="size-4 text-error" />
                  <span
                    :if={state == :pending}
                    class="inline-block size-4 rounded-full border border-base-content/20"
                  ></span>
                  <span class={[state == :pending && "text-base-content/50"]}>
                    {Slipdock.Meetings.Pipeline.step_label(step)}
                  </span>
                </li>
              </ol>
              <div :if={@capture.state == "failed"} class="mt-3 flex flex-wrap items-center gap-3">
                <p id="capture-failure" class="text-sm text-error">{@capture.state_reason}</p>
                <button
                  :if={@can_write}
                  id="retry-capture"
                  type="button"
                  phx-click="retry"
                  class="btn btn-sm btn-outline"
                >
                  <.icon name="hero-arrow-path" class="size-4" /> Retry
                </button>
              </div>
            </section>

            <.review
              :if={not analysing?(@capture)}
              capture={@capture}
              kept={@kept}
              dropped={@dropped}
              selected={@selected}
              editing={@editing}
              adding={@adding}
              open_count={@open_count}
              can_write={@can_write}
              narrow?={@narrow?}
              show_transcript={@show_transcript}
              members={@members}
              lists={@lists}
              error={@review_error}
            />

            <section
              :if={analysing?(@capture) and @capture.findings != []}
              id="capture-findings"
              class="rounded-xl bg-base-100 ring-1 ring-base-content/10"
            >
              <h2 class="border-b border-base-content/10 px-4 py-2 text-sm font-medium">Found</h2>
              <ul class="divide-y divide-base-content/5 text-sm">
                <li
                  :for={f <- @capture.findings}
                  id={"finding-#{f.id}"}
                  class={["px-4 py-2", f.status == "dropped" && "text-base-content/50"]}
                >
                  <span class="badge badge-ghost badge-xs mr-1">
                    {String.replace(f.kind, "_", " ")}
                  </span>
                  <span class={[f.status == "dropped" && "line-through"]}>{f.title}</span>
                  <p :if={f.status == "dropped"} class="mt-0.5 text-xs">
                    Dropped: {f.drop_reason}
                  </p>
                </li>
              </ul>
            </section>

            <section
              :if={analysing?(@capture)}
              id="capture-transcript"
              class="rounded-xl bg-base-100 ring-1 ring-base-content/10"
            >
              <h2 class="border-b border-base-content/10 px-4 py-2 text-sm font-medium">
                Transcript
              </h2>
              <p :if={@capture.utterances == []} class="px-4 py-3 text-sm text-base-content/60">
                No transcript yet.
              </p>
              <ol class="divide-y divide-base-content/5 text-sm">
                <li
                  :for={u <- @capture.utterances}
                  id={"line-#{u.line_id}"}
                  class="flex gap-3 px-4 py-2"
                >
                  <span class="w-12 shrink-0 font-mono text-2xs text-base-content/40">{clock(
                    u.start_ms
                  )}</span>
                  <span class="min-w-0">
                    <span :if={u.speaker} class="font-medium">{u.speaker}: </span>{u.text}
                  </span>
                </li>
              </ol>
            </section>

            <section id="capture-record" class="text-xs text-base-content/60">
              <h2 class="mb-1 font-medium text-base-content/70">Record</h2>
              <ol class="space-y-0.5">
                <li :for={e <- @capture.events}>
                  {Calendar.strftime(e.inserted_at, "%d %b %H:%M")} · {e.message}
                  <span :if={e.user}>— {e.user.name || e.user.email}</span>
                </li>
              </ol>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

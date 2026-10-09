defmodule Slipdock.Meetings.Pipeline do
  @moduledoc """
  A capture's journey from received to ready for review, one durable step
  at a time:

      ingest → transcribe → diarise → attribute → context → read → verify → relisten → ready

  Each step's output is stored before the next starts (the transcript lines,
  the context, the readings, the findings), and `capture.step` names the last
  one finished. So a server that restarts halfway resumes **after** that step
  rather than starting again — a meeting is never read twice because a
  deploy happened during the reading. The scheduler's clock
  (`Slipdock.Automations.Scheduler`) calls `sweep/0`, which picks up any
  capture still `reading` that nothing on this node is running and that has
  not moved for a while: the ones a restart or a crash left behind.

  A step that fails leaves the capture `failed` with the reason (a
  provider's own message where there is one), and `retry/2` carries on from
  the step after the last one that finished. Every step that costs something
  writes it to the usage ledger as it goes (`Slipdock.Meetings.Usage`).

  Progress is broadcast on the capture's topic (`Slipdock.Meetings.subscribe/1`)
  after every step, which is what moves the Analysing screen along; findings
  appear on it as soon as verification has written them. When it is done,
  the capture is `needs_review` (questions to settle) or `ready`, and the
  person who sent it is told by email.

  How a pipeline is run is config (`config :slipdock, :meetings, pipeline:`):
  `:async` (under `Slipdock.TaskSupervisor`, the default), `:sync` (in the
  caller, for a test that wants it), or `:manual` (not started by ingest at
  all — the test suite's default, so tests drive it step by step).
  """
  require Logger

  alias Slipdock.{Meetings, Repo}
  alias Slipdock.Meetings.Capture

  @steps ~w(ingest transcribe diarise attribute context read verify relisten ready)
  @stale_seconds 90

  @doc "The steps, in order."
  def steps, do: @steps

  @doc "How a step reads on the Analysing screen."
  def step_label("ingest"), do: "Received"
  def step_label("transcribe"), do: "Transcribing"
  def step_label("diarise"), do: "Separating voices"
  def step_label("attribute"), do: "Working out who spoke"
  def step_label("context"), do: "Reading the board and its wiki"
  def step_label("read"), do: "Reading the meeting, twice"
  def step_label("verify"), do: "Checking every quote"
  def step_label("relisten"), do: "Re-listening to unclear words"
  def step_label("ready"), do: "Ready for review"

  @doc """
  Starts reading a capture that has just been received. Returns the capture
  as it stands when this returns (still `reading` when the work runs in the
  background).
  """
  def start(%Capture{state: "receiving"} = capture, opts \\ []) do
    {:ok, capture} =
      Meetings.transition(capture, "reading",
        changes: %{step: capture.step || "ingest", progress: progress(capture.step || "ingest")}
      )

    launch(capture, opts)
  end

  @doc "Carries a failed capture on from the step after the last one finished."
  def retry(capture, user, opts \\ [])

  def retry(%Capture{state: "failed"} = capture, user, opts) do
    {:ok, capture} =
      Meetings.transition(capture, "reading",
        user: user,
        via: opts[:via],
        message: "Retrying from #{step_label(next_step(capture.step))}."
      )

    launch(capture, opts)
  end

  def retry(%Capture{} = capture, _user, _opts),
    do: {:error, "only a failed capture can be retried (this one is #{capture.state})"}

  @doc """
  Captures left `reading` with nothing running them — after a restart, or a
  crash — carried on from where they got to. Returns how many.
  """
  def sweep do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_seconds, :second)

    import Ecto.Query

    Repo.all(from(c in Capture, where: c.state == "reading" and c.updated_at < ^cutoff))
    |> Enum.reject(&running?(&1.id))
    |> Enum.map(fn capture ->
      Logger.info("Resuming meeting capture #{capture.id} after #{capture.step || "ingest"}")

      Meetings.record(
        capture,
        "resumed",
        "Resumed after a restart, from #{step_label(next_step(capture.step))}."
      )

      launch(capture, [])
    end)
    |> length()
  end

  @doc "Whether this node is working on the capture right now."
  def running?(id), do: Registry.lookup(Slipdock.Meetings.Registry, id) != []

  defp mode(opts),
    do: opts[:mode] || Keyword.get(Slipdock.Config.get(:meetings, []), :pipeline, :async)

  defp launch(capture, opts) do
    case mode(opts) do
      :manual ->
        capture

      :sync ->
        guarded(capture, opts)

      :async ->
        {:ok, _pid} =
          Task.Supervisor.start_child(Slipdock.TaskSupervisor, fn -> guarded(capture, opts) end)

        capture
    end
  end

  # One runner per capture per node, and an exception inside a step is a
  # failure with a reason rather than a capture stuck reading for ever.
  defp guarded(capture, opts) do
    case Registry.register(Slipdock.Meetings.Registry, capture.id, nil) do
      {:ok, _} ->
        try do
          run(capture, opts)
        rescue
          e ->
            Logger.error(
              "Meeting capture #{capture.id} crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
            )

            capture = Meetings.get_capture!(capture.id)

            fail(
              capture,
              "something went wrong while #{String.downcase(step_label(next_step(capture.step)))}"
            )
        after
          Registry.unregister(Slipdock.Meetings.Registry, capture.id)
        end

      {:error, {:already_registered, _}} ->
        capture
    end
  end

  @doc """
  Runs the remaining steps in the caller. Options: `:stop_after` — stop once
  that step is stored, as a restart would (the tests' way of killing the
  process between steps); `:ai` — passed to the model calls.
  """
  def run(%Capture{} = capture, opts \\ []) do
    remaining = Enum.drop_while(@steps, &(&1 != next_step(capture.step)))

    Enum.reduce_while(remaining, capture, fn step, capture ->
      case run_step(step, capture, opts) do
        {:ok, capture} ->
          capture = finished(capture, step)
          if opts[:stop_after] == step, do: {:halt, capture}, else: {:cont, capture}

        {:error, reason} ->
          {:halt, fail(capture, reason)}
      end
    end)
  end

  @doc "The step after `step` (nil is before the first)."
  def next_step(nil), do: "ingest"

  def next_step(step) do
    case Enum.drop_while(@steps, &(&1 != step)) do
      [_, next | _] -> next
      _ -> nil
    end
  end

  ## The steps ------------------------------------------------------------------

  defp run_step("ingest", capture, _opts), do: {:ok, capture}

  defp run_step("transcribe", capture, opts),
    do: Slipdock.Meetings.Audio.transcribe(capture, opts)

  defp run_step("diarise", capture, opts), do: Slipdock.Meetings.Speakers.diarise(capture, opts)

  defp run_step("attribute", capture, opts),
    do: Slipdock.Meetings.Speakers.attribute(capture, opts)

  defp run_step("context", capture, _opts) do
    started = System.monotonic_time(:millisecond)

    with {:ok, capture} <- Meetings.gather_context(capture) do
      Slipdock.Meetings.Usage.record(capture, %{
        kind: :context,
        step: "context",
        seconds: (System.monotonic_time(:millisecond) - started) / 1000
      })

      {:ok, capture}
    end
  end

  defp run_step("read", capture, opts) do
    case Meetings.read_meeting(capture, ai: opts[:ai]) do
      {:ok, capture} -> {:ok, capture}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_step("verify", capture, _opts) do
    with {:ok, counts} <- Meetings.verify(capture) do
      capture = Meetings.get_capture!(capture.id)

      {:ok, update(capture, stats: Map.put(capture.stats || %{}, "found", stringify(counts)))}
    end
  end

  defp run_step("relisten", capture, opts), do: Slipdock.Meetings.Relisten.run(capture, opts)

  defp run_step("ready", capture, _opts) do
    open = length(Meetings.open_questions(capture))
    to = if open > 0, do: "needs_review", else: "ready"

    {:ok, capture} =
      Meetings.transition(capture, to,
        message:
          if(open > 0,
            do:
              "Read. #{open} #{if open == 1, do: "question needs", else: "questions need"} a person.",
            else: "Read, with nothing left to ask. Ready to commit."
          )
      )

    notify_owner(capture, open)
    {:ok, capture}
  end

  ## Bookkeeping -------------------------------------------------------------------

  # The step's output is already stored; this records that it is.
  defp finished(capture, step) do
    capture = Meetings.get_capture!(capture.id)

    capture =
      if capture.state == "reading",
        do: update(capture, step: step, progress: progress(step)),
        else: update(capture, step: step)

    Meetings.broadcast(capture)
    capture
  end

  defp progress(step) do
    done = Enum.take_while(@steps, &(&1 != step)) ++ [step]
    %{"done" => done, "current" => next_step(step)}
  end

  defp fail(capture, reason) do
    capture = Meetings.get_capture!(capture.id)

    case Meetings.transition(capture, "failed", reason: reason) do
      {:ok, capture} -> capture
      {:error, _} -> capture
    end
  end

  defp update(capture, changes) do
    capture |> Ecto.Changeset.change(changes) |> Repo.update!()
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # The person who sent it hears when it is ready, by email where the server
  # sends mail. Anyone else finds it in the board's Meetings tab.
  defp notify_owner(capture, open) do
    capture = Repo.preload(capture, [:owner, :board])

    url =
      "#{Slipdock.Config.get(:base_url) || SlipdockWeb.Endpoint.url()}/boards/#{capture.board_id}/meetings/#{capture.id}"

    body =
      """
      “#{capture.title}” on #{capture.board.name} has been read.

      #{if open > 0, do: "#{open} #{if open == 1, do: "thing needs", else: "things need"} you to settle before it can be committed.", else: "Nothing needs settling: it is ready to commit."}

      Nothing has been written to the board yet. Review it here:
      #{url}
      """

    Slipdock.Automations.Notifier.deliver(
      [capture.owner.email],
      "Meeting ready for review: #{capture.title}",
      body
    )

    Meetings.record(capture, "notified", "Told #{capture.owner.email} it is ready for review.")
  rescue
    e ->
      Logger.warning("Could not tell the owner of capture #{capture.id}: #{Exception.message(e)}")
  end
end

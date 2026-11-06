defmodule SlipdockWeb.BoardLive.JobLogComponent do
  @moduledoc """
  A runner job's live log (#1871), on the card's job panel and in a runner's
  details on the Runners panel: one line per message, tool call or tool
  result (`Slipdock.Runners.TranscriptView`), newest at the bottom, and each
  line with more to it opens to the whole of it.

  It updates without a reload. The first render subscribes the page's
  process to the job's `Slipdock.Runners.Transcript.topic/1`; the LiveView
  passes each `{:transcript, job_id, lines}` on with `notify/1`, and only the
  new lines are read and appended (a stream, so a line someone opened stays
  open). A running job's log is open; a finished one's is folded until asked.
  """
  use SlipdockWeb, :live_component

  import SlipdockWeb.SlipdockComponents, only: [timestamp: 1]

  alias Slipdock.Runners.{Job, Transcript, TranscriptView}

  # The most entries a page holds; a longer log starts this far from its end.
  @shown 300

  @doc "The places a job's log is shown, each with its own component id."
  def places, do: ~w(card runner)

  @doc "The component id for `job_id`'s log shown in `place`."
  def id(place, job_id), do: "job-log-#{place}-#{job_id}"

  @doc """
  Tells every log of `job_id` on this page that more of it has arrived. A
  place not showing it ignores this.
  """
  def notify(job_id) do
    for place <- places(), do: send_update(__MODULE__, id: id(place, job_id), more: true)
    :ok
  end

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(job: nil, next: nil, count: 0, skipped: 0, open: nil)
     |> stream_configure(:entries, dom_id: &"#{&1.dom}")
     |> stream(:entries, [])}
  end

  @impl true
  def update(%{more: true}, %{assigns: %{open: false, job: %Job{} = job}} = socket),
    do: {:ok, assign(socket, job: Slipdock.Runners.get_job(job.id) || job)}

  def update(%{more: true}, socket), do: {:ok, read_more(socket)}

  def update(%{job: %Job{} = job} = assigns, socket) do
    old = socket.assigns.job
    # The page re-renders often; the log is read again only when the job moved.
    moved? =
      is_nil(old) or old.status != job.status or job.transcript_lines > old.transcript_lines

    socket =
      socket
      |> assign(id: assigns.id)
      |> then(&if(is_nil(&1.assigns.open), do: assign(&1, open: Job.open?(job)), else: &1))
      |> then(&if(moved?, do: assign(&1, job: job), else: &1))
      |> subscribe()

    {:ok, if(moved?, do: read_more(socket), else: socket)}
  end

  # One subscription per job per page, however many places show it.
  defp subscribe(%{assigns: %{job: job}} = socket) do
    if connected?(socket) and Job.open?(job) and !socket.assigns[:subscribed] do
      topic = Transcript.topic(job.id)
      Phoenix.PubSub.unsubscribe(Slipdock.PubSub, topic)
      Phoenix.PubSub.subscribe(Slipdock.PubSub, topic)
      assign(socket, subscribed: true)
    else
      socket
    end
  end

  # Nothing is read until the log is open; then from where the page got to,
  # or, the first time, from @shown lines before the end.
  defp read_more(socket, opts \\ [])
  defp read_more(%{assigns: %{open: false}} = socket, _opts), do: socket

  defp read_more(%{assigns: %{job: %Job{} = job, next: next}} = socket, opts) do
    job = Slipdock.Runners.get_job(job.id) || job

    from =
      next ||
        max(job.transcript_lines - @shown, 0)

    entries =
      if job.transcript_lines > from do
        job |> Transcript.read(from) |> TranscriptView.entries(from)
      else
        []
      end

    entries = Enum.map(entries, &Map.put(&1, :dom, "#{socket.assigns.id}-#{&1.id}"))

    socket
    |> assign(
      job: job,
      next: max(job.transcript_lines, from),
      skipped: if(is_nil(next), do: from, else: socket.assigns.skipped),
      count: socket.assigns.count + length(entries)
    )
    |> stream(:entries, entries, limit: -@shown, reset: opts[:reset] == true)
  end

  defp read_more(socket, _opts), do: socket

  @impl true
  def handle_event("toggle", _params, socket) do
    # The lines left the page when it folded, so opening reads them afresh.
    if socket.assigns.open do
      {:noreply, assign(socket, open: false)}
    else
      {:noreply,
       socket |> assign(open: true, next: nil, count: 0, skipped: 0) |> read_more(reset: true)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="mt-1">
      <button
        type="button"
        id={"#{@id}-toggle"}
        phx-click="toggle"
        phx-target={@myself}
        class="flex items-center gap-1 text-2xs text-base-content/60 hover:text-base-content"
        aria-expanded={to_string(@open)}
      >
        <.icon name={if @open, do: "hero-chevron-down", else: "hero-chevron-right"} class="size-3" />
        Live log <span>· {lines(@job.transcript_lines)}</span>
        <span :if={Job.open?(@job)} class="text-info">· updating</span>
        <span :if={@job.transcript_at}>
          · last <.timestamp at={@job.transcript_at} format={:time} />
        </span>
      </button>
      <div :if={@open}>
        <p :if={@skipped > 0} id={"#{@id}-skipped"} class="mt-1 text-2xs text-base-content/50">
          {@skipped} earlier lines not shown: <code>slipdock job-log {@job.id}</code>
        </p>
        <.empty_state
          :if={@count == 0}
          id={"#{@id}-empty"}
          icon="hero-command-line"
          title={if Job.open?(@job), do: "Nothing yet", else: "No log"}
          compact
          class="mt-1"
        >
          {if Job.open?(@job),
            do: "The runner sends the log about once a minute.",
            else: "Nothing was sent for this job."}
        </.empty_state>
        <ol
          id={"#{@id}-lines"}
          phx-update="stream"
          phx-hook="LogTail"
          class="mt-1 max-h-72 space-y-px overflow-auto rounded bg-base-200 p-1.5 font-mono text-2xs"
        >
          <li :for={{dom_id, e} <- @streams.entries} id={dom_id} data-kind={e.kind}>
            <details :if={e.detail} class="group">
              <summary class="cursor-pointer list-none">
                <.line entry={e} />
              </summary>
              <pre class="mt-0.5 mb-1 max-h-64 overflow-auto whitespace-pre-wrap rounded bg-base-100 p-1.5">{e.detail}</pre>
            </details>
            <.line :if={!e.detail} entry={e} />
          </li>
        </ol>
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true

  defp line(assigns) do
    ~H"""
    <span class="flex gap-2">
      <.timestamp at={@entry.at} format={:time} class="shrink-0 text-base-content/50" />
      <span class={["min-w-0 break-words", kind_class(@entry.kind)]}>
        {TranscriptView.mark(@entry.kind) |> String.trim_leading()}{@entry.text}
      </span>
    </span>
    """
  end

  defp kind_class(:error), do: "text-error"
  defp kind_class(:result), do: "pl-4 text-base-content/70"
  defp kind_class(:note), do: "italic text-warning"
  defp kind_class(:prompt), do: "text-base-content/70"
  defp kind_class(_), do: nil

  defp lines(1), do: "1 line"
  defp lines(n), do: "#{n} lines"
end

defmodule SlipdockWeb.MeetingLive.New do
  @moduledoc """
  Sending a meeting to a board (screen 2 of the mockups): up to three things —
  a recording, a transcript (a file or pasted), and an agent's findings —
  with what each combination gets, what the reading looks at, where the data
  goes before anybody reviews it, and what it counts against. Nothing is sent
  anywhere until the person presses Start.

  The checks are `Slipdock.Meetings.Ingest`'s, the same as the API's.
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.MeetingLive.Components

  alias Slipdock.Meetings
  alias Slipdock.Meetings.{Ingest, Limits}
  alias SlipdockWeb.MeetingLive.Access

  on_mount {SlipdockWeb.MeetingsHook, :require_enabled}

  @transcript_types ~w(.vtt .srt .txt .json .text)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Access.mount_board(socket, id, :write) do
      {:ok, socket} ->
        user = socket.assigns.current_user
        settings = Slipdock.Settings.get()

        {:ok,
         socket
         |> assign(
           page_title: "Capture a meeting · #{socket.assigns.board.name}",
           settings: settings,
           destinations: Meetings.destinations(user),
           parent?: socket.assigns.board.parent_card_id != nil,
           error: nil,
           form:
             to_form(
               %{
                 "title" => "",
                 "when" => "",
                 "attendees" => "",
                 "pasted" => "",
                 "parent" => "false",
                 "retention" => "30_days"
               },
               as: :capture
             )
         )
         |> allow_upload(:audio,
           accept: Limits.audio_extensions(),
           max_entries: 1,
           max_file_size: Limits.max_audio_bytes()
         )
         |> allow_upload(:transcript,
           accept: @transcript_types,
           max_entries: 1,
           max_file_size: Limits.max_transcript_bytes()
         )
         |> allow_upload(:findings,
           accept: ~w(.json),
           max_entries: 1,
           max_file_size: Limits.max_findings_bytes()
         )
         |> allow_upload(:ics, accept: ~w(.ics), max_entries: 1, max_file_size: 1_000_000)}

      {:error, socket} ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_event("validate", %{"capture" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :capture), error: nil)}
  end

  def handle_event("cancel-upload", %{"slot" => slot, "ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(slot), ref)}
  end

  def handle_event("start", %{"capture" => params}, socket) do
    %{board: board, current_user: user} = socket.assigns

    transcript =
      first_upload(socket, :transcript, fn path, entry ->
        %{content: File.read!(path), filename: entry.client_name}
      end) || pasted(params["pasted"])

    findings =
      first_upload(socket, :findings, fn path, _entry -> %{content: File.read!(path)} end)

    ics = first_upload(socket, :ics, fn path, _entry -> File.read!(path) end)

    # The recording is copied out of the upload's temporary file before the
    # upload is let go of, since the capture is made from a path.
    audio =
      first_upload(socket, :audio, fn path, entry ->
        keep = Path.join(System.tmp_dir!(), "capture-#{System.unique_integer([:positive])}")
        File.cp!(path, keep)
        %{path: keep, filename: entry.client_name, content_type: entry.client_type}
      end)

    result =
      Ingest.ingest(board, user, %{
        transcript: transcript,
        audio: audio,
        findings: findings,
        ics: ics,
        title: params["title"],
        started_at: blank(params["when"]),
        attendees: params["attendees"],
        context: %{parent: params["parent"]},
        retention: params["retention"],
        source: "upload",
        via: "web"
      })

    if audio, do: File.rm(audio.path)

    case result do
      {:ok, capture} ->
        {:noreply, push_navigate(socket, to: ~p"/boards/#{board}/meetings/#{capture.id}")}

      {:existing, capture} ->
        {:noreply,
         socket
         |> put_flash(:info, "This meeting was already sent to this board. Here it is.")
         |> push_navigate(to: ~p"/boards/#{board}/meetings/#{capture.id}")}

      {:error, {:invalid, message}} ->
        {:noreply, assign(socket, error: message)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         assign(socket,
           error:
             Slipdock.Quota.refusal_message(cs) || "That couldn't be saved: #{inspect(cs.errors)}"
         )}
    end
  end

  defp first_upload(socket, slot, fun) do
    socket
    |> consume_uploaded_entries(slot, fn %{path: path}, entry -> {:ok, fun.(path, entry)} end)
    |> List.first()
  end

  defp pasted(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: %{content: text, filename: nil}
  end

  defp pasted(_), do: nil

  defp blank(""), do: nil
  defp blank(v), do: v

  # Which row of the table the person's choices are, so it can be marked.
  defp combination(assigns) do
    audio? = assigns.uploads.audio.entries != []

    transcript? =
      assigns.uploads.transcript.entries != [] or
        String.trim(assigns.form.params["pasted"] || "") != ""

    cond do
      audio? and transcript? -> :both
      audio? -> :audio
      transcript? -> :transcript
      true -> nil
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, combination: combination(assigns))

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
      <:subnav><.meeting_nav board={@board} /></:subnav>

      <div class="flex h-full flex-col">
        <.meeting_toolbar board={@board} marks={@marks} meetings={@meetings} />

        <div class="kanban-scroll min-h-0 flex-1 overflow-y-auto">
          <.form
            for={@form}
            id="new-capture-form"
            phx-change="validate"
            phx-submit="start"
            class="mx-auto max-w-3xl space-y-6 p-4 sm:p-6"
          >
            <header>
              <h1 class="text-xl font-semibold">Capture a meeting</h1>
              <p class="mt-1 text-sm text-base-content/60">
                Send a recording, a transcript, or both. Slipdock reads it alongside this board and
                proposes what it found. Nothing is written until somebody reviews and commits it.
              </p>
            </header>

            <p
              :if={@error}
              id="capture-error"
              class="rounded-xl bg-error/10 px-4 py-3 text-sm text-error"
              role="alert"
            >
              {@error}
            </p>

            <section class="grid gap-3 sm:grid-cols-3">
              <.slot_card
                id="slot-audio"
                upload={@uploads.audio}
                title="Recording"
                icon="hero-microphone"
                hint="wav, mp3, m4a, flac, ogg, webm, aac"
                off={!@settings.meetings_accept_audio}
              />
              <.slot_card
                id="slot-transcript"
                upload={@uploads.transcript}
                title="Transcript"
                icon="hero-document-text"
                hint="WebVTT, SRT, Name: text, Fireflies or Otter"
                off={!@settings.meetings_accept_transcripts}
              />
              <.slot_card
                id="slot-findings"
                upload={@uploads.findings}
                title="Agent findings"
                icon="hero-cpu-chip"
                hint="optional: JSON in the published schema"
                off={!@settings.meetings_accept_findings}
              />
            </section>

            <details
              :if={@settings.meetings_accept_transcripts}
              class="rounded-xl bg-base-100 p-3 ring-1 ring-base-content/10"
            >
              <summary class="cursor-pointer text-sm font-medium">Or paste the transcript</summary>
              <.input
                field={@form[:pasted]}
                type="textarea"
                rows="6"
                placeholder="Priya: Let's settle the pricing page.&#10;Sam: We go with the annual plan."
                class="textarea mt-2 w-full font-mono text-xs"
              />
            </details>

            <section
              id="combinations"
              class="overflow-x-auto rounded-xl bg-base-100 ring-1 ring-base-content/10"
            >
              <table class="table table-sm text-xs">
                <thead>
                  <tr>
                    <th>Sent</th>
                    <th>Transcribed here</th>
                    <th>Replay & re-listen</th>
                    <th>Speakers from</th>
                    <th>Counts against</th>
                  </tr>
                </thead>
                <tbody>
                  <tr id="combo-audio" class={@combination == :audio && "bg-primary/10"}>
                    <td class="font-medium">Recording</td>
                    <td>yes</td>
                    <td>yes</td>
                    <td>voices, dialogue, invite</td>
                    <td>transcription minutes, storage</td>
                  </tr>
                  <tr id="combo-both" class={@combination == :both && "bg-primary/10"}>
                    <td class="font-medium">Recording + transcript</td>
                    <td>no, aligned only</td>
                    <td>yes</td>
                    <td>voices, transcript labels, dialogue</td>
                    <td>storage</td>
                  </tr>
                  <tr id="combo-transcript" class={@combination == :transcript && "bg-primary/10"}>
                    <td class="font-medium">Transcript</td>
                    <td>no</td>
                    <td>no</td>
                    <td>transcript labels, dialogue</td>
                    <td>captures</td>
                  </tr>
                  <tr>
                    <td class="font-medium">…+ agent findings</td>
                    <td>—</td>
                    <td>—</td>
                    <td>—</td>
                    <td>nothing more; still checked word for word</td>
                  </tr>
                </tbody>
              </table>
            </section>

            <section class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@form[:title]}
                label="Title"
                placeholder="Taken from the invite or the file if empty"
              />
              <.input field={@form[:when]} type="datetime-local" label="Started" />
              <div class="sm:col-span-2">
                <.input
                  field={@form[:attendees]}
                  label="Attendees"
                  placeholder="Priya, sam@example.com — the strongest hint at who is speaking"
                />
                <div class="mt-1 flex items-center gap-2 text-xs text-base-content/60">
                  <label class="btn btn-ghost btn-xs">
                    <.icon name="hero-calendar" class="size-3.5" /> From an invite (.ics)
                    <.live_file_input upload={@uploads.ics} class="hidden" />
                  </label>
                  <span :for={entry <- @uploads.ics.entries}>{entry.client_name}</span>
                </div>
              </div>
            </section>

            <section id="capture-scope" class="rounded-xl bg-base-100 p-4 ring-1 ring-base-content/10">
              <h2 class="text-sm font-medium">Read alongside</h2>
              <div class="mt-2 flex flex-wrap gap-x-6 gap-y-2 text-sm">
                <label class="flex items-center gap-2">
                  <input type="checkbox" checked disabled class="checkbox checkbox-sm" /> This board
                </label>
                <label class="flex items-center gap-2">
                  <input type="checkbox" checked disabled class="checkbox checkbox-sm" /> Its wiki
                </label>
                <label :if={@parent?} class="flex items-center gap-2">
                  <input type="hidden" name="capture[parent]" value="false" />
                  <input
                    type="checkbox"
                    name="capture[parent]"
                    value="true"
                    checked={@form.params["parent"] == "true"}
                    class="checkbox checkbox-sm"
                  /> Its parent board
                </label>
              </div>
              <p class="mt-2 text-xs text-base-content/60">
                Only what you can open yourself is read.
              </p>
            </section>

            <section
              id="capture-destination"
              class="rounded-xl bg-base-100 p-4 ring-1 ring-base-content/10"
            >
              <h2 class="text-sm font-medium">Where it goes before anyone reviews it</h2>
              <ul class="mt-2 space-y-1 text-sm">
                <li :if={@destinations.reading}>
                  <.icon name="hero-arrow-up-right" class="size-3.5 text-base-content/50" />
                  The transcript is read by
                  <span class="font-medium">{@destinations.reading.model}</span>
                  at <span class="font-mono text-xs">{@destinations.reading.host}</span>
                  <span class="text-base-content/60">
                    ({if @destinations.reading.own?, do: "your AI settings", else: "this server's shared key"})
                  </span>.
                </li>
                <li :if={!@destinations.reading} class="text-warning">
                  <.icon name="hero-exclamation-triangle" class="size-3.5" />
                  You have no AI model set up, so nothing can be read yet. Add one under Account → Settings → AI model.
                </li>
                <li :if={@combination in [:audio, :both]}>
                  <.icon name="hero-arrow-up-right" class="size-3.5 text-base-content/50" />
                  <%= if @destinations.transcription do %>
                    The recording is transcribed by
                    <span class="font-medium">{@destinations.transcription.model}</span>
                    at <span class="font-mono text-xs">{@destinations.transcription.host}</span>.
                  <% else %>
                    The recording stays on this server: it transcribes nothing, so send a transcript with it.
                  <% end %>
                </li>
              </ul>
              <div :if={@combination in [:audio, :both]} class="mt-3 max-w-xs">
                <.input
                  field={@form[:retention]}
                  type="select"
                  label="Keep the recording"
                  options={[
                    {"Until it is committed", "until_committed"},
                    {"30 days", "30_days"},
                    {"90 days", "90_days"}
                  ]}
                />
              </div>
            </section>

            <section id="capture-cost" class="text-sm text-base-content/70">
              <%= case @combination do %>
                <% :transcript -> %>
                  This counts as one capture from a transcript.
                <% :both -> %>
                  The recording counts against this board's file storage; no transcription is used.
                <% :audio -> %>
                  The recording counts against this board's file storage and your transcription minutes.
                <% nil -> %>
                  Add a recording or a transcript to start.
              <% end %>
            </section>

            <div class="flex justify-end gap-2">
              <.link navigate={~p"/boards/#{@board}/meetings"} class="btn btn-ghost">Cancel</.link>
              <button
                type="submit"
                id="start-capture"
                class="btn btn-primary"
                disabled={is_nil(@combination)}
              >
                Start
              </button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :upload, :any, required: true
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :hint, :string, required: true
  attr :off, :boolean, default: false

  defp slot_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "rounded-xl bg-base-100 p-4 ring-1 ring-base-content/10",
        @off && "opacity-50"
      ]}
      phx-drop-target={!@off && @upload.ref}
    >
      <div class="flex items-center gap-2 text-sm font-medium">
        <.icon name={@icon} class="size-4" /> {@title}
      </div>
      <p :if={@off} class="mt-1 text-xs text-base-content/60">Not accepted on this server.</p>
      <div :if={!@off}>
        <p class="mt-1 text-xs text-base-content/60">{@hint}</p>
        <%!-- The input stays put once a file is chosen: LiveView sends the file
              through it, so it must outlive the button that opened it. --%>
        <label class={["btn btn-outline btn-xs mt-3", @upload.entries != [] && "hidden"]}>
          Choose file <.live_file_input upload={@upload} class="hidden" />
        </label>
        <div :for={entry <- @upload.entries} class="mt-3 flex items-center gap-2 text-xs">
          <span class="min-w-0 flex-1 truncate">{entry.client_name}</span>
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="cancel-upload"
            phx-value-slot={@upload.name}
            phx-value-ref={entry.ref}
            aria-label="Remove"
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </div>
        <p :for={err <- upload_errors(@upload)} class="mt-1 text-xs text-error">
          {upload_error(err)}
        </p>
        <p
          :for={err <- Enum.flat_map(@upload.entries, &upload_errors(@upload, &1))}
          class="mt-1 text-xs text-error"
        >
          {upload_error(err)}
        </p>
      </div>
    </div>
    """
  end

  defp upload_error(:too_large), do: "That file is larger than this server takes."
  defp upload_error(:not_accepted), do: "That kind of file isn't taken here."
  defp upload_error(:too_many_files), do: "One file at a time."
  defp upload_error(other), do: to_string(other)
end

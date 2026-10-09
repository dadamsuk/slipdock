defmodule SlipdockWeb.MeetingLive.Speakers do
  @moduledoc """
  *Who said what* (screen 3b): a card per voice — a few of its lines to
  replay, the person it is believed to be and why, and confirm or change —
  and the lines whose speaker is unsure that a finding depends on. Changing a
  voice re-derives the findings that took their owner or decision-maker from
  it (`Slipdock.Meetings.Speakers.reassign/3`).
  """
  use SlipdockWeb, :live_view

  import Ecto.Query, warn: false
  import SlipdockWeb.MeetingLive.Components

  alias Slipdock.{Meetings, Repo}
  alias Slipdock.Meetings.{Speakers, Utterance, Voice}
  alias SlipdockWeb.MeetingLive.Access

  on_mount {SlipdockWeb.MeetingsHook, :require_enabled}

  @impl true
  def mount(%{"id" => id, "capture_id" => capture_id}, _session, socket) do
    with {:ok, socket} <- Access.mount_board(socket, id, :read),
         cid when is_integer(cid) <- SlipdockWeb.Params.id(capture_id),
         %Meetings.Capture{board_id: board_id} = capture when board_id == socket.assigns.board.id <-
           Meetings.get_capture(cid) do
      if connected?(socket), do: Meetings.subscribe(capture)

      {:ok,
       socket
       |> assign(
         page_title: "Who said what · #{capture.title}",
         members: Slipdock.Wiki.Links.members(socket.assigns.board),
         error: nil
       )
       |> load(capture)}
    else
      {:error, socket} -> {:ok, socket}
      _ -> {:ok, push_navigate(socket, to: ~p"/boards/#{socket.assigns.board}/meetings")}
    end
  end

  defp load(socket, capture) do
    voices =
      Repo.all(
        from(v in Voice,
          where: v.capture_id == ^capture.id and is_nil(v.merged_into_id),
          order_by: v.id,
          preload: [:confirmed_by]
        )
      )

    lines =
      Repo.all(from(u in Utterance, where: u.capture_id == ^capture.id, order_by: u.position))

    assign(socket,
      capture: Repo.preload(capture, [:owner], force: true),
      voices: voices,
      lines_by_voice: Enum.group_by(lines, & &1.voice_id),
      unsure: Speakers.unsure_lines_that_matter(capture),
      people: people(socket.assigns.members, capture)
    )
  end

  defp people(members, capture) do
    attendees =
      for a <- capture.attendees || [],
          is_nil(a["user_id"]),
          name = a["name"] || a["email"],
          do: {"name:" <> name, name}

    Enum.map(members, &{"user:#{&1.id}", &1.name || &1.email}) ++ attendees
  end

  @impl true
  def handle_info({:capture_changed, id}, socket),
    do: {:noreply, load(socket, Meetings.get_capture!(id))}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("assign", %{"voice" => voice_id, "who" => who} = params, socket) do
    with true <- socket.assigns.can_write,
         %Voice{} = voice <- Enum.find(socket.assigns.voices, &(to_string(&1.id) == voice_id)) do
      choice =
        case who do
          "user:" <> id -> %{"user_id" => SlipdockWeb.Params.id(id) || -1}
          "name:" <> name -> %{"name" => name}
          "other" -> %{"name" => params["other"]}
          _ -> %{}
        end

      case Speakers.reassign(voice, choice, socket.assigns.current_user) do
        {:ok, _} ->
          {:noreply,
           socket |> assign(error: nil) |> load(Meetings.get_capture!(voice.capture_id))}

        {:error, message} ->
          {:noreply, assign(socket, error: message)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  defp confidence_label("sure"), do: {"sure", "badge-success"}
  defp confidence_label("confirm"), do: {"please confirm", "badge-warning"}
  defp confidence_label("confirmed"), do: {"confirmed", "badge-primary"}
  defp confidence_label(_), do: {"unknown", "badge-ghost"}

  defp clip_src(capture, line) do
    if capture.audio_key && line.start_ms do
      stop = (line.end_ms || line.start_ms + 5_000) / 1000
      "/captures/#{capture.id}/audio#t=#{line.start_ms / 1000},#{stop}"
    end
  end

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

      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-4xl space-y-5 p-4 sm:p-6">
          <header class="flex flex-wrap items-center gap-3">
            <h1 class="flex-1 text-xl font-semibold">Who said what</h1>
            <.link
              navigate={~p"/boards/#{@board}/meetings/#{@capture.id}"}
              class="btn btn-ghost btn-sm"
            >
              Back to the meeting
            </.link>
          </header>
          <p class="text-sm text-base-content/60">
            Who said something decides who owns an action and who made a decision. Changing a voice
            here changes those findings too; nothing else is read again.
          </p>
          <p :if={!@capture.audio_key} class="text-xs text-base-content/60">
            {if @capture.audio_purged_at,
              do: "The recording has been deleted, so there are no clips to replay.",
              else:
                "There is no recording, so there are no clips to replay: the lines are what there is."}
          </p>
          <p
            :if={@error}
            id="speakers-error"
            role="alert"
            class="rounded-xl bg-error/10 px-4 py-2 text-sm text-error"
          >
            {@error}
          </p>

          <p
            :if={@voices == []}
            class="rounded-xl bg-base-100 p-4 text-sm text-base-content/60 ring-1 ring-base-content/10"
          >
            Nothing in this meeting says who was speaking.
          </p>

          <div class="grid gap-4 md:grid-cols-2">
            <article
              :for={v <- @voices}
              id={"voice-#{v.id}"}
              data-confidence={v.confidence}
              class="rounded-xl bg-base-100 p-4 ring-1 ring-base-content/10"
            >
              <div class="flex items-center gap-2">
                <span class="font-mono text-xs text-base-content/50">{v.label}</span>
                <span class="flex-1 font-medium">{v.name || "Not known yet"}</span>
                <span class={["badge badge-sm", elem(confidence_label(v.confidence), 1)]}>
                  {elem(confidence_label(v.confidence), 0)}
                </span>
              </div>

              <ul class="mt-2 space-y-1 text-sm">
                <li
                  :for={line <- Enum.take(Map.get(@lines_by_voice, v.id, []), 3)}
                  class="flex items-center gap-2"
                >
                  <audio
                    :if={clip_src(@capture, line)}
                    controls
                    preload="none"
                    src={clip_src(@capture, line)}
                    class="h-7 w-36 shrink-0"
                  ></audio>
                  <span class="min-w-0">
                    <span class="font-mono text-2xs text-base-content/40">{line.line_id}</span>
                    {String.slice(line.text, 0, 120)}
                  </span>
                </li>
              </ul>

              <ul
                :if={v.evidence != []}
                id={"evidence-#{v.id}"}
                class="mt-2 space-y-0.5 text-xs text-base-content/70"
              >
                <li :for={e <- v.evidence}>· {e["detail"]}</li>
              </ul>

              <form
                :if={@can_write}
                id={"assign-#{v.id}"}
                phx-submit="assign"
                class="mt-3 flex flex-wrap items-center gap-2"
              >
                <input type="hidden" name="voice" value={v.id} />
                <select name="who" class="select select-xs" aria-label="Who this is">
                  <option
                    :for={{value, label} <- @people}
                    value={value}
                    selected={
                      value == "user:#{v.user_id}" or
                        (is_nil(v.user_id) and value == "name:#{v.name}")
                    }
                  >
                    {label}
                  </option>
                  <option value="other">Someone else…</option>
                </select>
                <input
                  type="text"
                  name="other"
                  placeholder="Name"
                  class="input input-xs w-28"
                  aria-label="Someone else's name"
                />
                <button type="submit" class="btn btn-primary btn-xs">
                  {if v.confidence == "confirmed", do: "Change", else: "Confirm"}
                </button>
              </form>
            </article>
          </div>

          <section :if={@unsure != []} id="unsure-lines" class="rounded-xl bg-warning/10 p-4 text-sm">
            <h2 class="font-medium">Lines whose speaker is unsure, that something depends on</h2>
            <ul class="mt-1 space-y-1">
              <li :for={line <- @unsure} id={"unsure-#{line.line_id}"}>
                <span class="font-mono text-2xs text-base-content/50">{line.line_id} {clock(
                  line.start_ms
                )}</span>
                {line.text}
              </li>
            </ul>
            <p class="mt-1 text-xs text-base-content/60">
              They are asked about on the meeting's review, where each one matters.
            </p>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

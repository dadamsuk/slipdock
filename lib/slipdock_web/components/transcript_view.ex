defmodule SlipdockWeb.TranscriptView do
  @moduledoc """
  A WebVTT transcript as the turns of a conversation: each speaker's turn
  under their name, in a colour of their own, with the time it starts.

  One view for both places a transcript turns up, so they cannot drift: a
  `.vtt` file opened in the file viewer (`SlipdockWeb.FileViewer`, #774) and
  a ` ```vtt ` block in a wiki page (`SlipdockWeb.Wiki.Renderer`, W-1690),
  which is how a meeting page carries its transcript.

  Each turn carries `data-start-ms` and `data-end-ms`, and the list
  `data-transcript`, for the player (`assets/js/transcript_player.js`) to
  highlight, follow and seek by.

  Tags pressed during the recording (`Slipdock.Wiki.TranscriptTags`, #785)
  sit inline where they were pressed, each a chip with its time and
  `data-seek-ms` for the player to jump to.
  """
  use Phoenix.Component

  alias Slipdock.Wiki.{TranscriptTags, Viewer}

  attr :transcript, :map, required: true, doc: "what `Slipdock.Wiki.Viewer.transcript/2` reads"
  attr :id, :string, default: nil
  attr :class, :string, default: "mx-auto max-w-3xl"
  attr :tags, :list, default: [], doc: "`Slipdock.Wiki.TranscriptTags.parse/1`'s"

  def transcript(assigns) do
    marks = TranscriptTags.place(assigns.transcript.turns, assigns.tags)

    # `block_html/2` calls this by hand, with a plain map.
    assigns =
      if Map.has_key?(assigns, :__changed__),
        do: assign(assigns, :marks, marks),
        else: Map.put(assigns, :marks, marks)

    ~H"""
    <article id={@id} class={["wiki-transcript", @class]} data-transcript>
      <p
        id={@id && "#{@id}-summary"}
        class="wiki-transcript-summary mb-4 text-xs text-base-content/60"
      >
        {clock(@transcript.duration_ms)} · {count(length(@transcript.speakers), "speaker")} · {count(
          length(@transcript.turns),
          "turn"
        )}
      </p>
      <ol class="space-y-4">
        <li
          :for={{turn, t} <- Enum.with_index(@transcript.turns)}
          class="wiki-transcript-turn grid grid-cols-[4rem_1fr] gap-x-3 rounded-lg"
          data-speaker={turn.speaker}
          data-start-ms={turn.start_ms}
          data-end-ms={turn[:end_ms]}
        >
          <time class="pt-0.5 text-right font-mono text-xs text-base-content/50 tabular-nums">
            {turn.start_ms && clock(turn.start_ms)}
          </time>
          <div class={["border-l-4 pl-3", speaker_colour(turn.speaker, @transcript.speakers)]}>
            <p :if={turn.speaker} class="text-sm font-semibold">{turn.speaker}</p>
            <p
              :for={{line, l} <- Enum.with_index(turn.lines)}
              class="leading-relaxed text-base-content"
            >
              <.segment :for={segment <- segments(line, @marks[{t, l}])} segment={segment} />
            </p>
          </div>
        </li>
      </ol>
    </article>
    """
  end

  attr :segment, :any, required: true

  defp segment(%{segment: {:tag, tag}} = assigns) do
    assigns = assign(assigns, :tag, tag)

    ~H"""
    <span
      class="wiki-transcript-tag badge badge-sm badge-warning cursor-pointer align-middle font-mono"
      data-tag={@tag.tag}
      data-seek-ms={@tag.ms}
      title={"Tagged ##{@tag.tag} at #{clock(@tag.ms)}"}
    >#{@tag.tag} {clock(@tag.ms)}</span>
    """
  end

  defp segment(%{segment: {:text, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"{@text}"
  end

  # A line as its text, cut where tags were placed in it. Without tags it is
  # the line exactly as written.
  defp segments(line, nil), do: [{:text, line}]

  defp segments(line, marks) do
    words = TranscriptTags.words(line)
    at = Enum.group_by(marks, &elem(&1, 0), &elem(&1, 1))

    0..length(words)
    |> Enum.flat_map(fn i ->
      tags = Enum.map(Map.get(at, i, []), &{:tag, &1})
      word = if i < length(words), do: [{:text, Enum.at(words, i)}], else: []
      tags ++ word
    end)
    |> Enum.intersperse({:text, " "})
  end

  @doc """
  A ` ```vtt ` block's text as HTML for a wiki page, with the page's timed
  `tags` placed in it: the transcript, or a
  quiet note when there is nothing to show — "No speech detected." for a
  recording nobody spoke in (Manuel2 writes `NOTE No speech detected.`),
  "No transcript." for anything else without a cue that has words.
  """
  def block_html(text, tags \\ []) when is_binary(text) do
    case Viewer.transcript(text) do
      {:ok, transcript} ->
        %{transcript: transcript, id: nil, class: "wiki-transcript-block my-4", tags: tags}
        |> transcript()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      {:error, _} ->
        note =
          if text =~ ~r/No speech detected/i, do: "No speech detected.", else: "No transcript."

        ~s|<p class="wiki-transcript-empty text-sm italic text-base-content/50">#{note}</p>|
    end
  end

  # Written out whole so Tailwind keeps them; a speaker's colour is their place
  # in the order people first speak, so it stays put down the transcript.
  # Plain hues rather than the theme's, few of which tell apart; the -500s
  # read on a light page and a dark one.
  @speaker_colours [
    "border-sky-500 text-sky-500",
    "border-amber-500 text-amber-500",
    "border-emerald-500 text-emerald-500",
    "border-rose-500 text-rose-500",
    "border-violet-500 text-violet-500",
    "border-teal-500 text-teal-500"
  ]

  defp speaker_colour(nil, _speakers), do: "border-base-300"

  defp speaker_colour(speaker, speakers) do
    index = Enum.find_index(speakers, &(&1 == speaker)) || 0
    Enum.at(@speaker_colours, rem(index, length(@speaker_colours)))
  end

  @doc "Milliseconds as `m:ss`, or `h:mm:ss` from an hour."
  def clock(ms) do
    s = div(ms, 1000)
    {h, m, s} = {div(s, 3600), div(rem(s, 3600), 60), rem(s, 60)}
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(s)}", else: "#{m}:#{pad.(s)}"
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end

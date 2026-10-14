defmodule SlipdockWeb.FileViewer do
  @moduledoc """
  A wiki file that is not a page, shown rather than downloaded: the panel
  the wiki opens beside the page (`SlipdockWeb.WikiLive.Index`, #768) and
  the page of its own at `/files/:id` (`SlipdockWeb.FileLive`) both draw it
  with `viewer/1`. Which viewer it gets is `Slipdock.Wiki.Viewer.kind/1`'s
  to say:

    * an image is an `<img>`, an SVG too, served with a policy that lets it
      run nothing (`SlipdockWeb.WikiFileController`, `?view=inline`);
    * a PDF is the browser's own PDF viewer, in a frame;
    * an HTML file is drawn in a sandboxed frame, served with the same
      policy as an SVG: no scripts, no fetching, an origin of its own;
    * audio (.mp3, .m4a and the like) plays in the browser's own player,
      the one a card's attachments have, seeking by byte range (#770);
    * JSON is a tree whose objects and arrays fold, or pretty-printed text
      when it is too big to fold, or the line where it stopped being JSON;
    * CSV and TSV are a table, the first row its header;
    * a WebVTT or SubRip transcript (.vtt, .srt) reads as a conversation:
      each speaker's turn under their name, in a colour of their own, with
      the time it starts (#774);
    * plain text is itself.

  Anything else, and anything too big to read here, says so and offers the
  download.
  """
  use SlipdockWeb, :html

  alias Slipdock.{Access, Repo}
  alias Slipdock.Wiki.{Files, Viewer, WikiFile}

  @doc """
  The file with id `id` and what its viewer needs, for `user`:
  `{:ok, %{file: file, kind: kind, ...}}`, or `:error` when it isn't there,
  is archived, or is on a board they can't read.
  """
  def load(user, id) do
    with n when is_integer(n) <- SlipdockWeb.Params.id(id),
         %WikiFile{archived_at: nil} = file <- Files.get(n),
         file = Repo.preload(file, [:board, :folder]),
         true <- Access.can_read?(Access.board_permission(user, file.board)) do
      kind = Viewer.kind(file)
      {:ok, Map.merge(%{file: file, kind: kind}, content(file, kind))}
    else
      _ -> :error
    end
  end

  # What the server reads for the viewer: nothing for what the browser draws.
  defp content(file, kind) when kind in [:json, :csv, :tsv, :transcript, :text] do
    case Viewer.read(file) do
      {:ok, text} ->
        parsed(kind, text, file.name)

      {:error, :too_large} ->
        %{problem: "It is too big to show here (over #{size(Viewer.max_text())})."}

      {:error, :not_text} ->
        %{problem: "It isn't text this viewer can read."}

      {:error, :missing} ->
        %{problem: "Its contents are missing on the server."}
    end
  end

  defp content(_file, _kind), do: %{}

  defp parsed(:json, text, name) do
    case Viewer.json(text, name) do
      {:ok, tree, pretty} -> %{tree: tree, text: pretty}
      {:error, message} -> %{problem: message, text: text}
    end
  end

  defp parsed(:csv, text, _name), do: %{table: Viewer.csv(text, ?,)}
  defp parsed(:tsv, text, _name), do: %{table: Viewer.csv(text, ?\t)}
  defp parsed(:text, text, _name), do: %{text: text}

  defp parsed(:transcript, text, name) do
    case Viewer.transcript(text, name) do
      {:ok, transcript} -> %{transcript: transcript}
      {:error, message} -> %{problem: message, text: text}
    end
  end

  @doc "A file's size, the way the viewer's header gives it."
  def size(bytes) when bytes < 1_000, do: "#{bytes} bytes"
  def size(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  def size(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp inline_url(file), do: Files.url(file) <> "?view=inline"

  attr :kind, :atom, required: true
  attr :file, WikiFile, required: true
  attr :tree, :any, default: nil
  attr :text, :string, default: nil
  attr :table, :map, default: nil
  attr :transcript, :map, default: nil
  attr :problem, :string, default: nil

  def viewer(%{problem: problem} = assigns) when is_binary(problem) do
    ~H"""
    <div id="file-problem" class="alert alert-warning mb-4">
      <.icon name="hero-exclamation-triangle" class="size-5" />
      <span>{@problem}</span>
    </div>
    <pre :if={@text} id="file-text" class="text-sm whitespace-pre-wrap break-words">{@text}</pre>
    """
  end

  def viewer(%{kind: kind} = assigns) when kind in [:image, :svg] do
    ~H"""
    <div class="flex justify-center">
      <img
        id="file-image"
        src={if @kind == :svg, do: inline_url(@file), else: Files.url(@file)}
        alt={@file.name}
        class="max-w-full h-auto bg-[repeating-conic-gradient(#8881_0_25%,transparent_0_50%)] bg-[length:16px_16px]"
      />
    </div>
    """
  end

  def viewer(%{kind: :pdf} = assigns) do
    ~H"""
    <iframe
      id="file-pdf"
      src={inline_url(@file)}
      title={@file.name}
      class="h-full min-h-[70vh] w-full rounded border border-base-300"
    ></iframe>
    """
  end

  def viewer(%{kind: :html} = assigns) do
    ~H"""
    <iframe
      id="file-html"
      src={inline_url(@file)}
      title={@file.name}
      sandbox=""
      referrerpolicy="no-referrer"
      class="h-full min-h-[70vh] w-full rounded border border-base-300 bg-white"
    ></iframe>
    """
  end

  # preload="metadata" fetches its length and no more until play is pressed.
  def viewer(%{kind: :audio} = assigns) do
    ~H"""
    <div class="mx-auto max-w-xl py-8">
      <audio
        id="file-audio"
        controls
        preload="metadata"
        src={inline_url(@file)}
        class="w-full"
      ></audio>
    </div>
    """
  end

  def viewer(%{kind: :json, tree: tree} = assigns) when not is_nil(tree) do
    ~H"""
    <div id="file-json" class="font-mono text-sm">
      <.json_node node={@tree} depth={0} />
    </div>
    """
  end

  def viewer(%{kind: kind, table: %{}} = assigns) when kind in [:csv, :tsv] do
    ~H"""
    <p
      :if={@table.total > length(@table.rows)}
      id="file-table-cut"
      class="mb-2 text-xs text-base-content/60"
    >
      Showing the first {length(@table.rows)} of {@table.total} rows. Download it for the rest.
    </p>
    <p :if={@table.header == []} class="text-sm text-base-content/60">This file is empty.</p>
    <table :if={@table.header != []} id="file-table" class="table table-zebra table-pin-rows table-sm">
      <thead>
        <tr>
          <th :for={cell <- @table.header}>{cell}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @table.rows}>
          <td :for={cell <- row} class="whitespace-pre-wrap align-top">{cell}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  def viewer(%{kind: :transcript, transcript: %{}} = assigns) do
    ~H"""
    <article id="file-transcript" class="mx-auto max-w-3xl">
      <p id="file-transcript-summary" class="mb-4 text-xs text-base-content/60">
        {clock(@transcript.duration_ms)} · {count(length(@transcript.speakers), "speaker")} · {count(
          length(@transcript.turns),
          "turn"
        )}
      </p>
      <ol class="space-y-4">
        <li
          :for={turn <- @transcript.turns}
          class="grid grid-cols-[4rem_1fr] gap-x-3"
          data-speaker={turn.speaker}
        >
          <time class="pt-0.5 text-right font-mono text-xs text-base-content/50 tabular-nums">
            {turn.start_ms && clock(turn.start_ms)}
          </time>
          <div class={["border-l-4 pl-3", speaker_colour(turn.speaker, @transcript.speakers)]}>
            <p :if={turn.speaker} class="text-sm font-semibold">{turn.speaker}</p>
            <p :for={line <- turn.lines} class="leading-relaxed text-base-content">{line}</p>
          </div>
        </li>
      </ol>
    </article>
    """
  end

  def viewer(%{text: text} = assigns) when is_binary(text) do
    ~H"""
    <pre id="file-text" class="text-sm whitespace-pre-wrap break-words">{@text}</pre>
    """
  end

  def viewer(assigns) do
    ~H"""
    <div id="file-none" class="mx-auto max-w-md py-12 text-center text-sm text-base-content/70">
      <.icon name="hero-document" class="size-10 opacity-50" />
      <p class="mt-2">There's no viewer for this kind of file yet.</p>
      <a href={Files.url(@file)} class="btn btn-primary btn-sm mt-4" download>Download it</a>
    </div>
    """
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

  attr :node, :any, required: true
  attr :depth, :integer, required: true
  attr :key, :string, default: nil

  # A value on one line; an object or array folds, the outer two levels open.
  defp json_node(%{node: {:value, _}} = assigns) do
    ~H"""
    <div class="pl-4">
      <span :if={@key} class="text-primary">{Jason.encode!(@key)}: </span><span class={
        value_class(@node)
      }>{elem(@node, 1)}</span>
    </div>
    """
  end

  defp json_node(%{node: {type, children}} = assigns) do
    assigns = assign(assigns, type: type, children: children)

    ~H"""
    <details open={@depth < 2} class="pl-4" data-json={@type}>
      <summary class="cursor-pointer select-none">
        <span :if={@key} class="text-primary">{Jason.encode!(@key)}: </span><span class="text-base-content/60">{summary(
          @type,
          @children
        )}</span>
      </summary>
      <%= for child <- @children do %>
        <%= if @type == :object do %>
          <.json_node node={elem(child, 1)} key={elem(child, 0)} depth={@depth + 1} />
        <% else %>
          <.json_node node={child} depth={@depth + 1} />
        <% end %>
      <% end %>
    </details>
    """
  end

  defp summary(:object, children),
    do: "{…} #{length(children)} #{if length(children) == 1, do: "key", else: "keys"}"

  defp summary(:array, children),
    do: "[…] #{length(children)} #{if length(children) == 1, do: "item", else: "items"}"

  defp value_class({:value, "\"" <> _}), do: "text-success"
  defp value_class({:value, v}) when v in ["true", "false", "null"], do: "text-warning"
  defp value_class(_), do: "text-info"
end

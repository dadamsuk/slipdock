defmodule SlipdockWeb.BoardLive.CardPanel.Attachments do
  @moduledoc """
  The card panel's files: the list of attachments with what was read or
  transcribed from each, and the uploads under way. Drawn by
  `BoardLive.CardPanel`, which passes it the assigns it reads, by name.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.{Boards, Transcription}
  alias Slipdock.Boards.{Attachment, Card}
  alias Slipdock.OCR.Text, as: OCRText

  attr :can_write, :boolean, required: true
  attr :card, Card, required: true
  attr :target, :any, required: true
  attr :uploads, :map, required: true

  attr :at, :string,
    default: nil,
    doc:
      "where a search result points (`transcript-5-part-2`): that transcript opens at that part"

  attr :transcribe, :boolean,
    default: false,
    doc: "whether a transcription server is set up, so recordings offer Transcribe"

  @doc "The card's files, and the uploads under way."
  def attachments_section(assigns) do
    ~H"""
    <section
      id="card-attachments"
      class="space-y-2 rounded-xl px-1 transition-colors"
      phx-drop-target={@uploads.attachment.ref}
      data-section-key="a"
    >
      <div class="flex items-center justify-between">
        <h3 class="flex items-center gap-1.5 section-label">
          <.icon name="hero-paper-clip" class="size-3.5" />
          <.keyed_label key="a" label="Attachments" />
          <span :if={@card.attachments != []} class="font-normal">({length(@card.attachments)})</span>
        </h3>
        <form
          :if={@can_write}
          phx-target={@target}
          id="attach-form"
          phx-change="validate_attachments"
          phx-submit="validate_attachments"
        >
          <label class="btn btn-ghost btn-xs cursor-pointer">
            <.icon name="hero-arrow-up-tray" class="size-3.5" /> Attach
            <.live_file_input upload={@uploads.attachment} class="hidden" />
          </label>
        </form>
      </div>
      <ul :if={@card.attachments != []} class="grid grid-cols-1 gap-2 sm:grid-cols-2">
        <li
          :for={a <- @card.attachments}
          id={"attachment-#{a.id}"}
          class={[
            "group flex flex-wrap items-center gap-3 rounded-xl bg-base-200/70 p-2",
            Attachment.audio?(a) && "sm:col-span-2"
          ]}
        >
          <a
            href={Boards.Attachments.attachment_url(a)}
            target="_blank"
            rel="noopener"
            class="flex size-12 shrink-0 items-center justify-center overflow-hidden rounded-lg bg-base-300/60"
            title={a.filename}
          >
            <img
              :if={Attachment.image?(a)}
              src={Boards.Attachments.attachment_url(a)}
              alt={a.filename}
              loading="lazy"
              class="size-full object-cover"
            />
            <.icon
              :if={not Attachment.image?(a)}
              name={attachment_icon(a)}
              class="size-6 text-base-content/50"
            />
          </a>
          <div class="min-w-0 flex-1">
            <a
              href={Boards.Attachments.attachment_url(a)}
              target="_blank"
              rel="noopener"
              class="block truncate text-sm font-medium hover:underline"
            >
              {a.filename}
            </a>
            <p class="text-xs text-base-content/50">
              {file_size(a.size)} · {relative_time(a.inserted_at)}
            </p>
            <label
              :if={Attachment.image?(a)}
              class={[
                "mt-0.5 flex items-center gap-1.5 text-xs text-base-content/60",
                @can_write && "cursor-pointer"
              ]}
              title="The card's front shows the first image that isn't ticked here, unless Display leaves images out"
            >
              <input
                type="checkbox"
                id={"hide-on-card-#{a.id}"}
                class="checkbox"
                checked={a.hide_on_card}
                disabled={!@can_write}
                phx-target={@target}
                phx-click="hide_on_card"
                phx-value-id={a.id}
                phx-value-hide={to_string(!a.hide_on_card)}
              /> Don't show on the card front
            </label>
          </div>
          <button
            :if={@can_write}
            phx-target={@target}
            type="button"
            class="btn btn-ghost btn-xs btn-square shrink-0 opacity-0 group-hover:opacity-100 focus:opacity-100 no-hover:opacity-100"
            phx-click="delete_attachment"
            phx-value-id={a.id}
            data-confirm={"Delete #{a.filename}?"}
            title="Delete attachment"
          >
            <.icon name="hero-trash" class="size-3.5" />
          </button>
          <%!-- A recording plays where it is. preload="metadata" fetches its
                length and no more until somebody presses play. --%>
          <audio
            :if={Attachment.audio?(a)}
            id={"audio-#{a.id}"}
            controls
            preload="metadata"
            src={Boards.Attachments.attachment_url(a)}
            class="h-9 min-w-0 flex-1 basis-60"
          ></audio>
          <button
            :if={Attachment.audio?(a) and @transcribe and @can_write}
            id={"transcribe-#{a.id}"}
            phx-target={@target}
            type="button"
            class="btn btn-ghost btn-xs shrink-0"
            phx-click="transcribe"
            phx-value-id={a.id}
            disabled={Transcription.running?(a)}
            title="Send the recording to the transcription server"
          >
            <span :if={Transcription.running?(a)} class="loading loading-spinner loading-xs"></span>
            <.icon :if={not Transcription.running?(a)} name="hero-language" class="size-3.5" />
            {transcribe_label(a)}
          </button>
          <p
            :if={a.transcript_status == "failed" and not Transcription.running?(a)}
            id={"transcript-error-#{a.id}"}
            class="basis-full text-xs text-error"
          >
            Couldn't transcribe it: {a.transcript_error}
          </p>
          <details
            :if={a.transcript_status == "done"}
            id={"transcript-#{a.id}"}
            open={opened_at?(@at, a)}
            class="basis-full rounded-lg bg-base-100/70 px-2 py-1 text-sm"
          >
            <summary class="cursor-pointer text-xs font-medium text-base-content/60">
              Transcript
            </summary>
            <%!-- Silence is not an error: the server answers with no text. --%>
            <p :if={a.transcript in [nil, ""]} class="mt-1 text-xs text-base-content/50">
              No speech was found in the recording.
            </p>
            <%!-- Drawn in the parts search indexes it in, so a result can land
                  on the one that matched (see `SlipdockWeb.SearchLinks`). --%>
            <div :if={a.transcript not in [nil, ""]} class="mt-1 max-h-80 overflow-y-auto">
              <p
                :for={
                  {part, n} <-
                    Enum.with_index(Slipdock.Search.Chunk.transcript_parts(a.transcript), 1)
                }
                id={"transcript-#{a.id}-part-#{n}"}
                class={[
                  "whitespace-pre-wrap rounded",
                  @at == "transcript-#{a.id}-part-#{n}" && "bg-warning/15"
                ]}
                phx-no-format
              >{part}</p>
            </div>
          </details>
          <.document_text attachment={a} at={@at} target={@target} can_write={@can_write} />
        </li>
      </ul>
      <div
        :for={entry <- @uploads.attachment.entries}
        id={"upload-#{entry.ref}"}
        class="flex items-center gap-3 rounded-xl bg-base-200/40 px-3 py-2"
      >
        <.icon name="hero-arrow-up-tray" class="size-4 shrink-0 text-base-content/50" />
        <div class="min-w-0 flex-1 space-y-1">
          <p class="truncate text-xs">{entry.client_name}</p>
          <progress
            class="progress progress-primary h-1 w-full"
            value={entry.progress}
            max="100"
          ></progress>
        </div>
        <button
          phx-target={@target}
          type="button"
          class="btn btn-ghost btn-xs btn-square"
          phx-click="cancel_upload"
          phx-value-name="attachment"
          phx-value-ref={entry.ref}
          title="Cancel upload"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>
      <%!-- With nothing attached, one line (#1728): a drop zone that is
            also the file picker's label. --%>
      <label
        :if={@card.attachments == [] and @uploads.attachment.entries == [] and @can_write}
        for={@uploads.attachment.ref}
        data-role="drop-zone"
        class="flex cursor-pointer items-center gap-2 truncate rounded-lg border border-dashed border-base-content/15 px-3 py-1.5 text-xs text-base-content/50 transition-colors hover:border-primary/40 hover:text-base-content/70"
        title="You can also paste images straight into the description or a comment"
      >
        <.icon name="hero-arrow-up-tray" class="size-3.5 shrink-0" />
        <span class="truncate">Drop files here or click to attach</span>
      </label>
    </section>
    """
  end

  defp opened_at?(at, a) when is_binary(at),
    do: String.starts_with?(at <> "-", "transcript-#{a.id}-")

  defp opened_at?(_at, _a), do: false

  # What was read from a PDF or an image (see `Slipdock.OCR`). Waiting in the
  # queue shows nothing: it is background work that nobody asked for, and a
  # file with no words in it simply never shows anything either.
  attr :attachment, :map, required: true
  attr :at, :any, default: nil
  attr :target, :any, required: true
  attr :can_write, :boolean, default: false

  defp document_text(%{attachment: %{document_text: %OCRText{} = read}} = assigns) do
    assigns = assign(assigns, read: read, a: assigns.attachment)

    ~H"""
    <p
      :if={@read.status == "running"}
      id={"document-reading-#{@a.id}"}
      class="basis-full text-xs text-base-content/50"
    >
      <span class="loading loading-spinner loading-xs"></span> Reading the text…
    </p>
    <p
      :if={@read.status == "failed"}
      id={"document-error-#{@a.id}"}
      class="basis-full text-xs text-error"
    >
      Couldn't read the text: {@read.error}
      <button
        :if={@can_write}
        id={"read-text-#{@a.id}"}
        phx-target={@target}
        type="button"
        class="link"
        phx-click="read_text"
        phx-value-id={@a.id}
      >
        Try again
      </button>
    </p>
    <details
      :if={OCRText.readable?(@read)}
      id={"document-#{@a.id}"}
      open={@at && String.starts_with?(@at <> "-", "document-#{@a.id}-")}
      class="basis-full rounded-lg bg-base-100/70 px-2 py-1 text-sm"
    >
      <summary class="cursor-pointer text-xs font-medium text-base-content/60">
        Text in this file <span :if={@read.truncated} class="font-normal">(the start of it)</span>
      </summary>
      <div class="mt-1 max-h-80 overflow-y-auto">
        <p
          :for={{part, n} <- Enum.with_index(Slipdock.Search.Chunk.document_parts(@read.text), 1)}
          id={"document-#{@a.id}-part-#{n}"}
          class={[
            "whitespace-pre-wrap rounded",
            @at == "document-#{@a.id}-part-#{n}" && "bg-warning/15"
          ]}
          phx-no-format
        >{part}</p>
      </div>
    </details>
    """
  end

  defp document_text(assigns), do: ~H""

  defp transcribe_label(a) do
    cond do
      Transcription.running?(a) -> "Transcribing…"
      a.transcript_status == "done" -> "Transcribe again"
      a.transcript_status == "failed" -> "Try again"
      true -> "Transcribe"
    end
  end
end

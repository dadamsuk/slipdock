defmodule Slipdock.OCR do
  @moduledoc """
  Reads the words out of uploaded PDFs and images, so that search can find
  them (#1527). See `Slipdock.OCR.Extractor` for the reading.

  There is no job library here, so the `document_texts` rows are the queue:
  an upload adds a `queued` row, and `Slipdock.OCR.Worker` works through them
  one at a time, oldest first. That makes it survive a restart, and one at a
  time is what keeps a 300-page scan from taking the server's CPU with it.

  The scheduler's tick calls `sweep/0`, which puts back a job a restart left
  `running` and adds files that have no row: everything uploaded before this
  existed, a few at a time, so there is nothing to run after a deploy. On a
  machine without the programs the rows simply wait.

  Text finished here goes to `Slipdock.Search.Chunk` through the indexer; it
  is not itself a search index.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.Attachment
  alias Slipdock.OCR.{Extractor, Text, Worker}
  alias Slipdock.Search.Indexer
  alias Slipdock.Wiki.{Files, WikiFile}

  # A job marked running for longer than the extractor's own deadline allows
  # was cut off by a restart.
  @stale_after_seconds 2 * 60 * 60
  # A file that has taken the job down this often is not tried again.
  @max_attempts 3
  @backfill_per_tick 25

  @doc "Whether this kind of file is read at all."
  def readable?(%Attachment{content_type: type, filename: name}),
    do: Extractor.kind(type, name) != nil

  def readable?(%WikiFile{content_type: type, name: name}), do: Extractor.kind(type, name) != nil

  @doc "Queues a newly stored file, if it is one that gets read. Safe to call again."
  def enqueue(source) do
    if readable?(source) do
      Repo.insert_all(Text, [row(source)], on_conflict: :nothing)
      Worker.nudge()
    end

    :ok
  end

  @doc """
  The file's bytes have changed: what was read from the old ones is dropped
  and it is read again, or the row goes if it is no longer a file that is read.
  """
  def requeue(%WikiFile{} = file) do
    if readable?(file) do
      reset(from(t in Text, where: t.wiki_file_id == ^file.id))
      enqueue(file)
    else
      Repo.delete_all(from(t in Text, where: t.wiki_file_id == ^file.id))
      :ok
    end
  end

  @doc """
  Reads a file again, after it failed or to try for a better result.
  `{:ok, text}`; `{:error, :not_readable}` for a file that is not a PDF or an
  image, `{:error, :running}` while it is being read.
  """
  def retry(%Attachment{} = attachment) do
    if readable?(attachment) do
      enqueue(attachment)
      query = from(t in Text, where: t.attachment_id == ^attachment.id)

      case Repo.one(query) do
        %Text{status: "running"} ->
          {:error, :running}

        %Text{} ->
          reset(query)
          Worker.nudge()
          {:ok, Repo.one(query)}
      end
    else
      {:error, :not_readable}
    end
  end

  @doc "A reason from `retry/1`, as a person reads it."
  def describe(:not_readable), do: "Only PDFs and images are read for text."
  def describe(:running), do: "It is being read already."

  @doc "What has been read from an attachment, or nil."
  def text_of(%Attachment{id: id}), do: Repo.one(from(t in Text, where: t.attachment_id == ^id))

  @doc "A few numbers for a person checking on the queue, as `status => count`."
  def stats do
    from(t in Text, group_by: t.status, select: {t.status, count(t.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Reads the oldest queued file. `:ok` when there may be more, `:none` when
  there is nothing to do, `:unavailable` when this machine can't read files.
  """
  def run_next do
    if Extractor.available?() do
      case claim() do
        nil -> :none
        %Text{} = job -> run(job)
      end
    else
      :unavailable
    end
  end

  @doc "Puts back what a restart cut off, adds a few unread files, and wakes the worker."
  def sweep(now \\ DateTime.utc_now(:second)) do
    if Extractor.available?() do
      recover(now)
      backfill()
      Worker.nudge()
    end

    :ok
  end

  defp row(source) do
    now = DateTime.utc_now(:second)

    {attachment_id, wiki_file_id} =
      case source do
        %Attachment{id: id} -> {id, nil}
        %WikiFile{id: id} -> {nil, id}
      end

    %{
      attachment_id: attachment_id,
      wiki_file_id: wiki_file_id,
      status: "queued",
      inserted_at: now,
      updated_at: now
    }
  end

  defp reset(query) do
    Repo.update_all(query,
      set: [
        status: "queued",
        text: nil,
        error: nil,
        pages: nil,
        ocr_pages: nil,
        truncated: false,
        attempts: 0,
        started_at: nil,
        updated_at: DateTime.utc_now(:second)
      ]
    )
  end

  defp claim do
    now = DateTime.utc_now(:second)

    case Repo.one(from(t in Text, where: t.status == "queued", order_by: [asc: t.id], limit: 1)) do
      nil ->
        nil

      job ->
        {n, _} =
          Repo.update_all(from(t in Text, where: t.id == ^job.id and t.status == "queued"),
            set: [status: "running", started_at: now, updated_at: now],
            inc: [attempts: 1]
          )

        if n == 1, do: job, else: claim()
    end
  end

  defp run(job) do
    job = Repo.preload(job, [:attachment, :wiki_file])

    attrs =
      case read(job) do
        {:ok, result} ->
          [
            status: "done",
            text: result.text,
            error: nil,
            pages: result.pages,
            ocr_pages: result.ocr_pages,
            truncated: result.truncated
          ]

        {:error, reason} ->
          Logger.warning("reading document text #{job.id} failed: #{reason}")
          [status: "failed", text: nil, error: String.slice(reason, 0, 250)]
      end

    finish(job, attrs)
    :ok
  end

  defp read(%Text{attachment: %Attachment{} = a}) do
    Extractor.extract(Boards.attachment_path(a), Extractor.kind(a.content_type, a.filename))
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp read(%Text{wiki_file: %WikiFile{} = f}) do
    Extractor.extract(Files.disk_path(f), Extractor.kind(f.content_type, f.name))
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Only over a job still running: new bytes while it was reading put the row
  # back in the queue, and what was read from the old ones is no use.
  defp finish(job, attrs) do
    {n, _} =
      Repo.update_all(from(t in Text, where: t.id == ^job.id and t.status == "running"),
        set: attrs ++ [updated_at: DateTime.utc_now(:second)]
      )

    if n == 1, do: announce(job)
  end

  defp announce(%Text{attachment: %Attachment{} = a}), do: Boards.attachment_text_changed(a)
  defp announce(%Text{wiki_file: %WikiFile{id: id}}), do: Indexer.enqueue_file(id)

  defp recover(now) do
    cutoff = DateTime.add(now, -@stale_after_seconds, :second)
    stale = from(t in Text, where: t.status == "running" and t.started_at < ^cutoff)

    Repo.update_all(from(t in stale, where: t.attempts >= @max_attempts),
      set: [status: "failed", error: "reading it never finished", updated_at: now]
    )

    Repo.update_all(stale, set: [status: "queued", updated_at: now])
  end

  defp backfill do
    types = Extractor.types()

    attachments =
      from(a in Attachment,
        left_join: t in Text,
        on: t.attachment_id == a.id,
        where: is_nil(t.id),
        where: a.content_type in ^types or like(fragment("lower(?)", a.filename), "%.pdf"),
        order_by: [asc: a.id],
        limit: @backfill_per_tick
      )
      |> Repo.all()

    files =
      from(f in WikiFile,
        left_join: t in Text,
        on: t.wiki_file_id == f.id,
        where: is_nil(t.id) and is_nil(f.archived_at),
        where: f.content_type in ^types or like(fragment("lower(?)", f.name), "%.pdf"),
        order_by: [asc: f.id],
        limit: @backfill_per_tick
      )
      |> Repo.all()

    Enum.each(attachments ++ files, &enqueue/1)
  end
end

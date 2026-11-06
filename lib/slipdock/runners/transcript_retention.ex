defmodule Slipdock.Runners.TranscriptRetention do
  @moduledoc """
  Job logs evaporate unless kept (#1872). A job's live log
  (`Slipdock.Runners.Transcript`) is deleted a set time after the job ends:
  its top board's `job_log_hours` (24 by default), or `failure_log_hours`
  (7 days) for a failure. The job itself, its summary and its counts stay.

  A failure is a job that failed, timed out or was cancelled, or one whose
  work turned out a failure after it ended: its card rejected (the verify
  job's own log too), flagged `stuck` by the health monitor, or put back on
  its list because the job left it in progress. Those set
  `transcript_failed_at`, and the failure time runs from then, so a build
  that ended well and is rejected a day later keeps its log a week from the
  rejection.

  **Keep this log** (`keep/3`) writes the log as a wiki page in the card's
  folder, shaped like the after-job hook's pass log (`Pass <card> (<date>)`),
  links it from the job, and stops the log expiring. Keeping it again links
  the same page.

  Expiry is worked out when asked (`expires_at/2`), never stored, so a board
  whose settings change applies them to every log at once. `sweep/1`, on the
  scheduler's minute, deletes what is past its time.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo
  alias Slipdock.Runners.{Job, Transcript, TranscriptChunk, TranscriptView}

  @failed ~w(failed timeout cancelled)

  @doc "Whether `job`'s log is kept for the failure time."
  def failure?(%Job{transcript_failed_at: %DateTime{}}), do: true
  def failure?(%Job{status: status}), do: Enum.member?(@failed, status)

  @doc """
  When `job`'s log will be deleted, by `board`'s settings (its top board,
  loaded when not given): nil while the job is open, once the log is kept or
  gone, or when there is none.
  """
  def expires_at(%Job{} = job, board \\ nil) do
    cond do
      Job.open?(job) or is_nil(job.finished_at) -> nil
      not is_nil(job.transcript_page_id) -> nil
      job.transcript_bytes == 0 -> nil
      true -> expiry(job, board || top_board(job))
    end
  end

  defp expiry(job, %Board{} = board) do
    {from, hours} =
      if failure?(job),
        do: {job.transcript_failed_at || job.finished_at, board.failure_log_hours},
        else: {job.finished_at, board.job_log_hours}

    DateTime.add(from, hours * 3600, :second)
  end

  defp expiry(job, nil), do: expiry(job, %Board{})

  defp top_board(%Job{root_board_id: id}) when is_integer(id), do: Repo.get(Board, id)
  defp top_board(%Job{board_id: id}), do: id && Repo.get(Board, id)

  @doc """
  Deletes every log past its time, as of `now`: its chunks go, and the job
  says when (`transcript_deleted_at`) with its line and byte counts back to
  0. Answers how many logs went.
  """
  def sweep(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    ids = Repo.all(due(now))

    if ids == [] do
      0
    else
      Repo.transaction(fn ->
        Repo.delete_all(from(c in TranscriptChunk, where: c.job_id in ^ids))

        Repo.update_all(from(j in Job, where: j.id in ^ids),
          set: [
            transcript_lines: 0,
            transcript_bytes: 0,
            transcript_capped: false,
            transcript_deleted_at: now
          ]
        )
      end)

      length(ids)
    end
  end

  # The jobs whose log is due, by their top board's two times. The partial
  # index on finished_at holds only ended jobs with a log nobody kept.
  defp due(now) do
    from(j in Job,
      join: b in Board,
      on: b.id == coalesce(j.root_board_id, j.board_id),
      where:
        j.transcript_bytes > 0 and is_nil(j.transcript_page_id) and not is_nil(j.finished_at) and
          j.status not in ^Job.open_statuses(),
      where:
        fragment(
          "CASE WHEN ? IS NOT NULL OR ? = ANY(?) THEN ? + make_interval(hours => ?) ELSE ? + make_interval(hours => ?) END <= ?",
          j.transcript_failed_at,
          j.status,
          ^@failed,
          coalesce(j.transcript_failed_at, j.finished_at),
          b.failure_log_hours,
          j.finished_at,
          b.job_log_hours,
          ^now
        ),
      select: j.id,
      limit: 500
    )
  end

  @doc """
  Marks the jobs with `ids` as failures from `now`: their logs keep the
  failure time from then. A kept or deleted log is left alone.
  """
  def mark_failed(ids, now \\ DateTime.utc_now())
  def mark_failed([], _now), do: 0

  def mark_failed(ids, now) when is_list(ids) do
    {count, _} =
      Repo.update_all(
        from(j in Job,
          where: j.id in ^ids and is_nil(j.transcript_page_id) and is_nil(j.transcript_deleted_at)
        ),
        set: [transcript_failed_at: DateTime.truncate(now, :second)]
      )

    count
  end

  @doc """
  `card`'s work was rejected or flagged stuck: its latest job that did the
  work and, for a rejection, the verify job that judged it, become failures
  from now.
  """
  def card_failed(card, opts \\ [])

  def card_failed(%Card{id: card_id}, opts) do
    kinds = if opts[:verify] == false, do: ["work"], else: ["work", "verify"]

    kinds
    |> Enum.map(&latest_job(card_id, &1))
    |> Enum.reject(&is_nil/1)
    |> mark_failed(opts[:now] || DateTime.utc_now())
  end

  def card_failed(_card, _opts), do: 0

  defp latest_job(card_id, "verify"),
    do: Repo.one(from(j in base_jobs(card_id), where: j.kind == "verify", select: j.id, limit: 1))

  defp latest_job(card_id, "work"),
    do:
      Repo.one(
        from(j in base_jobs(card_id),
          where: j.kind not in ["verify", "merge"],
          select: j.id,
          limit: 1
        )
      )

  defp base_jobs(card_id),
    do: from(j in Job, where: j.card_id == ^card_id, order_by: [desc: j.id])

  ## Keep this log -------------------------------------------------------------

  @doc """
  Keeps `job`'s log as a page in its card's folder, written as `user`
  (`opts` go on to `Slipdock.Wiki.create_page_from_card/2`: `via`, `agent`).
  Answers `{:ok, page, job}`; keeping it again answers the page it already
  has. Refused while the job runs (`{:error, :running}`), and once there is
  no log to keep (`{:error, :no_log}`).
  """
  def keep(%Job{id: id}, user, opts \\ []) do
    Repo.transaction(fn ->
      job = Repo.one!(from(j in Job, where: j.id == ^id, lock: "FOR UPDATE"))

      case kept_page(job) do
        %{} = page -> {page, job}
        nil -> write(job, user, opts)
      end
    end)
    |> case do
      {:ok, {page, job}} -> {:ok, page, job}
      {:error, reason} -> {:error, reason}
    end
  end

  defp kept_page(%Job{transcript_page_id: nil}), do: nil
  defp kept_page(%Job{transcript_page_id: id}), do: Slipdock.Wiki.get_page(id)

  defp write(job, user, opts) do
    with :ok <- keepable(job),
         %Card{} = card <- Repo.get(Card, job.card_id) || {:error, :no_card},
         {:ok, page} <-
           Slipdock.Wiki.create_page_from_card(
             card,
             [
               title: title(job, user),
               body: body(job),
               summary: "Full output of the pass on ##{card.id}",
               user: user
             ] ++ Keyword.take(opts, [:via, :agent])
           ) do
      {1, [job]} =
        Repo.update_all(from(j in Job, where: j.id == ^job.id, select: j),
          set: [transcript_page_id: page.id]
        )

      {page, job}
    else
      {:error, :payment_required, code, message} ->
        Repo.rollback({:payment_required, code, message})

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  @doc "What a refused keep says, in a sentence."
  def refusal(:running), do: "the job is still running: keep its log once it has ended"
  def refusal(:no_log), do: "this job has no log to keep: none was sent, or it has expired"
  def refusal(:no_card), do: "the job's card is gone, so there is no folder to keep its log in"
  def refusal({:payment_required, code, message}), do: "#{code}: #{message}"

  def refusal(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
      |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)

    "the page could not be written: #{errors}"
  end

  def refusal(other), do: "the log could not be kept: #{inspect(other)}"

  defp keepable(job) do
    cond do
      Job.open?(job) -> {:error, :running}
      job.transcript_bytes == 0 -> {:error, :no_log}
      true -> :ok
    end
  end

  @doc """
  The title a kept log's page takes: `Pass <card> (<YYYY-MM-DD HH.MM>)`,
  the job's end in the keeper's timezone, as the after-job hook's pass log
  names its pages.
  """
  def title(%Job{} = job, user \\ nil) do
    at = job.finished_at || DateTime.utc_now()
    zone = (user && Map.get(user, :timezone)) || "Etc/UTC"

    local =
      case DateTime.shift_zone(at, zone) do
        {:ok, local} -> local
        _ -> at
      end

    "Pass #{job.card_id} (#{Calendar.strftime(local, "%Y-%m-%d %H.%M")})"
  end

  @doc """
  A kept log's page body, as the pass log writes one: a line saying which
  pass it was, then everything the agent said, oldest first.
  """
  def body(%Job{} = job) do
    said =
      job
      |> Transcript.read()
      |> TranscriptView.entries()
      |> Enum.filter(&(&1.kind == :message))
      |> Enum.map_join("\n", &((&1.detail || &1.text) <> "\n"))

    exit = if is_nil(job.exit_code), do: job.status, else: job.exit_code
    "Pass on ##{job.card_id}, job ##{job.id}, exit #{exit}.\n\n" <> said
  end
end

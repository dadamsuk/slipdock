defmodule Slipdock.Runners.Transcript do
  @moduledoc """
  A job's live log (#1870): the runner sends its agent's Claude Code
  transcript about once a minute while the job runs, and once more as it
  ends (`POST /api/runner/jobs/:id/transcript?from=N`, see
  `SlipdockWeb.API.RunnerController`). Each send is the transcript's whole
  lines from line `N` (0-based); the server keeps them in order, in chunks
  (`Slipdock.Runners.TranscriptChunk`), and answers how many lines it holds,
  which is where the runner's next send starts. So a send that failed is
  simply sent again, and one that arrives twice is trimmed.

  What is kept is bounded, and says so where it was cut:

    * a send over #{div(1_000_000, 1000)} kB is read only that far: the whole lines in it are
      kept and the rest comes in the next send;
    * a line over #{div(32_768, 1024)} KiB (a big tool result) is replaced by a line
      `{"type":"slipdock_cut","bytes":N,"limit":L}`;
    * once the log reaches #{div(8_000_000, 1_000_000)} MB nothing more is kept, and a last line
      `{"type":"slipdock_capped","limit":L}` says so.

  A job handed to a new run (#3088: claimed again after its lease ran out or
  a `status=requeue` finish) keeps the log its earlier runs sent, and
  `new_run/2` starts a segment after it with a line
  `{"type":"slipdock_run","attempt":N,"runner":"…"}`. The new run's agent
  writes a new transcript, so its runner sends from line 0 again: `from` and
  the answers count from the start of the job's last segment, while the log
  itself (and `transcript_lines`) counts every line kept.

  Before anything is stored, secrets are taken out (`scrub/2`): the runner's
  own token, any other Slipdock token, and the shapes of the common secrets
  gitleaks looks for (cloud keys, GitHub, Slack and model-provider tokens,
  private keys, JWTs, bearer headers and `password=`/`token=` values).
  """

  import Ecto.Query

  alias Slipdock.Repo
  alias Slipdock.Runners.{Job, Runner, TranscriptChunk}

  @max_send 1_000_000
  @max_line 32_768
  @max_bytes 8_000_000
  @redacted "[redacted]"
  @run_note ~s({"type":"slipdock_run")

  @doc "The largest send read, in bytes; the rest of it is sent again."
  def max_send, do: @max_send
  @doc "The longest line kept as it is, in bytes."
  def max_line, do: @max_line
  @doc "The most a job's log keeps, in bytes."
  def max_bytes, do: @max_bytes

  @doc """
  Appends what `runner` sent for `job_id`: `body` holds the transcript's
  lines from line `from`. `opts[:secrets]` are more literal strings to take
  out (the controller passes the runner's token).

  Answers `{:ok, lines}`, the lines now held, which is where the next send
  starts; `{:capped, lines}` once the log is full (the runner can stop
  sending); `{:gap, lines}` when `from` is past what is held, so lines are
  missing (send again from `lines`); `{:error, :not_found}` for a job that
  isn't this runner's, and `{:error, :ended}` for one that has finished.
  """
  def append(%Runner{} = runner, job_id, from, body, opts \\ []) do
    with {id, ""} <- Integer.parse(to_string(job_id)),
         {from, ""} when from >= 0 <- Integer.parse(to_string(from)) do
      Repo.transaction(fn -> locked_append(runner, id, from, body, opts) end)
      |> case do
        {:ok, {:ok, result, %Job{} = job}} ->
          broadcast(job)
          result

        {:ok, result} ->
          result
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp locked_append(runner, id, from, body, opts) do
    job = Repo.one(from(j in Job, where: j.id == ^id, lock: "FOR UPDATE"))

    cond do
      is_nil(job) or job.runner_id != runner.id ->
        {:error, :not_found}

      not Enum.member?(~w(claimed running), job.status) ->
        {:error, :ended}

      true ->
        # What this run has sent so far: the lines after its segment's note.
        base = run_base(job.id)
        held = job.transcript_lines - base

        cond do
          job.transcript_capped -> {:capped, held}
          from > held -> {:gap, held}
          true -> store(job, base, from, body, opts)
        end
    end
  end

  # The line the job's last segment starts at: the one after its last
  # `slipdock_run` note, or 0 when it has none.
  defp run_base(job_id) do
    note = String.replace(@run_note, "_", "\\_") <> "%"

    from(c in TranscriptChunk,
      where: c.job_id == ^job_id and c.lines == 1 and like(c.body, ^note),
      select: max(c.first_line)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      line -> line + 1
    end
  end

  defp store(job, base, from, body, opts) do
    secrets = opts |> Keyword.get(:secrets, []) |> Enum.filter(&(is_binary(&1) and &1 != ""))
    sent = lines(body)
    from = base + from
    total = from + length(sent)
    new = sent |> Enum.drop(job.transcript_lines - from) |> Enum.map(&clean(&1, secrets))
    room = @max_bytes - job.transcript_bytes
    kept = fit(new, room)
    capped = length(kept) < length(new)

    kept = if capped, do: kept ++ [capped_line()], else: kept
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    bytes =
      if kept == [] do
        0
      else
        text = Enum.map_join(kept, "", &(&1 <> "\n"))

        Repo.insert!(%TranscriptChunk{
          job_id: job.id,
          first_line: job.transcript_lines,
          lines: max(total, job.transcript_lines) - job.transcript_lines,
          bytes: byte_size(text),
          body: text
        })

        byte_size(text)
      end

    lines_held = max(total, job.transcript_lines)

    {_, [job]} =
      Repo.update_all(
        from(j in Job, where: j.id == ^job.id, select: j),
        set: [
          transcript_lines: lines_held,
          transcript_bytes: job.transcript_bytes + bytes,
          transcript_capped: capped,
          transcript_at: now
        ]
      )

    held = lines_held - base
    {:ok, if(capped, do: {:capped, held}, else: {:ok, held}), job}
  end

  @doc """
  Starts a new segment of `job`'s log as `runner` claims it (#3088), when
  an earlier run sent lines: a `slipdock_run` note after them, so the new
  run's sends, which start from line 0 again, are kept after it rather than
  trimmed as already held. A log already full gets no note (nothing more is
  kept), and one with no room left for it is capped. Run inside the claim's
  transaction, before the runner can send. Answers the job as it now is.
  """
  def new_run(%Job{transcript_lines: lines, transcript_capped: capped} = job, _runner)
      when lines == 0 or capped,
      do: job

  def new_run(%Job{} = job, %Runner{} = runner) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    note =
      [type: "slipdock_run", attempt: job.attempts, runner: runner.name]
      |> Jason.OrderedObject.new()
      |> Jason.encode!()

    {text, capped} =
      if job.transcript_bytes + byte_size(note) + 1 <= @max_bytes,
        do: {note <> "\n", false},
        else: {capped_line() <> "\n", true}

    Repo.insert!(%TranscriptChunk{
      job_id: job.id,
      first_line: job.transcript_lines,
      lines: 1,
      bytes: byte_size(text),
      body: text
    })

    {_, [job]} =
      Repo.update_all(
        from(j in Job, where: j.id == ^job.id, select: j),
        set: [
          transcript_lines: job.transcript_lines + 1,
          transcript_bytes: job.transcript_bytes + byte_size(text),
          transcript_capped: capped,
          transcript_at: now
        ]
      )

    job
  end

  # The whole lines in a send. A last line with no newline is one the send
  # cut off (it was over the size read), so it comes again in the next send,
  # unless it is the only line: then it is one line too long for a send,
  # which is kept as a cut line.
  defp lines(body) do
    case String.split(to_string(body), "\n") do
      [""] -> []
      [only] -> [only]
      parts -> Enum.drop(parts, -1)
    end
  end

  defp clean(line, secrets) do
    line =
      line |> String.replace_invalid() |> String.replace(<<0>>, "") |> String.trim_trailing("\r")

    if byte_size(line) > @max_line do
      Jason.encode!(%{type: "slipdock_cut", bytes: byte_size(line), limit: @max_line})
    else
      line |> scrub(secrets) |> not_a_run_note()
    end
  end

  # Only the server starts a segment: a sent line that reads like its note
  # is kept with a space in front, which JSON ignores and `run_base/1` doesn't.
  defp not_a_run_note(@run_note <> _ = line), do: " " <> line
  defp not_a_run_note(line), do: line

  defp fit(lines, room) do
    Enum.reduce_while(lines, {[], 0}, fn line, {kept, used} ->
      size = byte_size(line) + 1

      if used + size <= room,
        do: {:cont, {[line | kept], used + size}},
        else: {:halt, {kept, used}}
    end)
    |> then(fn {kept, _used} -> Enum.reverse(kept) end)
  end

  defp capped_line, do: Jason.encode!(%{type: "slipdock_capped", limit: @max_bytes})

  @doc """
  `text` with secrets replaced by `#{@redacted}`: each of the literal
  strings in `secrets`, then everything matching the secret patterns.
  """
  def scrub(text, secrets \\ []) do
    text =
      Enum.reduce(secrets, text, fn secret, acc ->
        if byte_size(secret) >= 8, do: String.replace(acc, secret, @redacted), else: acc
      end)

    text = Enum.reduce(patterns(), text, &Regex.replace(&1, &2, @redacted))

    # `password=…`, `Bearer …`: the name stays, and a value that looks made
    # up (letters and digits, no call or path) goes.
    Regex.replace(assignment(), text, fn whole, name, value ->
      if value =~ ~r/[0-9]/ and value =~ ~r/[A-Za-z]/, do: name <> @redacted, else: whole
    end)
  end

  # Generic shapes only, as in .gitleaks.toml: never a list of real values.
  # A `{regex, n}` keeps its group n (the name before the value).
  defp patterns do
    [
      ~r/-----BEGIN[A-Z ]*PRIVATE KEY-----.*?-----END[A-Z ]*PRIVATE KEY-----/s,
      ~r/\bsd[a-z]_[A-Za-z0-9_-]{20,}/,
      ~r/\b(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b/,
      ~r/\bgh[pousr]_[A-Za-z0-9]{30,}/,
      ~r/\bgithub_pat_[A-Za-z0-9_]{30,}/,
      ~r/\bglpat-[A-Za-z0-9_-]{20,}/,
      ~r/\bxox[abposr]-[A-Za-z0-9-]{10,}/,
      ~r/\bsk-ant-[A-Za-z0-9_-]{20,}/,
      ~r/\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}/,
      ~r/\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}/,
      ~r/\bAIza[0-9A-Za-z_-]{35}/,
      ~r/\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/
    ]
  end

  defp assignment do
    ~r/((?:(?:Bearer|Basic)\s+)|(?:(?:password|passwd|secret|api[_-]?key|access[_-]?key|token)[A-Za-z_]*\\?["']?\s*[:=]\s*\\?["']?))([A-Za-z0-9_+\/=.~-]{12,})(?![A-Za-z0-9_+\/=.~(-])/i
  end

  @doc """
  The job's log from line `from` on (0-based), as the lines were kept:
  JSON Lines, one per line of the agent's transcript.
  """
  def read(%Job{id: id}, from \\ 0) when is_integer(from) and from >= 0 do
    from(c in TranscriptChunk,
      where: c.job_id == ^id and (c.first_line + c.lines > ^from or c.first_line >= ^from),
      order_by: c.id
    )
    |> Repo.all()
    |> Enum.map_join("", fn
      %{first_line: first, body: body} when first >= from ->
        body

      %{first_line: first, body: body} ->
        body |> String.split("\n") |> Enum.drop(from - first) |> Enum.join("\n")
    end)
  end

  @doc "The topic a job's log arriving is broadcast on: `{:transcript, job_id, lines}`."
  def topic(job_id), do: "runner_job_transcript:#{job_id}"

  defp broadcast(%Job{} = job) do
    Phoenix.PubSub.broadcast(
      Slipdock.PubSub,
      topic(job.id),
      {:transcript, job.id, job.transcript_lines}
    )
  end
end

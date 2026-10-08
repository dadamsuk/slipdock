defmodule Slipdock.Runners do
  @moduledoc """
  Sending cards to coding agents on the user's own machines.

  **Pull, not push.** A runner dials out and asks for work; the server never
  calls the machine, so nothing needs an open port, a tunnel or an exception
  to `Slipdock.Egress`. An automation rule's `runner` action queues a
  `Slipdock.Runners.Job`; runners of the matching pool on the same board tree
  claim jobs one at a time, heartbeat while they run, and finish them.

  **The server never decides what runs.** A job carries data — its id, its
  kind, the card and the prompt. Which command a kind means is written in the
  runner's own config on its own machine, and a kind it has no definition for
  is refused there. Every kind of runner (the shell script, the PowerShell
  one, a Claude session over MCP) takes jobs from this one queue through the
  functions here, so the lease and cancel rules have one implementation.

  A claim holds a lease (`lease_seconds`, 90 by default) that every heartbeat
  renews. `sweep/1`, run by the automation scheduler's clock, puts a job whose
  lease has run out back in the queue, and after `max_attempts` fails it and
  flags the card instead of handing it out for ever.
  """

  import Ecto.Query

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Runners.{Job, Runner}

  @pubsub Slipdock.PubSub

  # What a job's text and logs may grow to. The tail is what matters: the
  # last lines say how it ended.
  @max_prompt 20_000
  @max_log 8_000
  # A burst of rules must not fill the queue faster than anybody can read it.
  @queue_per_minute 60
  @max_open_per_tree 200

  @doc false
  def limits,
    do: %{
      max_prompt: @max_prompt,
      max_log: @max_log,
      queue_per_minute: @queue_per_minute,
      max_open_per_tree: @max_open_per_tree,
      lease_seconds: lease_seconds(),
      max_attempts: max_attempts()
    }

  defp config, do: Slipdock.Config.get(:runners, [])
  def lease_seconds, do: config()[:lease_seconds] || 90
  def max_attempts, do: config()[:max_attempts] || 3

  ## PubSub -------------------------------------------------------------------

  @doc "Subscribes to `{:jobs_changed, card_id}` for every card on `board_id`."
  def subscribe_board(board_id), do: Phoenix.PubSub.subscribe(@pubsub, "runner_jobs:#{board_id}")

  defp pool_topic(root_id, pool), do: "runner_queue:#{root_id}:#{pool}"

  defp changed(%Job{} = job) do
    Phoenix.PubSub.broadcast(@pubsub, "runner_jobs:#{job.board_id}", {:jobs_changed, job.card_id})
    job
  end

  ## Runners ------------------------------------------------------------------

  @doc """
  Makes a runner for `board`'s tree and returns `{:ok, runner, token}`. The
  token is shown this once; only its hash is kept.
  """
  def create_runner(%Board{} = board, attrs, user \\ nil) do
    token = "sdr_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    %Runner{
      board_id: Board.root_id(board),
      created_by_id: user && user.id,
      token_hash: hash(token)
    }
    |> Runner.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, runner} -> {:ok, runner, token}
      error -> error
    end
  end

  @doc "The runners that take work from `board`'s tree, newest first."
  def list_runners(%Board{} = board) do
    Repo.all(
      from(r in Runner, where: r.board_id == ^Board.root_id(board), order_by: [desc: r.id])
    )
  end

  @doc "A runner of `board`'s tree by id or name."
  def find_runner(%Board{} = board, ref) do
    ref = to_string(ref)
    base = from(r in Runner, where: r.board_id == ^Board.root_id(board))

    found =
      case Integer.parse(ref) do
        {id, ""} -> Repo.one(from(r in base, where: r.id == ^id))
        _ -> nil
      end || Repo.one(from(r in base, where: r.name == ^ref, limit: 1))

    if found, do: {:ok, found}, else: {:error, :not_found, "runner"}
  end

  @doc "Revokes a runner: its token stops working at once."
  def delete_runner(%Runner{} = runner), do: Repo.delete(runner)

  @doc "Saves the setup wizard's answers on the runner (never the token)."
  def update_runner(%Runner{} = runner, attrs),
    do: runner |> Runner.changeset(attrs) |> Repo.update()

  @doc """
  The runner `token` belongs to, with its last-seen time brought up to date,
  or nil.
  """
  def authenticate(token) when is_binary(token) and token != "" do
    case Repo.get_by(Runner, token_hash: hash(String.trim(token))) do
      nil -> nil
      runner -> touch(runner)
    end
  end

  def authenticate(_), do: nil

  defp touch(runner) do
    now = now()
    Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: [last_seen_at: now])
    %{runner | last_seen_at: now}
  end

  defp hash(token), do: :crypto.hash(:sha256, token)

  ## Queueing -----------------------------------------------------------------

  @doc """
  Queues `card` for `pool`. `attrs` carries `:kind`, `:prompt` and `:rule`
  (optional). Returns `{:ok, job}`, `{:ok, :already_open, job}` when the rule
  already has an open job for the card, or `{:error, message}`.
  """
  def queue(%Card{} = card, attrs) do
    rule = attrs[:rule]
    pool = attrs |> Map.get(:pool) |> to_string() |> String.downcase()
    kind = attrs |> Map.get(:kind, "claude") |> to_string() |> String.downcase()
    prompt = attrs |> Map.get(:prompt, "") |> to_string()
    board = Repo.get!(Board, card.board_id)
    root_id = Board.root_id(board)

    with :ok <- valid_name(pool, "pool"),
         :ok <- valid_name(kind, "kind"),
         :ok <- valid_prompt(prompt),
         nil <- rule && open_job(card.id, rule.id),
         :ok <- queue_allowance(root_id) do
      %Job{
        board_id: card.board_id,
        root_board_id: root_id,
        card_id: card.id,
        rule_id: rule && rule.id,
        pool: pool,
        kind: kind,
        prompt: prompt,
        status: "queued"
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint([:card_id, :rule_id],
        name: :runner_jobs_one_open_per_card_rule
      )
      |> Repo.insert()
      |> case do
        {:ok, job} ->
          Phoenix.PubSub.broadcast(@pubsub, pool_topic(root_id, pool), :job_queued)
          {:ok, changed(job)}

        # Two events at once: the other one queued it.
        {:error, %Ecto.Changeset{}} ->
          {:ok, :already_open, open_job(card.id, rule.id)}
      end
    else
      %Job{} = job -> {:ok, :already_open, job}
      {:error, _} = error -> error
    end
  end

  defp valid_name(name, what) do
    if Regex.match?(Runner.name_format(), name),
      do: :ok,
      else: {:error, "#{what} “#{name}” must be lower case letters, digits, - or _"}
  end

  defp valid_prompt(prompt) do
    if byte_size(prompt) > @max_prompt,
      do: {:error, "the prompt is over #{@max_prompt} bytes"},
      else: :ok
  end

  defp open_job(card_id, rule_id) do
    Repo.one(
      from(j in Job,
        where:
          j.card_id == ^card_id and j.rule_id == ^rule_id and j.status in ^Job.open_statuses(),
        limit: 1
      )
    )
  end

  defp queue_allowance(root_id) do
    open =
      Repo.aggregate(
        from(j in Job, where: j.root_board_id == ^root_id and j.status in ^Job.open_statuses()),
        :count
      )

    cond do
      open >= @max_open_per_tree ->
        {:error, "the queue is full: #{open} jobs are already waiting or running on this board"}

      match?(
        {:error, _},
        Slipdock.RateLimit.hit("runner:queue:#{root_id}", @queue_per_minute, :timer.minutes(1))
      ) ->
        {:error, "held back: over #{@queue_per_minute} jobs queued this minute"}

      true ->
        :ok
    end
  end

  ## Claiming -----------------------------------------------------------------

  @doc """
  Hands `runner` the oldest queued job of its pool and tree, with a lease, or
  waits up to `wait_ms` for one to arrive. Returns the job (with its card
  preloaded) or nil. Two runners asking at once never get the same job: the
  claim is one `UPDATE` over a row locked with `SKIP LOCKED`.
  """
  def claim(%Runner{} = runner, wait_ms \\ 0) do
    deadline = System.monotonic_time(:millisecond) + max(wait_ms, 0)
    topic = pool_topic(runner.board_id, runner.pool)

    case try_claim(runner) do
      nil when wait_ms > 0 ->
        Phoenix.PubSub.subscribe(@pubsub, topic)

        try do
          wait_for_job(runner, deadline)
        after
          Phoenix.PubSub.unsubscribe(@pubsub, topic)
        end

      result ->
        result
    end
  end

  defp wait_for_job(runner, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      # One last look: a job queued between the last try and the subscribe
      # would otherwise wait for the next poll.
      try_claim(runner)
    else
      receive do
        :job_queued ->
          case try_claim(runner) do
            nil -> wait_for_job(runner, deadline)
            job -> job
          end
      after
        left -> try_claim(runner)
      end
    end
  end

  # The candidate is locked with SKIP LOCKED and then updated by id, in one
  # transaction: a second runner skips the locked row rather than waiting
  # for it. (An `UPDATE … WHERE id IN (SELECT … LIMIT 1 SKIP LOCKED)` looks
  # the same but may run the subquery again per row and claim two.)
  defp try_claim(runner) do
    now = now()

    candidate =
      from(j in Job,
        where:
          j.root_board_id == ^runner.board_id and j.pool == ^runner.pool and
            j.status == "queued",
        order_by: [asc: j.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED",
        select: j.id
      )

    {:ok, claimed} =
      Repo.transaction(fn ->
        with id when is_integer(id) <- Repo.one(candidate),
             {1, [job]} <-
               Repo.update_all(
                 from(j in Job, where: j.id == ^id and j.status == "queued", select: j),
                 set: [
                   status: "claimed",
                   runner_id: runner.id,
                   runner_name: runner.name,
                   claimed_at: now,
                   lease_expires_at: DateTime.add(now, lease_seconds()),
                   updated_at: now
                 ],
                 inc: [attempts: 1]
               ) do
          Repo.update_all(from(r in Runner, where: r.id == ^runner.id),
            set: [current_job_id: job.id]
          )

          job
        else
          _ -> nil
        end
      end)

    if claimed do
      Boards.log_activity(
        claimed.board_id,
        claimed.card_id,
        "runner",
        "#{runner.name} took job ##{claimed.id}"
      )

      claimed |> changed() |> Repo.preload(:card)
    end
  end

  ## Reporting ----------------------------------------------------------------

  @doc """
  A runner saying it is still at work on `job_id`, with the tail of its log.
  Renews the lease. Answers `{:ok, :ok}`, `{:ok, :cancel}` when somebody has
  asked for the job to stop (or it is no longer this runner's to run), or
  `{:error, :not_found}`.
  """
  def heartbeat(%Runner{} = runner, job_id, log \\ nil) do
    with {:ok, job} <- runner_job(runner, job_id) do
      cond do
        job.status not in ~w(claimed running) ->
          {:ok, :cancel}

        true ->
          now = now()

          changes =
            [lease_expires_at: DateTime.add(now, lease_seconds()), updated_at: now]
            |> then(&if(log in [nil, ""], do: &1, else: [{:log_tail, tail(log)} | &1]))
            |> then(
              &if(job.status == "claimed",
                do: [status: "running", started_at: now] ++ &1,
                else: &1
              )
            )

          Repo.update_all(from(j in Job, where: j.id == ^job.id), set: changes)
          changed(job)

          if job.cancel_requested_at, do: {:ok, :cancel}, else: {:ok, :ok}
      end
    end
  end

  @doc """
  A runner saying `job_id` has ended. `status` is one of done, failed,
  cancelled or timeout; without one, exit 0 is done and anything else
  failed. A job somebody asked to cancel ends cancelled whatever it says.
  """
  def finish(%Runner{} = runner, job_id, attrs) do
    with {:ok, job} <- runner_job(runner, job_id) do
      if job.status in Job.finished_statuses() do
        {:ok, job}
      else
        exit_code = to_int(attrs[:exit])

        status =
          cond do
            job.cancel_requested_at -> "cancelled"
            attrs[:status] in Job.finished_statuses() -> attrs[:status]
            exit_code == 0 -> "done"
            true -> "failed"
          end

        now = now()

        {:ok, job} =
          job
          |> Ecto.Changeset.change(%{
            status: status,
            exit_code: exit_code,
            output: if(attrs[:output] in [nil, ""], do: job.output, else: tail(attrs[:output])),
            finished_at: now,
            lease_expires_at: nil,
            error:
              if(exit_code == 127 and status == "failed", do: "the runner has no such job kind")
          })
          |> Repo.update()

        Repo.update_all(
          from(r in Runner, where: r.id == ^runner.id and r.current_job_id == ^job.id),
          set: [current_job_id: nil]
        )

        Boards.log_activity(
          job.board_id,
          job.card_id,
          "runner",
          "#{runner.name} finished job ##{job.id}: #{status}#{exit_text(exit_code)}"
        )

        {:ok, changed(job)}
      end
    end
  end

  defp exit_text(nil), do: ""
  defp exit_text(code), do: " (exit #{code})"

  # A job is only ever reported on by the runner holding it. Anybody else's —
  # another tree's, or one handed to another runner after a lease ran out — is
  # not there as far as this runner is concerned.
  defp runner_job(runner, job_id) do
    with {id, ""} <- Integer.parse(to_string(job_id)),
         %Job{runner_id: runner_id} = job when runner_id == runner.id <- Repo.get(Job, id) do
      {:ok, job}
    else
      _ -> {:error, :not_found}
    end
  end

  ## Cancelling ---------------------------------------------------------------

  @doc """
  Stops a job. A queued one is cancelled there and then; a running one is
  asked to stop, and its runner hears `cancel` on its next heartbeat.
  """
  def cancel_job(%Job{} = job) do
    case job.status do
      "queued" ->
        job
        |> Ecto.Changeset.change(%{status: "cancelled", finished_at: now()})
        |> Repo.update()
        |> tap_changed()

      status when status in ~w(claimed running) ->
        job
        |> Ecto.Changeset.change(%{cancel_requested_at: job.cancel_requested_at || now()})
        |> Repo.update()
        |> tap_changed()

      status ->
        {:error, "job ##{job.id} has already finished (#{status})"}
    end
  end

  defp tap_changed({:ok, job}), do: {:ok, changed(job)}
  defp tap_changed(other), do: other

  ## Leases -------------------------------------------------------------------

  @doc """
  Deals with every claimed or running job whose lease has run out: back in the
  queue if it has tries left, cancelled if somebody had asked it to stop,
  failed (and its card flagged) if not. Returns how many it touched.
  """
  def sweep(now \\ DateTime.utc_now()) do
    expired =
      Repo.all(
        from(j in Job,
          where: j.status in ["claimed", "running"] and j.lease_expires_at < ^now
        )
      )

    Enum.each(expired, &expire(&1, now))
    length(expired)
  end

  defp expire(job, now) do
    cond do
      job.cancel_requested_at ->
        settle(job, %{status: "cancelled", finished_at: now, lease_expires_at: nil})

      job.attempts >= max_attempts() ->
        settle(job, %{
          status: "failed",
          finished_at: now,
          lease_expires_at: nil,
          error: "no runner finished it: the lease ran out #{job.attempts} times"
        })

        flag_card(job)

      true ->
        if settle(job, %{status: "queued", runner_id: nil, lease_expires_at: nil, claimed_at: nil}) do
          Phoenix.PubSub.broadcast(@pubsub, pool_topic(job.root_board_id, job.pool), :job_queued)
        end
    end
  end

  # Only if nothing has happened to the job since it was read: a heartbeat
  # that lands during the sweep wins.
  defp settle(job, changes) do
    changes = Map.put(changes, :updated_at, now())

    {count, _} =
      Repo.update_all(
        from(j in Job,
          where:
            j.id == ^job.id and j.status == ^job.status and
              j.lease_expires_at == ^job.lease_expires_at
        ),
        set: Map.to_list(changes)
      )

    if count == 1 do
      if job.runner_id do
        Repo.update_all(
          from(r in Runner, where: r.id == ^job.runner_id and r.current_job_id == ^job.id),
          set: [current_job_id: nil]
        )
      end

      changed(job)
      true
    else
      false
    end
  end

  defp flag_card(job) do
    case Repo.get(Card, job.card_id) do
      nil ->
        :ok

      card ->
        Boards.update_card(card, %{"flags" => Enum.uniq(card.flags ++ ["flagged"])})

        Boards.add_comment(
          card,
          "Runner job ##{job.id} (pool #{job.pool}, #{job.kind}) failed: no runner finished it " <>
            "after #{job.attempts} tries. Check the runner is running, then send the card again."
        )
    end
  end

  ## Reading ------------------------------------------------------------------

  @doc "A job by id, or nil."
  def get_job(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.get(Job, id)
      _ -> nil
    end
  end

  @doc "A card's jobs, newest first."
  def list_card_jobs(card_id, limit \\ 20) do
    Repo.all(from(j in Job, where: j.card_id == ^card_id, order_by: [desc: j.id], limit: ^limit))
  end

  @doc "The jobs on `board`'s tree, newest first; `status:` narrows them."
  def list_jobs(%Board{} = board, opts \\ []) do
    query =
      from(j in Job,
        where: j.root_board_id == ^Board.root_id(board),
        order_by: [desc: j.id],
        limit: ^min(opts[:limit] || 50, 200),
        preload: :card
      )

    query =
      case opts[:status] do
        nil -> query
        "open" -> from(j in query, where: j.status in ^Job.open_statuses())
        status -> from(j in query, where: j.status == ^status)
      end

    Repo.all(query)
  end

  ## Helpers ------------------------------------------------------------------

  @doc false
  # The last `max` bytes of `text`, starting on a whole character.
  def tail(text, max \\ @max_log) do
    text = to_string(text)

    if byte_size(text) <= max do
      text
    else
      text
      |> binary_part(byte_size(text) - max, max)
      |> drop_partial()
    end
  end

  defp drop_partial(<<byte, rest::binary>>) when byte >= 0x80 and byte < 0xC0,
    do: drop_partial(rest)

  defp drop_partial(text), do: text

  defp to_int(nil), do: nil
  defp to_int(n) when is_integer(n), do: n

  defp to_int(text) do
    case Integer.parse(to_string(text)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end

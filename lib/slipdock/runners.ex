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
  alias Slipdock.Accounts.UserToken
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Runners.{ClaimDrain, Job, Pause, Recovery, Requeue, Runner}

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
      session_lease_seconds: session_lease_seconds(),
      max_attempts: max_attempts()
    }

  defp config, do: Slipdock.Config.get(:runners, [])
  def lease_seconds, do: config()[:lease_seconds] || 90

  # A Claude session reports between steps of its own work, and one step
  # (a test run, a CI watch) can take many minutes; a shell runner's
  # heartbeat is a background loop. So a session holds a longer lease.
  def session_lease_seconds, do: config()[:session_lease_seconds] || 1200

  @doc "The lease `runner` holds a job on, in seconds."
  def lease_for(%Runner{} = runner),
    do: if(Runner.session?(runner), do: session_lease_seconds(), else: lease_seconds())

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
    token = new_token()

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

  @doc """
  Everything known about a runner, for its detail view: who made it, the API
  token a Claude session works through (`nil` for a runner with a token of
  its own), the job it holds now, how its jobs have ended, its latest jobs and
  the enabled rules on its board that send cards to its pool.
  """
  def runner_details(%Runner{} = runner, opts \\ []) do
    runner = Repo.preload(runner, [:created_by, :api_token])

    jobs =
      Repo.all(
        from(j in Job,
          where: j.runner_id == ^runner.id,
          order_by: [desc: j.id],
          limit: ^(opts[:limit] || 5),
          preload: :card
        )
      )

    counts =
      Repo.all(
        from(j in Job,
          where: j.runner_id == ^runner.id,
          group_by: j.status,
          select: {j.status, count(j.id)}
        )
      )
      |> Map.new()

    current =
      runner.current_job_id &&
        Repo.one(from(j in Job, where: j.id == ^runner.current_job_id, preload: :card))

    rules =
      runner.board_id
      |> Slipdock.Automations.list_rules()
      |> Enum.filter(fn rule ->
        rule.enabled and
          Enum.any?(
            Slipdock.Automations.Spec.actions(rule.spec),
            &(&1["type"] == "runner" and to_string(&1["pool"]) == runner.pool)
          )
      end)

    %{
      runner: runner,
      created_by: runner.created_by,
      api_token: runner.api_token,
      current_job: current,
      job_counts: counts,
      jobs_total: counts |> Map.values() |> Enum.sum(),
      recent_jobs: jobs,
      rules: rules
    }
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

  @doc """
  Gives a runner a new token, returning `{:ok, runner, token}`. The old one
  stops working at once; the new one is shown this once.
  """
  def rotate_token(%Runner{} = runner) do
    token = new_token()

    case runner |> Ecto.Changeset.change(token_hash: hash(token)) |> Repo.update() do
      {:ok, runner} -> {:ok, runner, token}
      error -> error
    end
  end

  defp new_token, do: "sdr_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

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

  @doc """
  The runner standing for a Claude session that takes `pool`'s jobs on
  `board`'s tree with its API token `api_token` (over MCP or the CLI): made
  the first time, brought up to date each time after. It has no token of its
  own that works — the session's API token is what authenticates it — so it
  shows in the runner list and goes when the API token is revoked.
  """
  def session_runner(%Board{} = board, pool, %UserToken{} = api_token, user) do
    pool = pool |> to_string() |> String.trim() |> String.downcase()
    root = Board.root_id(board)

    with :ok <- valid_name(pool, "pool") do
      existing =
        Repo.one(
          from(r in Runner,
            where: r.board_id == ^root and r.pool == ^pool and r.api_token_id == ^api_token.id
          )
        )

      case existing do
        %Runner{} = runner ->
          {:ok, touch(runner)}

        nil ->
          %Runner{
            board_id: root,
            created_by_id: user && user.id,
            api_token_id: api_token.id,
            # Nobody holds the token this hashes: a session runner is only
            # ever reached through its API token.
            token_hash: hash(Base.encode64(:crypto.strong_rand_bytes(32))),
            last_seen_at: now()
          }
          |> Runner.changeset(%{
            "name" => session_name(api_token),
            "pool" => pool,
            "settings" => %{"scenario" => "session"}
          })
          |> Ecto.Changeset.unique_constraint([:board_id, :pool, :api_token_id],
            name: :runners_one_per_session
          )
          |> Repo.insert()
          |> case do
            {:ok, runner} ->
              {:ok, runner}

            {:error, changeset} ->
              # Two first calls at once: the other one made it.
              if Keyword.has_key?(changeset.errors, :board_id),
                do: session_runner(board, pool, api_token, user),
                else: {:error, changeset}
          end
      end
    end
  end

  defp session_name(%UserToken{label: label}) when is_binary(label) and label != "",
    do: String.slice("#{label} (session)", 0, 80)

  defp session_name(%UserToken{id: id}), do: "session #{id}"

  @doc """
  The session runner `api_token` holds `job_id` through, or
  `{:error, :not_found}`: a session reports only on jobs it claimed itself.
  """
  def session_job_runner(job_id, %UserToken{id: token_id}) do
    with %Job{runner_id: runner_id} when not is_nil(runner_id) <- get_job(job_id),
         %Runner{api_token_id: ^token_id} = runner <- Repo.get(Runner, runner_id) do
      {:ok, touch(runner)}
    else
      _ -> {:error, :not_found}
    end
  end

  def session_job_runner(_job_id, _token), do: {:error, :not_found}

  @doc """
  The job a session runner on `api_token` is working on `card_id` now
  (claimed or running), or nil: what a wait opened through that token is
  asked from, without the session having to name it (#1114, KTD4).
  """
  def session_job_on_card(%UserToken{id: token_id}, card_id) do
    from(j in Job,
      join: r in Runner,
      on: r.id == j.runner_id,
      where:
        r.api_token_id == ^token_id and j.card_id == ^card_id and
          j.status in ["claimed", "running"],
      order_by: [desc: j.id],
      limit: 1,
      select: j.id
    )
    |> Repo.one()
  end

  def session_job_on_card(_token, _card_id), do: nil

  ## Queueing -----------------------------------------------------------------

  @doc """
  Queues `card` for `pool`. `attrs` carries `:kind`, `:prompt`, `:rule` and
  `:wait_while_doing` (optional). Returns `{:ok, job}`, `{:ok, :already_open, job}` when the rule
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
        wait_while_doing: attrs[:wait_while_doing] == true,
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

  # The open cards in a doing list on the job's board, other than its own: a
  # job that waits while anything is in progress is not handed out while
  # there is one. Its own card doesn't count, so a job put back after a
  # lapsed claim, whose agent had already moved the card along, still goes.
  defp busy_cards do
    from(c in Card,
      join: col in assoc(c, :column),
      where:
        c.board_id == parent_as(:job).board_id and col.category == "doing" and
          is_nil(c.archived_at) and c.completed == false and c.id != parent_as(:job).card_id,
      select: 1
    )
  end

  @doc """
  Why a queued job that waits while anything is in progress is not being
  handed out: the card in the way (the first, in list order), or nil when
  nothing is.
  """
  def waiting_on(%Job{status: "queued", wait_while_doing: true} = job) do
    Repo.one(
      from(c in Card,
        join: col in assoc(c, :column),
        where:
          c.board_id == ^job.board_id and col.category == "doing" and is_nil(c.archived_at) and
            c.completed == false and c.id != ^job.card_id,
        order_by: [asc: col.position, asc: c.position, asc: c.id],
        limit: 1
      )
    )
  end

  def waiting_on(_job), do: nil

  @doc """
  Why a queued job is not being handed out, as one line, or nil when nothing
  holds it (KTD12). In order, the first that applies:

    * `"paused by David: bad deploy"` — its pool or its tree is paused;
    * `"WIP full: In Progress 3/3"` — its board holds automated work at the
      WIP limit (`automation_wip`) and its card isn't in progress already;
    * `"#123 is in progress"` — it waits while anything is (`wait_while_doing`);
    * `"No runner online for pool dev"` — no runner of its pool has been seen
      for three leases. Left out with `claimant: true`: the runner asking is
      online, whatever its last poll says.
  """
  def held_reason(job, opts \\ [])

  def held_reason(%Job{status: "queued"} = job, opts) do
    cond do
      pause = pause_for(job.root_board_id, job.pool) ->
        Pause.line(pause)

      line = wip_held(job) ->
        line

      card = waiting_on(job) ->
        "##{card.id} is in progress"

      !opts[:claimant] and not runner_online?(job.root_board_id, job.pool) ->
        "No runner online for pool #{job.pool}"

      true ->
        nil
    end
  end

  def held_reason(_job, _opts), do: nil

  # The WIP line for a job whose board holds automated work at its limit,
  # unless its card is in progress already (it is the work, not more of it).
  defp wip_held(%Job{} = job) do
    with {column, count} <- wip_full(job.board_id),
         false <- in_doing?(job.card_id) do
      wip_line(column, count)
    else
      _ -> nil
    end
  end

  defp in_doing?(card_id) do
    Repo.exists?(
      from(c in Card,
        join: col in assoc(c, :column),
        where: c.id == ^card_id and col.category == "doing"
      )
    )
  end

  @doc ~S'The WIP held line: `"WIP full: In Progress 3/3"`.'
  def wip_line(column, count), do: "WIP full: #{column.name} #{count}/#{column.wip_limit}"

  @doc """
  `{column, count}` when `board_id` holds automated work at its WIP limit
  (KTD11): `automation_wip` is on and its first doing list by position has
  a `wip_limit` that its open cards (stand-ins left out, as on the badge)
  reach. Else nil.
  """
  def wip_full(board_id) do
    from(b in Board,
      join: col in assoc(b, :columns),
      where: b.id == ^board_id and b.automation_wip and col.category == "doing",
      order_by: [asc: col.position, asc: col.id],
      limit: 1,
      select: col
    )
    |> Repo.one()
    |> case do
      %{wip_limit: limit} = column when is_integer(limit) ->
        count = wip_count(column.id)
        if count >= limit, do: {column, count}

      _ ->
        nil
    end
  end

  defp wip_count(column_id) do
    Repo.aggregate(
      from(c in Card,
        where:
          c.column_id == ^column_id and is_nil(c.archived_at) and c.completed == false and
            is_nil(c.stand_in_for_id)
      ),
      :count
    )
  end

  # The boards of a tree holding automated work at their limit: the claim
  # passes over their jobs whose cards aren't in progress.
  defp wip_full_boards(root_id) do
    from(b in Board,
      where: (b.id == ^root_id or b.root_id == ^root_id) and b.automation_wip,
      select: b.id
    )
    |> Repo.all()
    |> Enum.filter(&wip_full/1)
  end

  # The job's own card is in a doing list.
  defp own_card_doing do
    from(c in Card,
      join: col in assoc(c, :column),
      where: c.id == parent_as(:job).card_id and col.category == "doing",
      select: 1
    )
  end

  # Online: seen within three of its leases.
  defp runner_online?(root_id, pool) do
    now = DateTime.utc_now()

    from(r in Runner,
      where: r.board_id == ^root_id and r.pool == ^pool and not is_nil(r.last_seen_at)
    )
    |> Repo.all()
    |> Enum.any?(&(DateTime.diff(now, &1.last_seen_at) <= 3 * lease_for(&1)))
  end

  @doc """
  What a runner of `pool` that got no job is held by, for the claim
  answers: `%{reason: line, pause: pause}` when the pool or tree is paused,
  `%{reason: line, job: job}` for the oldest queued job something holds, or
  nil. Never "no runner online": the one asking is.
  """
  def held(%Board{} = board, pool) do
    root_id = Board.root_id(board)
    pool = pool |> to_string() |> String.downcase()

    case pause_for(root_id, pool) do
      %Pause{} = pause ->
        %{reason: Pause.line(pause), pause: pause, job: nil}

      nil ->
        from(j in Job,
          where: j.root_board_id == ^root_id and j.pool == ^pool and j.status == "queued",
          order_by: [asc: j.id],
          limit: 20
        )
        |> Repo.all()
        |> Enum.find_value(fn job ->
          if reason = held_reason(job, claimant: true),
            do: %{reason: reason, job: job, pause: nil}
        end)
    end
  end

  ## Pausing ------------------------------------------------------------------

  @doc """
  Pauses `board`'s tree, or one `pool` on it, with a `reason` (both in
  `attrs`, string keys). Kept on the root (see `Slipdock.Runners.Pause`).
  `actor` is a `Slipdock.Actor`: an agent's token label is kept and shown.
  The caller has checked that `user` owns the board. Returns `{:ok, pause}`
  or `{:error, changeset | message}`.
  """
  def pause(%Board{} = board, attrs, user, actor \\ Slipdock.Actor.unknown()) do
    root_id = Board.root_id(board)
    pool = blank(attrs["pool"])

    case pause_exactly(root_id, pool && String.downcase(String.trim(pool))) do
      %Pause{} = open ->
        {:error, "#{Pause.scope(open)} is already #{Pause.line(open)}"}

      nil ->
        %Pause{
          root_board_id: root_id,
          paused_by_id: user && user.id,
          agent: if(actor[:kind] == "agent", do: actor[:agent])
        }
        |> Pause.changeset(%{"pool" => pool, "reason" => attrs["reason"] || ""})
        |> Repo.insert()
        |> case do
          {:ok, pause} ->
            pause = Repo.preload(pause, :paused_by)

            Boards.log_activity(
              root_id,
              nil,
              "runner",
              "#{Pause.who(pause)} paused #{Pause.scope(pause)}: #{pause.reason}"
            )

            Boards.broadcast_tree(root_id)
            {:ok, pause}

          error ->
            error
        end
    end
  end

  @doc """
  Resumes the pause of `board`'s tree with exactly this `pool` (nil: the
  whole-tree pause; a pool's own pause stays). A person's to do (`actor`
  kind human): an agent can pull the brake but not let it off. Feeds every
  board in the tree and wakes every waiting runner, so held work goes at
  once. Returns `{:ok, pause}` or `{:error, message}`.
  """
  def resume(%Board{} = board, pool, user, actor \\ Slipdock.Actor.unknown()) do
    root_id = Board.root_id(board)
    pool = pool |> blank() |> then(&(&1 && String.downcase(String.trim(&1))))

    with :ok <- person(actor),
         %Pause{} = pause <- pause_exactly(root_id, pool) do
      {:ok, pause} =
        pause
        |> Ecto.Changeset.change(resumed_at: now(), resumed_by_id: user && user.id)
        |> Repo.update()

      Boards.log_activity(
        root_id,
        nil,
        "runner",
        "#{user_name(user)} resumed #{Pause.scope(pause)}"
      )

      Boards.broadcast_tree(root_id)
      release(root_id)
      {:ok, pause}
    else
      nil -> {:error, "#{if pool, do: "pool #{pool}", else: "the whole tree"} is not paused"}
      error -> error
    end
  end

  defp person(%{kind: "human"}), do: :ok

  defp person(_actor),
    do:
      {:error,
       "only a person can resume: on the board's Runners panel, or with the CLI outside an agent"}

  # Everything a pause held: every list_top rule on the tree looks again,
  # and every runner waiting on one of the tree's pools is woken.
  defp release(root_id) do
    board_ids =
      Repo.all(from(b in Board, where: b.id == ^root_id or b.root_id == ^root_id, select: b.id))

    Enum.each(board_ids, &Slipdock.Automations.feed_board/1)

    pools =
      Repo.all(from(r in Runner, where: r.board_id == ^root_id, distinct: true, select: r.pool)) ++
        Repo.all(
          from(j in Job,
            where: j.root_board_id == ^root_id and j.status == "queued",
            distinct: true,
            select: j.pool
          )
        )

    pools
    |> Enum.uniq()
    |> Enum.each(&Phoenix.PubSub.broadcast(@pubsub, pool_topic(root_id, &1), :job_queued))
  end

  @doc "The open pauses on `board`'s tree, the whole-tree one first, then by pool."
  def pauses(%Board{} = board), do: open_pauses(Board.root_id(board))

  def open_pauses(root_id) do
    from(p in Pause,
      where: p.root_board_id == ^root_id and is_nil(p.resumed_at),
      order_by: [asc_nulls_first: p.pool],
      preload: [:paused_by]
    )
    |> Repo.all()
  end

  @doc """
  The open pause holding `pool` on the tree rooted at `root_id`: the pool's
  own, else the whole tree's, else nil. `pool` nil asks about the tree.
  """
  def pause_for(root_id, pool) do
    pauses = open_pauses(root_id)

    Enum.find(pauses, &(pool && &1.pool == pool)) || Enum.find(pauses, &is_nil(&1.pool))
  end

  defp pause_exactly(root_id, pool) do
    from(p in Pause, where: p.root_board_id == ^root_id and is_nil(p.resumed_at))
    |> then(&if(pool, do: where(&1, [p], p.pool == ^pool), else: where(&1, [p], is_nil(p.pool))))
    |> preload(:paused_by)
    |> Repo.one()
  end

  @doc """
  Whether `pools` (a list_top rule's) are held on the tree: the whole tree
  is paused, or any of them is.
  """
  def paused?(root_id, pools) do
    Enum.any?(open_pauses(root_id), &(is_nil(&1.pool) or &1.pool in pools))
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp blank(value), do: to_string(value)

  defp user_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_name(%{email: email}) when is_binary(email), do: email
  defp user_name(_), do: "someone"

  @doc """
  Hands `runner` the oldest queued job of its pool and tree, with a lease, or
  waits up to `wait_ms` for one to arrive. Returns the job (with its card
  preloaded) or nil. Two runners asking at once never get the same job: the
  claim is one `UPDATE` over a row locked with `SKIP LOCKED`.
  """
  def claim(%Runner{} = runner, wait_ms \\ 0) do
    deadline = System.monotonic_time(:millisecond) + max(wait_ms, 0)
    topic = pool_topic(runner.board_id, runner.pool)

    # A node on its way down hands out nothing: an answer the endpoint drops
    # would leave the job leased to nobody until the lease runs out.
    first = if ClaimDrain.draining?(), do: :draining, else: try_claim(runner)

    case first do
      nil when wait_ms > 0 ->
        Phoenix.PubSub.subscribe(@pubsub, topic)
        ClaimDrain.subscribe()

        try do
          # Looked at after subscribing, so a drain in between isn't missed.
          if not ClaimDrain.draining?(), do: wait_for_job(runner, deadline)
        after
          Phoenix.PubSub.unsubscribe(@pubsub, topic)
          ClaimDrain.unsubscribe()
        end

      :draining ->
        nil

      result ->
        result
    end
  end

  @doc "True when this node is stopping, and so answering claims with nothing at once."
  defdelegate draining?, to: ClaimDrain

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

        :draining ->
          nil
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
    # A paused pool or tree hands out nothing (#1116); its jobs wait.
    if pause_for(runner.board_id, runner.pool), do: nil, else: claim_next(runner)
  end

  defp claim_next(runner) do
    now = now()
    wip_full = wip_full_boards(runner.board_id)

    candidate =
      from(j in Job,
        as: :job,
        where:
          j.root_board_id == ^runner.board_id and j.pool == ^runner.pool and
            j.status == "queued",
        where: not j.wait_while_doing or not exists(busy_cards()),
        where: j.board_id not in ^wip_full or exists(own_card_doing()),
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
                   lease_expires_at: DateTime.add(now, lease_for(runner)),
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
            [lease_expires_at: DateTime.add(now, lease_for(runner)), updated_at: now]
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

  A job with an open wait asked from it ends `parked`, whatever it says
  (KTD5): its agent asked a person something and stopped. `status: parked`
  from a job with no such wait is refused, as `{:error, message}`.
  """
  def finish(%Runner{} = runner, job_id, attrs) do
    with {:ok, job} <- runner_job(runner, job_id) do
      if job.status in Job.finished_statuses() do
        {:ok, job}
      else
        with {:ok, status} <- end_status(job, attrs) do
          job = end_job(runner, job, status, attrs)
          {:ok, after_end(runner, job, status)}
        end
      end
    end
  end

  @doc """
  A runner parking `job_id` on a question in one step (`finish_job
  outcome: "waiting"`): `open_wait` is called with the job and opens the
  wait (`{:ok, wait}` or `{:error, message}`), and the job ends parked. Both
  or neither: if the runner no longer holds a claimed or running job, or the
  wait is refused, nothing changes. Answers `{:ok, job, wait}`,
  `{:error, :not_found}` or `{:error, message}`.
  """
  def finish_waiting(%Runner{} = runner, job_id, open_wait, attrs \\ %{})
      when is_function(open_wait, 1) do
    {result, effects} =
      Slipdock.Deferred.collect(fn ->
        Repo.transaction(fn ->
          with {:ok, job} <- runner_job(runner, job_id),
               %Job{} = job <-
                 Repo.one(from(j in Job, where: j.id == ^job.id, lock: "FOR UPDATE")),
               :ok <- can_park(job),
               {:ok, wait} <- open_wait.(job) do
            {end_job(runner, job, "parked", attrs), wait}
          else
            {:error, reason} -> Repo.rollback(reason)
            _ -> Repo.rollback(:not_found)
          end
        end)
      end)

    case result do
      {:ok, {job, wait}} ->
        Slipdock.Deferred.run(effects)
        {:ok, after_end(runner, job, "parked"), wait}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp can_park(%Job{status: status} = job) when status in ~w(claimed running) do
    if job.cancel_requested_at,
      do: {:error, "job ##{job.id} was cancelled: finish it cancelled instead"},
      else: :ok
  end

  defp can_park(job), do: {:error, "job ##{job.id} has already ended (#{job.status})"}

  defp end_status(job, attrs) do
    exit_code = to_int(attrs[:exit])

    cond do
      job.cancel_requested_at -> {:ok, "cancelled"}
      open_linked_wait(job) -> {:ok, "parked"}
      attrs[:status] == "parked" -> {:error, not_parkable(job)}
      attrs[:status] in Job.finished_statuses() -> {:ok, attrs[:status]}
      exit_code == 0 -> {:ok, "done"}
      true -> {:ok, "failed"}
    end
  end

  defp not_parkable(job),
    do:
      "job ##{job.id} has no open wait to park on: open one first (slipdock wait " <>
        "#{job.card_id} \"…\" --job #{job.id}, or update_card wait), or finish it done or failed"

  @doc "The open wait asked from `job`, or nil."
  def open_linked_wait(%Job{id: id}) do
    Repo.one(
      from(w in Slipdock.Boards.Wait, where: w.job_id == ^id and is_nil(w.closed_at), limit: 1)
    )
  end

  # The answered wait asked from `job`, or nil: an answer that came while it
  # was still running.
  defp answered_linked_wait(%Job{id: id}) do
    Repo.one(
      from(w in Slipdock.Boards.Wait,
        where: w.job_id == ^id and w.close_reason == "answered",
        order_by: [desc: w.id],
        limit: 1
      )
    )
  end

  defp end_job(runner, job, status, attrs) do
    exit_code = to_int(attrs[:exit])

    {:ok, job} =
      job
      |> Ecto.Changeset.change(%{
        status: status,
        exit_code: exit_code,
        output: if(attrs[:output] in [nil, ""], do: job.output, else: tail(attrs[:output])),
        finished_at: now(),
        lease_expires_at: nil,
        error: if(exit_code == 127 and status == "failed", do: "the runner has no such job kind")
      })
      |> Repo.update()

    Repo.update_all(
      from(r in Runner, where: r.id == ^runner.id and r.current_job_id == ^job.id),
      set: [current_job_id: nil]
    )

    job
  end

  defp after_end(runner, job, status) do
    Boards.log_activity(
      job.board_id,
      job.card_id,
      "runner",
      "#{runner.name} finished job ##{job.id}: #{status}#{exit_text(job.exit_code)}"
    )

    leave_handoff(job, runner, status)
    job = changed(job)
    refill(job)
    job
  end

  # A job that ends with its card still open leaves its summary as the
  # card's handoff (W-1804), unless the agent wrote one itself during the
  # job: that one knows more, and is not to be overwritten.
  defp leave_handoff(%Job{} = job, runner, status) do
    since = job.claimed_at || job.inserted_at

    case Repo.get(Slipdock.Boards.Card, job.card_id) do
      %{completed: false} = card ->
        unless Boards.handoff_written_since?(card.id, since) do
          Boards.leave_handoff(card, nil, handoff_attrs(job, runner, status))
        end

      _ ->
        :ok
    end
  end

  @doc false
  # The handoff a job's summary makes: its first line is the next step.
  def handoff_attrs(%Job{} = job, runner, status) do
    summary = String.trim(job.output || "")
    ended = "Job ##{job.id} on #{runner.name} ended #{status}#{exit_text(job.exit_code)}."

    next_step =
      case String.split(summary, ~r/\R/, parts: 2) do
        [first | _] when first != "" -> first |> String.trim() |> ellipsize(280)
        _ -> "Pick up where job ##{job.id} stopped (#{status}): see its log"
      end

    %{
      next_step: next_step,
      body:
        String.slice(Enum.join(Enum.reject([summary, ended], &(&1 == "")), "\n\n"), -8000, 8000),
      via: "runner",
      job_id: job.id
    }
  end

  defp ellipsize(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
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
        |> tap_refill()

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

  defp tap_refill({:ok, job} = result) do
    refill(job)
    result
  end

  defp tap_refill(other), do: other

  # A job from a rule that keeps a pool fed from a list (`list_top`) has
  # ended, so the rule may send the next card — after putting back the card
  # the job left in progress, if the rule says to, so that it can be the one.
  #
  # Answers waiting for the rule's open job to close go first (KTD7): a
  # list_top rule drains them inside its feed, ahead of the next card; any
  # other rule here.
  defp refill(%Job{rule_id: rule_id} = job) do
    Recovery.recover(job)
    announce(job)

    case rule_id && Repo.get(Slipdock.Automations.Rule, rule_id) do
      nil ->
        :ok

      rule ->
        unless Slipdock.Automations.Spec.feed?(rule.spec), do: Requeue.drain(rule)
        Slipdock.Automations.feed_rule(rule)
    end
  end

  # Rules watching for jobs ending (`job_finished`) hear about it once, with
  # the job as it ended and after its card was put back or given up on.
  defp announce(%Job{id: id}) do
    with %Job{} = job <- Repo.get(Job, id),
         true <- job.status in Job.finished_statuses() do
      card = Repo.get(Card, job.card_id)

      Slipdock.Automations.dispatch(%{
        type: "job_finished",
        card: card,
        job: job,
        board_id: (card && card.board_id) || job.board_id
      })
    end
  end

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

  # A job whose agent asked a person something never goes back in the
  # queue with its old prompt (KTD5): with the question still open it is
  # parked; answered while it ran, it fails, pointing at the fresh job the
  # answer queues once this one has closed.
  defp expire(job, now) do
    cond do
      job.cancel_requested_at ->
        if settle(job, %{status: "cancelled", finished_at: now, lease_expires_at: nil}),
          do: refill(job)

      open_linked_wait(job) ->
        if settle(job, %{status: "parked", finished_at: now, lease_expires_at: nil}) do
          Boards.log_activity(
            job.board_id,
            job.card_id,
            "runner",
            "job ##{job.id} parked: its lease ran out while it waited on a person"
          )

          refill(job)
        end

      wait = answered_linked_wait(job) ->
        error = "its question was answered while it ran: a fresh job with the answer takes over"

        if settle(job, %{status: "failed", finished_at: now, lease_expires_at: nil, error: error}) do
          refill(job)
          point_to_fresh_job(job, wait, error)
        end

      job.attempts >= max_attempts() ->
        settle(job, %{
          status: "failed",
          finished_at: now,
          lease_expires_at: nil,
          error: "no runner finished it: the lease ran out #{job.attempts} times"
        })

        flag_card(job)
        refill(job)

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

  defp point_to_fresh_job(job, wait, error) do
    case Repo.get(Slipdock.Boards.Wait, wait.id) do
      %{requeue_job_id: fresh} when is_integer(fresh) ->
        Repo.update_all(from(j in Job, where: j.id == ^job.id),
          set: [error: String.replace(error, "a fresh job", "job ##{fresh}")]
        )

        changed(job)

      _ ->
        :ok
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

  @doc """
  What a claim answers beside the prompt (#1115), for runners that read
  more than the prompt: the wait the job carries on from — the answered
  question that queued it, else the card's open one — and the card's open
  handoff. Either is nil when there is none.
  """
  def claim_context(%Job{} = job) do
    wait =
      Repo.one(
        from(w in Slipdock.Boards.Wait,
          where: w.requeue_job_id == ^job.id,
          order_by: [desc: w.id],
          limit: 1,
          preload: [:on_user, :opened_by, :closed_by]
        )
      ) || Boards.current_wait(job.card_id)

    %{wait: wait, handoff: Boards.current_handoff(job.card_id)}
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

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
  flags the card instead of handing it out for ever. Until another runner
  claims a requeued job, the runner that held it takes it back with its next
  heartbeat or finish (#2817): a machine that slept carries on where it was.
  """

  import Ecto.Query

  require Slipdock.Flow.DoingList, as: DoingList

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Accounts.UserToken
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Runners.{ClaimDrain, ClaimMove, Job, Pause, Probe, Recovery, Requeue, Runner}

  @pubsub Slipdock.PubSub

  # What a job's text and logs may grow to. The tail is what matters: the
  # last lines say how it ended.
  @max_prompt 20_000
  @max_log 8_000
  # The longest progress message a job keeps (#1668).
  @max_step 300
  @max_steps 200
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
  # (a test run, a CI watch) can take many minutes; a machine's runner's
  # heartbeat is a background loop. So a session holds a longer lease.
  def session_lease_seconds, do: config()[:session_lease_seconds] || 1200

  @doc "The lease `runner` holds a job on, in seconds."
  def lease_for(%Runner{} = runner),
    do: if(Runner.session?(runner), do: session_lease_seconds(), else: lease_seconds())

  def max_attempts, do: config()[:max_attempts] || 3

  @doc """
  Whether `runner` is idle: seen within three of its leases, and holding no
  job now. A merge goes to an idle runner first (#1754).
  """
  def idle?(%Runner{last_seen_at: %DateTime{} = seen} = runner),
    do: DateTime.diff(DateTime.utc_now(), seen) <= 3 * lease_for(runner) and not busy?(runner)

  def idle?(%Runner{}), do: false

  @doc """
  Whether `runner` holds an open job: one claimed or running under it.

  One token can be claimed through by several processes, or by a session,
  so the runner's `current_job_id` is only its last claim: that one ending
  leaves the others open, and it can be cleared while they run (#1965).
  """
  def busy?(%Runner{id: id}),
    do:
      Repo.exists?(
        from(j in Job, where: j.runner_id == ^id and j.status in ["claimed", "running"])
      )

  ## PubSub -------------------------------------------------------------------

  @doc "Subscribes to `{:jobs_changed, card_id}` for every card on `board_id`."
  def subscribe_board(board_id), do: Phoenix.PubSub.subscribe(@pubsub, "runner_jobs:#{board_id}")

  defp pool_topic(root_id, pool), do: "runner_queue:#{root_id}:#{pool}"

  defp changed(%Job{} = job) do
    Phoenix.PubSub.broadcast(@pubsub, "runner_jobs:#{job.board_id}", {:jobs_changed, job.card_id})
    Probe.broadcast(job)
    job
  end

  @doc false
  # Wakes the runners of `pool` waiting on a claim: a job has been queued.
  def wake_pool(root_id, pool),
    do: Phoenix.PubSub.broadcast(@pubsub, pool_topic(root_id, pool), :job_queued)

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
  The latest progress message (#1668) of the job each of `runners` holds
  now, as `%{runner_id => step}`; a runner with no job, or a job with no
  step yet, isn't in it.
  """
  def current_steps(runners) do
    ids = for %Runner{current_job_id: id} <- runners, id, do: id

    if ids == [] do
      %{}
    else
      from(j in Job,
        where: j.id in ^ids and not is_nil(j.step) and not is_nil(j.runner_id),
        select: {j.runner_id, j.step}
      )
      |> Repo.all()
      |> Map.new()
    end
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

  @doc """
  The runner `token` belongs to, with its last-seen time brought up to date,
  or nil. A machine's runner (#2571) is never found by a token: it
  authenticates with its machine's key (`authenticate_machine/2`).
  """
  def authenticate(token) when is_binary(token) and token != "" do
    case Repo.one(
           from(r in Runner,
             where: r.token_hash == ^hash(String.trim(token)) and is_nil(r.machine_id)
           )
         ) do
      nil -> nil
      runner -> touch(runner)
    end
  end

  def authenticate(_), do: nil

  @doc """
  The runner a machine key (`sdm_…`) and a runner id name together (#2571):
  the machine's own runner, with its last-seen time brought up to date, or
  `{:error, reason}`: `:unauthorized` for a key that is unknown or revoked,
  `:no_runner` when no runner id is given, and `:not_this_machine` for a
  runner that isn't the machine's. A machine key claims and reports only for
  its own runners.
  """
  def authenticate_machine(key, runner_ref, ip \\ nil) do
    with {:machine, %Slipdock.Machines.Machine{} = machine} <-
           {:machine, Slipdock.Machines.authenticate(key, ip)},
         {:ref, ref} when ref not in [nil, ""] <- {:ref, runner_ref},
         {:runner, %Runner{} = runner} <-
           {:runner, Slipdock.Runners.MachineRunners.machine_runner(machine, ref)} do
      {:ok, touch(runner)}
    else
      {:machine, nil} -> {:error, :unauthorized}
      {:ref, _} -> {:error, :no_runner}
      {:runner, nil} -> {:error, :not_this_machine}
    end
  end

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
    with runner_id when not is_nil(runner_id) <- holder_id(get_job(job_id)),
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
  asked from, without the session having to name it (#1114, KTD4). With
  none on the card itself, the nearest card above it with one counts: an
  epic's job asking about its subcard (#1755).
  """
  def session_job_on_card(%UserToken{id: token_id}, card_id) do
    case Repo.get(Card, card_id) do
      nil ->
        nil

      card ->
        ids = [card.id | Boards.Cards.ancestor_card_ids(card)]

        jobs =
          from(j in Job,
            join: r in Runner,
            on: r.id == j.runner_id,
            where:
              r.api_token_id == ^token_id and j.card_id in ^ids and
                j.status in ["claimed", "running"],
            order_by: [desc: j.id],
            select: {j.card_id, j.id}
          )
          |> Repo.all()

        Enum.find_value(ids, fn id -> Enum.find_value(jobs, fn {c, j} -> c == id && j end) end)
    end
  end

  def session_job_on_card(_token, _card_id), do: nil

  ## Queueing -----------------------------------------------------------------

  @doc """
  Queues `card` for `pool`. `attrs` carries `:kind`, `:prompt`, `:rule`,
  `:wait_while_doing`, `:exclude_runner_id` (a runner that may not take
  it), `:exclude_runner_ids` (more of them) and `:audit` (a verify job
  re-checking an accepted card, #1780) (optional). Returns `{:ok, job}`, `{:ok, :already_open, job}` when the rule
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
        exclude_runner_id: attrs[:exclude_runner_id],
        exclude_runner_ids: attrs |> Map.get(:exclude_runner_ids, []) |> Enum.reject(&is_nil/1),
        audit: attrs[:audit] == true,
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

  @doc """
  Queues a release job (#2835) on `root_id`'s tree for `pool`: kind
  `release`, no card, its prompt the board's release `command`. Lanes and
  WIP limits never hold it, and only a runner that says it takes `release`
  is handed it. `{:ok, job}` or `{:error, message}`.
  """
  def queue_release(root_id, pool, command) when is_integer(root_id) do
    # The pool is a runner's own and the command the board's, which keeps
    # it to one short line: neither is checked again here.
    with :ok <- queue_allowance(root_id) do
      job =
        %Job{
          board_id: root_id,
          root_board_id: root_id,
          card_id: nil,
          pool: pool,
          kind: Slipdock.Releases.kind(),
          prompt: command,
          status: "queued"
        }
        |> Ecto.Changeset.change()
        |> Repo.insert!()

      Phoenix.PubSub.broadcast(@pubsub, pool_topic(root_id, pool), :job_queued)
      {:ok, changed(job)}
    end
  end

  defp valid_name(name, what) do
    if Regex.match?(Runner.name_format(), name),
      do: :ok,
      else: {:error, "#{what} “#{name}” must be lower case letters, digits, - or _"}
  end

  defp valid_prompt(prompt) do
    if byte_size(prompt) > @max_prompt,
      do: {:error, prompt_refusal()},
      else: :ok
  end

  defp prompt_refusal, do: "the prompt is over #{@max_prompt} bytes"

  @doc """
  Whether a refusal from `queue/2` would come again for the same job
  (#2705): a prompt over the cap or a pool or kind that isn't a name. A
  full queue or the per-minute allowance clears by itself.
  """
  def lasting_refusal?(reason) when is_binary(reason),
    do: reason == prompt_refusal() or reason =~ ~r/^(pool|kind) “.*” must be lower case/u

  def lasting_refusal?(_reason), do: false

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
  The cards a runner job is working on in the tree under `root_id` (#1922),
  as `{card_ids, board_ids}`: a card is worked when it is in `card_ids` (an
  open job — queued, claimed or running, of any kind — is on it) or sits on
  a board in `board_ids` (under a card with an open job: an epic's job works
  its subcards). Only a worked card in progress holds runners off, by
  `wait_while_doing` or by its lane; one with nothing working on it is left
  to the stale and orphan in-progress checks.
  """
  def worked(root_ids) when is_list(root_ids) do
    card_ids =
      from(j in Job,
        where:
          j.root_board_id in ^root_ids and j.status in ^Job.open_statuses() and
            not is_nil(j.card_id),
        distinct: true,
        select: j.card_id
      )
      |> Repo.all()

    {card_ids, boards_under(card_ids)}
  end

  def worked(root_id), do: worked([root_id])

  # Every board below the given cards, a query per level of nesting rather
  # than per card, so the board page asks the same number whatever its size.
  defp boards_under([]), do: []

  defp boards_under(card_ids),
    do: below(Repo.all(from(b in Board, where: b.parent_card_id in ^card_ids, select: b.id)))

  defp below([]), do: []

  defp below(board_ids) do
    next =
      Repo.all(
        from(sb in Board,
          join: c in Card,
          on: sb.parent_card_id == c.id,
          where: c.board_id in ^board_ids,
          select: sb.id
        )
      )

    board_ids ++ below(next)
  end

  # The open cards in a doing list on the job's board, other than its own,
  # that a runner job is working on (`worked/1`): a job that waits while
  # anything is in progress is not handed out while there is one. Its own
  # card doesn't count, so a job put back after a lapsed claim, whose agent
  # had already moved the card along, still goes.
  defp busy_cards({worked_cards, worked_boards}) do
    from(c in Card,
      join: col in assoc(c, :column),
      where:
        c.board_id == parent_as(:job).board_id and DoingList.doing?(col.category, col.name) and
          is_nil(c.archived_at) and c.completed == false and c.id != parent_as(:job).card_id and
          (c.id in ^worked_cards or c.board_id in ^worked_boards),
      select: 1
    )
  end

  @doc """
  Why a queued job that waits while anything is in progress is not being
  handed out: the card in the way (the first, in list order, that a runner
  job is working on: `worked/1`), or nil when nothing is.
  """
  def waiting_on(%Job{status: "queued", wait_while_doing: true} = job) do
    {worked_cards, worked_boards} = worked(job.root_board_id)

    Repo.one(
      from(c in Card,
        join: col in assoc(c, :column),
        where:
          c.board_id == ^job.board_id and DoingList.doing?(col.category, col.name) and
            is_nil(c.archived_at) and
            c.completed == false and c.id != ^job.card_id and
            (c.id in ^worked_cards or c.board_id in ^worked_boards),
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
    * `"Lane: overlaps #12, in progress"` — lanes (#1628): its card's paths
      overlap a card in progress;
    * `"No runner online for pool dev"` — no runner of its pool has been seen
      for three leases. Left out with `claimant: true`: the runner asking is
      online, whatever its last poll says.

  The WIP limit and lanes hold work jobs only: a verify or merge job
  finishes a card's work rather than adding to it (#1807).
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

      other = lane_held(job) ->
        Slipdock.Lanes.held_line(other)

      !opts[:claimant] and not runner_online?(job.root_board_id, job.pool) ->
        "No runner online for pool #{job.pool}"

      true ->
        nil
    end
  end

  def held_reason(_job, _opts), do: nil

  # The card in progress whose paths a queued job's card overlaps (#1628).
  # A verify or merge job finishes work rather than adding to it, so lanes
  # don't hold one (#1807).
  defp lane_held(%Job{} = job) do
    if not finishing?(job), do: Slipdock.Lanes.held_cards(job.root_board_id)[job.card_id]
  end

  defp finishing?(%Job{kind: kind}), do: Enum.member?(Slipdock.Verified.finishing_kinds(), kind)

  @doc """
  `held_reason/1` for many jobs at once, as job id => line for each one
  something holds (#1117): the board page asks it for every queued job on
  the board, so each question is asked once per tree, pool or board rather
  than once per job. Same order, same words.
  """
  def held_reasons(jobs) do
    queued = Enum.filter(jobs, &(&1.status == "queued"))
    trees = queued |> Enum.map(& &1.root_board_id) |> Enum.uniq()
    boards = queued |> Enum.map(& &1.board_id) |> Enum.uniq()
    pauses = Map.new(trees, &{&1, open_pauses(&1)})
    online = Map.new(trees, &{&1, seen_pools(&1)})
    wip = Map.new(boards, &{&1, wip_full(&1)})
    doing = doing_cards(boards, worked(trees))
    in_doing = MapSet.new(for {_, cards} <- doing, c <- cards, do: c.id)
    lanes = Map.new(trees, &{&1, Slipdock.Lanes.held_cards(&1)})

    for job <- queued,
        line = batch_held(job, pauses, online, wip, {doing, in_doing, lanes}),
        into: %{} do
      {job.id, line}
    end
  end

  defp batch_held(job, pauses, online, wip, {doing, in_doing, lanes}) do
    tree_pauses = pauses[job.root_board_id]

    pause =
      Enum.find(tree_pauses, &(job.pool && &1.pool == job.pool)) ||
        Enum.find(tree_pauses, &is_nil(&1.pool))

    in_way =
      job.wait_while_doing &&
        Enum.find(Map.get(doing, job.board_id, []), &(&1.id != job.card_id))

    cond do
      pause ->
        Pause.line(pause)

      (full = wip[job.board_id]) && not MapSet.member?(in_doing, job.card_id) &&
          not finishing?(job) ->
        {column, count} = full
        wip_line(column, count)

      in_way ->
        "##{in_way.id} is in progress"

      (other = lanes[job.root_board_id][job.card_id]) && not finishing?(job) ->
        Slipdock.Lanes.held_line(other)

      not Enum.member?(online[job.root_board_id], job.pool) ->
        "No runner online for pool #{job.pool}"

      true ->
        nil
    end
  end

  # The pools of a tree with a runner seen within three leases.
  defp seen_pools(root_id) do
    now = DateTime.utc_now()

    from(r in Runner, where: r.board_id == ^root_id and not is_nil(r.last_seen_at))
    |> Repo.all()
    |> Enum.filter(&(DateTime.diff(now, &1.last_seen_at) <= 3 * lease_for(&1)))
    |> Enum.map(& &1.pool)
  end

  # Each board's cards in doing lists, in list order: open ones a runner job
  # is working on only, as `waiting_on/1` counts them.
  defp doing_cards([], _worked), do: %{}

  defp doing_cards(board_ids, {worked_cards, worked_boards}) do
    from(c in Card,
      join: col in assoc(c, :column),
      where:
        c.board_id in ^board_ids and DoingList.doing?(col.category, col.name) and
          is_nil(c.archived_at) and
          c.completed == false and (c.id in ^worked_cards or c.board_id in ^worked_boards),
      order_by: [asc: col.position, asc: c.position, asc: c.id],
      select: %{id: c.id, board_id: c.board_id}
    )
    |> Repo.all()
    |> Enum.group_by(& &1.board_id)
  end

  # The WIP line for a job whose board holds automated work at its limit,
  # unless its card is in progress already (it is the work, not more of it)
  # or the job verifies or merges it (#1807).
  defp wip_held(%Job{} = job) do
    with false <- finishing?(job),
         {column, count} <- wip_full(job.board_id),
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
        where: c.id == ^card_id and DoingList.doing?(col.category, col.name)
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
      where: b.id == ^board_id and b.automation_wip and DoingList.doing?(col.category, col.name),
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
      where: c.id == parent_as(:job).card_id and DoingList.doing?(col.category, col.name),
      select: 1
    )
  end

  @doc "Whether `runner` is online: seen within three of its leases."
  def online?(%Runner{last_seen_at: nil}), do: false

  def online?(%Runner{} = runner),
    do: DateTime.diff(DateTime.utc_now(), runner.last_seen_at) <= 3 * lease_for(runner)

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
  Whether `pool` on the tree under `root_id` has gone offline (#2805): one
  of its runners has been seen, and none within three of its leases. A
  pool whose runners have never been seen (one just set up) is not: work
  queued for it waits for its first claim, as it always has.
  """
  def pool_offline?(root_id, pool) do
    now = DateTime.utc_now()

    seen =
      from(r in Runner,
        where: r.board_id == ^root_id and r.pool == ^pool and not is_nil(r.last_seen_at)
      )
      |> Repo.all()

    seen != [] and
      not Enum.any?(seen, &(DateTime.diff(now, &1.last_seen_at) <= 3 * lease_for(&1)))
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

            Boards.ActivityLog.log_activity(
              root_id,
              nil,
              "runner",
              "#{Pause.who(pause)} paused #{Pause.scope(pause)}: #{pause.reason}"
            )

            Boards.PubSub.broadcast_tree(root_id)
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

      Boards.ActivityLog.log_activity(
        root_id,
        nil,
        "runner",
        "#{user_name(user)} resumed #{Pause.scope(pause)}"
      )

      Boards.PubSub.broadcast_tree(root_id)
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
    Enum.any?(open_pauses(root_id), &(is_nil(&1.pool) or Enum.member?(pools, &1.pool)))
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
    asked(runner)
    first = if ClaimDrain.draining?(), do: :draining, else: try_claim(runner)

    case first do
      nil when wait_ms > 0 ->
        Phoenix.PubSub.subscribe(@pubsub, topic)
        ClaimDrain.subscribe()

        try do
          # Looked at after subscribing, so a drain in between isn't missed.
          if not ClaimDrain.draining?(),
            do: runner |> wait_for_job(deadline) |> asked_if_empty(runner)
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

  # When `runner` last asked for a job (#1849): the health monitor's sign
  # that it takes work beside the job it holds.
  defp asked(runner) do
    Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: [asked_at: now()])
  end

  # A wait that ended empty was asking all along: said again at its end.
  defp asked_if_empty(nil, runner) do
    asked(runner)
    nil
  end

  defp asked_if_empty(job, _runner), do: job

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
    # A probe sent to this runner (#2580) goes first, whatever holds the
    # pool's work: it checks the machine, and does no card's work.
    # Otherwise a paused pool or tree hands out nothing (#1116); its jobs
    # wait. Nor does a machine runner paused on the Machines page (#2572).
    cond do
      probe = Probe.claim(runner) -> claimed_probe(probe)
      pause_for(runner.board_id, runner.pool) || runner_paused?(runner) -> nil
      true -> claim_next(runner)
    end
  end

  defp claimed_probe(job), do: job |> changed() |> Repo.preload(:card)

  # Read each time: a wait for a job can outlast the pause that ends it.
  defp runner_paused?(%Runner{machine_id: nil}), do: false

  defp runner_paused?(%Runner{id: id}),
    do: Repo.exists?(from(r in Runner, where: r.id == ^id and not is_nil(r.paused_at)))

  defp claim_next(runner) do
    now = now()
    wip_full = wip_full_boards(runner.board_id)
    # Lanes (#1628): cards whose paths overlap a card in progress wait.
    lane_held = runner.board_id |> Slipdock.Lanes.held_cards() |> Map.keys()
    worked = worked(runner.board_id)

    candidate =
      from(j in Job,
        as: :job,
        where:
          j.root_board_id == ^runner.board_id and j.pool == ^runner.pool and
            j.status == "queued",
        # A job for one runner (a probe, #2580) is that runner's, taken
        # above, never the pool's.
        where: is_nil(j.for_runner_id),
        # A verify job never goes to the runner that built its card (#1625).
        where: fragment("? IS DISTINCT FROM ?", j.exclude_runner_id, ^runner.id),
        # Nor an audit to its card's builder or verifier (#1780).
        where: not fragment("? = ANY(?)", ^runner.id, j.exclude_runner_ids),
        where: not j.wait_while_doing or not exists(busy_cards(worked)),
        where:
          j.board_id not in ^wip_full or exists(own_card_doing()) or
            j.kind in ^wip_exempt_kinds(),
        # A release (#2835) has no card, so it is in no lane.
        where: j.card_id not in ^lane_held or j.kind in ^lane_exempt_kinds(),
        # A merge job (#1656) or an overseer pass (#2068) only goes to a
        # runner that says it takes them.
        where: j.kind not in ^kinds_not_taken(runner),
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
                   last_runner_id: nil,
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
      claimed_profile(claimed, runner)
      # The card goes to its board's doing list on claim (#2633).
      moved = ClaimMove.move(claimed, runner)

      Boards.ActivityLog.log_activity(
        claimed.board_id,
        claimed.card_id,
        "runner",
        "#{runner.name} took job ##{claimed.id}" <> ClaimMove.activity_suffix(moved)
      )

      Slipdock.StepStatus.claimed(claimed)
      claimed |> changed() |> Repo.preload(:card)
    end
  end

  # A runner taking a card's job claims the card (#1951): on a board with
  # profiles on, one with no profile gets one. Checking it isn't claiming it.
  defp claimed_profile(%Job{card_id: card_id, kind: kind} = job, runner)
       when is_integer(card_id) do
    if not Enum.member?([Slipdock.Overseer.kind() | Slipdock.Verified.finishing_kinds()], kind) do
      case Repo.get(Card, card_id) do
        nil ->
          :ok

        card ->
          Boards.Cards.infer_profile(
            card,
            Slipdock.Actor.runner(runner.created_by_id, job.id, runner.name)
          )
      end
    end
  end

  defp claimed_profile(_job, _runner), do: :ok

  ## Job kinds and merge jobs (#1656) -----------------------------------------

  @max_kinds 30

  @doc """
  Keeps the job kinds `runner` says it takes (`X-Runner-Kinds: claude,verify,merge`,
  sent on every claim), and returns the runner with them. A header that is
  missing leaves what was kept alone; names that aren't kind names are
  dropped.
  """
  def report_kinds(%Runner{} = runner, nil), do: runner

  def report_kinds(%Runner{} = runner, header) when is_binary(header) do
    kinds =
      header
      |> String.split([",", " "], trim: true)
      |> Enum.map(&String.downcase/1)
      |> Enum.filter(&Regex.match?(Runner.name_format(), &1))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(@max_kinds)

    if kinds == runner.kinds do
      runner
    else
      Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: [kinds: kinds])
      %{runner | kinds: kinds}
    end
  end

  @doc """
  The job kinds `runner`'s board tree needs that it hasn't said it takes
  (#1658): `merge` when a board on the tree ships by pull request, and
  `release` (#2836) when the tree releases in batches and the runner
  merges, since the pool that merges fires the releases.
  """
  def missing_kinds(%Runner{} = runner) do
    needs_merge? =
      Repo.exists?(
        from(b in Board,
          where:
            (b.id == ^runner.board_id or b.root_id == ^runner.board_id) and
              b.ship_via == "pull_request" and b.verify_work
        )
      )

    if Runner.session?(runner),
      do: [],
      else: missing_merge(needs_merge?, runner) ++ missing_release(runner)
  end

  defp missing_merge(true, runner), do: if(takes_merge?(runner), do: [], else: ["merge"])
  defp missing_merge(false, _runner), do: []

  # A daemon older than the release kind (#2836) on a batched tree.
  defp missing_release(runner) do
    if takes_merge?(runner) and not takes_release?(runner) and
         Slipdock.Releases.batched?(runner.board_id),
       do: [Slipdock.Releases.kind()],
       else: []
  end

  @doc "Whether `runner` takes merge jobs: it said so on its last claim."
  def takes_merge?(%Runner{kinds: kinds}) when is_list(kinds), do: Enum.member?(kinds, "merge")
  def takes_merge?(_runner), do: false

  # The kinds a WIP limit never holds back: verify and merge jobs finish
  # work, and an overseer pass (#2068) does none.
  # The kinds no lane holds: what finishes a card (#1656), and a release
  # (#2835), which has no card.
  defp lane_exempt_kinds, do: [Slipdock.Releases.kind() | Slipdock.Verified.finishing_kinds()]

  # A release (#2835) is work on no card.
  defp wip_exempt_kinds,
    do: [
      Slipdock.Releases.kind(),
      Slipdock.Overseer.kind() | Slipdock.Verified.finishing_kinds()
    ]

  # The kinds only handed to a runner that says it takes them, that this
  # one hasn't said it does.
  defp kinds_not_taken(runner) do
    [
      {"merge", takes_merge?(runner)},
      {Slipdock.Overseer.kind(), takes_overseer?(runner)},
      {Slipdock.Releases.kind(), takes_release?(runner)}
    ]
    |> Enum.reject(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Whether `runner` takes release jobs (#2835): it said so on its last claim."
  def takes_release?(%Runner{kinds: kinds}) when is_list(kinds),
    do: Enum.member?(kinds, Slipdock.Releases.kind())

  def takes_release?(_runner), do: false

  @doc "Whether `runner` takes overseer passes (#2068): it said so on its last claim."
  def takes_overseer?(%Runner{kinds: kinds}) when is_list(kinds),
    do: Enum.member?(kinds, Slipdock.Overseer.kind())

  def takes_overseer?(_runner), do: false

  @doc """
  What a merge job's runner needs to know, read from its card (#1656): the
  pull request (`evidence_pr`) and the commit that was accepted (the
  verifier's `verify_commit`, else the builder's `evidence_commit`). Data,
  never a command: the runner checks the pull request is in its own
  repository and that its head is still that commit before merging.
  """
  def merge_target(%Job{kind: "merge", card_id: card_id}) when is_integer(card_id) do
    case Repo.get(Card, card_id) do
      %Card{} = card ->
        %{pr: card.evidence_pr, commit: card.verify_commit || card.evidence_commit}

      nil ->
        %{pr: nil, commit: nil}
    end
  end

  def merge_target(_job), do: nil

  defp sha(value) when is_binary(value) do
    value = String.trim(value)
    if Regex.match?(~r/\A[0-9a-f]{7,64}\z/i, value), do: String.downcase(value)
  end

  defp sha(_), do: nil

  ## Reporting ----------------------------------------------------------------

  @doc """
  A runner saying it is still at work on `job_id`, with the tail of its log.
  Renews the lease. Answers `{:ok, :ok}`, `{:ok, :cancel}` when somebody has
  asked for the job to stop (or it is no longer this runner's to run), or
  `{:error, :not_found}`.

  `opts[:step]` is the agent saying what it is doing now (#1668): kept as
  the job's `step` (the latest one, at most #{@max_step} characters) with
  `step_at`, and never posted on the card.
  """
  def heartbeat(%Runner{} = runner, job_id, log \\ nil, opts \\ []) do
    with {:ok, job} <- held_job(runner, job_id) do
      cond do
        not Enum.member?(~w(claimed running), job.status) ->
          {:ok, :cancel}

        true ->
          now = now()
          step = step_text(opts[:step])

          changes =
            [lease_expires_at: DateTime.add(now, lease_for(runner)), updated_at: now]
            |> then(
              &if(Enum.member?([nil, ""], log), do: &1, else: [{:log_tail, tail(log)} | &1])
            )
            |> then(
              &if(is_nil(step),
                do: &1,
                else: [step: step, step_at: now, steps: add_step(job.steps, step, now)] ++ &1
              )
            )
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
    with {:ok, job} <- held_job(runner, job_id) do
      if Enum.member?(Job.finished_statuses(), job.status) do
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
          with {:ok, job} <- held_job(runner, job_id),
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
      Enum.member?(Job.finished_statuses(), attrs[:status]) -> {:ok, attrs[:status]}
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
        output:
          if(Enum.member?([nil, ""], attrs[:output]), do: job.output, else: tail(attrs[:output])),
        finished_at: now(),
        lease_expires_at: nil,
        error: if(exit_code == 127 and status == "failed", do: "the runner has no such job kind"),
        merged_sha: if(job.kind == "merge", do: sha(attrs[:merged]), else: job.merged_sha)
      })
      |> Repo.update()

    Repo.update_all(
      from(r in Runner, where: r.id == ^runner.id and r.current_job_id == ^job.id),
      set: [current_job_id: nil]
    )

    job
  end

  # A probe (#2580) has no card, so nothing about it goes on one: it is
  # read from the Machines page.
  # A release (#2835) has none either: its request hears how it ended.
  defp after_end(_runner, %Job{card_id: nil} = job, _status) do
    if job.kind == Slipdock.Releases.kind(), do: Slipdock.Releases.job_finished(job)
    job = changed(job)
    refill(job)
    job
  end

  defp after_end(runner, job, status) do
    Boards.ActivityLog.log_activity(
      job.board_id,
      job.card_id,
      "runner",
      "#{runner.name} finished job ##{job.id}: #{status}#{exit_text(job.exit_code)}"
    )

    # A merge job (#1657) completes its card, or sends it back with the
    # reason; it leaves no handoff of its own.
    # An overseer pass (#2068) leaves its digest on the overseer's card.
    cond do
      job.kind == Slipdock.Verified.merge_kind() ->
        Slipdock.Verified.merge_finished(job, runner.name)

      job.kind == Slipdock.Overseer.kind() ->
        Slipdock.Overseer.job_finished(job)

      true ->
        leave_handoff(job, runner, status)
    end

    job = changed(job)
    refill(job)
    job
  end

  # A job that ends with its card still open leaves its summary as the
  # card's handoff (W-1804), unless the agent wrote one itself during the
  # job: that one knows more, and is not to be overwritten. Nor on a card
  # already accepted (merging, held or accepted, #2022): its work is judged,
  # and a verifier's summary isn't the next step.
  defp leave_handoff(%Job{} = job, runner, status) do
    since = job.claimed_at || job.inserted_at

    case Repo.get(Slipdock.Boards.Card, job.card_id) do
      %{completed: false, verify_state: state} = card
      when state not in ["merging", "held", "accepted"] ->
        unless Boards.Handoffs.handoff_written_since?(card.id, since) do
          Boards.Handoffs.leave_handoff(card, nil, handoff_attrs(job, runner, status))
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
  # The job's step history (#1875), oldest first, the newest
  # #{@max_steps} kept.
  defp add_step(steps, text, now),
    do:
      ((steps || []) ++ [%{"text" => text, "at" => DateTime.to_iso8601(now)}])
      |> Enum.take(-@max_steps)

  defp step_text(step) when is_binary(step) do
    case String.trim(step) do
      "" -> nil
      text -> String.slice(text, 0, @max_step)
    end
  end

  defp step_text(_), do: nil

  @doc """
  The runner running `job_id`, for the agent it started (#1668): that agent
  sends its job's id (`x-slipdock-job`, from `$SLIPDOCK_JOB_ID`) as
  `actor_job_id`, and may report progress on that job and no other.
  `{:ok, runner}`, or `{:error, :not_found}` when the ids differ or no
  runner holds the job.
  """
  def job_agent_runner(job_id, actor_job_id) do
    with id when is_integer(id) <- actor_job_id,
         %Job{id: ^id} = job <- get_job(job_id),
         runner_id when not is_nil(runner_id) <- holder_id(job),
         %Runner{} = runner <- Repo.get(Runner, runner_id) do
      {:ok, runner}
    else
      _ -> {:error, :not_found}
    end
  end

  # The runner a job is with: the one holding it, or, for a job its lease
  # put back in the queue, the one that may still take it back (#2817).
  defp holder_id(%Job{runner_id: nil, status: "queued", last_runner_id: last}), do: last
  defp holder_id(%Job{runner_id: runner_id}), do: runner_id
  defp holder_id(_), do: nil

  defp runner_job(runner, job_id) do
    with {id, ""} <- Integer.parse(to_string(job_id)),
         %Job{runner_id: runner_id} = job when runner_id == runner.id <- Repo.get(Job, id) do
      {:ok, job}
    else
      _ -> {:error, :not_found}
    end
  end

  # The runner's job, taken back first if its lease ran out and nobody has
  # claimed it since (#2817).
  defp held_job(runner, job_id) do
    with {:error, :not_found} <- runner_job(runner, job_id), do: reclaim(runner, job_id)
  end

  # A job the sweep put back in the queue is still its last runner's to
  # carry on with, until another runner claims it: a machine that slept
  # through its lease wakes with the agent and its worktree as they were.
  # The job goes back to running on a fresh lease, and costs no attempt (a
  # claim counts one, this doesn't). Not while the runner holds another job.
  defp reclaim(runner, job_id) do
    now = now()

    with {id, ""} <- Integer.parse(to_string(job_id)),
         false <- busy?(runner),
         {1, [job]} <-
           Repo.update_all(
             from(j in Job,
               where: j.id == ^id and j.status == "queued" and j.last_runner_id == ^runner.id,
               # As it was: claimed if it had not started, else running.
               update: [
                 set: [
                   status:
                     fragment(
                       "CASE WHEN ? IS NULL THEN 'claimed' ELSE 'running' END",
                       j.started_at
                     )
                 ]
               ],
               select: j
             ),
             set: [
               runner_id: runner.id,
               runner_name: runner.name,
               last_runner_id: nil,
               claimed_at: now,
               lease_expires_at: DateTime.add(now, lease_for(runner)),
               updated_at: now
             ]
           ) do
      Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: [current_job_id: job.id])

      Boards.ActivityLog.log_activity(
        job.board_id,
        job.card_id,
        "runner",
        "#{runner.name} took job ##{job.id} back: its lease had run out and no other runner had taken it"
      )

      changed(job)
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
        |> tap_release_ended()

      status when status in ~w(claimed running) ->
        job
        |> Ecto.Changeset.change(%{cancel_requested_at: job.cancel_requested_at || now()})
        |> Repo.update()
        |> tap_changed()

      status ->
        {:error, "job ##{job.id} has already finished (#{status})"}
    end
  end

  @doc """
  Withdraws a job nobody has taken yet, so that an answered card's job can
  have its rule's slot (#1750; `Slipdock.Runners.Requeue`). It ends
  `cancelled` with `recovery: "withdrawn"` and `reason` as its error, which
  keeps its card out of the feed's cool-down so it goes next. Unlike
  `cancel_job/1` it doesn't refill the rule: the answer's job is about to
  take the slot. `{:ok, job}`, or `:error` once it has been handed out.
  """
  def withdraw_job(%Job{id: id}, reason) do
    {count, _} =
      Repo.update_all(from(j in Job, where: j.id == ^id and j.status == "queued"),
        set: [
          status: "cancelled",
          recovery: "withdrawn",
          error: reason,
          finished_at: now(),
          updated_at: now()
        ]
      )

    if count == 1, do: {:ok, changed(Repo.get!(Job, id))}, else: :error
  end

  defp tap_changed({:ok, job}), do: {:ok, changed(job)}
  defp tap_changed(other), do: other

  defp tap_refill({:ok, job} = result) do
    refill(job)
    result
  end

  defp tap_refill(other), do: other

  defp tap_release_ended({:ok, job} = result) do
    release_ended(job)
    result
  end

  defp tap_release_ended(other), do: other

  # A job ended with no runner finishing it (cancelled while queued, or its
  # lease ran out): if it is a release's (#2835), its request hears, as
  # `after_end/3` tells it of a finish. Any other job has no request.
  defp release_ended(%Job{id: id}), do: Slipdock.Releases.job_finished(Repo.get!(Job, id))

  # A job from a rule that keeps a pool fed from a list (`list_top`) has
  # ended, so the rule may send the next card — after putting back the card
  # the job left in progress, if the rule says to, so that it can be the one.
  #
  # Answers waiting for the rule's open job to close go first (KTD7): a
  # list_top rule drains them inside its feed, ahead of the next card; any
  # other rule here.
  defp refill(%Job{rule_id: rule_id} = job) do
    Recovery.recover(job)
    # A job that timed out or failed is a finding on its card (W-2310).
    Slipdock.Findings.Signals.job_ended(job)
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
  # A probe (#2580) is about a runner, not a card: no rule hears of it.
  defp announce(%Job{card_id: nil}), do: :ok

  defp announce(%Job{id: id}) do
    with %Job{} = job <- Repo.get(Job, id),
         true <- Enum.member?(Job.finished_statuses(), job.status) do
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
          do: lapsed(job)

      open_linked_wait(job) ->
        if settle(job, %{status: "parked", finished_at: now, lease_expires_at: nil}) do
          Boards.ActivityLog.log_activity(
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
        out_of_tries(job, now)

      true ->
        # The runner that held it may take it back while it is still
        # queued (#2817, `held_job/2`): a machine that slept, say.
        requeued = %{
          status: "queued",
          runner_id: nil,
          last_runner_id: job.runner_id,
          lease_expires_at: nil,
          claimed_at: nil
        }

        if settle(job, requeued) do
          Phoenix.PubSub.broadcast(@pubsub, pool_topic(job.root_board_id, job.pool), :job_queued)
        end
    end
  end

  # The lease ran out for the last time: the job fails and its card is
  # flagged. A heartbeat that won the race leaves the job running: nothing
  # has ended, so nothing is flagged, fed or told (#2835).
  defp out_of_tries(job, now) do
    failed = %{
      status: "failed",
      finished_at: now,
      lease_expires_at: nil,
      error: "no runner finished it: the lease ran out #{job.attempts} times"
    }

    if settle(job, failed) do
      flag_card(job)
      lapsed(job)
    end
  end

  # A job its lease ended: the rule feeds the next, and a release's request
  # hears (#2835).
  defp lapsed(job) do
    refill(job)
    release_ended(job)
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

  defp flag_card(%Job{card_id: nil}), do: :ok

  defp flag_card(job) do
    case Repo.get(Card, job.card_id) do
      nil ->
        :ok

      card ->
        Boards.Cards.update_card(card, %{"flags" => Enum.uniq(card.flags ++ ["flagged"])})

        Boards.Comments.add_comment(
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
  The prompt a claimed job is handed (#1622): as it was queued, followed by
  the card's bar when it has one, so the agent works to it (and checks it at
  pickup for parts only a person can meet, #1883), its paths,
  the reason a verifier rejected it, when it is rejected (#1659), how the
  work ships, and last the list the card is in, with its board's doing list
  by name (#2633). A verify
  job's prompt carries the bar already.
  """
  def claimed_prompt(%Job{kind: kind, prompt: prompt})
      when kind in ["verify", "merge", "overseer"],
      do: prompt

  # A probe (#2580) has no card: its prompt is what the server knows of
  # the runner, as data.
  def claimed_prompt(%Job{card_id: nil, kind: "probe"} = job), do: Probe.prompt(job)
  # A release (#2835) has none either: its prompt is the release command.
  def claimed_prompt(%Job{card_id: nil, prompt: prompt}), do: prompt

  def claimed_prompt(%Job{} = job) do
    case Repo.one(from(c in Card, where: c.id == ^job.card_id, select: {c.bar, c.bar_locked_at})) do
      {bar, locked} when is_binary(bar) and bar != "" ->
        state = if locked, do: ", locked when work started", else: ""

        (job.prompt || "") <>
          "\n\nThe card's bar (what done means for it#{state}); work to it as written:\n" <>
          bar <> "\n\n" <> Slipdock.Verified.bar_pickup_check()

      _ ->
        job.prompt
    end
    |> with_paths(job)
    |> with_docs_places(job)
    |> with_lane_advice(job)
    |> with_rejection(job)
    |> with_shipping(job)
    |> with_housekeeping(job)
    |> with_list(job)
  end

  @doc """
  What the builder of a Housekeeping card is told (#2780): it is small and
  already decided, so one that needs a design choice or is growing into
  feature work goes back to a person rather than being built.
  """
  def housekeeping_note(card_id) do
    triage = triage_name(card_id)
    move = if triage =~ ~r/\s/, do: ~s("#{triage}"), else: triage

    """
    This is a Housekeeping card: a small fix or investigation, already decided, run after the ready list. If it turns out to need a design choice (anything that changes how the product or a process behaves), or is growing into feature work (a new surface, a data-model change, more than one sitting), stop before building:
    - move it to the #{triage} list (`slipdock move #{card_id} #{move}`);
    - leave a `product` wait on it saying what grew and the choice it needs (`slipdock wait #{card_id} "…" --kind product`);
    - finish without code: no branch, no pull request. A person moves it out of #{triage} once it is decided; no runner takes it from there.\
    """
  end

  # The name of the Triage list (category `triage`) on the card's board,
  # else its root's, else "Triage": the move names the board's own list,
  # as `with_list/2` does for the doing list.
  defp triage_name(card_id) do
    with %Card{board_id: board_id} <- Repo.get(Card, card_id),
         root_id = Slipdock.Boards.root_of_board(board_id),
         name when is_binary(name) <-
           Repo.one(
             from(col in Slipdock.Boards.Column,
               where:
                 col.board_id in ^Enum.uniq([board_id, root_id]) and col.category == "triage",
               order_by: [desc: col.board_id == ^board_id, asc: col.position],
               limit: 1,
               select: col.name
             )
           ) do
      name
    else
      _ -> "Triage"
    end
  end

  # A card a Housekeeping feed sent (#2780): its rule is a backfill feed,
  # or the card still sits in a Housekeeping list.
  defp with_housekeeping(prompt, %Job{} = job) do
    if housekeeping_job?(job),
      do: (prompt || "") <> "\n\n" <> housekeeping_note(job.card_id),
      else: prompt
  end

  defp housekeeping_job?(%Job{rule_id: rule_id, card_id: card_id}) do
    backfill? =
      case rule_id && Repo.get(Slipdock.Automations.Rule, rule_id) do
        %{spec: %{"trigger" => %{"backfill" => true}}} -> true
        _ -> false
      end

    backfill? or
      Repo.exists?(
        from(c in Card,
          join: col in assoc(c, :column),
          where: c.id == ^card_id and col.category == "housekeeping"
        )
      )
  end

  # Where the card is (#2633): its list, and the board's doing list by its
  # own name, so an agent moving it by hand doesn't guess "Doing".
  defp with_list(prompt, %Job{card_id: card_id}) do
    case ClaimMove.prompt_line(card_id) do
      nil -> prompt
      line -> (prompt || "") <> "\n\n" <> line
    end
  end

  # Sent back by a verifier (#1659): the reason is the brief for the rework,
  # read from the card rather than from its handoff.
  defp with_rejection(prompt, %Job{card_id: card_id}) do
    with %Card{} = card <- Repo.get(Card, card_id),
         %{reason: reason, by: by} <- Slipdock.Verified.rejection(card) do
      (prompt || "") <>
        "\n\nThis card's last submission was rejected by #{by}; fix exactly this, " <>
        "then complete it again with fresh evidence:\n" <> reason
    else
      _ -> prompt
    end
  end

  # How the work ships (#1655): on a board that ships by pull request, the
  # builder is told to open one, never to push the default branch.
  defp with_shipping(prompt, %Job{card_id: card_id}) do
    with %Card{} = card <- Repo.get(Card, card_id),
         text when is_binary(text) <- Slipdock.Verified.ship_instructions(card) do
      (prompt || "") <> "\n\n" <> text
    else
      _ -> prompt
    end
  end

  # The card's lane (#1628): the paths it declared, to stay inside, and
  # which of them are shared on the board (#1971).
  defp with_paths(prompt, %Job{card_id: card_id}) do
    case Repo.one(from(c in Card, where: c.id == ^card_id, preload: :board)) do
      %Card{paths: [_ | _] = paths, board: board} ->
        shared = Slipdock.Lanes.shared_paths(board)

        (prompt || "") <>
          "\n\nThe card's paths (its lane): touch and stage only files under these, " <>
          "or widen them on the card first:\n" <>
          Enum.map_join(paths, "\n", &path_line(&1, shared)) <>
          broad_note(paths, shared) <> shared_note(paths, shared)

      _ ->
        prompt
    end
  end

  # The docs places (#2694): a card whose paths fall in SPEC-10's scope is
  # told the enumeration its verifier runs, and that a place it leaves out
  # goes on the deferral card's bar by name.
  defp with_docs_places(prompt, %Job{card_id: card_id}) do
    with %Card{paths: [_ | _]} = card <-
           Repo.one(from(c in Card, where: c.id == ^card_id, preload: :board)),
         :in <- Slipdock.Verified.docs_places_scope(card, Slipdock.Handbook.find(card.board)) do
      (prompt || "") <> "\n\n" <> Slipdock.Verified.docs_places_builder()
    else
      _ -> prompt
    end
  end

  # Advisory lanes (#1972): on a board whose lane mode is `advise`, the
  # cards in progress whose paths overlap this card's, and what to do.
  # Nothing when none do, or in any other mode.
  defp with_lane_advice(prompt, %Job{card_id: card_id}) do
    with %Card{} = card <- Repo.one(from(c in Card, where: c.id == ^card_id, preload: :board)),
         "advise" <- Slipdock.Lanes.mode(card.board),
         [_ | _] = overlaps <- Slipdock.Lanes.overlaps(card) do
      (prompt || "") <> "\n\n" <> lane_advice(overlaps)
    else
      _ -> prompt
    end
  end

  @doc """
  The *Lanes* block of an advisory lane's prompt (#1972): each card in
  progress whose paths overlap, from `Slipdock.Lanes.overlaps/1`, with the
  globs, the job and runner working it, and what to do.
  """
  def lane_advice(overlaps) do
    lines =
      Enum.map_join(overlaps, "\n", fn %{card: other, paths: mine, theirs: theirs} ->
        "- ##{other.id} \"#{other.title}\"#{working_on(other)}: your " <>
          Enum.join(mine, ", ") <> " meets its " <> Enum.join(theirs, ", ")
      end)

    "Lanes (advisory): this board doesn't hold overlapping work, and these cards in " <>
      "progress touch some of the same files:\n" <>
      lines <>
      "\nBefore editing those files, read that card (slipdock card <id>) and its branch " <>
      "(card-<id>, if pushed); stay out of them where you can; rebase on the default " <>
      "branch before pushing, and expect to merge."
  end

  defp working_on(%Card{} = card) do
    case Slipdock.Lanes.working_job(card) do
      %Job{} = job ->
        " (job ##{job.id}" <> if(job.runner_name, do: " on #{job.runner_name})", else: ")")

      nil ->
        ""
    end
  end

  # A broad glob (#2698) is marked beside itself in the Paths block.
  defp path_line(glob, shared) do
    if Slipdock.Lanes.broad?(glob, shared),
      do: glob <> "  (broad: " <> Slipdock.Lanes.broad_reason() <> ")",
      else: glob
  end

  defp broad_note(paths, shared) do
    if Enum.any?(paths, &Slipdock.Lanes.broad?(&1, shared)),
      do:
        "\nA broad glob claims a whole top-level directory: narrow it on the card before " <>
          "you start (you may change an in-progress card's paths). It is advice: nothing " <>
          "is refused for it.",
      else: ""
  end

  defp shared_note(paths, shared) do
    case Enum.filter(paths, &Slipdock.Lanes.shared?(&1, shared)) do
      [] ->
        ""

      mine ->
        "\n\nShared on the board, so they hold no lane and other cards in progress may " <>
          "edit them too: keep to your own sections, and rebase on the default branch " <>
          "before pushing:\n" <> Enum.join(mine, "\n")
    end
  end

  @doc """
  What a claim answers beside the prompt (#1115), for runners that read
  more than the prompt: the wait the job carries on from — the answered
  question that queued it, else the card's open one — and the card's open
  handoff. Either is nil when there is none. With them, `profile`: the
  card's profile (#1953) when its board has profiles on, else nil, so a
  runner's own config may pick a model for it (`MODEL_<profile>`). The
  server sends the word, never a command (ARCH-5).
  """
  def claim_context(%Job{card_id: nil}), do: %{wait: nil, handoff: nil, profile: nil}

  def claim_context(%Job{} = job) do
    wait =
      Repo.one(
        from(w in Slipdock.Boards.Wait,
          where: w.requeue_job_id == ^job.id,
          order_by: [desc: w.id],
          limit: 1,
          preload: [:on_user, :opened_by, :closed_by]
        )
      ) || Boards.Waits.current_wait(job.card_id)

    %{
      wait: wait,
      handoff: Boards.Handoffs.current_handoff(job.card_id),
      profile: job_profile(job)
    }
  end

  @doc """
  The profile of a job's card (#1953): the one it has, else the one its
  paths and tags infer, when the card's board has profiles on; nil when
  they are off or the job has no card.
  """
  def job_profile(%Job{card_id: card_id}) when is_integer(card_id) do
    case Repo.get(Card, card_id) |> Repo.preload(:board) do
      %Card{board: %Board{profiles: true}} = card -> Slipdock.Profiles.profile_of(card)
      _ -> nil
    end
  end

  def job_profile(_job), do: nil

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

  @doc "How many of the tree `root_id`'s jobs are queued, claimed and running, by status."
  def active_job_counts(root_id) do
    from(j in Job,
      where: j.root_board_id == ^root_id and j.status in ~w(queued claimed running),
      group_by: j.status,
      select: {j.status, count(j.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "`pause` with the person who paused it loaded."
  def with_paused_by(%Pause{} = pause), do: Repo.preload(pause, :paused_by)
end

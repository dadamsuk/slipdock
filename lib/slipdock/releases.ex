defmodule Slipdock.Releases do
  @moduledoc """
  Batched releases (#2833): merging doesn't change, releasing does.

  A board's `release_mode` (`Board.release_modes/0`) is `on_merge`, where
  each merge deploys as it always has, or `batched`, where a merge waits for
  a release. `release_age_cap_hours` is how long the oldest waiting merge
  may wait before it triggers one (nil is off). Both belong to the tree:
  they are set on its root board (`Board.changeset/2` refuses them on a
  sub-board) and read from there by `mode/1` and `age_cap_hours/1`.

  A card's release state (`state/1`, #2834) is worked out on read from the
  existing Deployments record: on a batched board, a merged card is
  `awaiting` until a succeeded deploy names it, then `released`. A card
  still completes, and its dependents unblock, when it merges; the release
  state is shown afterwards and changes neither.

  ## Release requests (#2835)

  On a batched tree a release is asked for, never implied by a merge. Three
  things ask (`Request.triggers/0`): a card of priority `critical` merging
  (`card_merged/1`), *Release now* at any door (`release_now/2`), and the
  age cap (`tick/1`, from the scheduler): the oldest card `awaiting/1`
  release has waited `release_age_cap_hours`.

  `request/3` keeps releases one at a time. With none running it starts
  one: the request takes the cards awaiting release and queues a runner job
  of kind `release` (`kind/0`), with no card, whose prompt is the board's
  release command (`command/1`). With one running it queues a single
  follow-up, and any further trigger joins that follow-up. Lanes and WIP
  limits never hold a release job, and only a runner that says it takes
  `release` is handed one (`Slipdock.Runners`).

  A running request ends (`finish/3`) `released` when a deploy of the tree
  succeeds (`deployment_recorded/1`), or when its job is done on a tree
  that records no deploys; `failed` when the job or the deploy fails; and
  `timed_out` after `timeout_hours/0` with neither. Ending one starts the
  follow-up. Each step is a line in the root board's activity (kind
  `release`), naming who or what asked and the cards covered.
  """

  import Ecto.Query

  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Deployments
  alias Slipdock.Deployments.Deployment
  alias Slipdock.Releases.Request
  alias Slipdock.Repo
  alias Slipdock.Runners
  alias Slipdock.Runners.{Job, Runner}

  @kind "release"
  @default_command "gh workflow run release.yml --ref {default_branch}"
  @timeout_hours 3
  @pubsub Slipdock.PubSub

  @doc """
  The release settings of `board`'s tree, read from its root:
  `%{mode: "on_merge" | "batched", age_cap_hours: integer | nil, command:
  binary | nil}` (`command` nil is the default, `default_command/0`).
  `board` is a board or a board id.
  """
  def settings(%Board{root_id: nil} = board),
    do: %{
      mode: board.release_mode,
      age_cap_hours: board.release_age_cap_hours,
      command: board.release_command
    }

  def settings(%Board{root_id: root_id}), do: settings(root_id)

  def settings(board_id) when is_integer(board_id) do
    from(b in Board,
      left_join: r in Board,
      on: r.id == b.root_id,
      where: b.id == ^board_id,
      select:
        {r.id, {r.release_mode, r.release_age_cap_hours, r.release_command},
         {b.release_mode, b.release_age_cap_hours, b.release_command}}
    )
    |> Repo.one()
    |> case do
      nil -> %{mode: "on_merge", age_cap_hours: nil, command: nil}
      {nil, _root, {mode, cap, command}} -> %{mode: mode, age_cap_hours: cap, command: command}
      {_id, {mode, cap, command}, _own} -> %{mode: mode, age_cap_hours: cap, command: command}
    end
  end

  @doc "The kind of the runner job that fires a release (#2835): `release`."
  def kind, do: @kind

  @doc """
  The release command a board runs when it sets none: the runner puts the
  repository's default branch in place of `{default_branch}`.
  """
  def default_command, do: @default_command

  @doc "The hours a running release may go unheard of before it is ended `timed_out`."
  def timeout_hours, do: @timeout_hours

  @doc "The release command of `board`'s tree: its root's `release_command`, else the default."
  def command(%Board{root_id: nil, release_command: command}), do: command || @default_command
  def command(%Board{root_id: root_id}), do: command(Repo.get!(Board, root_id))

  @doc "Subscribes the caller to `{:release_changed, root_id}` for `board`'s tree."
  def subscribe(%Board{} = board),
    do: Phoenix.PubSub.subscribe(@pubsub, topic(Board.root_id(board)))

  defp topic(root_id), do: "releases:#{root_id}"

  ## Requests (#2835) ----------------------------------------------------------

  @doc """
  The cards of `board`'s tree that have merged and no release covers yet,
  oldest merge first: completed and accepted with a commit (as `state/1`),
  named by no succeeded deploy, and finished after the tree's last release
  (its last succeeded deploy, or its last request that didn't fail), so a
  card no deploy will ever name doesn't wait for ever. Never an archived
  card. Empty on a board that releases on merge.
  """
  def awaiting(%Board{} = board) do
    root_id = Board.root_id(board)
    if batched?(board), do: awaiting_on(root_id), else: []
  end

  defp awaiting_on(root_id) do
    floor = last_release_at(root_id)

    released =
      from(d in Deployment,
        join: b in Board,
        on: b.id == d.board_id,
        where: (b.id == ^root_id or b.root_id == ^root_id) and d.status == "succeeded",
        where: fragment("? = ANY(?)", parent_as(:card).id, d.card_ids),
        select: 1
      )

    from(c in Card,
      as: :card,
      join: b in Board,
      on: b.id == c.board_id,
      where: b.id == ^root_id or b.root_id == ^root_id,
      where: c.completed == true and c.verify_state == "accepted" and is_nil(c.archived_at),
      where:
        not is_nil(c.merge_sha) or not is_nil(c.verify_commit) or not is_nil(c.evidence_commit),
      where: not exists(released),
      order_by: [asc: c.completed_at, asc: c.id]
    )
    |> then(&if(floor, do: where(&1, [c], c.completed_at > ^floor), else: &1))
    |> Repo.all()
  end

  # When the tree last released: its latest succeeded deploy's start, or the
  # start of its latest request that didn't fail, whichever is later.
  defp last_release_at(root_id) do
    deployed =
      Repo.one(
        from(d in Deployment,
          join: b in Board,
          on: b.id == d.board_id,
          where: (b.id == ^root_id or b.root_id == ^root_id) and d.status == "succeeded",
          select: max(d.started_at)
        )
      )

    requested =
      Repo.one(
        from(r in Request,
          where: r.board_id == ^root_id and r.status == "released",
          select: max(r.started_at)
        )
      )

    [deployed, requested]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  @doc """
  Where `board`'s tree stands: `%{mode, running, queued, last, awaiting}`,
  the open requests (or nil), the last one that ended, and the cards
  awaiting release.
  """
  def status(%Board{} = board) do
    root_id = Board.root_id(board)

    %{
      mode: mode(board),
      running: open(root_id, "running"),
      queued: open(root_id, "queued"),
      last: last_ended(root_id),
      awaiting: awaiting(board)
    }
  end

  defp open(root_id, status),
    do: Repo.one(from(r in Request, where: r.board_id == ^root_id and r.status == ^status))

  defp last_ended(root_id) do
    Repo.one(
      from(r in Request,
        where: r.board_id == ^root_id and r.status in ^Request.ended_statuses(),
        order_by: [desc: r.id],
        limit: 1
      )
    )
  end

  @doc """
  *Release now* (#2835), at every door: asks for a release of `board`'s
  tree in `by`'s name (a person's or an agent's, in words). As `request/3`.
  """
  def release_now(%Board{} = board, by), do: request(board, "manual", by)

  @doc "What a door says of how `request/3` placed a request."
  def said(:started), do: "Release started: a runner fires the release command next."
  def said(:queued), do: "Release queued: it runs when the release under way has ended."
  def said(:joined), do: "A release is already queued behind the one running; this joined it."

  @doc "Why `request/3` refused, in words, for a door."
  def refusal(:not_batched),
    do: "this board releases on merge: set its root board's release mode to batched first"

  def refusal(message) when is_binary(message), do: message

  @doc """
  One line on where a tree's releases stand (`status/1`), for a banner:
  the release running, the follow-up queued and the cards awaiting. Nil
  when nothing is running, queued or awaiting.
  """
  def line(%{running: nil, queued: nil, awaiting: []}), do: nil

  def line(%{running: running, queued: queued, awaiting: awaiting}) do
    [
      running && "A release is running (#{length(running.card_ids)} cards)",
      queued && "another is queued",
      awaiting != [] && is_nil(running) && "#{length(awaiting)} merged, awaiting release"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  @doc """
  A card has merged (#2835): on a batched tree, one of priority `critical`
  asks for a release. Anything else is left for the next trigger, as is a
  card accepted with no commit (nothing merged).
  """
  def card_merged(%Card{priority: "critical"} = card) do
    board = Repo.get!(Board, card.board_id)

    if is_binary(merged_sha(card)) and batched?(board),
      do: request(board, "critical", "##{card.id} #{card.title}"),
      else: :ok
  end

  def card_merged(_card), do: :ok

  @doc """
  Asks for a release of `board`'s tree. `trigger` is one of
  `Request.triggers/0` and `by` says who or what it was.

    * `{:ok, :started, request}`: none was running, so this one is, with a
      `release` job queued for a runner;
    * `{:ok, :queued, request}`: one is running; this is the follow-up;
    * `{:ok, :joined, request}`: a follow-up was queued already; the
      trigger is added to it;
    * `{:error, :not_batched}` on a tree that releases on merge, and
      `{:error, message}` when no job could be queued (no runner on the
      tree takes merges or releases, or the queue is full).
  """
  def request(%Board{} = board, trigger, by \\ nil) when trigger in ~w(critical manual age_cap) do
    root = root(board)

    if root.release_mode == "batched",
      do: locked(root, fn -> place(root, entry(trigger, by)) end),
      else: {:error, :not_batched}
  end

  defp root(%Board{root_id: nil} = board), do: board
  defp root(%Board{root_id: root_id}), do: Repo.get!(Board, root_id)

  defp entry(trigger, by) do
    %{"trigger" => trigger, "by" => by, "at" => DateTime.to_iso8601(DateTime.utc_now())}
  end

  # One request at a time per tree: every change to a tree's requests holds
  # its root board's row.
  defp locked(root, fun) do
    Repo.transaction(fn ->
      Repo.one!(from(b in Board, where: b.id == ^root.id, lock: "FOR UPDATE", select: b.id))

      case fun.() do
        {:error, reason} -> Repo.rollback(reason)
        result -> result
      end
    end)
    |> case do
      {:ok, {:ok, how, request}} ->
        Phoenix.PubSub.broadcast(@pubsub, topic(root.id), {:release_changed, root.id})
        {:ok, how, request}

      {:ok, other} ->
        Phoenix.PubSub.broadcast(@pubsub, topic(root.id), {:release_changed, root.id})
        other

      {:error, reason} ->
        refused(root, reason)
        {:error, reason}
    end
  end

  # A release that couldn't start is said on the board, since a critical
  # merge or the age cap has nobody to tell.
  defp refused(root, message) when is_binary(message),
    do: Boards.ActivityLog.log_activity(root.id, nil, @kind, "Release not started: #{message}")

  defp refused(_root, _reason), do: :ok

  defp place(root, entry) do
    case {open(root.id, "running"), open(root.id, "queued")} do
      {nil, nil} ->
        start(root, %Request{board_id: root.id, triggers: [entry]})

      {%Request{}, nil} ->
        request = Repo.insert!(%Request{board_id: root.id, status: "queued", triggers: [entry]})

        log(root, "Release queued behind the one running: #{asked(entry)}")
        {:ok, :queued, request}

      {_running, %Request{} = queued} ->
        request =
          queued |> Ecto.Changeset.change(triggers: queued.triggers ++ [entry]) |> Repo.update!()

        log(root, "Release already queued; joined by #{asked(entry)}")
        {:ok, :joined, request}
    end
  end

  # Starts `request` (new, or the queued follow-up): it takes the cards
  # awaiting release now and a `release` job goes to a runner.
  defp start(root, %Request{} = request) do
    cards = awaiting_on(root.id)

    with {:ok, pool} <- pool(root.id),
         {:ok, job} <- Runners.queue_release(root.id, pool, command(root)) do
      request =
        request
        |> Ecto.Changeset.change(
          status: "running",
          card_ids: Enum.map(cards, & &1.id),
          job_id: job.id,
          started_at: DateTime.utc_now()
        )
        |> Repo.insert_or_update!()

      log(
        root,
        "Release started (job ##{job.id}, pool #{pool}): #{asked(request.triggers)}. " <>
          covers(cards)
      )

      {:ok, :started, request}
    end
  end

  # The pool that merges (#1656) fires releases: a runner that says it
  # takes `release`, an idle one first, else one that takes merges.
  defp pool(root_id) do
    runners =
      Repo.all(
        from(r in Runner,
          where: r.board_id == ^root_id,
          where: fragment("'release' = ANY(?) OR 'merge' = ANY(?)", r.kinds, r.kinds),
          order_by: [desc_nulls_last: r.last_seen_at, asc: r.id]
        )
      )

    releasers = Enum.filter(runners, &Runners.takes_release?/1)

    case Enum.find(releasers, &Runners.idle?/1) || List.first(releasers) || List.first(runners) do
      %Runner{pool: pool} -> {:ok, pool}
      nil -> {:error, "no runner on this board takes release or merge jobs"}
    end
  end

  defp asked(entries) when is_list(entries), do: Enum.map_join(entries, "; ", &asked/1)

  defp asked(%{"trigger" => "manual", "by" => by}), do: "Release now by #{by || "somebody"}"
  defp asked(%{"trigger" => "critical", "by" => by}), do: "critical card #{by} merged"
  defp asked(%{"trigger" => "age_cap", "by" => by}), do: "the age cap (#{by})"

  defp covers([]), do: "No merged card is awaiting release."

  defp covers(cards) do
    shown = cards |> Enum.take(20) |> Enum.map_join(", ", &"##{&1.id}")
    more = length(cards) - 20
    "Covers #{shown}" <> if(more > 0, do: " and #{more} more.", else: ".")
  end

  defp log(root, message), do: Boards.ActivityLog.log_activity(root.id, nil, @kind, message)

  @doc """
  A `release` job has ended (`Slipdock.Runners`). Failed, cancelled or
  expired: its request ends `failed`. Done: the request keeps the run's URL
  (the first link in the job's output) and waits for the deploy, or ends
  `released` there and then on a tree that records no deploys.
  """
  def job_finished(%Job{id: job_id} = job) do
    case Repo.one(from(r in Request, where: r.job_id == ^job_id and r.status == "running")) do
      nil ->
        :ok

      %Request{} = request when job.status == "done" ->
        root = Repo.get!(Board, request.board_id)
        url = run_url(job.output)
        request = request |> Ecto.Changeset.change(run_url: url) |> Repo.update!()
        log(root, "Release fired by job ##{job.id}" <> if(url, do: ": #{url}", else: "."))

        if records_deploys?(root.id),
          do: {:ok, request},
          else:
            finish(request, "released", "the release command ran; this board records no deploys")

      %Request{} = request ->
        finish(request, "failed", "job ##{job.id} #{job.status}: the release command didn't run")
    end
  end

  defp run_url(output) when is_binary(output) do
    case Regex.run(~r{https?://[^\s"'<>]+}, output) do
      [url] when byte_size(url) <= 500 -> url
      _ -> nil
    end
  end

  defp run_url(_output), do: nil

  defp records_deploys?(root_id) do
    Repo.exists?(
      from(b in Board,
        where: (b.id == ^root_id or b.root_id == ^root_id) and b.delivery_metrics == true
      )
    )
  end

  @doc """
  A deploy was recorded (`Slipdock.Deployments`): a finished one ends the
  tree's running request, `released` when it succeeded and `failed` when it
  didn't. A backfilled or rolled-back deploy, and one still started, end
  nothing. Returns what it was given.
  """
  def deployment_recorded(
        {:ok, %Deployment{status: status, rollback: false} = deployment} = result
      )
      when status in ["succeeded", "failed"] do
    if deployment.source != "backfill", do: deployed(deployment)
    result
  end

  def deployment_recorded(result), do: result

  defp deployed(%Deployment{} = deployment) do
    root_id = Board.root_id(Repo.get!(Board, deployment.board_id))

    case open(root_id, "running") do
      nil ->
        :ok

      %Request{} = request when deployment.status == "succeeded" ->
        finish(request, "released", "deployed to #{deployment.environment}")

      %Request{} = request ->
        at = if(deployment.stage, do: " at #{deployment.stage}", else: "")
        finish(request, "failed", "the release failed#{at}")
    end
  end

  @doc """
  Ends the running `request` as `status` (`Request.ended_statuses/0`) with
  a `note` saying why, and starts the queued follow-up if there is one.
  `{:ok, request}`, or `{:error, :not_running}` once it has ended.
  """
  def finish(%Request{id: id, board_id: root_id}, status, note \\ nil)
      when status in ~w(released failed timed_out) do
    root = Repo.get!(Board, root_id)

    locked(root, fn -> end_running(root, Repo.get(Request, id), status, note) end)
  end

  defp end_running(root, %Request{status: "running"} = request, status, note) do
    request =
      request
      |> Ecto.Changeset.change(
        status: status,
        note: note && String.slice(note, 0, 500),
        finished_at: DateTime.utc_now()
      )
      |> Repo.update!()

    log(root, "Release #{ended(status)}" <> if(note, do: ": #{note}.", else: "."))
    follow_up(root)
    {:ok, request}
  end

  defp end_running(_root, _request, _status, _note), do: {:error, :not_running}

  defp ended("released"), do: "released"
  defp ended("failed"), do: "failed"
  defp ended("timed_out"), do: "timed out"

  # The single follow-up runs once the release before it has ended. One
  # that can't start (no runner) is dropped, and the board says so.
  defp follow_up(root) do
    with %Request{} = queued <- open(root.id, "queued"),
         {:error, message} <- start(root, queued) do
      Repo.delete!(queued)
      refused(root, message)
    end
  end

  @doc """
  The scheduler's pass (#2835), every minute: ends running requests nothing
  has been heard of for `timeout_hours/0` (their job is cancelled), then
  asks for a release on each batched tree whose oldest card awaiting
  release has waited its `release_age_cap_hours`. The age cap asks only
  when none is running (a follow-up waits only behind one that is) and the
  tree's last one didn't fail or time out:
  after one of those, a person or a critical merge releases next. Returns
  how many requests it ended or started.
  """
  def tick(now \\ DateTime.utc_now()) do
    timed_out = Enum.count(stale(now), &time_out/1)
    timed_out + Enum.count(capped_roots(), &age_cap(&1, now))
  end

  defp stale(now) do
    cutoff = DateTime.add(now, -@timeout_hours * 3600, :second)
    Repo.all(from(r in Request, where: r.status == "running" and r.started_at <= ^cutoff))
  end

  defp time_out(%Request{} = request) do
    # A job that has already finished refuses the cancel and stays as it ended.
    with %Job{} = job <- request.job_id && Repo.get(Job, request.job_id) do
      Runners.cancel_job(job)
    end

    # Cancelling its queued job may have ended the request as failed.
    match?({:ok, _}, finish(request, "timed_out", "nothing heard for #{@timeout_hours} hours"))
  end

  defp capped_roots do
    Repo.all(
      from(b in Board,
        where: is_nil(b.root_id) and is_nil(b.archived_at),
        where: b.release_mode == "batched" and not is_nil(b.release_age_cap_hours)
      )
    )
  end

  defp age_cap(%Board{} = root, now) do
    with nil <- open(root.id, "running"),
         false <-
           match?(%Request{status: s} when s in ["failed", "timed_out"], last_ended(root.id)),
         [%Card{} = oldest | _] <- awaiting_on(root.id),
         true <- waited_hours(oldest, now) >= root.release_age_cap_hours do
      by =
        "##{oldest.id} has waited #{waited_hours(oldest, now)}h, cap #{root.release_age_cap_hours}h"

      match?({:ok, _, _}, request(root, "age_cap", by))
    else
      _ -> false
    end
  end

  defp waited_hours(%Card{completed_at: %DateTime{} = at}, now),
    do: div(DateTime.diff(now, at, :second), 3600)

  defp waited_hours(_card, _now), do: 0

  @doc "`board`'s release mode, from its tree's root: `on_merge` or `batched`."
  def mode(board), do: settings(board).mode

  @doc "Whether `board`'s tree releases in batches."
  def batched?(board), do: mode(board) == "batched"

  @doc """
  `card`'s release state (#2834), or nil: nil on a board that releases on
  merge and for a card that hasn't merged. Otherwise

    * `%{state: "awaiting", sha, merged_at}`: merged, awaiting release;
    * `%{state: "released", sha, merged_at, environment, deployment_id, at}`:
      a succeeded deploy names it (the latest, where there are several).
      On a tree that records no deploys, the release request that covered
      it and ended `released` is its release, with no environment (#2835).

  A card has merged when it is completed and accepted with a commit: the
  merge's (`merge_sha`) on a board that ships by pull request, else the one
  it was accepted at (`verify_commit`, else `evidence_commit`).
  """
  def state(%Card{} = card) do
    with true <- card.completed == true,
         sha when is_binary(sha) <- merged_sha(card),
         true <- batched?(card.board_id) do
      base = %{sha: sha, merged_at: card.completed_at}

      case Deployments.shipped(card) do
        [] ->
          Map.merge(base, released_by_request(card))

        [latest | _] ->
          Map.merge(base, %{
            state: "released",
            environment: latest.environment,
            deployment_id: latest.deployment_id,
            at: latest.at
          })
      end
    else
      _ -> nil
    end
  end

  # No deploy names it: on a tree that records no deploys, the request
  # that covered it and ended `released` is its release (#2835).
  defp released_by_request(%Card{id: id}) do
    request =
      Repo.one(
        from(r in Request,
          where: r.status == "released" and fragment("? = ANY(?)", ^id, r.card_ids),
          order_by: [desc: r.id],
          limit: 1
        )
      )

    case request do
      nil ->
        %{state: "awaiting"}

      %Request{} ->
        %{state: "released", environment: nil, deployment_id: nil, at: request.finished_at}
    end
  end

  defp merged_sha(%Card{verify_state: "accepted"} = card),
    do: card.merge_sha || card.verify_commit || card.evidence_commit

  defp merged_sha(_card), do: nil

  @doc """
  A release state in words, its time in `zone`: `Merged 1a2b3c4, awaiting
  release · since 12 Nov 10:04`, or `Released to production · 12 Nov 14:32`.
  """
  def text(state, zone \\ "Etc/UTC")

  def text(%{state: "awaiting"} = s, zone) do
    "Merged #{String.slice(s.sha, 0, 7)}, awaiting release" <>
      if(s.merged_at, do: " · since #{Deployments.time_text(s.merged_at, zone)}", else: "")
  end

  def text(%{state: "released", environment: nil} = s, zone),
    do: "Released · #{Deployments.time_text(s.at, zone)}"

  def text(%{state: "released"} = s, zone),
    do: "Released to #{s.environment} · #{Deployments.time_text(s.at, zone)}"
end

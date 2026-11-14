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
  follow-up, and any further trigger joins that follow-up. WIP limits
  never hold a release job, and only a runner that says it takes
  `release` is handed one (`Slipdock.Runners`).

  A running request ends (`finish/3`) `released` when a deploy of the tree
  succeeds (`deployment_recorded/1`), or when its job is done on a tree
  that records no deploys; `failed` when the job or the deploy fails; and
  `timed_out` after `timeout_hours/0` with neither. Ending one starts the
  follow-up. Each step is a line in the root board's activity (kind
  `release`), naming who or what asked and the cards covered.

  ## A red release files its fix card and holds nothing (#2838, #3179)

  A failed deploy recorded on a batched tree (a release's suite, build or
  deploy failing, #2820) is the tree's red release: the root board's
  `red_release` (`red_release/1`) says why, at which stage and with which
  run, and Slipdock files one fix card of priority `critical` on top of
  the root's ready list, naming the batch's cards and linking the run.
  It refuses nothing (#3179): *Release now*, the age cap, a queued
  follow-up and a critical merge all release as they would, and each says
  the last release failed, naming its run (`red_warning/1`). The age cap
  counts from the failed release's end rather than the oldest merge, so
  it doesn't fire again the minute a release fails. The red release
  stands, on the release banner, until the fix card merges (its merge
  releases, `card_merged/1`) or is accepted with no code (its cause was
  outside the repository, #2993: that releases nothing), or a succeeded
  deploy of the tree to the failed environment at the failed sha or newer
  (the failed run rerun, or a later release) clears it (#2996): the fix
  card is then archived if nobody has started it, else told. A second red
  release while one stands keeps the first and files no second card. A
  release job that failed to fire, a backfilled deploy and a board that
  releases on merge are no red release.
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
  Where `board`'s tree stands: `%{mode, red_release, running, queued, last,
  awaiting, releasing}`: the red release standing (`red_release/1`, or
  nil), the open requests
  (or nil), the last one that ended, the cards awaiting release, and the
  cards the running release takes (#3153: in its order, the archived
  left out; empty while none runs).
  """
  def status(%Board{} = board) do
    root_id = Board.root_id(board)
    running = open(root_id, "running")

    %{
      mode: mode(board),
      red_release: current_red(root_id),
      running: running,
      queued: open(root_id, "queued"),
      last: last_ended(root_id),
      awaiting: awaiting(board),
      releasing: releasing(running)
    }
  end

  defp releasing(%Request{card_ids: [_ | _] = ids}) do
    by_id =
      from(c in Card, where: c.id in ^ids and is_nil(c.archived_at))
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    for id <- ids, card = by_id[id], do: card
  end

  defp releasing(_running), do: []

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

  @doc """
  What a door says of how `request/3` placed a request. Its warning, while
  a red release stands, is `red_warning/1`'s.
  """
  def said(:started), do: "Release started: a runner fires the release command next."
  def said(:queued), do: "Release queued: it runs when the release under way has ended."
  def said(:joined), do: "A release is already queued behind the one running; this joined it."

  @doc "Why `request/3` refused, in words, for a door."
  def refusal(:not_batched),
    do: "this board releases on merge: set its root board's release mode to batched first"

  def refusal(message) when is_binary(message), do: message

  @doc """
  The warning a release asked for while a red release stands (#3179):
  that the last release failed, the run that failed and the fix card
  filed for it. Given a red release (`red_release/1`), a status
  (`status/1`) or a board; nil when none stands.
  """
  def red_warning(%Board{} = board), do: red_warning(red_release(board))
  def red_warning(%{red_release: red}), do: red_warning(red)
  def red_warning(nil), do: nil

  def red_warning(%{"reason" => reason} = red) do
    run = if(red["run_url"], do: " (#{red["run_url"]})", else: " (no run named)")
    fix = if(red["fix_card_id"], do: "; fix card ##{red["fix_card_id"]} is filed", else: "")
    "Warning: the last release failed: #{reason}#{run}#{fix}."
  end

  def red_warning(_other), do: nil

  @doc """
  One line on where a tree's releases stand (`status/1`), for a banner:
  the release running, the follow-up queued and the cards awaiting. Nil
  when nothing is running, queued or awaiting.
  """
  def line(status), do: line(status, awaiting: true)

  @doc """
  As `line/1`; with `awaiting: false` it leaves out the awaiting count,
  for a view that shows it as a list of the cards (#3038,
  `awaiting_text/1`), and with `red: false` the red release's reason, for
  a view that puts the failing run's link beside it (#2995, `red_text/1`).
  Nil when nothing is left to say.
  """
  def line(%{running: running, queued: queued} = status, opts) do
    red = Map.get(status, :red_release)

    [
      Keyword.get(opts, :red, true) && red_text(status),
      red && red["fix_card_id"] && "fix card ##{red["fix_card_id"]}",
      running && "A release is running (#{length(running.card_ids)} cards)",
      queued && "another is queued",
      Keyword.get(opts, :awaiting, true) && awaiting_text(status)
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  @doc """
  That a tree's last release failed and why (`"Last release failed: the
  release failed at deploy"`), the first part of `line/1`; nil while no
  red release stands.
  """
  def red_text(%{red_release: %{"reason" => reason}}), do: "Last release failed: #{reason}"
  def red_text(_status), do: nil

  @doc """
  How many merged cards await release, in words (`"2 merged, awaiting
  release"`), or nil when none do or a release is running (it takes them).
  """
  def awaiting_text(%{running: nil, awaiting: [_ | _] = awaiting}),
    do: "#{length(awaiting)} merged, awaiting release"

  def awaiting_text(_status), do: nil

  @doc """
  A card has merged (#2835): on a batched tree, one of priority `critical`
  asks for a release. The fix card of a red release (#2838) clears it
  first, and asks whatever its priority. Anything else is left for the
  next trigger, as is a card accepted with no commit (nothing merged): the
  fix card accepted so (#2993) clears the red release and asks for
  nothing, since nothing new merged and a release is a person's or a
  merge's to start.
  """
  def card_merged(%Card{} = card) do
    board = Repo.get!(Board, card.board_id)

    cond do
      not batched?(board) -> :ok
      fix_card?(board, card) -> fixed(board, card, merged?(card))
      not merged?(card) -> :ok
      card.priority == "critical" -> request(board, "critical", "##{card.id} #{card.title}")
      true -> :ok
    end
  end

  defp fix_card?(board, %Card{id: id}),
    do: match?(%{"fix_card_id" => ^id}, current_red(Board.root_id(board)))

  # Accepted with a commit and no "no code" reason: something merged.
  defp merged?(%Card{} = card),
    do: is_binary(merged_sha(card)) and not Slipdock.Verified.Evidence.no_code?(card)

  defp fixed(board, %Card{} = card, true) do
    _ = cleared(root(board), "fix card ##{card.id} merged", "Its merge releases.")
    request(board, "critical", "##{card.id} #{card.title}")
  end

  # Nothing merged (#2993): the red release clears, and the batch waits
  # for the next trigger.
  defp fixed(board, %Card{verify_state: "accepted"} = card, false) do
    _ =
      cleared(
        root(board),
        "fix card ##{card.id} accepted with no code",
        "Nothing was released: the batch goes at the next trigger."
      )

    :ok
  end

  defp fixed(_board, _card, false), do: :ok

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

  A red release standing refuses nothing (#3179): the request is placed,
  and the board's activity warns that the last release failed, naming
  its run (`red_warning/1`), for the doors to say too.
  """
  def request(%Board{} = board, trigger, by \\ nil) when trigger in ~w(critical manual age_cap) do
    root = root(board)

    entry = entry(trigger, by)

    if root.release_mode == "batched",
      do: root |> locked(fn -> place(root, entry) end) |> warned(root),
      else: {:error, :not_batched}
  end

  # A release asked for while a red release stands goes ahead (#3179);
  # the board's activity says what failed last, as the doors do.
  defp warned({:ok, _how, _request} = placed, root) do
    if warning = red_warning(current_red(root.id)), do: log(root, warning)
    placed
  end

  defp warned(result, _root), do: result

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
  `released` there and then on a tree that records no deploys. A job that
  hasn't ended (still queued, claimed or running) changes nothing: its
  request runs on.
  """
  def job_finished(%Job{} = job) do
    if Enum.member?(Job.open_statuses(), job.status), do: :ok, else: job_ended(job)
  end

  defp job_ended(%Job{id: job_id} = job) do
    case Repo.one(from(r in Request, where: r.job_id == ^job_id and r.status == "running")) do
      nil ->
        :ok

      %Request{} = request when job.status == "done" ->
        root = Repo.get!(Board, request.board_id)
        url = run_url(job.output)
        request = request |> Ecto.Changeset.change(run_url: url) |> Repo.update!()
        log(root, "Release fired by job ##{job.id}" <> if(url, do: ": #{url}", else: "."))

        # An open board's banner links the run as soon as it is known (#3005).
        if records_deploys?(root.id),
          do: broadcast_ok(root, request),
          else:
            finish(request, "released", "the release command ran; this board records no deploys")

      %Request{} = request ->
        finish(request, "failed", "job ##{job.id} #{job.status}: #{why_failed(job.output)}")
    end
  end

  # The run a release started: the one the runner daemon names (`release:
  # run <url>`, #2836), else the first link in the job's output.
  defp run_url(output) when is_binary(output) do
    named = Regex.run(~r{^release: run (https?://[^\s"'<>]+)}m, output, capture: :all_but_first)

    case named || Regex.run(~r{https?://[^\s"'<>]+}, output) do
      [url] when byte_size(url) <= 500 -> url
      _ -> nil
    end
  end

  defp run_url(_output), do: nil

  # Why a release job failed: the daemon's own last word on it (`release:
  # …`, #2836), else that the command didn't run.
  defp why_failed(output) when is_binary(output) do
    case Regex.scan(~r{^release: (.+)$}m, output, capture: :all_but_first) do
      [] -> "the release command didn't run"
      said -> said |> List.last() |> hd() |> String.trim()
    end
  end

  defp why_failed(_output), do: "the release command didn't run"

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
    root = root(Repo.get!(Board, deployment.board_id))
    root_id = root.id

    # Recorded before the request ends, so its follow-up's warning names it.
    if deployment.status == "failed" and root.release_mode == "batched",
      do: red_on(root, deployment, open(root_id, "running"))

    # Cleared before the request ends, so its follow-up warns of nothing (#2996).
    if deployment.status == "succeeded", do: deployed_past_red(root, deployment)

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

  # The single follow-up runs once the release before it has ended, a red
  # one too (#3179: it warns). One that can't start (no runner) is dropped,
  # and the board says so.
  defp follow_up(root) do
    case open(root.id, "queued") do
      nil -> :ok
      %Request{} = queued -> root |> start(queued) |> followed(root, queued)
    end
  end

  defp followed({:error, message}, root, queued) do
    Repo.delete!(queued)
    refused(root, message)
  end

  defp followed(started, root, _queued) do
    if warning = red_warning(current_red(root.id)), do: log(root, warning)
    started
  end

  @doc """
  The scheduler's pass (#2835), every minute: ends running requests nothing
  has been heard of for `timeout_hours/0` (their job is cancelled), then
  asks for a release on each batched tree whose oldest card awaiting
  release has waited its `release_age_cap_hours`. The age cap asks only
  when none is running (a follow-up waits only behind one that is). After
  a release that failed or timed out it isn't refused (#3179): it counts
  from that release's end instead of the oldest merge, so a red release
  isn't retried every minute, and it warns as `request/3` does. Returns
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
    ended? =
      match?({:ok, _}, finish(request, "timed_out", "nothing heard for #{@timeout_hours} hours"))

    # The request has ended, so its job's end changes nothing on it. A job
    # that has already finished refuses the cancel and stays as it ended.
    with %Job{} = job <- request.job_id && Repo.get(Job, request.job_id) do
      Runners.cancel_job(job)
    end

    ended?
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
         [%Card{} = oldest | _] <- awaiting_on(root.id),
         waited = waited_hours(oldest, last_ended(root.id), now),
         true <- waited >= root.release_age_cap_hours do
      by = "##{oldest.id} has waited #{waited}h, cap #{root.release_age_cap_hours}h"

      match?({:ok, _, _}, request(root, "age_cap", by))
    else
      _ -> false
    end
  end

  # From the oldest merge, or from the end of a release that failed or
  # timed out since it (#3179), whichever is later.
  defp waited_hours(%Card{completed_at: %DateTime{} = at}, last, now) do
    from =
      case last do
        %Request{status: s, finished_at: %DateTime{} = ended} when s in ["failed", "timed_out"] ->
          if DateTime.compare(ended, at) == :gt, do: ended, else: at

        _ ->
          at
      end

    div(DateTime.diff(now, from, :second), 3600)
  end

  defp waited_hours(_card, _last, _now), do: 0

  ## Red releases (#2838, #3179) ---------------------------------------------

  @doc """
  The red release standing on `board`'s tree, read from its root (nil
  when none does): `reason`, `stage`, `run_url`, `sha`, `deployment_id`,
  `card_ids` (the batch), `fix_card_id` and `failed_at`. It holds nothing
  (#3179): it is what the banner and the warnings say.
  """
  def red_release(%Board{} = board), do: current_red(Board.root_id(board))

  # Rows written before #3179 say `held_at`: read as `failed_at`.
  defp current_red(root_id) do
    case Repo.one(from(b in Board, where: b.id == ^root_id, select: b.red_release)) do
      %{"held_at" => at} = red -> red |> Map.delete("held_at") |> Map.put_new("failed_at", at)
      red -> red
    end
  end

  # A red release is recorded, unless one stands already. A second keeps
  # the first and files no second card; the same failed deploy recorded
  # again (release.yml finishes it failed, then its record-failure job adds
  # the stage and the run to the same row) fills in what the record and
  # its fix card say. It is set under the root's lock, and the fix card
  # filed after it, outside.
  defp red_on(root, %Deployment{} = deployment, running) do
    red = %{
      "reason" => reason(deployment.stage),
      "stage" => deployment.stage,
      "run_url" => deployment.run_url,
      "sha" => deployment.sha,
      "deployment_id" => deployment.id,
      "card_ids" => Enum.uniq(((running && running.card_ids) || []) ++ deployment.card_ids),
      "fix_card_id" => nil,
      "failed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    case locked(root, fn -> set_red(root, red) end) do
      :recorded -> recorded(root, red)
      {:same, red} -> said_more(root, red)
      :kept -> log(root, "Another release failed; the first one's fix card stands, no second.")
    end
  end

  defp reason(nil), do: "the release failed"
  defp reason(stage), do: "the release failed at #{stage}"

  defp set_red(root, red) do
    deployment_id = red["deployment_id"]

    case current_red(root.id) do
      nil ->
        put_red(root, red)
        :recorded

      %{"deployment_id" => ^deployment_id} = old ->
        stage = red["stage"] || old["stage"]

        same = %{
          old
          | "stage" => stage,
            "reason" => reason(stage),
            "run_url" => red["run_url"] || old["run_url"],
            "card_ids" => Enum.uniq(old["card_ids"] ++ red["card_ids"])
        }

        put_red(root, same)
        {:same, same}

      _another ->
        :kept
    end
  end

  defp put_red(root, red),
    do: Repo.update_all(from(b in Board, where: b.id == ^root.id), set: [red_release: red])

  # Newly recorded: the fix card is filed, then named on the record as it
  # stands now (never written back over a clearing, or over what was said
  # since).
  defp recorded(root, red) do
    fix = file_fix_card(root, red)

    case fix && locked(root, fn -> name_fix_card(root, red, fix) end) do
      {:named, now} ->
        if now != %{red | "fix_card_id" => fix.id}, do: refresh_fix_card(now)
        log(root, "Release failed: #{red_said(now)}. Releases aren't held.")

      _unnamed ->
        log(root, "Release failed: #{red_said(red)}. Releases aren't held.")
    end

    broadcast(root)
  end

  # A red release in words, for the board's activity: the reason, the run
  # and the fix card.
  defp red_said(red) do
    run = if(red["run_url"], do: " (#{red["run_url"]})", else: "")
    fix = if(red["fix_card_id"], do: "; fix card ##{red["fix_card_id"]}", else: "")
    "#{red["reason"]}#{run}#{fix}"
  end

  defp name_fix_card(root, red, fix) do
    failed_at = red["failed_at"]

    case current_red(root.id) do
      %{"failed_at" => ^failed_at} = now ->
        now = Map.put(now, "fix_card_id", fix.id)
        put_red(root, now)
        {:named, now}

      _cleared ->
        :cleared
    end
  end

  # The same failure, recorded again with its stage or run: the fix card
  # says it too.
  defp said_more(root, red) do
    refresh_fix_card(red)

    log(
      root,
      "The failed release is recorded at #{red["stage"] || "no stage"}: #{red_said(red)}."
    )

    broadcast(root)
  end

  defp refresh_fix_card(%{"fix_card_id" => id} = red) when is_integer(id) do
    with %Card{} = card <- Repo.get(Card, id) do
      Boards.Cards.update_card(card, fix_attrs(red), actor: Slipdock.Actor.automation())
    end
  end

  defp refresh_fix_card(_red), do: :ok

  defp broadcast(root),
    do: Phoenix.PubSub.broadcast(@pubsub, topic(root.id), {:release_changed, root.id})

  defp broadcast_ok(root, request) do
    broadcast(root)
    {:ok, request}
  end

  # One card of priority critical, on top of the root's ready list, naming
  # the batch and linking the run.
  defp file_fix_card(root, red) do
    root = Boards.get_board!(root.id)
    column = Slipdock.Flow.ready_list(root.columns) || List.first(root.columns)

    with %{} <- column,
         {:ok, card} <-
           Boards.Cards.create_card(column, Map.put(fix_attrs(red), "priority", "critical"),
             actor: Slipdock.Actor.automation(),
             origin: @kind
           ) do
      Boards.Cards.move_card_to_index(card, column, :top, actor: Slipdock.Actor.automation())
      card
    else
      _ -> nil
    end
  end

  defp fix_attrs(red) do
    cards = Repo.all(from(c in Card, where: c.id in ^red["card_ids"], order_by: c.id))

    %{
      "title" => "Red release: fix the #{red["stage"] || "release"} failure",
      "description" => fix_description(red, cards)
    }
  end

  defp fix_description(red, cards) do
    run = if(red["run_url"], do: "[the failing run](#{red["run_url"]})", else: "no run named")
    sha = if(red["sha"], do: " of `#{red["sha"]}`", else: "")

    batch =
      case cards do
        [] -> "No merged card was named in it."
        cards -> Enum.map_join(cards, "\n", &"- ##{&1.id} #{&1.title}")
      end

    "The release#{sha} failed#{if(red["stage"], do: " at **#{red["stage"]}**", else: "")}: " <>
      "#{run}.\n\nReleases on this board aren't held: Release now and the age cap " <>
      "still release, warning that this one failed, until this card merges, which " <>
      "releases. If the cause is outside the repository and this card is accepted " <>
      "with no code, that clears the warning and releases nothing: the batch goes at " <>
      "the next trigger (Release now, a critical merge or the age cap)." <>
      "\n\n**The batch**\n\n#{batch}"
  end

  # A succeeded deploy past the failed release (#2996): to the failed
  # environment, at its sha or with it among its commits (they run from
  # the environment's last succeeded deploy, so a later release names it).
  # It clears the red release, and the fix card has nothing left to do.
  defp deployed_past_red(root, %Deployment{} = deployment) do
    with %{} = red <- current_red(root.id),
         true <- past_red?(red, deployment),
         {:cleared, red} <- locked(root, fn -> clear_red_of(root, red) end) do
      fix = fix_card_settled(red, deployment)
      at = if(same_sha?(red["sha"], deployment.sha), do: "at the failed sha", else: "past it")
      run = if(deployment.run_url, do: " (#{deployment.run_url})", else: "")

      log(
        root,
        "Red release cleared: `#{short(deployment.sha)}` deployed to " <>
          "#{deployment.environment}#{run}, #{at} (#{red["reason"]}).#{fix}"
      )

      broadcast(root)
    else
      _ -> :ok
    end
  end

  defp past_red?(%{"sha" => sha} = red, %Deployment{} = deployment) when is_binary(sha) do
    same_environment?(red, deployment) and
      (same_sha?(sha, deployment.sha) or
         Enum.any?(deployment.commits, &same_sha?(sha, &1["sha"])))
  end

  defp past_red?(_red, _deployment), do: false

  defp same_environment?(red, %Deployment{environment: environment}) do
    case red["deployment_id"] && Repo.get(Deployment, red["deployment_id"]) do
      %Deployment{environment: failed} -> failed == environment
      nil -> true
    end
  end

  # Full or abbreviated: one sha is the start of the other.
  defp same_sha?(a, b) when is_binary(a) and is_binary(b) and a != "" and b != "",
    do: String.starts_with?(a, b) or String.starts_with?(b, a)

  defp same_sha?(_a, _b), do: false

  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 7)
  defp short(_sha), do: "a deploy"

  # Only the red release it judged: one cleared or replaced meanwhile is
  # left alone.
  defp clear_red_of(root, %{"failed_at" => failed_at}) do
    case current_red(root.id) do
      %{"failed_at" => ^failed_at} -> clear_red(root)
      _changed -> {:error, :not_red}
    end
  end

  # The fix card of a cleared red release: archived if it is still waiting in its
  # ready list with no job on it, else told on the card. Says which.
  defp fix_card_settled(%{"fix_card_id" => id}, deployment) when is_integer(id) do
    case Repo.get(Card, id) do
      %Card{completed: false, archived_at: nil} = card ->
        note =
          "**Red release cleared.** `#{short(deployment.sha)}` deployed to " <>
            "#{deployment.environment}" <>
            if(deployment.run_url, do: " ([the run](#{deployment.run_url}))", else: "") <>
            ", so the release this card was filed for is fixed."

        if unstarted?(card) do
          comment(card, note <> "\n\nNothing was started on this card, so it is archived.")
          _ = Boards.Cards.archive_card(card, actor: Slipdock.Actor.automation())
          " Fix card ##{id} was archived: nothing had started on it."
        else
          comment(card, note <> "\n\nThis card isn't needed to clear it any more.")
          " Fix card ##{id} is under way, so it was told and left open."
        end

      _done_or_gone ->
        ""
    end
  end

  defp fix_card_settled(_red, _deployment), do: ""

  defp unstarted?(%Card{} = card) do
    board = Boards.get_board!(card.board_id)

    match?(%{id: id} when id == card.column_id, Slipdock.Flow.ready_list(board.columns)) and
      not Repo.exists?(
        from(j in Job, where: j.card_id == ^card.id and j.status in ^Job.open_statuses())
      )
  end

  defp comment(card, body),
    do: Boards.Comments.add_comment(card, body)

  # A red release cleared by its fix card (#2993), `why` and `then` saying
  # how and what follows. `{:ok, red}`, or `{:error, :not_red}`.
  defp cleared(root, why, then) do
    case locked(root, fn -> clear_red(root) end) do
      {:cleared, red} ->
        log(root, "Red release cleared: #{why} (#{red["reason"]}). #{then}")
        {:ok, red}

      {:error, :not_red} = none ->
        none
    end
  end

  defp clear_red(root) do
    case current_red(root.id) do
      nil ->
        {:error, :not_red}

      red ->
        Repo.update_all(from(b in Board, where: b.id == ^root.id), set: [red_release: nil])
        {:cleared, red}
    end
  end

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

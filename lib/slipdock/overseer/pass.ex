defmodule Slipdock.Overseer.Pass do
  @moduledoc """
  The overseer's model pass (#2068): a runner job of kind `overseer`, run on
  the owner's machine by whatever their runner config's `job_overseer` says
  (a cheap, fast model), like a verify job and never on the server's key.

  **What it reads** is only what `inputs/3` puts in its prompt: the watch's
  conditions (open, and cleared in the last day), the root board's pulse
  (`Slipdock.Pulse.for_board/2`) and the counts the pacing goes by
  (`activity/2`). Never a card's description or comments, a job's log, or
  anything else on the board: the prompt says so, and carries nothing else
  to read.

  **What it does** is answer with one JSON line, `{"health", "digest",
  "look_now"}`. `finished/1` keeps that as a status update on the
  overseer's card on the root board, the digest. It flags; it never acts.

  **When** is `Slipdock.Overseer.Pacing`: `maybe_queue/3` queues a pass when
  one is due and none is open, and sets the next from what is in flight.
  """

  import Ecto.Query

  require Slipdock.Flow.DoingList, as: DoingList

  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, Column, Wait}
  alias Slipdock.Overseer
  alias Slipdock.Overseer.{Pacing, Settings, Watch}
  alias Slipdock.Repo
  alias Slipdock.Runners
  alias Slipdock.Runners.{Job, Runner}

  @max_digest 1000

  @doc """
  The counts the pacing and the prompt go by, for `root`'s tree: runners
  online and busy, cards in doing lists and on ready lists, jobs queued and
  running (the overseer's own left out), waits open, conditions open.
  """
  def activity(%Board{} = root, _now \\ DateTime.utc_now()) do
    ids =
      Repo.all(from(b in Board, where: b.id == ^root.id or b.root_id == ^root.id, select: b.id))

    runners = Repo.all(from(r in Runner, where: r.board_id == ^root.id))

    live =
      from(c in Card,
        where: c.board_id in ^ids and is_nil(c.archived_at) and not c.completed,
        where: is_nil(c.stand_in_for_id)
      )

    in_category = fn category ->
      Repo.aggregate(
        from(c in live,
          join: col in Column,
          on: col.id == c.column_id and col.category == ^category
        ),
        :count
      )
    end

    # A doing list by its name too (#2629): a Simple sub-board's "Doing".
    in_doing =
      Repo.aggregate(
        from(c in live,
          join: col in Column,
          on: col.id == c.column_id and DoingList.doing?(col.category, col.name)
        ),
        :count
      )

    jobs =
      from(j in Job,
        where: j.root_board_id == ^root.id and j.status in ^Job.open_statuses(),
        where: j.kind != ^Overseer.kind(),
        group_by: j.status,
        select: {j.status, count(j.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{
      runners_online: Enum.count(runners, &Runners.online?/1),
      runners_busy: Enum.count(runners, &(not is_nil(&1.current_job_id))),
      cards_in_doing: in_doing,
      ready_cards: in_category.("todo"),
      jobs_queued: Map.get(jobs, "queued", 0),
      jobs_running: Map.get(jobs, "claimed", 0) + Map.get(jobs, "running", 0),
      waits_open:
        Repo.aggregate(
          from(w in Wait,
            join: c in subquery(live),
            on: c.id == w.card_id,
            where: is_nil(w.closed_at)
          ),
          :count
        ),
      conditions_open: length(Watch.open_conditions(root.id))
    }
  end

  @doc """
  Whether anything happened on `root`'s tree since `since` that should bring
  the next pass forward: a card rejected, a wait opened, a job ended.
  """
  def event_since?(_root, nil), do: false

  def event_since?(%Board{} = root, since) do
    ids = from(b in Board, where: b.id == ^root.id or b.root_id == ^root.id, select: b.id)

    Repo.exists?(
      from(c in Card,
        where: c.board_id in subquery(ids) and c.verify_state == "rejected",
        where: c.verify_at > ^since
      )
    ) or
      Repo.exists?(
        from(w in Wait,
          join: c in Card,
          on: c.id == w.card_id,
          where: c.board_id in subquery(ids) and w.inserted_at > ^since
        )
      ) or
      Repo.exists?(
        from(j in Job,
          where: j.root_board_id == ^root.id and j.kind != ^Overseer.kind(),
          where: j.finished_at > ^since
        )
      )
  end

  @doc """
  Everything a pass may read, and nothing else: the board's name, the
  watch's conditions, the pulse and the activity counts.
  """
  def inputs(%Board{} = root, %Settings{} = settings, now \\ DateTime.utc_now()) do
    activity = activity(root, now)

    %{
      board: %{id: root.id, name: root.name},
      now: DateTime.truncate(now, :second),
      since_last_digest: settings.last_digest_at,
      conditions: Enum.map(Watch.open_conditions(root.id), &condition/1),
      cleared_last_day:
        root.id
        |> Watch.cleared_since(DateTime.add(now, -86_400, :second))
        |> Enum.map(&condition/1),
      pulse: Slipdock.Pulse.for_board(root, now: now),
      activity: activity,
      next_pass_minutes: Pacing.next_minutes(activity, settings)
    }
  end

  @doc "The keys `inputs/3` gives: the whole of what a pass reads."
  def input_keys,
    do:
      ~w(board now since_last_digest conditions cleared_last_day pulse activity next_pass_minutes)a

  defp condition(c) do
    %{
      id: c.id,
      check: c.check,
      card: c.card_id,
      title: c.title,
      why: c.why,
      todo: c.todo,
      opened_at: c.opened_at,
      cleared_at: c.cleared_at
    }
  end

  @doc "The prompt a pass is given: what to do, then `inputs` as JSON."
  def prompt(inputs) do
    """
    You are the overseer of the Slipdock board “#{inputs.board.name}”: you watch outcomes, not the work, and say "a person should look now" rarely and accurately.

    Read only the JSON below. Do not run commands, read files, call Slipdock or any other tool, or open cards, logs or the board: everything you may know is here. You flag; you never act.

    The JSON holds the watch's conditions (each fired once, with why and what to do; cleared_last_day are ones that have ended), the board's pulse (flow numbers: in progress, waiting, done in 7 days and today, P50/P85 seconds to done, moves, lists) and the activity counts the next pass is paced by.

    Judge, briefly:
    - Is each slow card slow for what it is, or only slower than usual?
    - Is each wait one only the owner can answer?
    - What changed since the last digest (since_last_digest)?

    Then answer with exactly one line of JSON and nothing after it:
    {"health": "on_track" | "at_risk" | "off_track", "digest": "<one or two sentences, at most #{@max_digest} characters: what moved, what took rounds, what waits on the owner and since when, what is not moving>", "look_now": [{"condition": <id>, "why": "<one sentence>"}]}
    look_now names only the conditions a person should look at now; [] when none should.

    #{Jason.encode!(inputs)}
    """
  end

  @doc """
  Queues a pass for `root` when one is due (its `next_run_at` reached, or
  brought forward by an event) and no pass is open, and sets the next.
  Returns `{:ok, job}`, `:not_due`, `:open` or `{:error, reason}`.
  """
  def maybe_queue(%Board{} = root, %Settings{} = settings, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    next =
      Pacing.forward(
        settings.next_run_at,
        settings.last_queued_at,
        now,
        event_since?(root, settings.last_queued_at)
      )

    cond do
      next && DateTime.compare(next, now) == :gt ->
        if next != settings.next_run_at, do: put(settings, next_run_at: next)
        :not_due

      open_job(root.id) ->
        :open

      true ->
        queue(root, settings, now)
    end
  end

  defp queue(root, settings, now) do
    with {:ok, card} <- Overseer.ensure_card(root, settings) do
      inputs = inputs(root, settings, now)

      case Runners.queue(card, %{
             kind: Overseer.kind(),
             pool: settings.pool,
             prompt: prompt(inputs)
           }) do
        {:ok, %Job{} = job} ->
          put(settings,
            last_queued_at: now,
            last_job_id: job.id,
            next_run_at: DateTime.add(now, inputs.next_pass_minutes * 60, :second)
          )

          {:ok, job}

        {:ok, :already_open, job} ->
          {:ok, job}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc "The open pass on `root_id`'s tree, or nil."
  def open_job(root_id) do
    Repo.one(
      from(j in Job,
        where: j.root_board_id == ^root_id and j.kind == ^Overseer.kind(),
        where: j.status in ^Job.open_statuses(),
        limit: 1
      )
    )
  end

  defp put(settings, changes) do
    Repo.update_all(from(s in Settings, where: s.id == ^settings.id),
      set: Keyword.put(changes, :updated_at, DateTime.utc_now(:second))
    )
  end

  @doc """
  After a pass ends: its answer, when it gave one, as the digest, a status
  update on the overseer's card and the settings' last digest. Returns
  `{:ok, digest}` or `:no_digest`.
  """
  def finished(%Job{kind: kind} = job) do
    with true <- kind == Overseer.kind(),
         %Settings{} = settings <- Repo.get_by(Settings, board_id: job.root_board_id),
         {:ok, digest} <- parse(job.output),
         %Card{} = card <- Repo.get(Card, job.card_id) do
      body = digest_body(digest)

      Boards.add_status_update(card, nil, %{"health" => digest.health, "body" => body},
        quiet: true
      )

      put(settings,
        last_digest: body,
        last_health: digest.health,
        last_digest_at: DateTime.utc_now(:second)
      )

      {:ok, digest}
    else
      _ -> :no_digest
    end
  end

  @doc """
  The pass's answer in `output`: the last line (or the whole, or a fenced
  block) that is a JSON object with a `digest`, as `{:ok, %{health, digest,
  look_now}}`, or `:error`. An unknown health is `at_risk`.
  """
  def parse(output) when is_binary(output) do
    fenced = Regex.scan(~r/```(?:json)?\s*(\{.*?\})\s*```/s, output, capture: :all_but_first)

    ([String.trim(output)] ++ List.flatten(fenced) ++ Enum.reverse(String.split(output, ~r/\R/)))
    |> Enum.find_value(:error, fn text ->
      case Jason.decode(String.trim(text)) do
        {:ok, %{"digest" => digest} = map} when is_binary(digest) and digest != "" ->
          {:ok,
           %{
             health: health(map["health"]),
             digest: String.slice(String.trim(digest), 0, @max_digest),
             look_now: look_now(map["look_now"])
           }}

        _ ->
          nil
      end
    end)
  end

  def parse(_), do: :error

  defp health(h) when h in ["on_track", "at_risk", "off_track"], do: h
  defp health(_), do: "at_risk"

  defp look_now(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      %{"why" => why} = item when is_binary(why) ->
        [%{condition: item["condition"], why: String.slice(why, 0, 300)}]

      _ ->
        []
    end)
    |> Enum.take(5)
  end

  defp look_now(_), do: []

  defp digest_body(%{digest: digest, look_now: []}), do: digest

  defp digest_body(%{digest: digest, look_now: items}) do
    digest <>
      "\n\nLook now:\n" <>
      Enum.map_join(items, "\n", fn i ->
        ref = if is_integer(i.condition), do: "condition #{i.condition}: ", else: ""
        "- " <> ref <> i.why
      end)
  end
end

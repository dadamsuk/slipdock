defmodule Slipdock.Health.Detectors.Deadlock do
  @moduledoc """
  Cycles in what waits on what (#1750 was one). Over a tree it builds a
  waits-for graph:

    * a queued job → what holds it: the cards in progress it waits beside
      (`wait_while_doing`), the card in progress whose lane its card overlaps,
      the cards filling a WIP limit, or — for a merge job — the jobs keeping
      every merge runner busy (holding a job, and not asking for another
      since it claimed it: runners take merges mid-pass);
    * a held answer (`Slipdock.Runners.Requeue`, `pending`) → the job of its
      rule it waits to close;
    * an open card → the answer to its question, still held; and its
      unfinished blockers;
    * a card pending verification → its verify job; a merging card → its
      merge job;
    * a claimed or running job → the subcards of its card waiting to merge
      (the pass that built them waits for them).

  A cycle is an incident, naming every edge in words. Safe fixes, in order:
  withdraw a work job in the cycle that was **never handed out** (it ends
  cancelled with a comment saying it gave way, and its card keeps its place
  and goes next), then send the held answers (`Requeue.drain/1`) and run the
  feeds. A cycle with nothing safe to withdraw — only card dependencies, or
  one through a claimed job — is flagged on every card in it. It never
  cancels a claimed or running job, moves a card, or changes dependencies.
  """
  @behaviour Slipdock.Health.Detector

  import Ecto.Query

  require Slipdock.Flow.DoingList, as: DoingList

  alias Slipdock.{Automations, Boards, Lanes, Repo, Runners, Verified}
  alias Slipdock.Automations.{Rule, Spec}
  alias Slipdock.Boards.{Board, Card, Column, Wait}
  alias Slipdock.Health.{Context, Runs}
  alias Slipdock.Runners.{Job, Requeue}

  @max_cycles 20

  @impl true
  def key, do: "deadlock"
  @impl true
  def label, do: "Deadlock"
  @impl true
  def defaults, do: %{}

  @impl true
  def detect(%Context{} = ctx, _settings) do
    graph = graph(ctx)

    graph
    |> cycles()
    |> Enum.map(&finding(&1, graph))
  end

  ## The graph -----------------------------------------------------------------

  @doc false
  # %{from => [{to, words}]}, nodes {:job, id}, {:card, id}, {:answer, wait_id}.
  def graph(%Context{} = ctx) do
    root_id = ctx.board.id

    open_jobs =
      Repo.all(
        from(j in Job,
          where: j.root_board_id == ^root_id and j.status in ^Job.open_statuses(),
          order_by: j.id
        )
      )

    queued = Enum.filter(open_jobs, &(&1.status == "queued"))
    live = Enum.filter(open_jobs, &Enum.member?(~w(claimed running), &1.status))
    lanes = Lanes.held_cards(root_id)
    worked = Runners.worked(root_id)

    edges =
      Enum.flat_map(queued, &queued_edges(&1, {lanes, worked}, live, ctx)) ++
        answer_edges(root_id, open_jobs) ++
        dependency_edges(ctx.board_ids) ++
        finishing_edges(ctx.board_ids, open_jobs) ++
        Enum.flat_map(live, &merge_wait_edges/1)

    Enum.reduce(edges, %{}, fn {from, to, words}, acc ->
      Map.update(acc, from, [{to, words}], &[{to, words} | &1])
    end)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(Enum.uniq_by(v, &elem(&1, 0)))} end)
  end

  defp queued_edges(job, {lanes, worked}, live, ctx) do
    finishing = Enum.member?(Verified.finishing_kinds(), job.kind)
    node = {:job, job.id}

    beside =
      if job.wait_while_doing,
        do:
          for(
            c <- doing_cards([job.board_id]),
            c.id != job.card_id,
            worked?(c, worked),
            do: {node, {:card, c.id}, "job ##{job.id} waits while ##{c.id} is in progress"}
          ),
        else: []

    lane =
      case !finishing && lanes[job.card_id] do
        %Card{id: id} ->
          [
            {node, {:card, id},
             "job ##{job.id}'s card ##{job.card_id} overlaps the lane of ##{id}, in progress"}
          ]

        _ ->
          []
      end

    wip =
      with false <- finishing,
           {%Column{} = column, _count} <- Runners.wip_full(job.board_id),
           false <- Enum.member?(Enum.map(doing_cards([job.board_id]), & &1.id), job.card_id) do
        for c <- column_cards(column.id),
            do:
              {node, {:card, c.id},
               "job ##{job.id} waits for a WIP slot in #{column.name}, held by ##{c.id}"}
      else
        _ -> []
      end

    merge =
      if job.kind == "merge", do: merge_runner_edges(job, live, ctx), else: []

    beside ++ lane ++ wip ++ merge
  end

  # A merge job waits for a merge runner; when every one online is busy, it
  # waits for the jobs they hold. Holding a job isn't being busy: runners
  # take merges mid-pass (#1849), so a runner that asked for work after its
  # newest claim is free for the merge, and there is no edge at all.
  defp merge_runner_edges(job, live, ctx) do
    held =
      job.root_board_id
      |> Runs.runners()
      |> Enum.filter(&(Runners.takes_merge?(&1) and Runs.online?(&1, ctx.now)))
      |> Enum.map(&{&1, held_jobs(&1, live)})

    if held != [] and Enum.all?(held, &busy?/1) do
      for {r, jobs} <- held,
          held_job <- jobs,
          do:
            {{:job, job.id}, {:job, held_job.id},
             "merge job ##{job.id} waits for runner #{r.name}, busy with job ##{held_job.id}"}
    else
      []
    end
  end

  # The live jobs `runner` holds: those leased to it, and the one it claimed last.
  defp held_jobs(runner, live),
    do: Enum.filter(live, &(&1.runner_id == runner.id or &1.id == runner.current_job_id))

  # Busy: it holds a live job and hasn't asked for another since its newest
  # claim. One that never said when it asked (`asked_at` nil) counts as busy.
  defp busy?({_runner, []}), do: false
  defp busy?({%{asked_at: nil}, _jobs}), do: true

  defp busy?({%{asked_at: asked}, jobs}) do
    case jobs |> Enum.map(& &1.claimed_at) |> Enum.reject(&is_nil/1) do
      [] -> true
      claims -> DateTime.compare(asked, Enum.max(claims, DateTime)) != :gt
    end
  end

  # A held answer waits for its rule's open job; the card it is for waits
  # for the answer.
  defp answer_edges(root_id, open_jobs) do
    from(w in Wait,
      join: j in Job,
      on: j.id == w.job_id,
      where: w.requeue_state == "pending" and j.root_board_id == ^root_id,
      select: {w, j}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {wait, asking} ->
      held =
        open_jobs
        |> Enum.filter(&(&1.rule_id == asking.rule_id))
        |> Enum.min_by(& &1.id, fn -> nil end)

      node = {:answer, wait.id}
      cards = Enum.uniq([asking.card_id, wait.card_id])

      waits =
        for id <- cards,
            open_card?(id),
            do: {{:card, id}, node, "##{id} waits for the answer on ##{wait.card_id} to be sent"}

      holds =
        if held,
          do: [
            {node, {:job, held.id},
             "the answer on ##{wait.card_id} waits for job ##{held.id} (#{held.status}, on ##{held.card_id}) to close"}
          ],
          else: []

      waits ++ holds
    end)
  end

  defp dependency_edges(board_ids) do
    from(d in "card_dependencies",
      join: a in Card,
      on: a.id == d.blocked_id,
      join: b in Card,
      on: b.id == d.blocker_id,
      where:
        a.board_id in ^board_ids and is_nil(a.archived_at) and a.completed == false and
          is_nil(b.archived_at) and b.completed == false,
      select: {a.id, b.id}
    )
    |> Repo.all()
    |> Enum.map(fn {a, b} -> {{:card, a}, {:card, b}, "##{a} is blocked by ##{b}"} end)
  end

  defp finishing_edges(board_ids, open_jobs) do
    from(c in Card,
      where:
        c.board_id in ^board_ids and c.verify_state in ["pending", "merging"] and
          is_nil(c.archived_at),
      select: {c.id, c.verify_state}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {id, state} ->
      kind = if state == "pending", do: "verify", else: "merge"

      for j <- open_jobs,
          j.card_id == id,
          j.kind == kind,
          do: {{:card, id}, {:job, j.id}, "##{id} waits for its #{kind} job ##{j.id}"}
    end)
  end

  # The pass working a card waits for that card's subcards to merge.
  defp merge_wait_edges(%Job{} = job) do
    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where:
        b.parent_card_id == ^job.card_id and c.verify_state == "merging" and
          is_nil(c.archived_at),
      select: c.id
    )
    |> Repo.all()
    |> Enum.map(
      &{{:job, job.id}, {:card, &1},
       "job ##{job.id} on ##{job.card_id} waits for its subcard ##{&1} to merge"}
    )
  end

  # Only a card a runner job is working on holds a job that waits while
  # anything is in progress (#1922), as `Runners.waiting_on/1` counts it.
  defp worked?(%{id: id, board_id: board_id}, {cards, boards}),
    do: Enum.member?(cards, id) or Enum.member?(boards, board_id)

  defp doing_cards(board_ids) do
    from(c in Card,
      join: col in assoc(c, :column),
      where:
        c.board_id in ^board_ids and DoingList.doing?(col.category, col.name) and
          is_nil(c.archived_at) and
          c.completed == false,
      select: %{id: c.id, board_id: c.board_id}
    )
    |> Repo.all()
  end

  defp column_cards(column_id) do
    from(c in Card,
      where:
        c.column_id == ^column_id and is_nil(c.archived_at) and c.completed == false and
          is_nil(c.stand_in_for_id),
      select: %{id: c.id}
    )
    |> Repo.all()
  end

  defp open_card?(id) do
    Repo.exists?(
      from(c in Card, where: c.id == ^id and is_nil(c.archived_at) and c.completed == false)
    )
  end

  ## Cycles --------------------------------------------------------------------

  @doc false
  # Every elementary cycle reachable in `graph`, each as its node list
  # rotated to start at its smallest node, at most @max_cycles of them.
  def cycles(graph) do
    graph
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(MapSet.new(), fn start, found ->
      if MapSet.size(found) >= @max_cycles, do: found, else: walk(graph, start, [start], found)
    end)
    |> Enum.sort()
  end

  defp walk(graph, node, path, found) do
    Enum.reduce(Map.get(graph, node, []), found, fn {next, _}, acc ->
      cond do
        MapSet.size(acc) >= @max_cycles ->
          acc

        Enum.member?(path, next) ->
          cycle = path |> Enum.reverse() |> Enum.drop_while(&(&1 != next))
          MapSet.put(acc, rotate(cycle))

        length(path) > 40 ->
          acc

        true ->
          walk(graph, next, [next | path], acc)
      end
    end)
  end

  defp rotate(cycle) do
    min = Enum.min(cycle)
    {before, rest} = Enum.split_while(cycle, &(&1 != min))
    rest ++ before
  end

  defp finding(cycle, graph) do
    pairs = Enum.zip(cycle, tl(cycle) ++ [hd(cycle)])

    words =
      Enum.map(pairs, fn {a, b} -> graph |> Map.fetch!(a) |> List.keyfind!(b, 0) |> elem(1) end)

    job_ids = for {:job, id} <- cycle, do: id
    jobs = Repo.all(from(j in Job, where: j.id in ^job_ids))

    cards =
      Enum.uniq(
        for({:card, id} <- cycle, do: id) ++
          Enum.map(jobs, & &1.card_id) ++
          answer_cards(cycle)
      )
      |> Enum.reject(&is_nil/1)

    withdraw =
      for j <- Enum.sort_by(jobs, & &1.id),
          j.status == "queued" and j.attempts == 0 and is_integer(j.rule_id) and
            not Enum.member?(Verified.finishing_kinds(), j.kind),
          do: j.id

    rules =
      Enum.uniq(Enum.map(jobs, & &1.rule_id) ++ answer_rules(cycle)) |> Enum.reject(&is_nil/1)

    %{
      subject: %{"cards" => cards, "jobs" => job_ids},
      card_id: List.first(cards),
      state: Enum.map(cycle, &node_key/1),
      summary: "A deadlock: " <> Enum.join(words, "; ") <> ".",
      data: %{
        "withdraw" => withdraw,
        "rules" => rules,
        "cards_only" => Enum.all?(cycle, &match?({:card, _}, &1)),
        "edges" => words
      }
    }
  end

  defp answer_cards(cycle) do
    ids = for {:answer, id} <- cycle, do: id
    Repo.all(from(w in Wait, where: w.id in ^ids, select: w.card_id))
  end

  defp answer_rules(cycle) do
    ids = for {:answer, id} <- cycle, do: id

    Repo.all(
      from(w in Wait,
        join: j in Job,
        on: j.id == w.job_id,
        where: w.id in ^ids,
        select: j.rule_id
      )
    )
  end

  defp node_key({kind, id}), do: "#{kind}:#{id}"

  ## The fix -------------------------------------------------------------------

  @impl true
  def resolve(%{data: %{"cards_only" => true}}, _attempt), do: :no_fix

  def resolve(%{data: data} = incident, _attempt) do
    withdrawn = withdraw_one(data["withdraw"] || [], incident)
    rules = Repo.all(from(r in Rule, where: r.id in ^(data["rules"] || [])))
    sent = Enum.flat_map(rules, &send_held/1)

    case {withdrawn, sent} do
      {nil, []} ->
        :no_fix

      {nil, sent} ->
        {:tried, "sent what the runners were holding: " <> Enum.join(sent, ", ")}

      {job, sent} ->
        {:fixed,
         "withdrew job ##{job.id}, which had never been handed out; ##{job.card_id} keeps its " <>
           "place and goes next" <>
           if(sent == [], do: "", else: "; then " <> Enum.join(sent, ", "))}
    end
  end

  defp withdraw_one(ids, incident) do
    Enum.find_value(ids, fn id ->
      with %Job{status: "queued", attempts: 0} = job <- Repo.get(Job, id),
           {:ok, job} <-
             Runners.withdraw_job(
               job,
               "gave way to break a deadlock (health incident ##{incident.id})"
             ) do
        with %Card{} = card <- Repo.get(Card, job.card_id) do
          Boards.Comments.add_comment(
            card,
            "**Health monitor:** job ##{job.id} gave way to break a deadlock (incident " <>
              "##{incident.id}). It had never been handed out. This card keeps its place in " <>
              "the list and goes next."
          )
        end

        job
      else
        _ -> nil
      end
    end)
  end

  # Held answers first, then the feed: what `Requeue.drain/1` and
  # `Automations.feed/2` would do on their own once the job closes.
  defp send_held(%Rule{} = rule) do
    drained =
      case Requeue.drain(rule) do
        %Job{} = job -> ["the held answer on ##{job.card_id} (job ##{job.id})"]
        _ -> []
      end

    fed =
      if Spec.feed?(rule.spec) do
        case Automations.feed(rule) do
          {:ok, %Card{} = card} -> ["##{card.id} from rule “#{rule.name}”"]
          _ -> []
        end
      else
        []
      end

    drained ++ fed
  end
end

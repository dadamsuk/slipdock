defmodule Slipdock.Now do
  @moduledoc """
  What is happening right now on a board's tree (#2103): which runners are
  doing what, which cards are in progress and where they sit, and the jobs
  waiting for a runner. One read of what is already recorded; nothing is
  stored.

  `snapshot/2` reads it for the tree the board is in (its root and every
  sub-board under it, since runners take work from the whole tree), as
  plain maps that the Right now page (`SlipdockWeb.NowLive.Index`), the
  REST API (`GET /api/boards/:board/now`) and MCP (`get_board` `now: true`)
  all give out (the two doors through `SlipdockWeb.API.NowJSON`):

    * `runners` — every runner of the tree, newest first: `id`, `name`,
      `pool`, `online`, `session` (a Claude session working through an API
      token rather than a runner of its own) and `jobs`, the jobs it holds now
      (claimed or running), oldest first;
    * `in_progress` — every open, unarchived card in a list whose category
      is *In progress* (`doing`), and every unarchived card a build job
      (claimed or running, of a kind that isn't `verify`, `merge`, `overseer`
      or `probe`) holds wherever it sits (#2633), longest there first: `id`, `title`, where
      it is (`board_id`, `board`, `list`, `parent`, the epic whose sub-board
      holds it, `%{id, title, board_id}` or nil), `state` (`Slipdock.CardState`'s line)
      and `state_kind`, `loop` (the runner and kind holding it), `holds` (what
      it waits on: `"waiting"`, `"verifying"`, `"merging"`, `"blocked"`,
      `"review"`, `"stuck"`, the health monitor's flag, and last
      `"over_usual"`, only past its list's usual stay, #2131), `age` (seconds
      in the list, nil when unknown) and `in_doing` (false for a card a build
      job holds outside a doing list, so a card that slipped through shows);
    * `queued` — the jobs queued for a runner, oldest first, each with
      `held`, the reason it isn't being handed out (nil when only a runner
      is missing);
    * `counts` — `runners`, `online`, `working` (runners holding a job),
      `in_progress` and `queued`.

  A job (in a runner's `jobs` or in `queued`) is `id`, `kind`, `status`,
  `pool`, `card_id`, `card`, `board_id`, `step`, `step_at` and `since` (when
  it was claimed, or queued).
  """

  import Ecto.Query

  alias Slipdock.{CardState, Repo, Runners}
  alias Slipdock.Boards.{Board, Card, Column, Wait}
  alias Slipdock.Runners.{Job, Runner}

  # Job kinds that check or finish a card, or do no card's work: a card one
  # of them holds is in progress only when it sits in a doing list.
  @not_building ~w(verify merge overseer probe)

  @doc "Why a reader of a sub-board who can't read its root is refused."
  def refusal,
    do: "Right now covers the whole tree from its root board, which you can't read"

  @doc "What is happening now on `board`'s tree; see the moduledoc."
  def snapshot(%Board{} = board, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    root_id = Board.root_id(board)
    boards = tree(root_id)
    runners = Repo.all(from(r in Runner, where: r.board_id == ^root_id, order_by: [desc: r.id]))
    jobs = open_jobs(root_id)
    {working, queued} = Enum.split_with(jobs, &Enum.member?(~w(claimed running), &1.status))
    held = Runners.held_reasons(queued)
    by_runner = Enum.group_by(working, & &1.runner_id)
    cards = in_progress(boards, building(working), now)

    runner_rows =
      Enum.map(runners, fn r ->
        %{
          id: r.id,
          name: r.name,
          pool: r.pool,
          online: Runners.online?(r),
          session: not is_nil(r.api_token_id),
          jobs: Enum.map(Map.get(by_runner, r.id, []), &job/1)
        }
      end)

    %{
      runners: runner_rows,
      in_progress: cards,
      queued: Enum.map(queued, &Map.put(job(&1), :held, held[&1.id])),
      counts: %{
        runners: length(runners),
        online: Enum.count(runner_rows, & &1.online),
        working: Enum.count(runner_rows, &(&1.jobs != [])),
        in_progress: length(cards),
        queued: length(queued)
      }
    }
  end

  @doc """
  One line saying what is happening, for the board page: `"2 runners
  working · 3 cards in progress · 1 queued"`. Nil when nothing is.
  """
  def sentence(%{counts: c}) do
    parts =
      [
        c.working > 0 && plural(c.working, "runner", "runners") <> " working",
        c.in_progress > 0 && plural(c.in_progress, "card", "cards") <> " in progress",
        c.queued > 0 && "#{c.queued} queued"
      ]
      |> Enum.filter(& &1)

    if parts == [], do: nil, else: Enum.join(parts, " · ")
  end

  @doc """
  The counts alone, for the board page's line: `snapshot/2`'s `counts`
  without reading each card's state.
  """
  def counts(%Board{} = board) do
    root_id = Board.root_id(board)
    board_ids = root_id |> tree() |> Map.keys()

    jobs =
      from(j in Job,
        where: j.root_board_id == ^root_id and j.status in ^Job.open_statuses(),
        group_by: j.status,
        select: {j.status, count(j.id)}
      )
      |> Repo.all()
      |> Map.new()

    working =
      Repo.one(
        from(j in Job,
          where:
            j.root_board_id == ^root_id and j.status in ~w(claimed running) and
              not is_nil(j.runner_id),
          select: count(j.runner_id, :distinct)
        )
      )

    building =
      from(j in Job,
        where:
          j.root_board_id == ^root_id and j.status in ~w(claimed running) and
            j.kind not in @not_building and not is_nil(j.card_id),
        select: j.card_id
      )
      |> Repo.all()

    %{
      working: working,
      in_progress: Repo.aggregate(in_progress_query(board_ids, building), :count),
      queued: Map.get(jobs, "queued", 0)
    }
  end

  defp plural(1, one, _many), do: "1 #{one}"
  defp plural(n, _one, many), do: "#{n} #{many}"

  # The tree's boards that aren't archived, by id, each with the card its
  # sub-board hangs from.
  defp tree(root_id) do
    from(b in Board,
      where: (b.id == ^root_id or b.root_id == ^root_id) and is_nil(b.archived_at),
      preload: :parent_card
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp open_jobs(root_id) do
    from(j in Job,
      where: j.root_board_id == ^root_id and j.status in ^Job.open_statuses(),
      order_by: [asc: j.id],
      preload: :card
    )
    |> Repo.all()
  end

  defp job(%Job{} = j) do
    %{
      id: j.id,
      kind: j.kind,
      status: j.status,
      pool: j.pool,
      card_id: j.card_id,
      card: j.card && j.card.title,
      board_id: j.board_id,
      step: j.step,
      step_at: j.step_at,
      since: j.claimed_at || j.inserted_at
    }
  end

  # The cards the build jobs among `working` hold (#2633).
  defp building(working) do
    for %Job{card_id: id, kind: kind} <- working,
        is_integer(id) and not Enum.member?(@not_building, kind),
        uniq: true,
        do: id
  end

  # The cards in a doing list, and the ones a build job holds wherever they
  # sit (#2633): a card whose agent never moved it still shows.
  defp in_progress_query(board_ids, building) do
    from(c in Card,
      join: col in Column,
      on: col.id == c.column_id,
      where:
        c.board_id in ^board_ids and is_nil(c.archived_at) and
          ((col.category == "doing" and not c.completed) or c.id in ^building)
    )
  end

  defp in_progress(boards, building, now) do
    cards =
      boards
      |> Map.keys()
      |> in_progress_query(building)
      |> preload([:column, wait: ^{from(w in Wait, where: is_nil(w.closed_at)), [:on_user]}])
      |> Repo.all()

    cards
    |> Enum.group_by(& &1.board_id)
    |> Enum.flat_map(fn {board_id, cards} -> CardState.put(cards, boards[board_id], now: now) end)
    |> Enum.map(&card(&1, boards[&1.board_id]))
    |> Enum.sort_by(&{-(&1.age || 0), &1.id})
  end

  defp card(%Card{} = c, %Board{} = b) do
    state = c.state || %CardState{}

    %{
      id: c.id,
      title: c.title,
      board_id: b.id,
      board: b.name,
      list: c.column.name,
      parent: parent(b.parent_card),
      state: state.line,
      state_kind: state.kind,
      loop: state.loop,
      holds: holds(c, state),
      age: state.age,
      in_doing: c.column.category == "doing"
    }
  end

  defp parent(nil), do: nil
  defp parent(%Card{} = p), do: %{id: p.id, title: p.title, board_id: p.board_id}

  @doc false
  # What a card in progress waits on, the first that applies; nil when it
  # is simply being worked (or nobody is on it). `stuck` is the health
  # monitor's flag alone, an incident for a person; a card merely past its
  # list's usual stay is `over_usual`, a note rather than a hold, and comes
  # last (#2131).
  def holds(%Card{} = c, %CardState{} = state) do
    flag? = &Enum.member?(c.flags || [], &1)

    Enum.find_value(
      [
        {"waiting", state.kind == "waiting" or flag?.("waiting")},
        {"merging", c.verify_state == "merging"},
        {"verifying", c.verify_state == "pending"},
        {"blocked", flag?.("blocked")},
        {"review", flag?.("review")},
        {"stuck", flag?.("stuck")},
        {"over_usual", state.stuck}
      ],
      fn {hold, on?} -> if on?, do: hold end
    )
  end
end

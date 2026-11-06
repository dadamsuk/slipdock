defmodule Slipdock.Findings do
  @moduledoc """
  What each card taught, kept on the board for every pass (W-2310 §Findings).

  A pass writes them as a `Findings:` block in its closing comment, beside the
  `Handbook:` line (`Slipdock.Findings.Block`); the system records its own
  signals the same way (`record/1`). They are kept on the root board of the
  tree, listed (`list/2`) and triaged: promoted into the handbook, dismissed,
  or merged into another finding of the same tree.

  Settled knowledge goes straight into the handbook; findings are for what is
  uncertain, cuts across cards, or shows the handbook was wrong, so they get a
  second look before they become rules.

  One record per lesson (#1941): a lesson said again on the same card counts on
  the open finding it repeats (`Slipdock.Findings.Lesson.near?/2`), and one
  said on another card of the tree is recorded `merged` into the open finding
  with the same normalised text (`Lesson.same?/2`), which counts it. `rule`
  and `handbook-wrong` items are never merged across cards: a rule candidate
  is judged on its own card. A `tooling (runner)` item is kept with the
  runner (`scope: "runner"`) and out of the board's default list.
  """
  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Comment}
  alias Slipdock.Findings.{Block, Finding, Lesson, Promote}
  alias Slipdock.Repo
  alias Slipdock.Runners.Job

  # Kinds judged per card: never merged into another card's finding.
  @per_card ~w(rule handbook-wrong)
  # What an automatic merge into another card's finding is marked with.
  @same_lesson "same-lesson"

  @doc """
  Keeps the findings a card's comment carries. Idempotent: parsing a comment
  again (after an edit) first takes back what it added before. An item that
  repeats an open finding on the card (`Lesson.near?/2`, same kind) adds this
  comment to its count rather than making another; one already triaged on the
  card is not made again. An item matching an open finding on another card of
  the tree (`Lesson.same?/2`, same kind and scope, not `rule` or
  `handbook-wrong`) is recorded merged into it, which counts it. A comment on
  a page, or with no block, makes none. Returns the findings it made or counted.
  """
  def from_comment(comment, opts \\ [])

  def from_comment(%Comment{card_id: nil}, _opts), do: {:ok, []}

  def from_comment(%Comment{} = comment, opts) do
    items = Block.parse(comment.body) || []

    Repo.transaction(fn ->
      retract(comment)

      case Repo.get(Card, comment.card_id) do
        nil ->
          []

        card ->
          user = opts[:by] || (comment.user_id && Repo.get(User, comment.user_id))
          at = %{card: card, comment: comment, root: root_id(card), user: user}
          Enum.flat_map(items, &keep_item(&1, at))
      end
    end)
    |> tap_ok(&Promote.consider/1)
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other

  defp keep_item(item, at) do
    item = %{item | text: String.slice(item.text, 0, Finding.max_text())}
    scope = Map.get(item, :scope, "board")
    item = Map.put(item, :scope, scope)

    case on_card(item, at) do
      {:open, finding} -> count_comment(finding, at.comment)
      :triaged -> []
      nil -> elsewhere(item, at)
    end
  end

  # The card's own finding for this lesson: an open one to count on, or one a
  # person already decided about (kept once, as it was).
  defp on_card(item, %{card: card}) do
    same =
      from(f in Finding,
        where: f.card_id == ^card.id and f.kind == ^item.kind and f.source == "agent",
        order_by: f.id
      )
      |> Repo.all()
      |> Enum.filter(&Lesson.near?(&1.text, item.text))

    cond do
      open = Enum.find(same, &(&1.status == "open")) -> {:open, open}
      same != [] -> :triaged
      true -> nil
    end
  end

  defp count_comment(%Finding{} = finding, %Comment{id: id}) do
    if Enum.member?(finding.comment_ids, id) do
      []
    else
      finding
      |> Ecto.Changeset.change(count: finding.count + 1, comment_ids: finding.comment_ids ++ [id])
      |> Repo.update!()
      |> List.wrap()
    end
  end

  defp elsewhere(item, at) do
    runner = if item.scope == "runner", do: runner_job(at.card)

    case not Enum.member?(@per_card, item.kind) && same_lesson(item, at, runner) do
      %Finding{} = target ->
        target |> Ecto.Changeset.change(count: target.count + 1) |> Repo.update!()

        item
        |> new_finding(at, runner)
        |> Finding.triage_changeset(%{status: "merged"}, target.id)
        |> Ecto.Changeset.put_change(:cause, @same_lesson)
        |> Repo.insert!()
        |> List.wrap()

      _ ->
        item |> new_finding(at, runner) |> Repo.insert!() |> List.wrap()
    end
  end

  # The open finding on another card of the tree with the same lesson, kind,
  # scope (and runner, for a runner's), oldest first.
  defp same_lesson(item, at, runner) do
    runner_id = runner && runner.runner_id

    from(f in Finding,
      where:
        f.board_id == ^at.root and f.status == "open" and f.kind == ^item.kind and
          f.scope == ^item.scope and f.lesson == ^Lesson.normalise(item.text) and
          (is_nil(f.card_id) or f.card_id != ^at.card.id),
      order_by: f.id,
      limit: 1
    )
    |> same_runner(item.scope, runner_id)
    |> Repo.one()
  end

  defp same_runner(q, "runner", nil), do: where(q, [f], is_nil(f.runner_id))
  defp same_runner(q, "runner", id), do: where(q, [f], f.runner_id == ^id)
  defp same_runner(q, _scope, _id), do: q

  defp new_finding(item, at, runner) do
    %Finding{
      board_id: at.root,
      card_id: at.card.id,
      comment_id: at.comment.id,
      comment_ids: [at.comment.id],
      user_id: at.user && at.user.id,
      job_id: runner && runner.id,
      runner_id: runner && runner.runner_id
    }
    |> Finding.changeset(%{
      by: at.user && User.display_name(at.user),
      kind: item.kind,
      source: "agent",
      text: item.text,
      scope: item.scope
    })
  end

  # The job a pass on this card runs in, when one is: the card's own, else
  # the nearest epic's above it (a runner works an epic's subcards in its job).
  defp runner_job(%Card{} = card, depth \\ 0) do
    job =
      Repo.one(
        from j in Job,
          where:
            j.card_id == ^card.id and j.status in ~w(claimed running) and not is_nil(j.runner_id),
          order_by: [desc: j.id],
          limit: 1
      )

    with nil <- job,
         true <- depth < 10,
         %Board{parent_card_id: parent_id} when not is_nil(parent_id) <-
           Repo.get(Board, card.board_id),
         %Card{} = parent <- Repo.get(Card, parent_id) do
      runner_job(parent, depth + 1)
    else
      %Job{} = job -> job
      _ -> nil
    end
  end

  @doc """
  A comment is going: what it added to open findings goes with it. Triaged
  ones stay, since the decision about them still stands.
  """
  def comment_deleted(%Comment{} = comment), do: retract(comment)

  # Takes back what a comment added: a finding only it said goes, one others
  # said too loses this comment's count, and a repeat it merged into another
  # card's finding goes and takes its count back.
  defp retract(%Comment{id: id}) do
    from(f in Finding,
      where: f.source == "agent" and f.status == "open" and ^id in f.comment_ids
    )
    |> Repo.all()
    |> Enum.each(&take_back(&1, id))

    from(f in Finding,
      where:
        f.source == "agent" and f.status == "merged" and f.cause == @same_lesson and
          f.comment_id == ^id
    )
    |> Repo.all()
    |> Enum.each(fn repeat ->
      with %Finding{} = target <-
             repeat.merged_into_id && Repo.get(Finding, repeat.merged_into_id) do
        target |> Ecto.Changeset.change(count: max(target.count - 1, 1)) |> Repo.update!()
      end

      Repo.delete!(repeat)
    end)
  end

  defp take_back(%Finding{comment_ids: [id], count: 1} = finding, id), do: Repo.delete!(finding)

  defp take_back(%Finding{} = finding, id) do
    rest = List.delete(finding.comment_ids, id)

    finding
    |> Ecto.Changeset.change(
      count: max(finding.count - 1, 1),
      comment_ids: rest,
      comment_id: if(finding.comment_id == id, do: List.first(rest), else: finding.comment_id)
    )
    |> Repo.update!()
  end

  @doc """
  Records a finding from the system's own signals: `attrs` has `card` (or
  `board`), `source`, `kind`, `text`, and optionally `cause`, `job_id`, `by`.
  An open finding on the same card with the same source and cause counts the
  repeat (and takes the newer text) rather than making another.
  """
  def record(attrs) do
    attrs = attrs |> Map.new() |> Map.put_new(:job_id, nil)
    cause = attrs[:cause] && String.slice(to_string(attrs[:cause]), 0, 255)

    case repeat(attrs, cause) do
      nil ->
        insert_signal(attrs, cause)

      # The same job seen again (a job's end can be heard twice) is no repeat.
      %Finding{job_id: job} = finding when not is_nil(job) and job == attrs.job_id ->
        {:ok, finding}

      finding ->
        count_repeat(finding, attrs)
    end
    |> tap_ok(&Promote.consider/1)
  end

  defp insert_signal(attrs, cause) do
    card = attrs[:card]

    %Finding{
      board_id: if(card, do: root_id(card), else: Board.root_id(attrs[:board])),
      card_id: card && card.id,
      job_id: attrs[:job_id]
    }
    |> Finding.changeset(%{
      kind: attrs[:kind] || "process",
      source: attrs[:source],
      text: attrs[:text],
      cause: cause,
      by: attrs[:by] || "Slipdock"
    })
    |> Repo.insert()
  end

  defp count_repeat(finding, attrs) do
    text = String.slice(to_string(attrs[:text] || finding.text), 0, Finding.max_text())

    finding
    |> Ecto.Changeset.change(
      count: finding.count + 1,
      text: text,
      lesson: Lesson.normalise(text),
      job_id: attrs[:job_id] || finding.job_id
    )
    |> Repo.update()
  end

  defp repeat(_attrs, nil), do: nil

  defp repeat(%{card: %Card{id: card_id}} = attrs, cause) do
    open_repeat(from(f in Finding, where: f.card_id == ^card_id), attrs[:source], cause)
  end

  # A finding about a whole board (a health incident with no card) repeats
  # on the root board.
  defp repeat(%{board: %Board{} = board} = attrs, cause) do
    root = Board.root_id(board)

    open_repeat(
      from(f in Finding, where: f.board_id == ^root and is_nil(f.card_id)),
      attrs[:source],
      cause
    )
  end

  defp repeat(_attrs, _cause), do: nil

  defp open_repeat(query, source, cause) do
    Repo.one(
      from f in query,
        where: f.source == ^source and f.cause == ^cause and f.status == "open",
        order_by: [desc: f.id],
        limit: 1
    )
  end

  @doc """
  The tree's findings, newest first, each with `cards`: its own and those of
  the findings merged into it. `filters`: `status` (default `open`; `all` for
  every one), `kind`, `source`, `card` (an id), `since` (a `DateTime`, or ISO
  8601 text, or a whole number of days back) and `scope` (default `board`;
  `runner` for the tooling kept with a runner, `all` for both).
  """
  def list(%Board{} = board, filters \\ %{}) do
    with {:ok, since} <- since(filters["since"] || filters[:since]),
         {:ok, scope} <- scope(filters["scope"] || filters[:scope]) do
      status = filters["status"] || filters[:status] || "open"

      Finding
      |> where([f], f.board_id == ^Board.root_id(board))
      |> by_value(:status, if(status == "all", do: nil, else: status))
      |> by_value(:kind, filters["kind"] || filters[:kind])
      |> by_value(:source, filters["source"] || filters[:source])
      |> by_value(:card_id, filters["card"] || filters[:card])
      |> by_value(:scope, scope)
      |> since_query(since)
      |> order_by([f], desc: f.updated_at, desc: f.id)
      |> limit(500)
      |> preload([:card, :runner])
      |> Repo.all()
      |> with_cards()
      |> then(&{:ok, &1})
    end
  end

  defp scope(v) when v in [nil, ""], do: {:ok, "board"}
  defp scope("all"), do: {:ok, nil}
  defp scope(v) when v in ["board", "runner"], do: {:ok, v}
  defp scope(_), do: {:error, "scope is board, runner or all"}

  @doc "Sets each finding's `cards`: its own card, then those of the findings merged into it."
  def with_cards(findings) do
    ids = Enum.map(findings, & &1.id)

    merged =
      from(f in Finding,
        where: f.merged_into_id in ^ids and not is_nil(f.card_id),
        order_by: f.id,
        preload: :card
      )
      |> Repo.all()
      |> Enum.group_by(& &1.merged_into_id, & &1.card)

    for f <- findings do
      cards =
        [f.card | Map.get(merged, f.id, [])] |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.id)

      %{f | cards: cards}
    end
  end

  defp since_query(q, nil), do: q
  defp since_query(q, since), do: where(q, [f], f.updated_at >= ^since)

  defp by_value(q, _field, v) when v in [nil, ""], do: q
  defp by_value(q, field, v), do: where(q, [f], field(f, ^field) == ^v)

  defp since(v) when v in [nil, ""], do: {:ok, nil}
  defp since(%DateTime{} = at), do: {:ok, at}
  defp since(days) when is_integer(days) and days >= 0, do: {:ok, days_ago(days)}

  defp since(text) when is_binary(text) do
    cond do
      Regex.match?(~r/^\d+$/, text) ->
        {:ok, days_ago(String.to_integer(text))}

      match?({:ok, _, _}, DateTime.from_iso8601(text)) ->
        {:ok, text |> DateTime.from_iso8601() |> elem(1)}

      match?({:ok, _}, Date.from_iso8601(text)) ->
        {:ok, DateTime.new!(Date.from_iso8601!(text), ~T[00:00:00])}

      true ->
        {:error, "since is a date (2026-11-01), a time (ISO 8601) or a number of days"}
    end
  end

  defp since(_),
    do: {:error, "since is a date (2026-11-01), a time (ISO 8601) or a number of days"}

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)

  @doc "How many open findings a card has."
  def open_count(%Card{id: id}),
    do: Repo.aggregate(from(f in Finding, where: f.card_id == ^id and f.status == "open"), :count)

  @doc "How many open findings each of these cards has, as `%{card_id => n}` (none: absent)."
  def open_counts(card_ids) do
    from(f in Finding,
      where: f.card_id in ^card_ids and f.status == "open",
      group_by: f.card_id,
      select: {f.card_id, count(f.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  def get(id) do
    case Repo.get(Finding, id) do
      nil -> nil
      finding -> finding |> Repo.preload([:card, :runner]) |> List.wrap() |> with_cards() |> hd()
    end
  end

  @doc """
  Collapses a tree's open agent findings into one per lesson, as `from_comment/2`
  would have recorded them (#1941): first each card's repeats
  (`Lesson.near?/2`, same kind) into the card's oldest, then each lesson
  across cards (`Lesson.same?/2`, same kind and scope, not `rule` or
  `handbook-wrong`) into the tree's oldest. Each repeat is merged, so its
  count moves and a person can reopen it. `dry_run: true` changes nothing.
  Returns `[{repeat, into}]`, oldest first.
  """
  def dedupe(%Board{} = board, opts \\ []) do
    root = Board.root_id(board)
    dry? = Keyword.get(opts, :dry_run, false)

    open = fn ->
      Repo.all(
        from f in Finding,
          where: f.board_id == ^root and f.status == "open" and f.source == "agent",
          order_by: f.id
      )
    end

    same_card = pairs(open.(), &{&1.card_id, &1.kind}, &Lesson.near?(&1.text, &2.text))
    folded = MapSet.new(same_card, fn {repeat, _} -> repeat.id end)
    unless dry?, do: Enum.each(same_card, &fold(&1, :card))

    across =
      open.()
      |> Enum.reject(&(Enum.member?(@per_card, &1.kind) or MapSet.member?(folded, &1.id)))
      |> pairs(&{&1.kind, &1.scope, &1.runner_id, &1.lesson || Lesson.normalise(&1.text)}, fn _,
                                                                                              _ ->
        true
      end)

    unless dry?, do: Enum.each(across, &fold(&1, :tree))
    unless dry?, do: Promote.consider(Enum.map(same_card ++ across, fn {_, into} -> into.id end))
    same_card ++ across
  end

  @doc """
  `dedupe/2` for a board named by id, code or name, as a report in words: what
  was (or, with `dry_run: true`, would be) merged into what. `{:error, why}`
  when there is no such board.
  """
  def dedupe_named(ref, opts \\ []) do
    case Slipdock.Boards.find_board(ref) do
      {:ok, board} ->
        pairs = dedupe(board, opts)
        verb = if opts[:dry_run], do: "would merge", else: "merged"

        lines =
          Enum.map(pairs, fn {repeat, into} ->
            "  ##{repeat.id} into ##{into.id} (#{repeat.kind}): #{String.slice(repeat.text, 0, 80)}"
          end)

        Enum.join(["#{board.name}: #{verb} #{length(pairs)} repeated findings" | lines], "\n")

      {:error, :not_found} ->
        {:error, "no board #{inspect(ref)}"}
    end
  end

  # Within each group, every finding that matches an earlier one is a repeat
  # of the first it matches.
  defp pairs(findings, group, match?) do
    findings
    |> Enum.group_by(group)
    |> Enum.flat_map(fn {_key, members} -> repeats(members, match?) end)
    |> Enum.sort_by(fn {f, _} -> f.id end)
  end

  # A card's repeat hands its comments to the finding it repeats, as a repeat
  # said today would have counted there; a repeat on another card stays the
  # record of that card's comment, marked as `from_comment/2` marks one.
  defp repeats(members, match?) do
    {_kept, pairs} = Enum.reduce(members, {[], []}, &repeat_of(&1, &2, match?))
    pairs
  end

  defp repeat_of(f, {kept, pairs}, match?) do
    case Enum.find(kept, &match?.(&1, f)) do
      nil -> {kept ++ [f], pairs}
      into -> {kept, [{f, into} | pairs]}
    end
  end

  defp fold({repeat, into}, where) do
    into = Repo.get!(Finding, into.id)
    repeat = Repo.get!(Finding, repeat.id)

    comment_ids =
      if where == :card,
        do: Enum.uniq(into.comment_ids ++ repeat.comment_ids),
        else: into.comment_ids

    {:ok, _} =
      Repo.transaction(fn ->
        into
        |> Ecto.Changeset.change(count: into.count + repeat.count, comment_ids: comment_ids)
        |> Repo.update!()

        repeat
        |> Finding.triage_changeset(
          %{status: "merged", note: "same lesson as ##{into.id} (dedupe)"},
          into.id
        )
        |> Ecto.Changeset.put_change(:cause, if(where == :tree, do: @same_lesson))
        |> Ecto.Changeset.put_change(
          :comment_ids,
          if(where == :card, do: [], else: repeat.comment_ids)
        )
        |> Repo.update!()
      end)
  end

  @doc """
  Triages a finding: `"dismiss"`, `"promote"` (say what it became in `note`,
  e.g. `W-1950 §Tests TEST-4`), `"merge"` (with `into`, another finding of the
  same tree, which takes its count) or `"reopen"`.
  """
  def triage(%Finding{} = finding, action, params \\ %{}) do
    note = params["note"] || params[:note]

    case action do
      "dismiss" ->
        set(finding, "dismissed", note)

      "promote" ->
        set(finding, "promoted", note)

      "reopen" ->
        finding |> reopen() |> tap_ok(&Promote.consider/1)

      "merge" ->
        finding |> merge(params["into"] || params[:into], note) |> tap_ok(&Promote.consider/1)

      other ->
        {:error, "unknown change #{inspect(other)}: dismiss, promote, merge or reopen"}
    end
  end

  defp set(%Finding{status: "merged"}, _status, _note),
    do: {:error, "it was merged into another finding: reopen it first"}

  defp set(finding, status, note) do
    finding
    |> Finding.triage_changeset(%{status: status, note: note || finding.note})
    |> Repo.update()
  end

  defp reopen(%Finding{status: "merged", merged_into_id: into_id} = finding) do
    Repo.transaction(fn ->
      case into_id && Repo.get(Finding, into_id) do
        %Finding{} = into ->
          into
          |> Ecto.Changeset.change(count: max(into.count - finding.count, 1))
          |> Repo.update!()

        _ ->
          :ok
      end

      finding
      |> Finding.triage_changeset(%{status: "open"})
      |> Repo.update!()
    end)
  end

  defp reopen(finding),
    do: finding |> Finding.triage_changeset(%{status: "open"}) |> Repo.update()

  defp merge(_finding, into, _note) when into in [nil, ""],
    do: {:error, "say which finding it merges into (into)"}

  defp merge(%Finding{status: "merged"}, _into, _note),
    do: {:error, "it is already merged: reopen it first"}

  defp merge(finding, into, note) do
    into_id = if is_binary(into), do: Integer.parse(into), else: {into, ""}

    with {id, ""} when is_integer(id) <- into_id,
         %Finding{} = target <- Repo.get(Finding, id),
         :ok <- mergeable(finding, target) do
      Repo.transaction(fn ->
        target |> Ecto.Changeset.change(count: target.count + finding.count) |> Repo.update!()

        finding
        |> Finding.triage_changeset(%{status: "merged", note: note}, id)
        |> Repo.update!()
      end)
    else
      {:error, _} = e -> e
      _ -> {:error, "no finding #{into} in this tree to merge into"}
    end
  end

  defp mergeable(%Finding{id: id}, %Finding{id: id}),
    do: {:error, "a finding can't merge into itself"}

  defp mergeable(%Finding{board_id: b}, %Finding{board_id: other}) when b != other,
    do: {:error, "that finding is on another board tree"}

  defp mergeable(_, %Finding{status: "merged", merged_into_id: next}),
    do: {:error, "that one is merged itself: merge into ##{next} instead"}

  defp mergeable(_, _), do: :ok

  defp root_id(%Card{board: %Board{} = board}), do: Board.root_id(board)
  defp root_id(%Card{board_id: id}), do: Board.root_id(Repo.get!(Board, id))
end

defmodule Slipdock.Lanes do
  @moduledoc """
  Lanes (#1628): parallel agents stay out of each other's files.

  A card can declare the paths its work will touch (`Card.paths`), as globs
  relative to the repository — `lib/slipdock/runners/**`, `test/*_test.exs`,
  `docs/{manual,agents}.md`. With the board's `lanes` switch on (off by
  default; sub-boards made afterwards inherit it, and the root's switch holds
  for its whole tree), an agent can't start a card whose paths
  overlap those of an open card already in progress on the board's tree
  that a runner job is working on (#1922: its own job, or its epic's, is
  queued, claimed or running; a card in progress with nothing working on it,
  dragged there by hand or left behind, holds no lane):

    * moving it into a doing list is refused, naming the other card;
    * changing an in-progress card's paths to overlap one is refused;
    * a queued runner job for it is held (and skipped by claims) while the
      other card is in progress, unless its own card is in progress already.
      Only work jobs are held: a verify or merge job edits nobody's files
      (#1807, `Slipdock.Verified.finishing_kinds/0`).

  The card's own subcards and parents never count against it: they are the
  same piece of work. An epic's lane is its subcards' (#1811): a card whose
  sub-board has cards holds no lane of its own while in progress (the
  subcards in progress hold theirs), and it waits only when none of the
  subcards its pass could take could start. Nor does a card awaiting verification on a board that
  ships by push (#1661, `Slipdock.Verified.released?/2`): its work is on the
  default branch and nobody is editing its files. A rejection sends it back
  to the ready list, and moving it into a doing list again takes the lane
  back, through the same check. On a board that ships by pull request a
  pending card keeps its lane until the merge. Nor does a spike
  (#2349, `Slipdock.Profiles.spike?/1`): its code is never merged, so its
  paths, if it has any, hold no lane, and nothing is held behind it or holds
  it. People are never refused — a person moving the card is
  the override — and nor are automations. With the switch off, paths are
  recorded and shown and nothing is refused.

  Matching is on the globs alone: the server never sees a working tree. `*`
  and `?` stay inside one segment, `**` is any number of segments, `{a,b}`
  is either, and `[...]` is taken as any one character (so it errs towards
  overlapping). A path covers everything under it: `lib/foo` overlaps
  `lib/foo/bar.ex`. A card with no paths overlaps nothing.

  A board's `shared_paths` (#1971) never count toward a lane: a card's glob
  wholly inside one is left out on both sides before comparing, so two cards
  whose only overlap is `docs/manual.md` don't hold each other when that is
  shared. A glob only partly inside one still counts in full. The root's
  list holds for its whole tree (`shared_paths/1`). Empty by default.

  A board's `lane_mode` (#1972, `mode/1`) says what an overlap does: `hold`
  is all of the above, and what `lanes: true` means; `advise` refuses and
  holds nothing, and the job's prompt names the overlapping cards instead
  (`overlaps/1`, `Slipdock.Runners.lane_advice/1`). The card panel and the
  card's JSON still show the overlap, as advisory.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Repo
  alias Slipdock.Runners.Job

  @max_paths 50
  @max_length 200
  @max_expansions 64

  @doc "How many paths a card may declare, and how long each may be."
  def limits, do: %{paths: @max_paths, length: @max_length}

  ## Writing paths ------------------------------------------------------------

  @doc """
  `attrs` with a `paths` (or `field`, such as a board's `shared_paths`)
  given as one string split into a list: one glob per line or comma (a comma
  inside `{…}` is part of the glob). A list, or no such key, is left alone.
  """
  def split_paths(attrs, field \\ :paths)

  def split_paths(%{} = attrs, field) do
    Enum.reduce([to_string(field), field], attrs, fn key, acc ->
      case acc do
        %{^key => value} when is_binary(value) -> Map.put(acc, key, split(value))
        _ -> acc
      end
    end)
  end

  def split_paths(attrs, _field), do: attrs

  @doc "One string of globs as a list: split on newlines, and on commas outside `{…}`."
  def split(text) when is_binary(text) do
    {parts, current, _depth} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        "{", {parts, cur, d} -> {parts, cur <> "{", d + 1}
        "}", {parts, cur, d} -> {parts, cur <> "}", max(d - 1, 0)}
        "," = _c, {parts, cur, 0} -> {[cur | parts], "", 0}
        "\n", {parts, cur, d} -> {[cur | parts], "", d}
        c, {parts, cur, d} -> {parts, cur <> c, d}
      end)

    Enum.reverse([current | parts])
  end

  @doc """
  Tidies and checks a changeset's `paths`, or another field of globs (a
  board's `shared_paths`, #1971), with the same rules.
  """
  def validate_paths(%Ecto.Changeset{} = changeset, field \\ :paths) do
    changeset
    |> Ecto.Changeset.update_change(field, &tidy/1)
    |> Ecto.Changeset.validate_change(field, fn ^field, paths ->
      case path_error(paths) do
        nil -> []
        message -> [{field, message}]
      end
    end)
  end

  @doc """
  The globs of `paths` that would pass `validate_paths/2`, tidied, at most
  as many as it allows: for a list read from somewhere else, such as an
  import, where one bad glob shouldn't lose the rest.
  """
  def keep_valid(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> tidy()
    |> Enum.filter(&is_nil(path_error([&1])))
    |> Enum.take(@max_paths)
  end

  def keep_valid(_paths), do: []

  defp path_error(paths) do
    cond do
      length(paths) > @max_paths ->
        "lists at most #{@max_paths} paths"

      bad = Enum.find(paths, &(String.length(&1) > @max_length)) ->
        "has a path over #{@max_length} characters: #{String.slice(bad, 0, 40)}…"

      bad = Enum.find(paths, &absolute?/1) ->
        "are relative to the repository: #{bad} isn't"

      bad = Enum.find(paths, &Enum.member?(String.split(&1, "/"), "..")) ->
        "stay inside the repository: #{bad} has a .."

      bad = Enum.find(paths, &(not balanced?(&1))) ->
        "has unbalanced braces: #{bad}"

      true ->
        nil
    end
  end

  @doc "A list of globs, tidied: trimmed, `./` dropped, blanks and repeats left out."
  def tidy(nil), do: []

  def tidy(paths) when is_list(paths) do
    paths
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.replace_prefix("./", "")))
    |> Enum.reject(&Enum.member?(["", "."], &1))
    |> Enum.uniq()
  end

  defp absolute?(path),
    do: String.starts_with?(path, ["/", "~", "\\"]) or Regex.match?(~r/\A[A-Za-z]:/, path)

  defp balanced?(path) do
    path
    |> String.graphemes()
    |> Enum.reduce_while(0, fn
      "{", d -> {:cont, d + 1}
      "}", 0 -> {:halt, -1}
      "}", d -> {:cont, d - 1}
      _, d -> {:cont, d}
    end)
    |> Kernel.==(0)
  end

  ## Shared paths (#1971) -----------------------------------------------------

  @doc """
  The globs that never count toward a lane on `board`'s tree: the root
  board's `shared_paths`, and the board's own (a sub-board made from a
  board inherits its list). `[]` when none are set.
  """
  def shared_paths(%Board{} = board) do
    root =
      case board.root_id do
        nil -> []
        id -> Repo.one(from(b in Board, where: b.id == ^id, select: b.shared_paths)) || []
      end

    tidy(root ++ (board.shared_paths || []))
  end

  def shared_paths(_board), do: []

  @doc """
  `paths` without the globs wholly inside a shared glob: the ones a lane
  counts. A glob only partly inside one (`docs/**` when `docs/manual.md` is
  shared) counts in full; globs are never subtracted.
  """
  def counted(paths, []), do: paths
  def counted(paths, shared), do: Enum.reject(paths, &shared?(&1, shared))

  @doc "Whether `glob` is wholly inside one of the `shared` globs."
  def shared?(glob, shared), do: Enum.any?(shared, &within?(glob, &1))

  @doc """
  Whether every path `glob` could match (and everything under it) is matched
  by `outer`. It errs towards no: a `[...]` class in `outer` covers only the
  same class in `glob`, and a wildcard in `glob` only a wildcard as wide in
  `outer`.
  """
  def within?(glob, outer) do
    outers = expand(outer)

    Enum.all?(expand(glob), fn g ->
      Enum.any?(
        outers,
        &covers?(segments(&1), segments(g), "**", fn o, x -> segment_within?(x, o) end)
      )
    end)
  end

  defp segment_within?("**", _outer), do: false

  defp segment_within?(segment, outer),
    do: covers?(class_tokens(outer), class_tokens(segment), "*", &char_within?/2)

  # `?` covers any one character but a run; anything else covers only itself.
  defp char_within?("?", x), do: x != "*"
  defp char_within?(o, x), do: o == x

  # A segment's characters, with `*` runs as one `*` and each `[...]` class
  # kept whole as one token.
  defp class_tokens(segment) do
    ~r/\[[^\]]*\]|\*+|./u
    |> Regex.scan(segment)
    |> Enum.map(fn [token] -> if String.starts_with?(token, "*"), do: "*", else: token end)
  end

  # Whether pattern `ps` (where `star` is any run) matches every string of
  # `xs`, `elem?.(p, x)` saying whether one pattern element covers one of
  # `xs`'s. Dynamic programming from the ends, as `intersect?/4`.
  defp covers?(ps, xs, star, elem?) do
    ps = List.to_tuple(ps)
    xs = List.to_tuple(xs)
    n = tuple_size(ps)
    m = tuple_size(xs)

    table =
      for i <- n..0//-1, j <- m..0//-1, reduce: %{} do
        dp -> Map.put(dp, {i, j}, covers_cell(dp, {i, j}, {ps, xs, n, m}, {star, elem?}))
      end

    table[{0, 0}]
  end

  defp covers_cell(_dp, {n, j}, {_ps, _xs, n, m}, _how), do: j == m

  defp covers_cell(dp, {i, j}, {ps, xs, _n, m}, {star, elem?}) do
    p = elem(ps, i)

    cond do
      p == star -> dp[{i + 1, j}] or (j < m and dp[{i, j + 1}])
      j == m -> false
      true -> elem?.(p, elem(xs, j)) and dp[{i + 1, j + 1}]
    end
  end

  ## Broad globs ---------------------------------------------------------------

  @broad_reason "it overlaps most cards; name the files or the deepest directory the change touches"

  @doc """
  Whether `glob` claims a whole top-level directory or one just below it
  (#2698): its last segment is `**` and it sits at most one directory below
  the repository root (`**`, `lib/**`, `lib/slipdock/**`, `cli/lib/**`),
  unless it is wholly inside one of the board's `shared` globs. A `{a,b}`
  glob is broad when any of its expansions is. Advice only: nothing is
  refused for it. The one judge, so the card panel, the CLI, the job's
  prompt and the card's JSON agree.
  """
  def broad?(glob, shared) when is_binary(glob) do
    not shared?(glob, shared || []) and Enum.any?(expand(glob), &broad_one?/1)
  end

  defp broad_one?(glob) do
    segs = glob |> String.split("/") |> Enum.reject(&Enum.member?(["", "."], &1))

    case Enum.reverse(segs) do
      ["**" | dirs] -> length(dirs) <= 2
      _ -> false
    end
  end

  @doc "The globs of `paths` that are `broad?/2`, in order."
  def broad_paths(paths, shared), do: Enum.filter(tidy(paths), &broad?(&1, shared))

  @doc "Why a broad glob is marked, in one line (#2698)."
  def broad_reason, do: @broad_reason

  @doc """
  Which side of an overlap between `card` and `other` claims it with a
  broad glob (#2698): `%{side:, this:, other:}`, `side` being `"this"`,
  `"other"` or `"both"`, and `this`/`other` the broad globs on each side
  that meet the other's paths. nil when neither does.
  """
  def broad_overlap(%Card{} = card, %Card{} = other, shared) do
    mine = counted(tidy(card.paths), shared)
    theirs = counted(tidy(other.paths), shared)
    this = Enum.filter(mine, &(broad?(&1, shared) and overlap?([&1], theirs)))
    that = Enum.filter(theirs, &(broad?(&1, shared) and overlap?(mine, [&1])))

    case {this, that} do
      {[], []} -> nil
      {_, []} -> %{side: "this", this: this, other: []}
      {[], _} -> %{side: "other", this: [], other: that}
      _ -> %{side: "both", this: this, other: that}
    end
  end

  ## Overlap ------------------------------------------------------------------

  @doc "Whether any glob of `a` overlaps any glob of `b`."
  def overlap?(a, b) when is_list(a) and is_list(b) do
    Enum.any?(a, fn x -> Enum.any?(b, &glob_overlap?(x, &1)) end)
  end

  @doc """
  Whether some path could match both globs (each also covering everything
  under what it matches).
  """
  def glob_overlap?(a, b) do
    Enum.any?(expand(a), fn x ->
      Enum.any?(expand(b), fn y ->
        intersect?(segments(x), segments(y), "**", &segment_overlap?/2)
      end)
    end)
  end

  # `{a,b}` expanded, innermost first, to at most @max_expansions globs.
  defp expand(glob) do
    case Regex.run(~r/\{([^{}]*)\}/, glob, return: :index) do
      nil ->
        [glob]

      [{start, len}, {inner_start, inner_len}] ->
        prefix = binary_part(glob, 0, start)
        suffix = binary_part(glob, start + len, byte_size(glob) - start - len)
        options = glob |> binary_part(inner_start, inner_len) |> String.split(",")

        options
        |> Enum.flat_map(&expand(prefix <> &1 <> suffix))
        |> Enum.take(@max_expansions)
    end
  end

  # A glob's segments, with everything under it covered: `lib/foo` is
  # `lib/foo/**`. Empty segments (`a//b`, a trailing /) are dropped.
  defp segments(glob) do
    segs = glob |> String.split("/") |> Enum.reject(&Enum.member?(["", "."], &1))
    if List.last(segs) == "**", do: segs, else: segs ++ ["**"]
  end

  # Two segments overlap when some name matches both. A `**` inside a
  # segment is a `*`; a `[...]` class is any one character. Equal segments,
  # and two with no wildcard in them, are decided without the character
  # table (#1977: most pairs are plain names).
  defp segment_overlap?(same, same), do: true

  defp segment_overlap?(a, b) do
    if wild?(a) or wild?(b),
      do: intersect?(chars(a), chars(b), "*", &char_overlap?/2),
      else: false
  end

  defp wild?(segment), do: String.contains?(segment, ["*", "?", "["])

  defp chars(segment) do
    segment
    |> String.replace(~r/\*+/, "*")
    |> String.replace(~r/\[[^\]]*\]/, "?")
    |> String.graphemes()
  end

  defp char_overlap?(a, b), do: a == "?" or b == "?" or a == b

  # Whether two patterns over the same alphabet — `star` matching any run of
  # elements, `compat?` saying whether two single elements can be the same —
  # have a string in common. Dynamic programming from the ends.
  defp intersect?(xs, ys, star, compat?) do
    xs = List.to_tuple(xs)
    ys = List.to_tuple(ys)
    n = tuple_size(xs)
    m = tuple_size(ys)

    table =
      for i <- n..0//-1, j <- m..0//-1, reduce: %{} do
        dp ->
          x = i < n && elem(xs, i)
          y = j < m && elem(ys, j)

          value =
            cond do
              i == n and j == m -> true
              x == star -> dp[{i + 1, j}] or (j < m and dp[{i, j + 1}])
              y == star -> dp[{i, j + 1}] or (i < n and dp[{i + 1, j}])
              i == n or j == m -> false
              # The cell first: comparing two elements costs more (#1977).
              true -> dp[{i + 1, j + 1}] and compat?.(x, y)
            end

          Map.put(dp, {i, j}, value)
      end

    table[{0, 0}]
  end

  ## The checks ---------------------------------------------------------------

  @doc "Whether the lanes checks apply to a change made by `actor`: agents only."
  def gated?(actor), do: Slipdock.Verified.gated?(actor)

  @doc """
  The first open card in progress on `card`'s tree whose paths overlap
  `paths` (by default the card's own), when the card's board has lanes on;
  else nil. The card itself, its subcards and its parents don't count, nor
  does a card `Slipdock.Verified.released?/2`, nor an epic (a card whose
  sub-board has cards): its subcards in progress hold its lane (#1811).

  With no `paths` given, an epic is checked through its subcards: nil when
  any subcard its pass could take is in progress already or free, else the
  first one's conflict. An epic with none to take is checked on its own
  paths.
  """
  def conflict(%Card{} = card, paths \\ nil) do
    board = Repo.get(Board, card.board_id)

    if board && on?(board) && not Slipdock.Profiles.spike?(card) do
      case is_nil(paths) && workable_subcards(card) do
        [_ | _] = subcards -> epic_conflict(subcards)
        _ -> paths_conflict(card, board, tidy(paths || card.paths))
      end
    end
  end

  defp paths_conflict(card, board, paths) do
    shared = shared_paths(board)

    case counted(paths, shared) do
      [] -> nil
      counted -> others_conflict(card, board, counted, shared)
    end
  end

  defp others_conflict(card, board, paths, shared) do
    card
    |> in_progress_others(board)
    |> Enum.find(&overlap?(paths, counted(&1.paths, shared)))
  end

  # The open cards in progress on the tree that hold a lane, other than
  # `card`, its parents and what is below it, in board order.
  defp in_progress_others(card, board) do
    root = Board.root_id(board)
    {exclude, below} = own_tree(card, board)
    doing = doing_column_ids(root)

    from(c in Card,
      as: :card,
      join: col in assoc(c, :column),
      join: b in assoc(c, :board),
      as: :board,
      where:
        (b.id == ^root or b.root_id == ^root) and col.id in ^doing and
          is_nil(c.archived_at) and c.completed == false and c.paths != ^[] and
          c.id not in ^exclude and c.board_id not in ^below and
          not exists(epic_subcards()),
      where: ^not_spike(),
      where: ^holding(Slipdock.Runners.worked(root)),
      order_by: [asc: c.board_id, asc: col.position, asc: c.position, asc: c.id]
    )
    |> Repo.all()
  end

  @doc """
  Every open card in progress on `card`'s tree whose paths overlap `card`'s
  own, on a board with lanes on (#1972, for an advisory lane's prompt): a
  list of `%{card:, paths:, theirs:}`, `paths` being this card's globs that
  overlap and `theirs` the other's. Shared paths (#1971) don't count; the
  same cards are left out as for `conflict/2`. `[]` with lanes off, no
  paths, or nothing in the way.
  """
  def overlaps(%Card{} = card) do
    board = Repo.get(Board, card.board_id)
    shared = shared_paths(board)

    with true <- board != nil and on?(board),
         [_ | _] = mine <- counted(tidy(card.paths), shared) do
      card
      |> in_progress_others(board)
      |> Enum.flat_map(&overlap_with(&1, mine, shared))
    else
      _ -> []
    end
  end

  # One overlap for `overlaps/1`: `[%{card:, paths:, theirs:}]`, or [].
  defp overlap_with(other, mine, shared) do
    theirs = counted(other.paths, shared)

    case Enum.filter(mine, &overlap?([&1], theirs)) do
      [] -> []
      paths -> [%{card: other, paths: paths, theirs: Enum.filter(theirs, &overlap?(paths, [&1]))}]
    end
  end

  # Whether a card in progress holds its lane: a runner job is working on it
  # (#1922, `Slipdock.Runners.worked/1`), and it isn't released (pending on
  # a push board, #1661). A pull-request board's card pending verification,
  # merging or held for a person (#1952) keeps its lane until the merge,
  # with or without a job.
  defp holding({worked_cards, worked_boards}) do
    pr_finishing =
      dynamic(
        [board: b, card: c],
        b.ship_via == "pull_request" and b.verify_work and
          coalesce(c.verify_state, "") in ["pending", "merging", "held"]
      )

    released =
      dynamic([card: c], coalesce(c.verify_state, "") == "pending" and not (^pr_finishing))

    dynamic(
      [card: c],
      (c.id in ^worked_cards or c.board_id in ^worked_boards or ^pr_finishing) and
        not (^released)
    )
  end

  # The cards that don't count against `card` (itself and its parents) and
  # the boards below it. A card not yet made (`check_create/3`) has no id,
  # and nothing below it.
  defp own_tree(%Card{id: nil}, board), do: {ancestor_ids(board), []}

  defp own_tree(%Card{id: id}, board),
    do: {[id | ancestor_ids(board)], Slipdock.Boards.Moves.subtree_board_ids(id)}

  # Not a spike (#2349): a spike is profile `spike`, or no profile and tagged `spike`, as
  # `Slipdock.Profiles.spike?/1` reads it.
  defp not_spike do
    tagged =
      from(ct in "card_tags",
        join: t in Slipdock.Boards.Tag,
        on: t.id == ct.tag_id,
        where: ct.card_id == parent_as(:card).id and fragment("lower(?)", t.name) == "spike",
        select: 1
      )

    dynamic(
      [card: c],
      not (coalesce(c.profile, "") == "spike" or
             (coalesce(c.profile, "") == "" and exists(subquery(tagged))))
    )
  end

  # The cards on the sub-board of the card in progress being looked at: it
  # is an epic when there are any.
  defp epic_subcards do
    from(sc in Card,
      join: sb in Board,
      on: sc.board_id == sb.id,
      where: sb.parent_card_id == parent_as(:card).id and is_nil(sc.archived_at),
      select: 1
    )
  end

  # The subcards a pass on `card` could take: open, not submitted, not
  # waiting on anything, in a list that isn't done. [] for a card with none.
  defp workable_subcards(%Card{id: id}) do
    from(c in Card,
      join: col in assoc(c, :column),
      join: b in assoc(c, :board),
      where:
        b.parent_card_id == ^id and is_nil(c.archived_at) and c.completed == false and
          coalesce(col.category, "") != "done" and
          coalesce(c.verify_state, "") not in ["pending", "merging", "held"],
      order_by: [asc: col.position, asc: c.position, asc: c.id],
      preload: [column: col, blocked_by: ^Slipdock.Boards.dependency_query()]
    )
    |> Repo.all()
    |> Enum.reject(
      &(Card.blocked?(&1) or
          Enum.any?(&1.flags, fn f -> Enum.member?(["blocked", "waiting"], f) end))
    )
  end

  # An epic waits only when every subcard its pass could take is held: one
  # in progress already is the pass's work, and one that is free can start.
  defp epic_conflict(subcards) do
    Enum.reduce_while(subcards, nil, fn subcard, first ->
      case not doing_list?(subcard.column) && conflict(subcard) do
        %Card{} = other -> {:cont, first || other}
        _ -> {:halt, :free}
      end
    end)
    |> case do
      :free -> nil
      other -> other
    end
  end

  # The cards above a board: the card it is the sub-board of, that card's
  # board's card, and so on up.
  defp ancestor_ids(%Board{parent_card_id: nil}), do: []

  defp ancestor_ids(%Board{parent_card_id: card_id}) do
    case Repo.one(
           from(c in Card, join: b in assoc(c, :board), where: c.id == ^card_id, select: b)
         ) do
      nil -> [card_id]
      board -> [card_id | ancestor_ids(board)]
    end
  end

  @doc "The refusal's words: the other card named, and what to do."
  def message(%Card{} = card, %Card{} = other) do
    "this board keeps agents in lanes: card ##{card.id}'s paths overlap those of " <>
      "##{other.id} \"#{other.title}\", in progress (#{Enum.join(other.paths, ", ")}). " <>
      "Narrow this card's paths, wait for ##{other.id}, or ask a person to move it"
  end

  @doc """
  `:ok`, or `{:error, message}` when `actor` (an agent) may not move `card`
  into `to` because its paths overlap a card in progress.
  """
  def check_move(%Card{} = card, %Column{} = to, actor) do
    with true <- doing_list?(to) and gated?(actor),
         true <- hold?(card),
         %Card{} = other <- conflict(card) do
      {:error, message(card, other)}
    else
      _ -> :ok
    end
  end

  @doc """
  `changeset` (a new card's) with a `paths` error when `actor` (an agent)
  creates the card straight into a doing list, on a board with lanes on,
  with paths that overlap a card in progress (#1815): the check a move into
  that list makes. Otherwise it comes back as it was.
  """
  def check_create(%Ecto.Changeset{valid?: true} = changeset, %Column{} = column, actor) do
    card = Ecto.Changeset.apply_changes(changeset)

    with true <- doing_list?(column) and gated?(actor),
         true <- hold?(card),
         %Card{} = other <- conflict(card, card.paths) do
      Ecto.Changeset.add_error(changeset, :paths, create_message(column, other))
    else
      _ -> changeset
    end
  end

  def check_create(%Ecto.Changeset{} = changeset, _column, _actor), do: changeset

  defp create_message(column, other) do
    "overlap those of ##{other.id} \"#{other.title}\", in progress " <>
      "(#{Enum.join(other.paths, ", ")}): this board keeps agents in lanes. Create the card " <>
      "in another list than #{column.name}, narrow its paths, wait for ##{other.id}, " <>
      "or ask a person to move it"
  end

  @doc """
  `:ok`, or `{:error, :paths, message}` when `actor` (an agent) changes the
  paths of a card in progress to overlap another card in progress.
  """
  def check_update(%Card{} = card, attrs, actor) do
    new = attrs |> split_paths() |> fetch_paths()

    with true <- new != :none and gated?(actor),
         true <- in_doing?(card),
         true <- hold?(card),
         %Card{} = other <- conflict(card, if(is_list(new), do: new, else: [])) do
      {:error, :paths, message(card, other)}
    else
      _ -> :ok
    end
  end

  defp fetch_paths(attrs) do
    cond do
      Map.has_key?(attrs, "paths") -> attrs["paths"]
      Map.has_key?(attrs, :paths) -> attrs[:paths]
      true -> :none
    end
  end

  defp in_doing?(%Card{column_id: column_id}) do
    case Repo.get(Column, column_id) do
      %Column{} = column -> doing_list?(column)
      nil -> false
    end
  end

  # A doing list, as the guide reads one (`Slipdock.Flow.doing_list?/1`):
  # by its category, else by its name. A sub-board made from the Simple
  # template has a "Doing" list with no category, and its cards in progress
  # held no lane and its moves were never checked (#2597).
  defp doing_list?(%Column{} = column), do: Slipdock.Flow.doing_list?(column)

  # The ids of the doing lists on the tree under `root`, read as
  # `doing_list?/1` reads them.
  defp doing_column_ids(root) do
    from(col in Column,
      join: b in assoc(col, :board),
      where: b.id == ^root or b.root_id == ^root
    )
    |> Repo.all()
    |> Enum.filter(&doing_list?/1)
    |> Enum.map(& &1.id)
  end

  @doc """
  The cards of queued work jobs on the tree under `root_id` that lanes hold
  back, as card id => the card in progress in the way. A card in progress
  itself is never held: it is the work, not more of it. Nor are verify and
  merge jobs (#1807): they finish the work, and touch nobody's files.
  """
  def held_cards(root_id) do
    if lanes_on?(root_id) do
      doing = doing_column_ids(root_id)

      from(c in Card,
        join: j in Job,
        on: j.card_id == c.id,
        join: col in assoc(c, :column),
        where:
          j.root_board_id == ^root_id and j.status == "queued" and col.id not in ^doing and
            j.kind not in ^Slipdock.Verified.finishing_kinds(),
        distinct: true
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn card, acc ->
        case hold?(card) && conflict(card) do
          %Card{} = other -> Map.put(acc, card.id, other)
          _ -> acc
        end
      end)
    else
      %{}
    end
  end

  @doc """
  What an overlap does on `board` (#1972): `"hold"` (an agent's start is
  refused and its job held), `"advise"` (the agent is told in its job's
  prompt instead) or `"off"`. The root's mode holds for its whole tree, as
  its switch does; a board under a root with lanes off goes by its own.
  """
  def mode(%Board{} = board) do
    root =
      board.root_id &&
        Repo.one(from(b in Board, where: b.id == ^board.root_id, select: b.lane_mode))

    cond do
      Enum.member?(["hold", "advise"], root) -> root
      Enum.member?(["hold", "advise"], board.lane_mode) -> board.lane_mode
      board.lanes -> "hold"
      true -> "off"
    end
  end

  def mode(_board), do: "off"

  @doc """
  The open runner job working on `card` (#1972): its own, else its epic's,
  up the tree; a claimed or running one before a queued one. nil when none.
  """
  def working_job(%Card{} = card) do
    ids = [card.id | ancestor_ids(Repo.get(Board, card.board_id))]

    from(j in Job,
      where: j.card_id in ^ids and j.status in ^Job.open_statuses(),
      order_by: [desc: j.status in ["claimed", "running"], desc: j.id]
    )
    |> Repo.all()
    |> Enum.min_by(&Enum.find_index(ids, fn id -> id == &1.card_id end), fn -> nil end)
  end

  @doc "Whether an overlap holds `card` (its board's mode is `hold`), rather than advising."
  def hold?(%Card{board_id: board_id}), do: mode(Repo.get(Board, board_id)) == "hold"

  @doc "Whether lanes are on for `board`: on it, or on the root of its tree."
  def on?(%Board{lanes: true}), do: true
  def on?(%Board{root_id: nil}), do: false

  def on?(%Board{root_id: root}),
    do: Repo.exists?(from(b in Board, where: b.id == ^root and b.lanes))

  defp lanes_on?(root_id) do
    Repo.exists?(from(b in Board, where: (b.id == ^root_id or b.root_id == ^root_id) and b.lanes))
  end

  @doc ~S'The held line for a job lanes hold: `"Lane: overlaps #12, in progress"`.'
  def held_line(%Card{id: id}), do: "Lane: overlaps ##{id}, in progress"
end

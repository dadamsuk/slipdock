defmodule Slipdock.Lanes do
  @moduledoc """
  Lanes (#1628): parallel agents stay out of each other's files.

  A card can declare the paths its work will touch (`Card.paths`), as globs
  relative to the repository — `lib/slipdock/runners/**`, `test/*_test.exs`,
  `docs/{manual,agents}.md`. With the board's `lanes` switch on (off by
  default; sub-boards made afterwards inherit it, and the root's switch holds
  for its whole tree), an agent can't start a card whose paths
  overlap those of an open card already in progress on the board's tree:

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
  pending card keeps its lane until the merge. People are never refused — a person moving the card is
  the override — and nor are automations. With the switch off, paths are
  recorded and shown and nothing is refused.

  Matching is on the globs alone: the server never sees a working tree. `*`
  and `?` stay inside one segment, `**` is any number of segments, `{a,b}`
  is either, and `[...]` is taken as any one character (so it errs towards
  overlapping). A path covers everything under it: `lib/foo` overlaps
  `lib/foo/bar.ex`. A card with no paths overlaps nothing.
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
  `attrs` with a `paths` given as one string split into a list: one glob per
  line or comma (a comma inside `{…}` is part of the glob). A list, or no
  `paths`, is left alone.
  """
  def split_paths(%{} = attrs) do
    Enum.reduce(["paths", :paths], attrs, fn key, acc ->
      case acc do
        %{^key => value} when is_binary(value) -> Map.put(acc, key, split(value))
        _ -> acc
      end
    end)
  end

  def split_paths(attrs), do: attrs

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

  @doc "Tidies and checks a changeset's `paths`."
  def validate_paths(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.update_change(:paths, &tidy/1)
    |> Ecto.Changeset.validate_change(:paths, fn :paths, paths ->
      cond do
        length(paths) > @max_paths ->
          [paths: "lists at most #{@max_paths} paths"]

        bad = Enum.find(paths, &(String.length(&1) > @max_length)) ->
          [paths: "has a path over #{@max_length} characters: #{String.slice(bad, 0, 40)}…"]

        bad = Enum.find(paths, &absolute?/1) ->
          [paths: "are relative to the repository: #{bad} isn't"]

        bad = Enum.find(paths, &(".." in String.split(&1, "/"))) ->
          [paths: "stay inside the repository: #{bad} has a .."]

        bad = Enum.find(paths, &(not balanced?(&1))) ->
          [paths: "has unbalanced braces: #{bad}"]

        true ->
          []
      end
    end)
  end

  @doc "A list of globs, tidied: trimmed, `./` dropped, blanks and repeats left out."
  def tidy(nil), do: []

  def tidy(paths) when is_list(paths) do
    paths
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.replace_prefix("./", "")))
    |> Enum.reject(&(&1 in ["", "."]))
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
    segs = glob |> String.split("/") |> Enum.reject(&(&1 in ["", "."]))
    if List.last(segs) == "**", do: segs, else: segs ++ ["**"]
  end

  # Two segments overlap when some name matches both. A `**` inside a
  # segment is a `*`; a `[...]` class is any one character.
  defp segment_overlap?(a, b), do: intersect?(chars(a), chars(b), "*", &char_overlap?/2)

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
              true -> compat?.(x, y) and dp[{i + 1, j + 1}]
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

    if board && on?(board) do
      case is_nil(paths) && workable_subcards(card) do
        [_ | _] = subcards -> epic_conflict(subcards)
        _ -> paths_conflict(card, board, tidy(paths || card.paths))
      end
    end
  end

  defp paths_conflict(_card, _board, []), do: nil

  defp paths_conflict(card, board, paths) do
    root = Board.root_id(board)
    exclude = [card.id | ancestor_ids(board)]
    below = Slipdock.Boards.subtree_board_ids(card.id)

    from(c in Card,
      as: :card,
      join: col in assoc(c, :column),
      join: b in assoc(c, :board),
      where:
        (b.id == ^root or b.root_id == ^root) and col.category == "doing" and
          is_nil(c.archived_at) and c.completed == false and c.paths != ^[] and
          c.id not in ^exclude and c.board_id not in ^below and
          (coalesce(c.verify_state, "") != "pending" or
             (b.ship_via == "pull_request" and b.verify_work)) and
          not exists(epic_subcards()),
      order_by: [asc: c.board_id, asc: col.position, asc: c.position, asc: c.id]
    )
    |> Repo.all()
    |> Enum.find(&overlap?(paths, &1.paths))
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
          coalesce(c.verify_state, "") not in ["pending", "merging"],
      order_by: [asc: col.position, asc: c.position, asc: c.id],
      preload: [column: col, blocked_by: ^Slipdock.Boards.dependency_query()]
    )
    |> Repo.all()
    |> Enum.reject(
      &(Card.blocked?(&1) or Enum.any?(&1.flags, fn f -> f in ["blocked", "waiting"] end))
    )
  end

  # An epic waits only when every subcard its pass could take is held: one
  # in progress already is the pass's work, and one that is free can start.
  defp epic_conflict(subcards) do
    Enum.reduce_while(subcards, nil, fn subcard, first ->
      case subcard.column.category != "doing" && conflict(subcard) do
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
    with true <- to.category == "doing" and gated?(actor),
         %Card{} = other <- conflict(card) do
      {:error, message(card, other)}
    else
      _ -> :ok
    end
  end

  @doc """
  `:ok`, or `{:error, :paths, message}` when `actor` (an agent) changes the
  paths of a card in progress to overlap another card in progress.
  """
  def check_update(%Card{} = card, attrs, actor) do
    new = attrs |> split_paths() |> fetch_paths()

    with true <- new != :none and gated?(actor),
         true <- in_doing?(card),
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
    Repo.exists?(from(col in Column, where: col.id == ^column_id and col.category == "doing"))
  end

  @doc """
  The cards of queued work jobs on the tree under `root_id` that lanes hold
  back, as card id => the card in progress in the way. A card in progress
  itself is never held: it is the work, not more of it. Nor are verify and
  merge jobs (#1807): they finish the work, and touch nobody's files.
  """
  def held_cards(root_id) do
    if lanes_on?(root_id) do
      from(c in Card,
        join: j in Job,
        on: j.card_id == c.id,
        join: col in assoc(c, :column),
        where:
          j.root_board_id == ^root_id and j.status == "queued" and col.category != "doing" and
            j.kind not in ^Slipdock.Verified.finishing_kinds(),
        distinct: true
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn card, acc ->
        case conflict(card) do
          nil -> acc
          other -> Map.put(acc, card.id, other)
        end
      end)
    else
      %{}
    end
  end

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

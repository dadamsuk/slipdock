defmodule Slipdock.Overseer.Housekeeping do
  @moduledoc """
  The morning digest of Housekeeping's work (#2781, W-2588 §5): once a day,
  at the overseer's `digest_at` (07:00 by default) in the root board's
  owner's time zone, a status update on the overseer's card saying what the
  Housekeeping feeds (`backfill: true` rules, #2777) worked since the last
  one. Worked out on the server from what it holds; no model, no tokens.

  The cards are grouped by theme, one line a group: a card's first tag by
  name, else the handbook area its paths fall in (`Slipdock.Sweep.areas/1`),
  else *other*. Only the cards that need the owner are named one by one:
  rejected by verification, escalated to Triage (#2780), given up on, or
  whose paths overlap an in-progress epic subcard's. It shows wherever the
  overseer's digests do (`Slipdock.Overseer.Pass.finished/1` keeps those on
  the same card), and an empty day says so in one line.
  """

  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Automations.Rule
  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Overseer
  alias Slipdock.Overseer.Settings
  alias Slipdock.Repo
  alias Slipdock.Runners.Job
  alias Slipdock.Timezones

  @default_at "07:00"

  @doc "The time of day the digest is written when none is set."
  def default_at, do: @default_at

  @doc """
  Writes the digest on `root`'s overseer card when it is due: the overseer
  is on, it is past `digest_at` in the owner's zone, and none has been
  written today. Answers `{:ok, body}` when it wrote one, else `:not_due`.
  """
  def maybe_digest(%Board{} = root, %Settings{} = settings, now \\ DateTime.utc_now()) do
    zone = zone(root)
    today = Timezones.today(zone, now)
    at = Timezones.to_utc(today, time(settings.digest_at), zone)

    if settings.enabled and DateTime.compare(now, at) != :lt and
         settings.housekeeping_digest_on != today,
       do: write(root, settings, now, today),
       else: :not_due
  end

  defp write(root, settings, now, today) do
    since = settings.housekeeping_digest_at || DateTime.add(now, -86_400, :second)

    with {:ok, card} <- Overseer.ensure_card(root, settings) do
      %{body: body, needs_owner: needs} = digest(root, since, now)
      health = if needs == [], do: "on_track", else: "at_risk"

      Boards.add_status_update(card, nil, %{"health" => health, "body" => body}, quiet: true)

      Repo.update_all(from(s in Settings, where: s.id == ^settings.id),
        set: [
          housekeeping_digest_on: today,
          housekeeping_digest_at: DateTime.truncate(now, :second)
        ]
      )

      {:ok, body}
    end
  end

  @doc """
  What the Housekeeping feeds of `root`'s tree worked between `since` and
  `now`: `%{body, cards, groups, needs_owner}`. `groups` is `[{theme,
  [card]}]` largest first; `needs_owner` is `[{card, why}]`.
  """
  def digest(%Board{} = root, %DateTime{} = since, %DateTime{} = now) do
    board_ids = tree_ids(root)
    cards = worked_cards(board_ids, since, now)
    jobs = jobs_by_card(board_ids, since, now)
    areas = Slipdock.Sweep.areas(root)
    epics = epic_paths(board_ids)

    groups =
      cards
      |> Enum.group_by(&theme(&1, areas))
      |> Enum.sort_by(fn {theme, list} -> {-length(list), theme} end)

    needs = for card <- cards, why = why(card, jobs[card.id] || [], epics, since), do: {card, why}

    %{
      cards: cards,
      groups: groups,
      needs_owner: needs,
      body: body(cards, groups, needs, since, zone(root))
    }
  end

  # The cards a backfill feed sent a job for that ended in the window.
  defp worked_cards(board_ids, since, now) do
    ids =
      from(j in Job,
        where: j.rule_id in subquery(backfill_rules(board_ids)),
        where: j.finished_at >= ^since and j.finished_at < ^now and not is_nil(j.card_id),
        distinct: true,
        select: j.card_id
      )
      |> Repo.all()

    from(c in Card, where: c.id in ^ids, order_by: [asc: c.id], preload: [:tags, :column])
    |> Repo.all()
  end

  defp jobs_by_card(board_ids, since, now) do
    from(j in Job,
      where: j.rule_id in subquery(backfill_rules(board_ids)),
      where: j.finished_at >= ^since and j.finished_at < ^now
    )
    |> Repo.all()
    |> Enum.group_by(& &1.card_id)
  end

  defp backfill_rules(board_ids) do
    from(r in Rule,
      where:
        r.board_id in ^board_ids and
          fragment("(?->'trigger'->>'backfill') = 'true'", r.spec),
      select: r.id
    )
  end

  # Why the owner should look at this one, or nil.
  defp why(card, jobs, epics, since) do
    cond do
      card.verify_state == "rejected" and after?(card.verify_at, since) ->
        "rejected by verification"

      match?(%Column{category: "triage"}, card.column) ->
        "escalated to Triage"

      gave_up?(jobs) ->
        "given up on"

      epic = overlapping_epic(card, epics) ->
        "its paths overlap ##{epic.id} “#{epic.title}”, in progress under an epic"

      true ->
        nil
    end
  end

  # Judged on the card's newest job (the highest id), as `Slipdock.Work`
  # does: a job that failed and was retried to done isn't given up on.
  defp gave_up?([]), do: false

  defp gave_up?(jobs) do
    newest = Enum.max_by(jobs, & &1.id)
    newest.recovery == "gave_up" or Enum.member?(~w(failed timeout), newest.status)
  end

  defp after?(%DateTime{} = at, since), do: DateTime.compare(at, since) != :lt
  defp after?(_, _), do: false

  defp overlapping_epic(%Card{paths: [_ | _] = paths}, epics),
    do: Enum.find(epics, &Slipdock.Lanes.overlap?(paths, &1.paths))

  defp overlapping_epic(_card, _epics), do: nil

  # The cards in progress on an epic's sub-board, with paths.
  defp epic_paths(board_ids) do
    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      join: col in Column,
      on: col.id == c.column_id,
      where:
        c.board_id in ^board_ids and not is_nil(b.parent_card_id) and col.category == "doing" and
          c.completed == false and is_nil(c.archived_at) and
          fragment("cardinality(?) > 0", c.paths),
      order_by: [asc: c.id]
    )
    |> Repo.all()
  end

  defp theme(%Card{tags: [_ | _] = tags}, _areas),
    do: tags |> Enum.map(& &1.name) |> Enum.sort() |> hd()

  defp theme(%Card{paths: [_ | _] = paths}, areas) do
    case Enum.find(areas, fn {_title, globs} -> Slipdock.Lanes.overlap?(paths, globs) end) do
      {title, _} -> title
      nil -> "other"
    end
  end

  defp theme(_card, _areas), do: "other"

  defp body([], _groups, _needs, since, zone),
    do: "**Housekeeping since #{local(since, zone)}**: nothing ran."

  defp body(cards, groups, needs, since, zone) do
    lines =
      Enum.map(groups, fn {theme, list} ->
        "- #{theme}: #{length(list)} (#{Enum.map_join(list, ", ", &"##{&1.id}")})"
      end)

    head =
      "**Housekeeping since #{local(since, zone)}**: #{length(cards)} " <>
        if(length(cards) == 1, do: "card", else: "cards") <> " worked."

    tail =
      case needs do
        [] ->
          "\n\nNothing needs you."

        needs ->
          "\n\nNeeds you:\n" <>
            Enum.map_join(needs, "\n", fn {card, why} ->
              "- ##{card.id} “#{card.title}”: #{why}"
            end)
      end

    head <> "\n\n" <> Enum.join(lines, "\n") <> tail
  end

  defp local(at, zone),
    do: at |> Timezones.to_local(zone) |> Calendar.strftime("%a %-d %b %H:%M")

  defp tree_ids(%Board{id: id}),
    do: Repo.all(from(b in Board, where: b.id == ^id or b.root_id == ^id, select: b.id))

  defp zone(%Board{} = root) do
    owner_id = Board.root_owner_id(root)
    Timezones.of(owner_id && Repo.get(User, owner_id))
  end

  defp time(at) do
    case Settings.digest_time(at) do
      {:ok, time} -> time
      :error -> ~T[07:00:00]
    end
  end
end

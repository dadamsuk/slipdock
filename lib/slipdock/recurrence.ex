defmodule Slipdock.Recurrence do
  @moduledoc """
  Recurring cards (W-1802): repeating work kept on the card it repeats.

  A card is given a series (`set/3`) with a rule (`Slipdock.Recurrence.Rule`).
  The scheduler's clock calls `tick/1`, which makes each series' next
  instance when its time comes, by copying the current instance as it is now
  (`Slipdock.Boards.copy_card/3`) to the top of its board's ready list, due
  on the occurrence's date.

  **Not stacking up.** A fixed series whose current instance is still open
  when the next comes due does what its `on_missed` says:

    * `bump` (the default) moves the open card's due date on to the new
      occurrence and says so in a comment, so a forgotten weekly chore is
      one card, not six;
    * `skip` leaves the card alone and lets the occurrence go, with a
      comment;
    * `stack` makes the new instance anyway.

  A server that was down for a while catches up to the latest occurrence
  whose time has come, once, rather than making one per missed occurrence.

  **After done.** An after-done series waits for its current instance to be
  completed (`completion_changed/1`, called by `Boards.update_card/3`): the
  next is due that long after the local day it was done.

  **Once only.** Each occurrence a series acts on is claimed in
  `recurrence_fires` inside the same transaction, with the series row held,
  so two nodes ticking at once or a restart mid-tick never make it twice.

  Archiving the current instance pauses the series (`card_archived/1`);
  deleting it deletes the series. Older instances keep `series_id` as a
  marker of where they came from.
  """

  import Ecto.Query

  require Logger

  alias Slipdock.{Boards, Repo, Timezones}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Card, Column}
  alias Slipdock.Recurrence.{Rule, Series}

  ## Reading

  @doc "The series `card` is the current instance of, or nil."
  def for_card(%{id: id}), do: Repo.get_by(Series, card_id: id)

  @doc """
  The series `card` belongs to: the one it is the current instance of, else
  the one it was made by (an older instance), or nil.
  """
  def series_of(%Card{} = card) do
    for_card(card) || (card.series_id && Repo.get(Series, card.series_id))
  end

  @doc "Every series whose current instance is on `board` or a board under it."
  def list_for_board(board) do
    card_ids = Repo.all(from(c in Card, where: c.board_id == ^board.id, select: c.id))
    ids = [board.id | Enum.flat_map(card_ids, &Boards.subtree_board_ids/1)]

    from(s in Series,
      join: c in Card,
      on: c.id == s.card_id,
      where: c.board_id in ^ids,
      order_by: [asc_nulls_last: s.next_at, asc: s.id],
      preload: [card: c]
    )
    |> Repo.all()
  end

  @doc """
  The next few dates the series will fall on, for showing before it is set:
  the dates of `rule` (a `Rule`) after `from`, `n` of them.
  """
  def preview(%Rule{} = rule, %Date{} = from, n \\ 3), do: Rule.upcoming(rule, from, n)

  @weekday_codes ~w(MO TU WE TH FR SA SU)
  @weekday_names ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  @doc """
  The Repeat… dialog's presets, worded for `date` (the card's due date, or
  today): `[{rule, label}]`. "Monthly on the second Tuesday" is the last
  Tuesday instead when `date` is in the month's last week of that day.
  """
  def presets(%Date{} = date) do
    dow = Date.day_of_week(date)
    code = Enum.at(@weekday_codes, dow - 1)
    name = Enum.at(@weekday_names, dow - 1)
    nth = div(date.day - 1, 7) + 1
    last? = date.day + 7 > Date.days_in_month(date)

    {ord, ord_word} =
      if last? and nth >= 4, do: {-1, "last"}, else: {nth, ordinal_word(nth)}

    [
      {"FREQ=DAILY", "Daily"},
      {"FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", "Every weekday (Monday to Friday)"},
      {"FREQ=WEEKLY;BYDAY=#{code}", "Weekly on #{name}"},
      {"FREQ=MONTHLY;BYMONTHDAY=#{date.day}", "Monthly on the #{day_ordinal(date.day)}"},
      {"FREQ=MONTHLY;BYDAY=#{ord}#{code}", "Monthly on the #{ord_word} #{name}"},
      {"FREQ=YEARLY", "Yearly on #{Calendar.strftime(date, "%-d %B")}"},
      {"AFTER=1W", "A week after the last one is done"}
    ]
  end

  defp ordinal_word(n), do: Enum.at(~w(first second third fourth fifth), n - 1)

  defp day_ordinal(n) when n in [11, 12, 13], do: "#{n}th"
  defp day_ordinal(n) when rem(n, 10) == 1, do: "#{n}st"
  defp day_ordinal(n) when rem(n, 10) == 2, do: "#{n}nd"
  defp day_ordinal(n) when rem(n, 10) == 3, do: "#{n}rd"
  defp day_ordinal(n), do: "#{n}th"

  @doc """
  What a rule as typed would do, for the dialog to show before it is saved:
  `{:ok, %{rule: stored, summary: "Every Mon, 07:00 Europe/London", dates:
  [the next three on or after from]}}`, or `{:error, message}`. An after-done
  rule has no dates until the card is done.
  """
  def describe(rule_text, at_text, zone, %Date{} = from) do
    with {:ok, rule} <- Rule.parse_phrase(rule_text || "", from),
         {:ok, at} <- read_time(if(at_text in [nil, ""], do: "07:00", else: at_text)),
         true <- Timezones.valid?(zone) || {:error, "timezone: #{inspect(zone)} isn't one"} do
      {:ok,
       %{
         rule: Rule.to_string(rule),
         kind: rule.kind,
         summary: Rule.summary(rule, at, zone),
         dates: Rule.upcoming(rule, Date.add(from, -1), 3)
       }}
    end
  end

  ## Setting it

  @doc """
  Makes `card` recurring, or changes its series. `attrs` (string keys):

    * `"rule"` — an RRULE subset, `AFTER=3D`, or a phrase (`"every mon"`,
      `"month last fri"`, `"3d after"`). Required for a new series.
    * `"at"` — the time of day instances are made, `"HH:MM"` (07:00).
    * `"timezone"` — defaults to `by`'s.
    * `"lead_days"` — make each this many days before it is due (0).
    * `"ends"` — `"never"`, `"on"` with `"ends_on"`, `"after"` with `"count"`.
    * `"on_missed"` — `bump`, `skip` or `stack`.
    * `"column"` — a list on the card's board to put instances in (the
      board's ready list when not given); `""` clears it.
    * `"paused"` — true to hold it.

  A card with no due date is made the series' first occurrence: it gets the
  first date the rule falls on from today.
  """
  def set(%Card{} = card, attrs, %User{} = by) do
    existing = for_card(card)

    with {:ok, attrs} <- read_attrs(card, attrs, existing, by),
         {:ok, card} <- first_occurrence(card, attrs),
         series = existing || %Series{card_id: card.id, created_by_id: by.id},
         changeset = Series.changeset(series, attrs),
         {:ok, series} <- save(changeset),
         {:ok, series} <- reschedule_after(series, card, existing, changeset) do
      if is_nil(card.series_id), do: put_series_id(card, series)

      Boards.log_activity_for(
        card,
        "card",
        if(existing,
          do: "changed how “#{card.title}” repeats: #{Series.summary(series)}",
          else: "made “#{card.title}” recurring: #{Series.summary(series)}"
        )
      )

      Boards.card_changed(card)
      {:ok, series}
    end
  end

  defp save(%Ecto.Changeset{data: %{id: nil}} = cs), do: Repo.insert(cs)
  defp save(cs), do: Repo.update(cs)

  defp read_attrs(card, attrs, existing, by) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, rule} <- read_rule(attrs["rule"], existing),
         {:ok, at} <- read_time(attrs["at"]),
         {:ok, column_id} <- read_column(card, attrs["column"]),
         {:ok, zone} <- read_zone(attrs["timezone"], existing, by) do
      start = (existing && existing.starts_on) || card.due_date || Timezones.today(zone)

      {:ok,
       attrs
       |> Map.drop(~w(rule at column))
       |> put_some("rule", rule && Rule.to_string(rule))
       |> put_some("create_at", at)
       |> put_some("column_id", column_id)
       |> Map.put("timezone", zone)
       |> Map.put("starts_on", start)}
    end
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, :clear), do: Map.put(map, key, nil)
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp read_rule(nil, %Series{}), do: {:ok, nil}
  defp read_rule(nil, nil), do: {:error, "say how often it repeats (rule), like \"every mon\""}

  defp read_rule(text, _existing) when is_binary(text) do
    case Rule.parse_phrase(text) do
      {:ok, rule} -> {:ok, rule}
      {:error, message} -> {:error, "rule: " <> message}
    end
  end

  defp read_rule(_, _), do: {:error, "rule: say how often, like \"every mon\""}

  defp read_zone(nil, existing, by),
    do: {:ok, (existing && existing.timezone) || Timezones.of(by)}

  defp read_zone(zone, _existing, _by) do
    if Timezones.valid?(zone),
      do: {:ok, zone},
      else: {:error, "timezone: #{inspect(zone)} isn't a timezone this server knows"}
  end

  defp read_time(nil), do: {:ok, nil}

  defp read_time(text) when is_binary(text) do
    case Regex.run(~r/^(\d{1,2}):(\d{2})(?::\d{2})?$/, String.trim(text)) do
      [_, h, m] ->
        case Time.new(String.to_integer(h), String.to_integer(m), 0) do
          {:ok, t} -> {:ok, t}
          _ -> {:error, "at: a time of day, like 07:00"}
        end

      nil ->
        {:error, "at: a time of day, like 07:00"}
    end
  end

  defp read_time(_), do: {:error, "at: a time of day, like 07:00"}

  defp read_column(_card, nil), do: {:ok, nil}
  defp read_column(_card, ""), do: {:ok, :clear}

  defp read_column(card, ref) do
    case Boards.find_column(Boards.get_board!(card.board_id), ref) do
      {:ok, column} -> {:ok, column.id}
      _ -> {:error, "column: no list #{inspect(ref)} on this card's board"}
    end
  end

  # The card a fixed series is set on is its first occurrence: one with no
  # due date is given the first date the rule falls on from today.
  defp first_occurrence(%Card{due_date: nil} = card, %{"rule" => text} = attrs)
       when is_binary(text) do
    {:ok, rule} = Rule.parse(text, attrs["starts_on"])

    case rule.kind do
      :fixed ->
        due = Rule.next_date(rule, Date.add(attrs["starts_on"], -1))
        Boards.update_card(card, %{"due_date" => due})

      :after_done ->
        {:ok, card}
    end
  end

  defp first_occurrence(card, _attrs), do: {:ok, card}

  defp put_series_id(card, series) do
    from(c in Card, where: c.id == ^card.id) |> Repo.update_all(set: [series_id: series.id])
  end

  # Only what a change touches is worked out again: a new rule (or a new
  # series) starts from the card; a new time, zone or lead keeps the next
  # date and moves when it is made; anything else (paused, ends, on_missed,
  # the list) leaves the next one where it was — a skip stays skipped.
  defp reschedule_after(series, card, existing, changeset) do
    changed = Map.keys(changeset.changes)

    cond do
      is_nil(existing) or :rule in changed ->
        schedule(series, card, DateTime.utc_now(:second))

      Enum.any?([:create_at, :timezone, :lead_days], &(&1 in changed)) ->
        series |> reschedule() |> end_if_over() |> Repo.update()

      true ->
        series |> Ecto.Changeset.change() |> end_if_over() |> Repo.update()
    end
  end

  # Works out the next occurrence from the series' current instance, and
  # when to make it.
  defp schedule(%Series{kind: "after_done"} = series, card, _now) do
    if card.completed and card.completed_at,
      do: series |> after_done_next(card.completed_at) |> Repo.update(),
      else: series |> Ecto.Changeset.change(next_on: nil, next_at: nil) |> Repo.update()
  end

  defp schedule(%Series{} = series, card, _now) do
    rule = Series.rule(series)
    from = card.due_date || Date.add(series.starts_on, -1)
    next_on = Rule.next_date(rule, from)

    series |> Ecto.Changeset.change(occurrence(series, next_on)) |> end_if_over() |> Repo.update()
  end

  @doc """
  A changeset putting `next_at` back in step with `next_on`, for a series
  whose `next_on` arrived from elsewhere (an import).
  """
  def reschedule(%Series{} = series),
    do: Ecto.Changeset.change(series, occurrence(series, series.next_on))

  defp occurrence(_series, nil), do: [next_on: nil, next_at: nil]

  defp occurrence(series, next_on),
    do: [next_on: next_on, next_at: make_at(series, next_on)]

  defp make_at(series, next_on),
    do: Timezones.to_utc(Date.add(next_on, -series.lead_days), series.create_at, series.timezone)

  defp after_done_next(series, done_at) do
    next_on = Rule.after_done_date(Series.rule(series), Timezones.today(series.timezone, done_at))
    series |> Ecto.Changeset.change(occurrence(series, next_on)) |> end_if_over()
  end

  # A series past its end is marked ended rather than deleted: the card
  # still says what it was.
  defp end_if_over(%Ecto.Changeset{} = cs) do
    series = Ecto.Changeset.apply_changes(cs)

    cond do
      not is_nil(series.ended_at) ->
        cs

      series.next_on && not Rule.within_end?(Series.ending(series), series.next_on, series.made) ->
        Ecto.Changeset.change(cs, next_on: nil, next_at: nil, ended_at: DateTime.utc_now(:second))

      true ->
        cs
    end
  end

  @doc "Stops `card`'s series. The instances made so far stay as they are."
  def stop(%Card{} = card) do
    case for_card(card) do
      nil ->
        {:error, :not_found}

      series ->
        Repo.delete(series)
        Boards.log_activity_for(card, "card", "stopped “#{card.title}” recurring")
        Boards.card_changed(card)
        {:ok, series}
    end
  end

  @doc """
  Lets the next occurrence go without making it. A fixed series moves on to
  the occurrence after; an after-done one, waiting on a completion, moves
  the date it will be due on by another of its amounts.
  """
  def skip(%Card{} = card) do
    with %Series{next_on: %Date{} = next_on} = series <- for_card(card) do
      rule = Series.rule(series)

      next =
        if series.kind == "after_done",
          do: Rule.after_done_date(rule, next_on),
          else: Rule.next_date(rule, next_on)

      series
      |> Ecto.Changeset.change(occurrence(series, next))
      |> end_if_over()
      |> Repo.update()
      |> tap(fn
        {:ok, _} ->
          Boards.log_activity_for(
            card,
            "card",
            "skipped the occurrence of #{next_on} of “#{card.title}”"
          )

          Boards.card_changed(card)

        _ ->
          :ok
      end)
    else
      nil -> {:error, :not_found}
      %Series{} -> {:error, "there is no next occurrence to skip"}
    end
  end

  ## What happens to the current instance

  @doc """
  Called when a card is completed or reopened. Completing the current
  instance of an after-done series sets when the next is made; reopening it
  before then takes that back.
  """
  def completion_changed(%Card{} = card) do
    case for_card(card) do
      %Series{kind: "after_done"} = series ->
        if card.completed do
          series
          |> after_done_next(card.completed_at || DateTime.utc_now(:second))
          |> Repo.update()
        else
          series |> Ecto.Changeset.change(next_on: nil, next_at: nil) |> Repo.update()
        end

      _ ->
        :ok
    end
  end

  @doc "Called when a card is archived: archiving the current instance pauses its series."
  def card_archived(%Card{} = card) do
    case for_card(card) do
      %Series{paused: false} = series ->
        {:ok, _} = series |> Ecto.Changeset.change(paused: true) |> Repo.update()
        Boards.card_changed(card)

        Boards.add_comment(
          card,
          "This card repeats, and archiving it has paused the series. " <>
            "Restore it and resume the series to carry on, or stop it."
        )

      _ ->
        :ok
    end
  end

  ## The clock

  @doc """
  Makes every instance whose time has come by `now`. Returns how many series
  acted. Called by `Slipdock.Automations.Scheduler` every minute.
  """
  def tick(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    from(s in Series,
      where: not s.paused and is_nil(s.ended_at) and not is_nil(s.next_at) and s.next_at <= ^now,
      order_by: s.next_at,
      select: s.id
    )
    |> Repo.all()
    |> Enum.count(fn id ->
      try do
        fire(id, now) == :fired
      rescue
        exception ->
          Logger.error("Recurring series #{id} failed: #{Exception.message(exception)}")
          false
      end
    end)
  end

  defp fire(id, now) do
    {result, effects} =
      Slipdock.Deferred.collect(fn ->
        Repo.transaction(fn ->
          series =
            Repo.one(from(s in Series, where: s.id == ^id, lock: "FOR UPDATE"))

          with %Series{} <- series,
               true <- Series.active?(series),
               %DateTime{} = at <- series.next_at,
               true <- DateTime.compare(at, now) != :gt,
               series = catch_up(series, now) do
            # An occurrence already acted on (a series set again onto a date
            # it had passed) is stepped over rather than acted on twice.
            if claim(series), do: act(series, now), else: step_over(series)
          else
            _ -> :skipped
          end
        end)
      end)

    case result do
      {:ok, :fired} ->
        Slipdock.Deferred.run(effects)
        # Anyone watching the board hears of the new instance once it is
        # really there: the copy's own notice went out inside the transaction.
        with %Series{card_id: card_id} <- Repo.get(Series, id),
             %Card{} = card <- Repo.get(Card, card_id),
             do: Boards.card_changed(card)

        :fired

      {:ok, other} ->
        other

      {:error, reason} ->
        held_up(id, reason)
        :failed
    end
  end

  defp step_over(series) do
    advance(series, nil, series.made)
    :skipped
  end

  # The next instance couldn't be made (the owner's card limit, most likely).
  # Trying again every minute would only say so every minute: the series is
  # paused, and the card says why.
  defp held_up(id, reason) do
    message =
      case reason do
        %Ecto.Changeset{} = cs ->
          Slipdock.Quota.refusal_message(cs) || inspect(cs.errors)

        other ->
          inspect(other)
      end

    Logger.warning("Recurring series #{id} didn't make its instance: #{message}")

    with %Series{} = series <- Repo.get(Series, id),
         {:ok, _} <- series |> Ecto.Changeset.change(paused: true) |> Repo.update(),
         %Card{} = card <- Repo.get(Card, series.card_id) do
      Boards.add_comment(
        card,
        "The next one of this recurring card couldn't be made, so the series is paused: " <>
          message
      )
    end
  end

  # A fixed series that missed several occurrences (the server was down)
  # acts once, for the latest whose time has come.
  defp catch_up(%Series{kind: "fixed"} = series, now) do
    rule = Series.rule(series)

    Stream.iterate(series.next_on, &Rule.next_date(rule, &1))
    |> Stream.take_while(&(&1 && DateTime.compare(make_at(series, &1), now) != :gt))
    |> Stream.take_while(&Rule.within_end?(Series.ending(series), &1, series.made))
    |> Enum.reduce(series.next_on, fn d, _ -> d end)
    |> then(&%{series | next_on: &1})
  end

  defp catch_up(series, _now), do: series

  defp claim(series) do
    attrs = %{
      recurrence_id: series.id,
      key: "#{series.kind}:#{series.next_on}",
      inserted_at: DateTime.utc_now(:second)
    }

    match?({1, _}, Repo.insert_all("recurrence_fires", [attrs], on_conflict: :nothing))
  end

  defp act(series, _now) do
    current = Repo.get!(Card, series.card_id)
    open? = not current.completed

    cond do
      not Rule.within_end?(Series.ending(series), series.next_on, series.made) ->
        finish(series)
        :ended

      open? and series.kind == "fixed" and series.on_missed == "bump" ->
        bump(series, current)

      open? and series.kind == "fixed" and series.on_missed == "skip" ->
        missed(series, current)

      true ->
        make_instance(series, current)
    end
  end

  defp finish(series) do
    series
    |> Ecto.Changeset.change(next_on: nil, next_at: nil, ended_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end

  # The open card takes the new occurrence's date; nothing new is made.
  defp bump(series, current) do
    old = current.due_date

    {:ok, current} =
      Boards.update_card(current, dated(current, series.next_on))

    {:ok, _} =
      Boards.add_comment(
        current,
        "Missed occurrence of #{old || "its last date"}: this card was still open, so " <>
          "it is now due #{series.next_on} instead of a new one being made."
      )

    advance(series, current, series.made)
    :fired
  end

  defp missed(series, current) do
    {:ok, _} =
      Boards.add_comment(
        current,
        "Skipped the occurrence of #{series.next_on}: this card is still open."
      )

    advance(series, current, series.made)
    :fired
  end

  defp make_instance(series, current) do
    column = target_column(series, current)

    case Boards.copy_card(current, column, at: :top, attrs: dated(current, series.next_on)) do
      {:ok, copy} ->
        from(c in Card, where: c.id == ^copy.id) |> Repo.update_all(set: [series_id: series.id])

        series =
          series
          |> Ecto.Changeset.change(card_id: copy.id, last_created_card_id: copy.id)
          |> Repo.update!()

        advance(series, copy, series.made + 1)
        :fired

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # Due on the occurrence; a start date keeps its distance from the due date.
  defp dated(%Card{start_date: %Date{} = s, due_date: %Date{} = d}, next_on),
    do: %{"due_date" => next_on, "start_date" => Date.add(next_on, Date.diff(s, d))}

  defp dated(_card, next_on), do: %{"due_date" => next_on, "start_date" => nil}

  defp target_column(%Series{column_id: id}, current) when not is_nil(id) do
    case Repo.get(Column, id) do
      %Column{board_id: board_id} = column when board_id == current.board_id -> column
      _ -> ready_column(current)
    end
  end

  defp target_column(_series, current), do: ready_column(current)

  defp ready_column(current) do
    board = Boards.get_board!(current.board_id)
    SlipdockWeb.APIGuide.list_roles(board.columns).ready || hd(board.columns)
  end

  defp advance(%Series{kind: "after_done"} = series, _card, made) do
    series
    |> Ecto.Changeset.change(made: made, next_on: nil, next_at: nil)
    |> Repo.update!()
  end

  defp advance(series, _card, made) do
    next_on = Rule.next_date(Series.rule(series), series.next_on)

    series
    |> Ecto.Changeset.change([made: made] ++ occurrence(series, next_on))
    |> end_if_over()
    |> Repo.update!()
  end
end

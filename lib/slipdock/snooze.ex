defmodule Slipdock.Snooze do
  @moduledoc """
  Snooze (W-1803): a card hidden until a moment, then brought back to the
  top of its list.

  A card is snoozed while `snoozed_until` is ahead of now. While it is, it is
  left out of the board's lists, My work, `list_cards` (unless asked for),
  the `list_top` runner pick and the time-based automation triggers — every
  one of them through `not_snoozed/2`, so there is one definition of
  "asleep" rather than one per site. It still counts in rollups (an epic
  whose remaining work is asleep is not done), and it is still found by
  search, read by `get_card` and drawn on the calendar.

  A date means midnight where the snoozer is (`Slipdock.Timezones`).

  **Waking.** The scheduler's tick (`tick/1`) wakes every card whose time
  has come; `wake/2` wakes one now, by hand; and `activity/3` wakes one when
  somebody other than the snoozer comments on it or assigns it to someone
  new, unless the snooze said not to. Waking clears the snooze, moves the
  card to the top of its list, says so in the activity log, raises an alert
  on the board when the snooze asked for one, and runs the `card_woken`
  automations. Each snooze wakes once, however many ticks race for it.
  """

  import Ecto.Query

  alias Slipdock.{Boards, QuickAdd, Repo, Timezones}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Card

  @note_max 280

  ## Reading ------------------------------------------------------------------

  @doc """
  Narrows a card query (cards as the first binding) to the cards that are
  not snoozed at `now`.
  """
  def not_snoozed(query, now \\ DateTime.utc_now()),
    do: where(query, [c], is_nil(c.snoozed_until) or c.snoozed_until <= ^now)

  @doc "Narrows a card query to the cards snoozed at `now`."
  def only_snoozed(query, now \\ DateTime.utc_now()),
    do: where(query, [c], c.snoozed_until > ^now)

  @doc """
  Narrows a card query by a `snoozed` filter as the API and the CLI send
  it: `"exclude"` (the default, and anything unrecognised), `"include"` (or
  `"all"`) or `"only"`.
  """
  def filter(query, mode, now \\ DateTime.utc_now())
  def filter(query, mode, _now) when mode in ["include", "all", :include], do: query
  def filter(query, mode, now) when mode in ["only", :only], do: only_snoozed(query, now)
  def filter(query, _exclude, now), do: not_snoozed(query, now)

  @doc """
  `board` with its snoozed cards back in their lists, in list order, for the
  views that show them on request (the "Show snoozed" toggle) and the ones
  that always do (calendar and timeline, faded).
  """
  def with_snoozed(%{columns: columns} = board) when is_list(columns) do
    columns =
      Enum.map(columns, fn
        %{snoozed: [_ | _] = asleep} = col ->
          %{col | cards: Enum.sort_by(col.cards ++ asleep, &{&1.position, &1.id}), snoozed: []}

        col ->
          col
      end)

    %{board | columns: columns}
  end

  @doc """
  The picker's presets for someone whose today is `today`, as
  `{key, label, date}`: tomorrow, next Monday, a week today and the first
  of next month. Each date means midnight where they are.
  """
  def presets(%Date{} = today) do
    days_to_monday = 8 - Date.day_of_week(today)

    [
      {"tomorrow", "Tomorrow", Date.add(today, 1)},
      {"monday", "Next Monday", Date.add(today, days_to_monday)},
      {"week", "In a week", Date.add(today, 7)},
      {"month", "Next month", today |> Date.shift(month: 1) |> Date.beginning_of_month()}
    ]
  end

  @doc "The longest a snooze note may be."
  def note_max, do: @note_max

  ## Snoozing -----------------------------------------------------------------

  @doc """
  Snoozes `card` until `until`, as `by` (a user, or nil for the system).

  `until` is a `DateTime`, a `Date` (midnight in `by`'s timezone), or a
  string: an ISO 8601 datetime, or a date phrase as quick add reads them
  (`2026-11-02`, `tomorrow`, `mon`, `next week`, `in 3 days`).

  Options: `:note` (≤ 280 characters), `:notify` (alert when it wakes,
  default false), `:wake_on_activity` (wake when someone else comments or
  assigns it, default true), `:now`.

  Refuses a completed or archived card (`{:error, :completed}`,
  `{:error, :archived}`), a stand-in (`{:error, :stand_in}`), a moment that
  isn't ahead (`{:error, :past}`), one that doesn't read
  (`{:error, :bad_date}`) and a note that's too long (`{:error, :note_too_long}`).
  """
  def snooze(%Card{} = card, by, until, opts \\ []) do
    now = opts[:now] || DateTime.utc_now()
    note = opts[:note] |> to_string() |> String.trim()

    with :ok <- snoozable(card),
         {:ok, until} <- resolve_until(until, by, now),
         :ok <- ahead(until, now),
         :ok <- note_fits(note) do
      card
      |> Ecto.Changeset.change(
        snoozed_until: DateTime.truncate(until, :second),
        snoozed_at: DateTime.truncate(now, :second),
        snoozed_by_id: by && by.id,
        snooze_note: if(note == "", do: nil, else: note),
        snooze_notify: opts[:notify] == true,
        snooze_wake_on_activity: opts[:wake_on_activity] != false
      )
      |> Repo.update()
      |> tap_ok(fn c ->
        Boards.log_activity_for(c, "card", "snoozed “#{c.title}” until #{describe(c, by)}")
        Boards.card_changed(c)
      end)
    end
  end

  defp snoozable(%Card{completed: true}), do: {:error, :completed}
  defp snoozable(%Card{archived_at: %DateTime{}}), do: {:error, :archived}
  defp snoozable(%Card{stand_in_for_id: id}) when not is_nil(id), do: {:error, :stand_in}
  defp snoozable(_), do: :ok

  defp ahead(until, now),
    do: if(DateTime.compare(until, now) == :gt, do: :ok, else: {:error, :past})

  defp note_fits(note),
    do: if(String.length(note) <= @note_max, do: :ok, else: {:error, :note_too_long})

  @doc """
  The UTC moment `value` means for `user` at `now`: see `snooze/4`.
  `{:ok, datetime}` or `{:error, :bad_date}`.
  """
  def resolve_until(value, user, now \\ DateTime.utc_now())

  def resolve_until(%DateTime{} = dt, _user, _now), do: {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}

  def resolve_until(%Date{} = date, user, _now),
    do: {:ok, Timezones.to_utc(date, ~T[00:00:00], Timezones.of(user))}

  def resolve_until(value, user, now) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        case QuickAdd.parse_date(value, Timezones.today(Timezones.of(user), now)) do
          {:ok, %Date{} = date} -> resolve_until(date, user, now)
          _ -> {:error, :bad_date}
        end
    end
  end

  def resolve_until(_value, _user, _now), do: {:error, :bad_date}

  @doc "What a refusal from `snooze/4` or `wake/2` means, in a sentence."
  def error_message(:past), do: "the snooze must end in the future"
  def error_message(:completed), do: "a completed card can't be snoozed"
  def error_message(:archived), do: "an archived card can't be snoozed"

  def error_message(:stand_in),
    do: "a stand-in can't be snoozed — snooze the card it stands for"

  def error_message(:bad_date),
    do:
      "until must be a date (YYYY-MM-DD), a datetime (ISO 8601) or a phrase such as " <>
        "tomorrow, mon, next week, in 3 days"

  def error_message(:note_too_long), do: "the note can be at most #{@note_max} characters"
  def error_message(:not_snoozed), do: "the card isn't snoozed"

  ## Waking -------------------------------------------------------------------

  @doc """
  Wakes every card whose snooze has run out at `now`. Returns how many woke.
  """
  def tick(now \\ DateTime.utc_now()) do
    from(c in Card,
      where: not is_nil(c.snoozed_until) and c.snoozed_until <= ^now and is_nil(c.archived_at),
      order_by: [asc: c.snoozed_until, asc: c.id],
      select: c.id
    )
    |> Repo.all()
    |> Enum.count(fn id -> match?({:ok, _}, wake(Repo.get(Card, id), reason: :time)) end)
  end

  @doc """
  Wakes `card`. Options: `:by` (who woke it; nil for the clock), `:reason`
  (`:hand`, the default, `:time` or `:activity`). `{:ok, card}`, or
  `{:error, :not_snoozed}` when there is nothing to wake — including when
  another tick got there first.
  """
  def wake(card, opts \\ [])

  def wake(%Card{snoozed_until: nil}, _opts), do: {:error, :not_snoozed}

  def wake(%Card{} = card, opts) do
    by = opts[:by]
    reason = opts[:reason] || :hand
    until = card.snoozed_until

    # Compare and set: of two ticks reading the same card, one clears it.
    {count, _} =
      from(c in Card, where: c.id == ^card.id and c.snoozed_until == ^until)
      |> Repo.update_all(
        set: [
          snoozed_until: nil,
          snoozed_at: nil,
          snoozed_by_id: nil,
          snooze_note: nil,
          snooze_notify: false,
          snooze_wake_on_activity: true,
          updated_at: DateTime.utc_now(:second)
        ]
      )

    if count == 1, do: {:ok, woke(card, by, reason)}, else: {:error, :not_snoozed}
  end

  def wake(_card, _opts), do: {:error, :not_snoozed}

  defp woke(%Card{} = card, by, reason) do
    snoozer = card.snoozed_by_id && Repo.get(User, card.snoozed_by_id)
    awake = Repo.get!(Card, card.id)

    if not awake.completed and is_nil(awake.archived_at) do
      column = Repo.get!(Slipdock.Boards.Column, awake.column_id)
      Boards.move_card_to_index(awake, column, :top, actor: Slipdock.Actor.automation())
    end

    line = "woke up “#{card.title}” (#{snoozed_line(card, snoozer)})#{woken_by(reason, by)}"
    Boards.log_activity_for(awake, "card", line)

    # The snoozer waking it themselves needs no telling.
    if card.snooze_notify and not same_person?(by, snoozer) do
      Slipdock.Automations.raise_alert(%{
        "title" => String.slice("Awake: #{card.title}", 0, 200),
        "body" => line,
        "severity" => "info",
        "board_id" => card.board_id,
        "card_id" => card.id
      })
    end

    awake = Repo.get!(Card, card.id)
    Boards.card_changed(awake)
    Slipdock.Automations.dispatch(%{type: "card_woken", card: awake, by: by, reason: reason})
    awake
  end

  defp snoozed_line(card, snoozer) do
    who = if snoozer, do: "snoozed by #{User.display_name(snoozer)}", else: "snoozed"
    on = if card.snoozed_at, do: " on #{day(card.snoozed_at, snoozer)}", else: ""
    note = if card.snooze_note, do: ": #{card.snooze_note}", else: ""
    who <> on <> note
  end

  defp woken_by(:time, _by), do: ""
  defp woken_by(:activity, %User{} = by), do: ", by #{User.display_name(by)}'s activity"
  defp woken_by(:activity, _by), do: ", by activity on it"
  defp woken_by(_hand, %User{} = by), do: ", woken by #{User.display_name(by)}"
  defp woken_by(_hand, _by), do: ", woken by hand"

  defp same_person?(%User{id: id}, %User{id: id}), do: true
  defp same_person?(_, _), do: false

  @doc """
  Somebody did something to `card` that a snooze should notice: `:comment`
  or `:assigned` (someone new was put on it), by `by`. Wakes the card when
  it is snoozed, its snooze wakes on activity, and `by` is not the snoozer —
  a write with nobody behind it (an automation, an import) counts as
  somebody else. Returns what `wake/2` does, or `:ignored`.
  """
  def activity(%Card{} = card, by, _kind) do
    fresh = Repo.get(Card, card.id)

    cond do
      is_nil(fresh) or not Card.snoozed?(fresh) -> :ignored
      not fresh.snooze_wake_on_activity -> :ignored
      match?(%User{}, by) and by.id == fresh.snoozed_by_id -> :ignored
      true -> wake(fresh, by: by, reason: :activity)
    end
  end

  def activity(_owner, _by, _kind), do: :ignored

  # "Tue 3 Nov" in the snoozer's timezone, with the note when there is one.
  defp describe(%Card{snoozed_until: until, snooze_note: note}, by) do
    day = day(until, by)
    if note, do: "#{day}: #{note}", else: day
  end

  defp day(utc, user) do
    local = Timezones.to_local(utc, Timezones.of(user))

    if Time.compare(DateTime.to_time(local), ~T[00:00:00]) == :eq,
      do: Calendar.strftime(local, "%a %-d %b"),
      else: Calendar.strftime(local, "%a %-d %b %H:%M")
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other
end

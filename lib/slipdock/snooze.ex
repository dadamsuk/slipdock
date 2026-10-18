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
  """

  import Ecto.Query

  alias Slipdock.{Boards, QuickAdd, Repo, Timezones}
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

  # "Tue 3 Nov" in the snoozer's timezone, with the note when there is one.
  defp describe(%Card{snoozed_until: until, snooze_note: note}, by) do
    local = Timezones.to_local(until, Timezones.of(by))

    day =
      if Time.compare(DateTime.to_time(local), ~T[00:00:00]) == :eq,
        do: Calendar.strftime(local, "%a %-d %b"),
        else: Calendar.strftime(local, "%a %-d %b %H:%M")

    if note, do: "#{day}: #{note}", else: day
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other
end

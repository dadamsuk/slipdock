defmodule Slipdock.WaitDefaults do
  @moduledoc """
  A stall must not outlive its reason (#2096). An approval wait — a
  question of kind `other`, opened by an agent, offering choices with one
  proposed as its `default_choice` (`Slipdock.Boards.Wait.approval?/1`) —
  left unanswered for its board's `wait_default_after` resolves to its
  proposal: the server answers it with that choice, the card says so, the
  person asked is told, and the card moves on as it would on their answer
  (a runner's card is sent again).

  `wait_default_after` is minutes, nil (the default) off. The card's board
  decides, or the nearest board above it that sets one. Product, ux,
  security and release questions, the server's own waits and a wait with
  no proposal never default: those are a person's, however long they take.

  The scheduler runs `tick/1` every minute (`Slipdock.Automations.Scheduler`).
  """

  import Ecto.Query

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.{Board, Card, Wait}

  # At most 30 days: past that the default is not a default but a forgotten wait.
  @max_minutes 30 * 24 * 60

  @doc "The longest `wait_default_after` a board may set, in minutes."
  def max_minutes, do: @max_minutes

  @doc """
  Reads a duration as minutes: an integer is minutes, and text is `90m`,
  `4h`, `2d` or a bare number of minutes. `nil`, `""`, `off`, `none` and `0`
  are off (nil). Anything else is `:error`.

      iex> Slipdock.WaitDefaults.parse("4h")
      {:ok, 240}
      iex> Slipdock.WaitDefaults.parse("off")
      {:ok, nil}
  """
  def parse(nil), do: {:ok, nil}
  def parse(0), do: {:ok, nil}
  def parse(n) when is_integer(n) and n > 0, do: {:ok, n}
  def parse(n) when is_integer(n), do: :error

  def parse(text) when is_binary(text) do
    case text |> String.trim() |> String.downcase() do
      off when off in ["", "off", "none", "never", "0"] ->
        {:ok, nil}

      trimmed ->
        case Regex.run(~r/^(\d+)\s*(m|min|mins|minutes?|h|hours?|d|days?)?$/, trimmed) do
          [_, n] -> {:ok, String.to_integer(n)}
          [_, n, unit] -> {:ok, String.to_integer(n) * unit_minutes(unit)}
          nil -> :error
        end
    end
  end

  def parse(_), do: :error

  defp unit_minutes("m" <> _), do: 1
  defp unit_minutes("h" <> _), do: 60
  defp unit_minutes("d" <> _), do: 24 * 60

  @doc """
  Minutes as the shortest text that reads back the same: `4h`, `90m`,
  `2d`; nil for off.

      iex> Slipdock.WaitDefaults.format(240)
      "4h"
  """
  def format(nil), do: nil
  def format(n) when is_integer(n) and rem(n, 1440) == 0, do: "#{div(n, 1440)}d"
  def format(n) when is_integer(n) and rem(n, 60) == 0, do: "#{div(n, 60)}h"
  def format(n) when is_integer(n), do: "#{n}m"

  @doc """
  The `wait_default_after` that applies to `card`'s waits, in minutes: its
  board's, else the nearest board above it that sets one; nil when none.
  """
  def after_minutes(%Card{board_id: board_id}) do
    ids = Boards.ancestor_board_ids(board_id)

    set =
      from(b in Board,
        where: b.id in ^ids and not is_nil(b.wait_default_after),
        select: {b.id, b.wait_default_after}
      )
      |> Repo.all()
      |> Map.new()

    Enum.find_value(ids, &set[&1])
  end

  @doc """
  Resolves every approval wait whose time is up (see the moduledoc) to its
  proposal, and tells the person asked. Returns how many it resolved.
  """
  def tick(now \\ DateTime.utc_now()) do
    candidates()
    |> Enum.filter(&Wait.approval?/1)
    |> Enum.reduce(0, fn wait, count ->
      card = Repo.get!(Card, wait.card_id)
      minutes = after_minutes(card)

      if due?(wait, minutes, now) and resolve(wait, card, minutes) == :ok,
        do: count + 1,
        else: count
    end)
  end

  @doc "Whether `wait`, under a setting of `minutes`, has waited long enough at `now`."
  def due?(_wait, nil, _now), do: false

  def due?(%Wait{inserted_at: at}, minutes, now),
    do: DateTime.compare(DateTime.add(at, minutes * 60, :second), now) != :gt

  # Open waits that could be approvals: the filter in SQL is a superset,
  # `Wait.approval?/1` has the last word.
  defp candidates do
    from(w in Wait,
      where:
        is_nil(w.closed_at) and not is_nil(w.default_choice) and w.question == "other" and
          is_nil(w.purpose),
      order_by: w.inserted_at
    )
    |> Repo.all()
  end

  defp resolve(wait, card, minutes) do
    case Boards.default_wait(wait, format(minutes)) do
      {:ok, closed} ->
        Slipdock.Boards.WaitEmail.defaulted(closed, card, format(minutes))
        :ok

      # Answered or withdrawn in the meantime: nothing to do.
      {:error, _} ->
        :skipped
    end
  end
end

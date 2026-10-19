defmodule Slipdock.CardTimeline do
  @moduledoc """
  A card's timeline (#1131): what it has been through, as spans of time
  on one axis, read from what is already recorded about it.

    * `stays` — the lists it has sat in, from the movement ledger
      (`Slipdock.Boards.CardMove`). Each runs from the row that put the
      card there to the next row, or to now. Time put away is a stay too,
      with `category: "archived"`. A stay whose end the ledger can't vouch
      for — the next move came from another list, or has no source (a
      backfilled move after one the backfill couldn't read) — is `unsure`,
      and so is the time before a card's first row when that row isn't its
      creation;
    * `waits` — each time it waited on a person (#1114), opened to closed;
    * `jobs` — each runner job sent on it, queued to finished.

  `from` is the earliest of all of them (or the card's creation) and `to`
  is now, so open spans end there. Read by the card panel, REST
  `GET /api/cards/:id/timeline`, MCP `get_card` with `timeline` and
  `slipdock timeline`.
  """

  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Card, CardMove, Wait}
  alias Slipdock.Repo
  alias Slipdock.Runners.Job

  defstruct from: nil, to: nil, stays: [], waits: [], jobs: []

  @doc """
  The timeline of `card`. Options: `:now` (a `DateTime`, for the end of
  open spans; defaults to the current time). Three queries.
  """
  def for_card(%Card{} = card, opts \\ []) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> sec()

    stays =
      from(m in CardMove,
        where: m.card_id == ^card.id,
        order_by: [asc: m.inserted_at, asc: m.id],
        preload: :user
      )
      |> Repo.all()
      |> stays(card, now)

    waits =
      from(w in Wait,
        where: w.card_id == ^card.id,
        order_by: [asc: w.inserted_at, asc: w.id],
        preload: :on_user
      )
      |> Repo.all()
      |> Enum.map(&wait(&1, now))

    jobs =
      from(j in Job, where: j.card_id == ^card.id, order_by: [asc: j.inserted_at, asc: j.id])
      |> Repo.all()
      |> Enum.map(&job(&1, now))

    starts = Enum.map(stays ++ waits ++ jobs, & &1.from)
    from = Enum.min([sec(card.inserted_at) | starts], DateTime, fn -> now end)

    %__MODULE__{from: from, to: now, stays: stays, waits: waits, jobs: jobs}
  end

  @doc "How long a span lasted, in seconds."
  def seconds(%{from: from, to: to}), do: max(DateTime.diff(to, from), 0)

  @doc "True when nothing has been recorded about the card at all."
  def empty?(%__MODULE__{stays: [], waits: [], jobs: []}), do: true
  def empty?(%__MODULE__{}), do: false

  # Walks the ledger in order: each row ends the stay before it and, unless
  # nothing follows, starts the next.
  defp stays([], %Card{}, _now), do: []

  defp stays([first | _] = rows, card, now) do
    lead = lead_in(first, card)

    {done, open} =
      Enum.reduce(rows, {[], lead}, fn row, {done, current} ->
        at = sec(row.inserted_at)
        done = if current, do: [close(current, row, at) | done], else: done
        {done, start(row, at)}
      end)

    Enum.reverse([%{open | to: now, open: true} | done])
  end

  # A card whose first row isn't its creation was somewhere before it:
  # in the list that row moved it from, if it says, for a time nobody logged.
  defp lead_in(%CardMove{kind: "created"}, _card), do: nil

  defp lead_in(%CardMove{} = row, card) do
    if DateTime.compare(sec(card.inserted_at), sec(row.inserted_at)) == :lt do
      %{
        stay(row.from_column_name, row.from_category, row.from_board_id, sec(card.inserted_at))
        | unsure: true
      }
    end
  end

  defp start(%CardMove{kind: "archived"} = row, at),
    do: %{stay("Archived", "archived", row.board_id, at) | how: how(row)}

  defp start(%CardMove{} = row, at),
    do: %{stay(row.to_column_name, row.to_category, row.board_id, at) | how: how(row)}

  defp close(stay, %CardMove{} = row, at) do
    %{stay | to: at, unsure: stay.unsure or not continues?(stay, row)}
  end

  # Does `row` leave from the stay it ends? An archive or a move names the
  # list it left; a restore leaves the archive; a second "created" never
  # follows anything that happened.
  defp continues?(%{category: "archived"}, %CardMove{kind: "restored"}), do: true
  defp continues?(_stay, %CardMove{kind: k}) when k in ~w(created restored), do: false

  defp continues?(stay, %CardMove{from_column_name: name}),
    do: not is_nil(name) and name == stay.list

  defp stay(list, category, board_id, at) do
    %{
      list: list || "Unknown list",
      category: category,
      board_id: board_id,
      from: at,
      to: at,
      open: false,
      unsure: false,
      how: nil
    }
  end

  # How the card got into the stay: the kind of move, and by whom.
  defp how(%CardMove{} = row) do
    %{
      kind: row.kind,
      actor_kind: row.actor_kind,
      via: row.via,
      by: by(row),
      backfilled: row.backfilled
    }
  end

  defp by(%CardMove{user: %User{} = user, agent: nil}), do: User.display_name(user)
  defp by(%CardMove{agent: agent}) when agent not in [nil, ""], do: agent
  defp by(%CardMove{actor_kind: "automation"}), do: "a rule"
  defp by(_row), do: nil

  defp wait(%Wait{} = w, now) do
    %{
      id: w.id,
      needs: w.needs,
      on: Wait.on_name(w),
      from: sec(w.inserted_at),
      to: if(w.closed_at, do: sec(w.closed_at), else: now),
      open: is_nil(w.closed_at),
      reason: w.close_reason
    }
  end

  defp job(%Job{} = j, now) do
    open = Job.open?(j)

    %{
      id: j.id,
      status: j.status,
      pool: j.pool,
      kind: j.kind,
      runner: j.runner_name,
      from: sec(j.inserted_at),
      to: if(open, do: now, else: sec(j.finished_at || j.updated_at)),
      open: open
    }
  end

  defp sec(%DateTime{} = at), do: DateTime.truncate(at, :second)
  defp sec(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> sec()
end

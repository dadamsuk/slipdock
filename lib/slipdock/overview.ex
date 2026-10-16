defmodule Slipdock.Overview do
  @moduledoc """
  What this server is being used for, for whoever runs it: every account,
  when it arrived and was last seen, and how much each person has made.

  ## Whose things

  Counted by **owner**, exactly as `Slipdock.Quota` counts them (it does most
  of the counting): a card on a board somebody shared with you is the board
  owner's, and a sub-board belongs to whoever owns the top of its tree. That
  way the numbers here are the numbers a limit would meet, and the totals add
  up without counting a shared board twice.

  `boards` is the live top-level boards, as the board limit sees them. Lists,
  cards, pages, files and storage are counted wherever they sit, archived
  board or not, because they are still on the disk. Archived cards and pages
  are not counted, again as the quota does.

  ## Last seen

  Two dates, because an account worked by an agent may never sign in at all:
  `last_signed_in_at` is the last browser sign-in, `last_api_at` the last time
  any of their API tokens (the CLI, an agent, MCP) was used. `last_active_at`
  is the later of the two, and is what "active" means in the totals.
  """
  import Ecto.Query, warn: false

  alias Slipdock.{Accounts, Quota, Repo}
  alias Slipdock.Accounts.UserToken
  alias Slipdock.Boards.{Board, Column}

  @counts ~w(boards lists cards pages files storage)a

  @sorts ~w(storage cards boards lists pages files last_active signed_up email)a

  @doc "The orders `people/1` accepts, as `sort:`."
  def sorts, do: @sorts

  @doc """
  The accounts and the totals across them: `%{people: [...], totals: %{...}}`.
  Takes `people/1`'s options.
  """
  def overview(opts \\ []) do
    people = people(opts)
    %{people: people, totals: totals(people, opts[:now] || DateTime.utc_now())}
  end

  @doc """
  Every account, with what it owns:
  `%{user, signed_up_at, last_signed_in_at, last_api_at, last_active_at,
  boards, lists, cards, pages, files, storage}`.

  `sort:` is one of `sorts/0` (as an atom or a string; anything else is the
  default, `storage`). Counts and dates go largest or latest first, with the
  never-seen last; `email` goes A to Z.
  """
  def people(opts \\ []) do
    users = Accounts.list_users()
    ids = Enum.map(users, & &1.id)
    usage = Quota.usage(ids)
    lists = lists_by_owner(ids)
    api = last_api_use(ids)

    users
    |> Enum.map(fn user ->
      last_api_at = Map.get(api, user.id)

      usage[user.id]
      |> Map.take([:boards, :cards, :pages, :files, :storage])
      |> Map.merge(%{
        user: user,
        lists: Map.get(lists, user.id, 0),
        signed_up_at: user.inserted_at,
        last_signed_in_at: user.last_signed_in_at,
        last_api_at: last_api_at,
        last_active_at: latest(user.last_signed_in_at, last_api_at)
      })
    end)
    |> sort(sort_key(opts[:sort]))
  end

  @doc """
  Totals across `people`: how many accounts and of what kind, how many of them
  arrived or were active in the last 7 and 30 days, and the sum of every count.
  """
  def totals(people, now \\ DateTime.utc_now()) do
    within = fn date, days -> date && DateTime.diff(now, date, :day) < days end

    counts = Map.new(@counts, fn key -> {key, people |> Enum.map(& &1[key]) |> Enum.sum()} end)

    Map.merge(counts, %{
      users: length(people),
      admins: Enum.count(people, & &1.user.admin),
      disabled: Enum.count(people, & &1.user.disabled_at),
      never_seen: Enum.count(people, &is_nil(&1.last_active_at)),
      joined_7d: Enum.count(people, &within.(&1.signed_up_at, 7)),
      joined_30d: Enum.count(people, &within.(&1.signed_up_at, 30)),
      active_7d: Enum.count(people, &within.(&1.last_active_at, 7)),
      active_30d: Enum.count(people, &within.(&1.last_active_at, 30))
    })
  end

  # Lists on every board in each person's trees, sub-boards included.
  defp lists_by_owner(ids) do
    from(c in Column,
      join: b in Board,
      on: b.id == c.board_id,
      join: root in Board,
      on: root.id == coalesce(b.root_id, b.id),
      where: root.owner_id in ^ids,
      group_by: root.owner_id,
      select: {root.owner_id, count(c.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # The last time any of their tokens was used. Only API tokens record it;
  # sessions and one-time links leave it blank, so they never count here.
  defp last_api_use(ids) do
    from(t in UserToken,
      where: t.user_id in ^ids and not is_nil(t.last_used_at),
      group_by: t.user_id,
      select: {t.user_id, max(t.last_used_at)}
    )
    |> Repo.all()
    |> Map.new(fn {id, at} -> {id, to_datetime(at)} end)
  end

  # SQLite hands an aggregate back as it was stored, not as the field's type.
  defp to_datetime(%DateTime{} = at), do: at
  defp to_datetime(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp to_datetime(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> at |> NaiveDateTime.from_iso8601!() |> to_datetime()
    end
  end

  defp latest(nil, b), do: b
  defp latest(a, nil), do: a
  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp sort_key(key) when is_atom(key) and key in @sorts, do: key

  defp sort_key(key) when is_binary(key),
    do: Enum.find(@sorts, :storage, &(Atom.to_string(&1) == key))

  defp sort_key(_), do: :storage

  defp sort(people, :email), do: Enum.sort_by(people, & &1.user.email)
  defp sort(people, :last_active), do: sort_dates(people, :last_active_at)
  defp sort(people, :signed_up), do: sort_dates(people, :signed_up_at)

  defp sort(people, key),
    do: Enum.sort_by(people, &{-Map.fetch!(&1, key), &1.user.email})

  # Latest first, never last; ties A to Z.
  defp sort_dates(people, key) do
    {seen, never} = Enum.split_with(people, &Map.fetch!(&1, key))

    Enum.sort_by(seen, &{-DateTime.to_unix(Map.fetch!(&1, key)), &1.user.email}) ++
      Enum.sort_by(never, & &1.user.email)
  end
end

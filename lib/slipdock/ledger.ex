defmodule Slipdock.Ledger do
  @moduledoc """
  What shipped on a board tree since a time (#1948): the list a person reads
  in ten minutes instead of approving each card, with each card's evidence
  beside it (W-1944 §Ledger).

  It reads only what the server already keeps, and writes nothing:

    * **completed** — a card's `completed_at`;
    * **accepted** — a verifier's (or a person's) acceptance: `verify_state`
      accepted or merging, at `verify_at`;
    * **merged** — a merge job that finished `done`, or a card a person
      marked merged (`merge_sha` with no merge job: its completion);
    * **deployed** — a succeeded deploy naming the card (`Deployments`).

  One line per card that had any of those in the window, at its latest one,
  grouped by day in the board's timezone (its owner's, `Flow.timezone/1`),
  newest first. A line carries who accepted it (`accepted_by`: a person or
  an agent, by `Verified.who/1`) and the last audit's verdict on it, the
  first line of its evidence, the `should` rules its verifier marked broken,
  its lead time by phase (`Slipdock.LeadTime.for_card/2`), its pull request
  and deploys. An epic's line rolls up its subcards: how many there are, how
  many are done and how many are on this ledger.

  Every door reads `since/2`: REST `GET /api/boards/:board/ledger?since=`,
  `slipdock ledger <board> [--since]`, the page at `/boards/:id/ledger` and
  MCP `activity` with `view: "ledger"`.
  """

  import Ecto.Query

  alias Slipdock.{Flow, LeadTime, Quality, Repo, Timezones, Verified}
  alias Slipdock.Boards.{Board, Card, Comment}
  alias Slipdock.Deployments.Deployment
  alias Slipdock.Runners.Job

  @accepted ~w(accepted merging)
  @day_starts ~T[07:00:00]
  @since_error "since is a date (2026-11-01), a time (ISO 8601) or a number of days"

  @doc "The kinds of event a line can carry, in the order a card goes through them."
  def events, do: ~w(completed accepted merged deployed)

  @doc """
  The ledger of `board` and every board beneath it.

  Options: `:since` (a `DateTime`, a number of days, or a string: digits for
  days, an ISO 8601 date or time; blank or missing is the default window),
  `:now` and `:timezone`. The default window starts at 07:00 on the day
  before today, in the board's timezone.

  Returns `{:ok, %{since, until, timezone, count, days: [%{date, items}]}}`,
  or `{:error, message}` for a `since` it can't read.
  """
  def since(%Board{} = board, opts \\ []) do
    # The query runs to `now` itself, so what happened this second counts.
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    tz = opts[:timezone] || Flow.timezone(board)

    with {:ok, from} <- window_start(opts[:since], now, tz) do
      items = board |> Quality.tree_ids() |> items(from, now)

      {:ok,
       %{
         board_id: board.id,
         since: from,
         until: DateTime.truncate(now, :second),
         timezone: tz,
         count: length(items),
         days: by_day(items, tz)
       }}
    end
  end

  @doc "Where the default window starts for `now` in `tz`: 07:00 the day before."
  def default_since(now, tz) do
    Timezones.to_utc(Date.add(Timezones.today(tz, now), -1), @day_starts, tz)
    |> DateTime.truncate(:second)
  end

  # -- The window ------------------------------------------------------------------

  defp window_start(v, now, tz) when v in [nil, ""], do: {:ok, default_since(now, tz)}
  defp window_start(%DateTime{} = at, _now, _tz), do: {:ok, DateTime.truncate(at, :second)}

  defp window_start(days, now, _tz) when is_integer(days) and days >= 0,
    do: {:ok, now |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)}

  defp window_start(text, now, tz) when is_binary(text) do
    text = String.trim(text)

    cond do
      Regex.match?(~r/^\d+$/, text) ->
        window_start(String.to_integer(text), now, tz)

      match?({:ok, _, _}, DateTime.from_iso8601(text)) ->
        {:ok, text |> DateTime.from_iso8601() |> elem(1) |> DateTime.truncate(:second)}

      match?({:ok, _}, Date.from_iso8601(text)) ->
        {:ok, Timezones.to_utc(Date.from_iso8601!(text), ~T[00:00:00], tz)}

      true ->
        {:error, @since_error}
    end
  end

  defp window_start(_v, _now, _tz), do: {:error, @since_error}

  # -- The events ------------------------------------------------------------------

  defp items(board_ids, from, to) do
    events =
      completed(board_ids, from, to) ++
        accepted(board_ids, from, to) ++
        merged(board_ids, from, to) ++ deployed(board_ids, from, to)

    by_card = Enum.group_by(events, & &1.card_id)
    cards = cards(Map.keys(by_card))
    epics = epics(Map.keys(cards), Map.keys(by_card))
    audits = audits(Map.keys(cards))

    cards
    |> Map.values()
    |> Enum.map(fn card ->
      line(card, Enum.sort_by(by_card[card.id], & &1.at, DateTime), epics, audits)
    end)
    |> Enum.sort_by(&{&1.at, &1.card.id}, :desc)
  end

  defp completed(ids, from, to) do
    Repo.all(
      from c in Card,
        where:
          c.board_id in ^ids and c.completed and c.completed_at >= ^from and
            c.completed_at <= ^to,
        select: %{card_id: c.id, at: c.completed_at}
    )
    |> tag("completed")
  end

  defp accepted(ids, from, to) do
    Repo.all(
      from c in Card,
        where:
          c.board_id in ^ids and c.verify_state in @accepted and not is_nil(c.verify_by) and
            c.verify_at >= ^from and c.verify_at <= ^to,
        select: %{card_id: c.id, at: c.verify_at}
    )
    |> tag("accepted")
  end

  # A merge job's end, or (a person's "merged it myself") a completed card
  # with a merge sha and no merge job done.
  defp merged(ids, from, to) do
    kind = Verified.merge_kind()

    jobs =
      Repo.all(
        from j in Job,
          join: c in Card,
          on: c.id == j.card_id,
          where:
            c.board_id in ^ids and j.kind == ^kind and j.status == "done" and
              j.finished_at >= ^from and j.finished_at <= ^to,
          select: %{card_id: c.id, at: j.finished_at}
      )

    tag(jobs ++ by_hand(ids, from, to, kind), "merged")
  end

  defp by_hand(ids, from, to, kind) do
    Repo.all(
      from c in Card,
        as: :card,
        where:
          c.board_id in ^ids and not is_nil(c.merge_sha) and c.completed and
            c.completed_at >= ^from and c.completed_at <= ^to and
            not exists(
              from j in Job,
                where: j.card_id == parent_as(:card).id and j.kind == ^kind and j.status == "done"
            ),
        select: %{card_id: c.id, at: c.completed_at}
    )
  end

  defp deployed(ids, from, to) do
    Repo.all(
      from d in Deployment,
        where:
          d.board_id in ^ids and d.status == "succeeded" and
            coalesce(d.finished_at, d.started_at) >= ^from and
            coalesce(d.finished_at, d.started_at) <= ^to,
        select: %{
          card_ids: d.card_ids,
          at: coalesce(d.finished_at, d.started_at),
          environment: d.environment,
          sha: d.sha
        }
    )
    |> Enum.flat_map(fn d ->
      for id <- d.card_ids || [],
          do: %{card_id: id, at: d.at, environment: d.environment, sha: d.sha}
    end)
    |> tag("deployed")
  end

  defp tag(rows, kind), do: Enum.map(rows, &Map.merge(&1, %{kind: kind, at: sec(&1.at)}))

  # The cards themselves, stand-ins left out (the work is the card they
  # stand in for).
  defp cards([]), do: %{}

  defp cards(ids) do
    Repo.all(from c in Card, where: c.id in ^ids and is_nil(c.stand_in_for_id))
    |> Map.new(&{&1.id, &1})
  end

  # Each card's sub-board, if it is an epic: how many subcards it has, how
  # many are done, and how many are on this ledger.
  defp epics([], _on_ledger), do: %{}

  defp epics(card_ids, on_ledger) do
    on_ledger = MapSet.new(on_ledger)

    Repo.all(
      from b in Board,
        join: c in Card,
        on: c.board_id == b.id,
        where:
          b.parent_card_id in ^card_ids and is_nil(b.archived_at) and is_nil(c.archived_at) and
            is_nil(c.stand_in_for_id),
        select: {b.parent_card_id, c.id, c.completed}
    )
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {epic_id, subs} ->
      {epic_id,
       %{
         total: length(subs),
         done: Enum.count(subs, &elem(&1, 2)),
         on_ledger: Enum.count(subs, &MapSet.member?(on_ledger, elem(&1, 1)))
       }}
    end)
  end

  # The last audit's verdict on each card (`Verified` posts it as a comment).
  defp audits([]), do: %{}

  defp audits(card_ids) do
    Repo.all(
      from c in Comment,
        where:
          c.card_id in ^card_ids and
            (like(c.body, "**Audit: agrees**%") or like(c.body, "**Audit: disagrees**%")),
        order_by: [asc: c.inserted_at, asc: c.id],
        select: {c.card_id, c.body, c.inserted_at}
    )
    |> Map.new(fn {id, body, at} ->
      verdict = if String.starts_with?(body, "**Audit: agrees**"), do: "agrees", else: "disagrees"
      {id, %{verdict: verdict, at: sec(at)}}
    end)
  end

  # -- A line ----------------------------------------------------------------------

  defp line(%Card{} = card, events, epics, audits) do
    lead = LeadTime.for_card(card)

    %{
      card: %{id: card.id, title: card.title, board_id: card.board_id, profile: card.profile},
      at: List.last(events).at,
      events: events |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort_by(&order/1),
      accepted_by: acceptor(card),
      audit: audits[card.id],
      evidence: first_line(card.evidence),
      evidence_commit: card.evidence_commit,
      should_broken: should_broken(card.verify_checks),
      lead_time: %{
        seconds: lead.seconds,
        ends: lead.ends,
        phases: for({phase, s} <- lead.totals, s > 0, into: %{}, do: {phase, s})
      },
      pr: card.evidence_pr,
      merge_sha: card.merge_sha,
      deploys:
        for(
          %{kind: "deployed"} = e <- events,
          do: %{environment: e.environment, sha: e.sha, at: e.at}
        ),
      subcards: epics[card.id]
    }
  end

  defp order(kind), do: Enum.find_index(events(), &(&1 == kind))

  @doc """
  Who accepted a card, from its `verify_by`: `%{kind: "person" | "agent",
  name}`, or nil when nobody did (a board that doesn't verify).
  """
  def acceptor(%Card{verify_state: state, verify_by: by})
      when state in @accepted and is_map(by) do
    kind = if (by["kind"] || by[:kind]) |> to_string() == "agent", do: "agent", else: "person"
    %{kind: kind, name: Verified.who(by)}
  end

  def acceptor(_card), do: nil

  @doc "The `should` rules a verdict marked broken: `[%{id, note}]`."
  def should_broken(%{"rules" => rules}) when is_list(rules) do
    for %{"result" => "broken", "severity" => "should", "id" => id} = r <- rules,
        do: %{id: id, note: r["note"]}
  end

  def should_broken(_checks), do: []

  @doc "The first line of some evidence with text on it, cut to 200 characters."
  def first_line(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> nil
      line -> String.slice(line, 0, 200)
    end
  end

  def first_line(_text), do: nil

  defp by_day(items, tz) do
    items
    |> Enum.group_by(&(&1.at |> Timezones.to_local(tz) |> DateTime.to_date()))
    |> Enum.sort_by(&elem(&1, 0), {:desc, Date})
    |> Enum.map(fn {date, items} -> %{date: date, items: items} end)
  end

  defp sec(%DateTime{} = at), do: DateTime.truncate(at, :second)
  defp sec(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> sec()
end

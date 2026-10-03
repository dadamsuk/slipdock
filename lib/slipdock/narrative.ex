defmodule Slipdock.Narrative do
  @moduledoc """
  The narrative view: what happened to the cards a view selects, over a
  date range, told as a document a stakeholder can read. Filtering,
  grouping and sorting come from the view's config (through
  `Slipdock.Table.rows/3`), so a saved view of "the Q1 initiatives grouped by
  goal" turns into "what happened to the Q1 initiatives, goal by goal".

  Events come from the activity log of every board in the tree; an event on
  a subcard is told under the top-level card it sits beneath, so a roadmap
  card's story includes its delivery work. The config's `tell` list picks
  which kinds of event are told and which sections appear (see
  `Slipdock.Swimlanes.Config.tell_events/0`).
  """

  alias Slipdock.Boards
  alias Slipdock.Boards.Card
  alias Slipdock.Swimlanes.Config
  alias Slipdock.Table

  @spans [
    {"7", "Last 7 days"},
    {"14", "Last 14 days"},
    {"30", "Last 30 days"},
    {"90", "Last 90 days"}
  ]

  def spans, do: @spans

  @doc "The date range a config asks for: explicit `from`/`to`, else the last `span` days."
  def range(%Config{} = config, today) do
    span = String.to_integer(config.span || "14")
    to = parse(config.to) || today
    from = parse(config.from) || Date.add(to, -(span - 1))
    if Date.compare(from, to) == :gt, do: {to, from}, else: {from, to}
  end

  defp parse(nil), do: nil
  defp parse(""), do: nil

  defp parse(iso) do
    case Date.from_iso8601(iso) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  @doc """
  Builds the narrative. Returns a map with:

    * `:from`, `:to` – the range
    * `:groups` – from the config's `rows` axis, each with `:cards`
      (`%{card, events, changed?}`) and `:changed` / `:total` counts
    * `:summary` – counts of what happened and of the current state
    * `:board_events` – events not tied to a card shown here
    * `:milestones` – `%{passed: [...], upcoming: [...]}`
    * `:shown` / `:hidden` – filter counts, `:grouped`
  """
  def build(board, %Config{} = config, today \\ Date.utc_today()) do
    {from, to} = range(config, today)
    rows = Table.rows(board, config, today)
    rollup = Map.get(board, :rollup)
    owner = owner_map(rollup, board.id)
    board_ids = if rollup, do: Map.keys(rollup.boards), else: [board.id]

    activities = Boards.list_activities_between(board_ids, from, to)
    tell = MapSet.new(config.tell)

    # On a board without a rollup every card is its own top-level card.
    owner =
      if owner == %{},
        do: Map.new(rows.groups |> Enum.flat_map(& &1.cards), &{&1.id, &1.id}),
        else: owner

    comments =
      if MapSet.member?(tell, "comments") and MapSet.member?(tell, "comment_text"),
        do: Boards.list_comments_between(Map.keys(owner), from, to),
        else: []

    # A card's activity is attributed to the top-level card that owns it; a
    # page's to the page itself. The two are bucketed separately because a
    # page id and a card id are different numbers in the same range — keying
    # both by the bare integer would hand one item's events to the other.
    {by_card, by_page, board_events} =
      Enum.reduce(activities, {%{}, %{}, []}, fn a, {by_card, by_page, loose} ->
        cond do
          a.page_id ->
            {by_card, Map.update(by_page, a.page_id, [event(a, nil)], &[event(a, nil) | &1]),
             loose}

          top_id = a.card_id && Map.get(owner, a.card_id) ->
            {Map.update(by_card, top_id, [event(a, top_id)], &[event(a, top_id) | &1]), by_page,
             loose}

          true ->
            {by_card, by_page, [event(a, nil) | loose]}
        end
      end)

    groups =
      Enum.map(rows.groups, fn group ->
        cards =
          Enum.map(group.cards, fn card ->
            events =
              card
              |> page?()
              |> if(do: by_page, else: by_card)
              |> Map.get(card.id, [])
              |> Enum.reverse()
              |> Enum.filter(&told?(&1, tell))
              |> coalesce()
              |> with_comments(comments)

            %{card: card, events: events, changed?: events != []}
          end)

        group
        |> Map.delete(:cards)
        |> Map.merge(%{
          cards: cards,
          changed: Enum.count(cards, & &1.changed?),
          total: length(cards)
        })
      end)

    all = Enum.flat_map(groups, & &1.cards)
    events = Enum.flat_map(all, & &1.events)

    milestones = Map.get(board, :milestones) || []
    span_days = Date.diff(to, from) + 1

    %{
      from: from,
      to: to,
      today: today,
      groups: groups,
      grouped: rows.grouped,
      tell: tell,
      board_events: if(MapSet.member?(tell, "board"), do: Enum.reverse(board_events), else: []),
      milestones: %{
        passed: Enum.filter(milestones, &Slipdock.Dates.within?(&1.date, from, to)),
        upcoming:
          Enum.filter(
            milestones,
            &Slipdock.Dates.within?(&1.date, Date.add(to, 1), Date.add(to, span_days))
          )
      },
      summary: summary(all, events, today),
      shown: rows.shown,
      hidden: rows.hidden
    }
  end

  # Whether the config asks for this event: its kind must be told, and an
  # event on a subcard only when subcard events are.
  defp told?(event, tell) do
    MapSet.member?(tell, tell_key(event.kind)) and
      (event.own? or MapSet.member?(tell, "subcards"))
  end

  # The `tell` key (see Config.tell_events/0) that switches each kind of event.
  defp tell_key(:created), do: "created"
  defp tell_key(:completed), do: "completed"
  defp tell_key(:reopened), do: "completed"
  defp tell_key(:moved), do: "moved"
  defp tell_key(:due), do: "due"
  defp tell_key(:start), do: "start"
  defp tell_key(:assigned), do: "assigned"
  defp tell_key(:comment), do: "comments"
  defp tell_key(:status), do: "status"
  defp tell_key(:vote), do: "votes"
  defp tell_key(:archived), do: "archived"
  defp tell_key(:attached), do: "attachments"
  defp tell_key(:milestone), do: "milestones"
  defp tell_key(_), do: "edits"

  # Several edits of the same thing on the same day (a due date nudged three
  # times) read as one: keep the last of each run. Comments, status reports
  # and votes each say something of their own, so they all stay.
  defp coalesce(events) do
    events
    |> Enum.chunk_by(fn e ->
      if e.kind in [:comment, :status, :vote],
        do: e.id,
        else: {e.date, e.card_id, e.kind, action(e.message)}
    end)
    |> Enum.map(&List.last/1)
  end

  # The comment each "commented on" line records, found by card and time:
  # both are written in the same call, so they land within a second of each
  # other. Each comment is used once, so two quick comments stay distinct.
  defp with_comments(events, []), do: events

  defp with_comments(events, comments) do
    {events, _} =
      Enum.map_reduce(events, comments, fn
        %{kind: :comment} = event, remaining ->
          case Enum.find(remaining, &near?(&1, event)) do
            nil -> {event, remaining}
            match -> {Map.put(event, :body, match.body), List.delete(remaining, match)}
          end

        event, remaining ->
          {event, remaining}
      end)

    events
  end

  defp near?(comment, event),
    do:
      comment.card_id == event.card_id and abs(DateTime.diff(comment.inserted_at, event.at)) <= 2

  # The part of a message before its value: "set due date on “X”".
  defp action(message) do
    message
    |> String.split(" to ", parts: 2)
    |> hd()
  end

  # Every card in the tree mapped to the top-level card on `board_id` it
  # sits beneath (a card on the board maps to itself).
  defp owner_map(nil, _board_id), do: %{}

  defp owner_map(rollup, board_id) do
    parent_of_board = Map.new(rollup.sub_board, fn {card_id, sub_id} -> {sub_id, card_id} end)

    Map.new(rollup.cards, fn {id, card} ->
      {id, climb(card, board_id, rollup.cards, parent_of_board)}
    end)
    |> Enum.reject(fn {_, top} -> is_nil(top) end)
    |> Map.new()
  end

  defp climb(%{board_id: bid, id: id}, board_id, _cards, _parents) when bid == board_id, do: id

  defp climb(%{board_id: bid}, board_id, cards, parents) do
    case Map.get(parents, bid) do
      nil -> nil
      parent_id -> if parent = cards[parent_id], do: climb(parent, board_id, cards, parents)
    end
  end

  defp page?(%Slipdock.Wiki.Page{}), do: true
  defp page?(_), do: false

  defp event(activity, top_id) do
    %{
      id: activity.id,
      at: activity.inserted_at,
      date: DateTime.to_date(activity.inserted_at),
      kind: classify(activity),
      message: activity.message,
      card_id: activity.card_id,
      own?: activity.card_id == top_id
    }
  end

  # What an activity line means, from its kind and how the message starts.
  def classify(%{kind: "comment"}), do: :comment
  def classify(%{kind: "status"}), do: :status
  def classify(%{kind: "vote"}), do: :vote
  def classify(%{kind: "milestone"}), do: :milestone

  def classify(%{message: m}) do
    cond do
      String.starts_with?(m, "added “") ->
        :created

      String.starts_with?(m, "completed") ->
        :completed

      String.starts_with?(m, "reopened") ->
        :reopened

      String.starts_with?(m, "moved") ->
        :moved

      String.starts_with?(m, ["set due date", "cleared due"]) ->
        :due

      String.starts_with?(m, ["set start date", "cleared start"]) ->
        :start

      String.starts_with?(m, ["archived", "restored"]) ->
        :archived

      String.starts_with?(m, "attached") ->
        :attached

      String.starts_with?(m, "assigned") or String.starts_with?(m, "unassigned") ->
        :assigned

      true ->
        :edited
    end
  end

  defp summary(cards, events, today) do
    count = fn kind -> Enum.count(events, &(&1.kind == kind)) end
    plain = Enum.map(cards, & &1.card)

    %{
      cards: length(cards),
      changed: Enum.count(cards, & &1.changed?),
      events: length(events),
      created: count.(:created),
      completed: count.(:completed),
      reopened: count.(:reopened),
      moved: count.(:moved),
      scheduled: count.(:due) + count.(:start),
      comments: count.(:comment),
      status_updates: count.(:status),
      votes: count.(:vote),
      done_now: Enum.count(plain, & &1.completed),
      overdue_now:
        Enum.count(plain, fn c ->
          not c.completed and
            case Card.effective_due(c) do
              %Date{} = d -> Date.compare(d, today) == :lt
              _ -> false
            end
        end),
      blocked_now: Enum.count(plain, &(Card.health(&1) == :blocked)),
      at_risk_now:
        Enum.count(
          plain,
          &(Card.health(&1) == :late or Card.stated_health(&1) in ~w(at_risk off_track))
        )
    }
  end
end

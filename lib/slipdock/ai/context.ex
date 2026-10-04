defmodule Slipdock.AI.Context do
  @moduledoc """
  What the model is told about the page: boards, cards and narratives
  rendered as compact plain text. Every card carries its id (`#12`) so an
  edit proposal can point back at it (see `Slipdock.AI.Actions`).

  `build/1` takes a source map describing the page:

    * `%{kind: :board, board: board, cards: cards, mode: mode, card: card}` –
      a board page in any mode, listing the cards the view shows and, when a
      card is open, that card in full
    * `%{kind: :card, board: board, card: card}` – one card in full
    * `%{kind: :work, sections: sections, user: user}` – the "My work" page
    * `%{kind: :narrative, board: board, narrative: narrative, config: config}` –
      the narrative view (also used by `Slipdock.AI.Narrator`)
  """

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Card, CardLink, Column}
  alias Slipdock.Fields

  @max_cards 200
  @description_cap 400
  @full_description_cap 6000

  @doc "Renders a source map (see the moduledoc) as text for the model."
  def build(%{kind: :board} = source) do
    board = source.board
    cards = source.cards || []
    open = source[:card]

    [
      "# Board: #{board.name}",
      board.description && "Description: #{board.description}",
      "View: #{mode_label(source[:mode])}. Today is #{today_line(source)}.",
      board_facts(board, source[:users]),
      "",
      "## Cards in this view (#{length(cards)})",
      cards_text(cards, board),
      "",
      pages_section(source[:pages]),
      open && "",
      open && "## The open card, in full",
      open && card_text(open, board)
    ]
    |> lines()
  end

  def build(%{kind: :card} = source) do
    board = source.board

    [
      "# Board: #{board.name}",
      "Today is #{today_line(source)}.",
      board_facts(board, source[:users], milestones: false),
      "",
      "## The card",
      card_text(source.card, board)
    ]
    |> lines()
  end

  def build(%{kind: :work} = source) do
    user = source[:user]

    [
      "# My work: every card assigned to #{(user && User.display_name(user)) || "me"}, across all boards",
      "Today is #{today_line(source)}.",
      "",
      Enum.map(source.sections || [], fn section ->
        [
          "## #{section.label} (#{length(section.items)})",
          Enum.map(section.items, fn %{card: card, path: path} ->
            card_line(card, nil) <> " — on: #{Enum.join(path, " › ")} / #{card.column.name}"
          end),
          ""
        ]
      end)
    ]
    |> lines()
  end

  def build(%{kind: :narrative} = source), do: narrative_text(source)

  @doc "The narrative view as text: the range, the summary, then every group, card and event."
  def narrative_text(%{board: board, narrative: n} = source) do
    s = n.summary
    tell = n.tell

    [
      "# #{board.name}#{if source[:view_name], do: " · #{source.view_name}"}",
      board.description && "Board description: #{board.description}",
      "Period: #{fmt(n.from)} to #{fmt(n.to)} (today is #{fmt(n.today)}).",
      "Summary: #{s.changed} of #{s.cards} cards changed; #{s.events} events" <>
        " (#{s.created} added, #{s.completed} completed, #{s.reopened} reopened, #{s.moved} moved, " <>
        "#{s.scheduled} rescheduled, #{s.comments} comments, #{s.status_updates} status updates, #{s.votes} votes).",
      "Right now: #{s.done_now} done, #{s.overdue_now} overdue, #{s.blocked_now} blocked, #{s.at_risk_now} at risk.",
      milestones_text(n.milestones),
      "",
      Enum.map(n.groups, fn group ->
        changed = Enum.filter(group.cards, & &1.changed?)
        unchanged = Enum.reject(group.cards, & &1.changed?)

        [
          if(n.grouped,
            do: "## #{group.label} (#{group.changed} of #{group.total} changed)",
            else: "## Cards"
          ),
          Enum.map(changed, fn entry ->
            [
              "### " <> card_line(entry.card, board),
              entry.card.description &&
                "Description: #{trim(entry.card.description, @description_cap)}",
              Enum.map(entry.events, fn e ->
                "- #{fmt(e.date)}: #{if e.own?, do: "", else: "(subcard) "}#{e.message}" <>
                  if(e[:body], do: " — “#{trim(e.body, 600)}”", else: "")
              end)
            ]
          end),
          if(unchanged != [] and MapSet.member?(tell, "unchanged"),
            do: "Unchanged: " <> Enum.map_join(unchanged, "; ", &card_line(&1.card, board))
          ),
          ""
        ]
      end),
      if(n.board_events != [],
        do: ["## Board changes", Enum.map(n.board_events, &"- #{fmt(&1.date)}: #{&1.message}")]
      )
    ]
    |> lines()
  end

  ## Cards -------------------------------------------------------------------

  @doc "One line per card, capped so a huge board doesn't swamp the prompt."
  def cards_text([], _board), do: "(none)"

  def cards_text(cards, board) do
    shown = Enum.take(cards, @max_cards)
    rest = length(cards) - length(shown)

    [
      Enum.map(shown, fn card ->
        line = "- " <> card_line(card, board)

        if length(cards) <= 60 and is_binary(card.description) and card.description != "",
          do: line <> "\n  description: #{trim(card.description, @description_cap)}",
          else: line
      end),
      rest > 0 && "- … and #{rest} more cards not listed"
    ]
    |> lines()
  end

  # The board's wiki. Listed separately and labelled plainly, because a page
  # is not a card and a request about "the wiki pages" must not be answered
  # by rummaging through card titles for the word.
  defp pages_section(nil), do: nil

  defp pages_section(pages) when is_list(pages) do
    [
      "## Wiki pages on this board (#{length(pages)})",
      "These are documents, not cards. They have their own codes (W-31) and are never referred to by a card id.",
      if(pages == [], do: "(none)", else: Enum.map(pages, &("- " <> page_line(&1))))
    ]
  end

  defp page_line(page) do
    facets =
      [
        page.summary && "summary: #{trim(page.summary, 160)}",
        page.status == "draft" && "draft",
        page.template && "template",
        page.column_id && "on the board",
        page.priority not in [nil, "none"] && "priority: #{page.priority}",
        page.due_date && "due #{page.due_date}",
        page.completed && "done"
      ]
      |> Enum.filter(&is_binary/1)

    "#{page.code} “#{page.title}”" <>
      if(facets == [], do: "", else: " — " <> Enum.join(facets, ", "))
  end

  @doc "A card in one line: id, title and its facets."
  def card_line(%Card{} = card, board) do
    column = column_of(card, board)
    progress = Card.progress(card)
    checklist = if is_list(card.checklist_items), do: card.checklist_items, else: []
    blockers = Card.open_blockers(card)

    facets =
      [
        column && "list: #{column.name}",
        card.completed && "DONE",
        card.priority != "none" && "priority: #{card.priority}",
        Card.assignees(card) != [] &&
          "assignee: #{Enum.map_join(Card.assignees(card), ", ", &User.display_name/1)}",
        card.start_date && "start: #{card.start_date}",
        card.due_date && "due: #{card.due_date}",
        Card.due_derived?(card) && Card.effective_due(card) &&
          "due (from subcards): #{Card.effective_due(card)}",
        Card.fuzzy?(card) && "precision: #{card.date_precision}",
        (is_list(card.tags) and card.tags != []) &&
          "tags: #{Enum.map_join(card.tags, ", ", & &1.name)}",
        card.flags != [] && "flags: #{Enum.join(card.flags, ", ")}",
        progress && "subcards: #{elem(progress, 0)}/#{elem(progress, 1)} done",
        checklist != [] && "checklist: #{Enum.count(checklist, & &1.done)}/#{length(checklist)}",
        not Enum.member?([nil, :ok, :done], Card.health(card)) && "health: #{Card.health(card)}",
        Card.stated_health(card) && "reported: #{Card.stated_health(card)}",
        blockers != [] && "blocked by: #{Enum.map_join(blockers, ", ", &"##{&1.id} #{&1.title}")}",
        Card.vote_total(card) > 0 && "votes: #{Card.vote_total(card)}"
      ]
      |> Enum.filter(&is_binary/1)

    "##{card.id} “#{card.title}”" <>
      if(facets == [], do: "", else: " (" <> Enum.join(facets, "; ") <> ")")
  end

  @doc "A card in full: every field, the description, checklist, comments, updates and relations."
  def card_text(%Card{} = card, board) do
    column = column_of(card, board)
    checklist = if is_list(card.checklist_items), do: card.checklist_items, else: []
    comments = if is_list(card.comments), do: card.comments, else: []
    updates = if is_list(card.status_updates), do: card.status_updates, else: []
    attachments = if is_list(card.attachments), do: card.attachments, else: []
    fields = if is_list(Map.get(board, :fields)), do: board.fields, else: []

    [
      "Card ##{card.id}: “#{card.title}”",
      column && "List: #{column.name}#{if Column.done?(column), do: " (a done list)"}",
      "Status: #{if card.completed, do: "done", else: "open"}",
      "Priority: #{card.priority}",
      "Assignee: #{case Card.assignees(card) do
        [] -> "unassigned"
        people -> Enum.map_join(people, ", ", &User.display_name/1)
      end}",
      "Start date: #{card.start_date || "none"}",
      "Due date: #{card.due_date || "none"}" <>
        if(Card.due_derived?(card),
          do: " (subcards run to #{Card.effective_due(card)})",
          else: ""
        ),
      Card.fuzzy?(card) && "Date precision: #{card.date_precision}",
      "Tags: #{if is_list(card.tags) and card.tags != [], do: Enum.map_join(card.tags, ", ", & &1.name), else: "none"}",
      "Flags: #{if card.flags == [], do: "none", else: Enum.join(card.flags, ", ")}",
      Card.health(card) not in [nil, :ok] && "Rolled-up health: #{Card.health(card)}",
      Card.stated_health(card) && "Reported health: #{Card.stated_health(card)}",
      Card.vote_total(card) > 0 && "Votes: #{Card.vote_total(card)}",
      "Created: #{fmt_at(card.inserted_at)}; last updated: #{fmt_at(card.updated_at)}",
      fields_text(card, fields),
      "",
      "Description:",
      if(is_binary(card.description) and String.trim(card.description) != "",
        do: trim(card.description, @full_description_cap),
        else: "(none)"
      ),
      checklist != [] && "",
      checklist != [] && "Checklist:",
      Enum.map(checklist, &"- [#{if &1.done, do: "x", else: " "}] #{&1.text}"),
      relations_text(card),
      subcards_text(card),
      updates != [] && "",
      updates != [] && "Status updates (latest first):",
      Enum.map(Enum.take(updates, 5), fn u ->
        "- #{fmt_at(u.inserted_at)} #{u.health}" <>
          if(is_binary(u.body) and u.body != "", do: ": #{trim(u.body, 500)}", else: "")
      end),
      comments != [] && "",
      comments != [] && "Comments (latest first):",
      Enum.map(Enum.take(comments, 15), &"- #{fmt_at(&1.inserted_at)}: #{trim(&1.body, 800)}"),
      attachments != [] && "Attachments: #{Enum.map_join(attachments, ", ", & &1.filename)}"
    ]
    |> lines()
  end

  defp fields_text(_card, []), do: nil

  defp fields_text(card, fields) do
    values =
      for field <- fields,
          text = Fields.format(field, Fields.value(card, field)),
          is_binary(text) and text != "",
          do: "#{field.name}: #{text}"

    if values == [], do: nil, else: "Fields: " <> Enum.join(values, "; ")
  end

  defp relations_text(card) do
    blocked_by = if is_list(card.blocked_by), do: card.blocked_by, else: []
    blocks = if is_list(card.blocks), do: card.blocks, else: []
    out = if is_list(card.links_out), do: card.links_out, else: []
    inn = if is_list(card.links_in), do: card.links_in, else: []

    [
      blocked_by != [] &&
        "Blocked by: " <>
          Enum.map_join(
            blocked_by,
            ", ",
            &"##{&1.id} #{&1.title}#{if &1.completed, do: " (done)"}"
          ),
      blocks != [] && "Blocks: " <> Enum.map_join(blocks, ", ", &"##{&1.id} #{&1.title}"),
      Enum.map(out, fn l ->
        match?(%Card{}, l.to) && "#{CardLink.label(l.kind, :out)}: ##{l.to.id} #{l.to.title}"
      end),
      Enum.map(inn, fn l ->
        match?(%Card{}, l.from) && "#{CardLink.label(l.kind, :in)}: ##{l.from.id} #{l.from.title}"
      end)
    ]
  end

  defp subcards_text(%Card{sub_board: %{cards: cards} = sub}) when is_list(cards) do
    active = Enum.reject(cards, &(not is_nil(&1.archived_at)))

    [
      "",
      "Subcards (on the sub-board “#{sub.name}”, #{length(active)}):",
      Enum.map(active, &("- " <> card_line(&1, sub)))
    ]
  end

  defp subcards_text(_), do: nil

  ## Board facts -------------------------------------------------------------

  @doc """
  A board's furniture as lines: its lists, the tags and people available, and
  its milestones. Shared with `Slipdock.AI.Researcher`, whose `read_board` tool
  answers from the same description the board assistant is given.

  Pass `milestones: false` to leave the milestones out.
  """
  def board_facts(board, users \\ nil, opts \\ []) do
    [
      columns_line(board),
      tags_line(board),
      people_line(users),
      Keyword.get(opts, :milestones, true) && milestones_line(board)
    ]
  end

  defp columns_line(board) do
    "Lists (columns), in order: " <>
      Enum.map_join(board.columns, ", ", fn c ->
        "“#{c.name}”" <>
          cond do
            Column.done?(c) -> " (done list: cards moved here are completed)"
            Column.dropped?(c) -> " (dropped list)"
            true -> ""
          end
      end)
  end

  defp tags_line(%{tags: tags}) when is_list(tags) and tags != [],
    do: "Tags available: " <> Enum.map_join(tags, ", ", &"“#{&1.name}”")

  defp tags_line(_), do: "Tags available: none yet"

  defp people_line(users) when is_list(users) and users != [],
    do: "People who can be assigned: " <> Enum.map_join(users, ", ", &user_ref/1)

  defp people_line(_), do: nil

  defp user_ref(%User{name: name, email: email}) when is_binary(name) and name != "",
    do: "#{name} <#{email}>"

  defp user_ref(%User{email: email}), do: email

  defp milestones_line(%{milestones: ms}) when is_list(ms) and ms != [],
    do: "Milestones: " <> Enum.map_join(ms, ", ", &"#{&1.name} on #{&1.date}")

  defp milestones_line(_), do: nil

  defp milestones_text(%{passed: passed, upcoming: upcoming}) do
    [
      passed != [] &&
        "Milestones passed: " <> Enum.map_join(passed, ", ", &"#{&1.name} (#{fmt(&1.date)})"),
      upcoming != [] &&
        "Milestones coming up: " <> Enum.map_join(upcoming, ", ", &"#{&1.name} (#{fmt(&1.date)})")
    ]
  end

  defp column_of(%Card{column: %Column{} = column}, _board), do: column

  defp column_of(%Card{column_id: id}, %{columns: columns}) when is_list(columns),
    do: Enum.find(columns, &(&1.id == id))

  defp column_of(_, _), do: nil

  defp mode_label(nil), do: "board"
  defp mode_label(mode), do: to_string(mode)

  defp today_line(source) do
    today = source[:today] || Date.utc_today()
    "#{Calendar.strftime(today, "%A")} #{fmt(today)} (#{today})"
  end

  ## Text helpers ------------------------------------------------------------

  # Flattens nested lists, drops nil/false, joins with newlines.
  defp lines(items) do
    items
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp trim(nil, _), do: ""

  defp trim(text, max) do
    text = String.trim(text)
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp fmt(%Date{} = d), do: Slipdock.Dates.medium(d)
  defp fmt(_), do: ""
  defp fmt_at(%DateTime{} = dt), do: Slipdock.Dates.medium(dt)
  defp fmt_at(_), do: ""
end

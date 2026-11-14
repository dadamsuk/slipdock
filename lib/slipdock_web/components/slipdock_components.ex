defmodule SlipdockWeb.SlipdockComponents do
  @moduledoc """
  Presentational components for boards, columns and cards.

  The components and helpers are defined in the modules under
  `SlipdockWeb.SlipdockComponents`, grouped by what they draw; this module
  delegates every one of them, so importing it or calling it by name reaches
  them all. `__components__/0` hands on their attribute and slot declarations,
  which is what the compiler checks a `<.component …>` call against.
  """

  alias SlipdockWeb.SlipdockComponents.CardFace
  alias SlipdockWeb.SlipdockComponents.Chrome
  alias SlipdockWeb.SlipdockComponents.Marks
  alias SlipdockWeb.SlipdockComponents.Progress
  alias SlipdockWeb.SlipdockComponents.Schedule

  @sources [Marks, Schedule, Progress, CardFace, Chrome]

  @doc false
  # The declarations of the components delegated below, private ones left out.
  def __components__ do
    @sources
    |> Enum.reduce(%{}, &Map.merge(&2, &1.__components__()))
    |> Map.filter(fn {_name, component} -> component.kind == :def end)
  end

  ## Priority, flags, tags and assignees -------------------------------------

  @doc false
  defdelegate priority_options(), to: Marks

  @doc false
  defdelegate priority_label(priority), to: Marks

  @doc "How many of the four signal bars a priority lights: 0 for none (or an unknown value), 4 for critical."
  defdelegate priority_level(priority), to: Marks

  @doc "Whether a priority is drawn where a card is shown on its own (the card face, the outline, the calendar)."
  defdelegate priority_on_face?(priority), to: Marks

  @doc "Four signal bars, rising left to right, with `level` of them lit."
  defdelegate priority_bars(assigns), to: Marks

  @doc "A priority as signal bars, with a tooltip naming it (\"Priority: High\")."
  defdelegate priority_badge(assigns), to: Marks

  @doc false
  defdelegate flags(), to: Marks

  @doc false
  defdelegate flag_label(flag), to: Marks

  @doc "A flag's icon."
  defdelegate flag_icon(assigns), to: Marks

  @doc "`{attention, why}` for a flag, or `{nil, nil}` with no card to read it from."
  defdelegate flag_attention(flag, card), to: Marks

  @doc "The words that say who clears a flag: the tooltip, the `sr-only` line, the card panel's chip."
  defdelegate flag_tip(label, attention, why), to: Marks

  @doc "A flag's chip fill: outline only for one that clears itself, filled otherwise."
  defdelegate flag_chip_class(attention), to: Marks

  @doc "A flag's icon: the solid one where a person must act, the outline one where it clears itself."
  defdelegate flag_icon_name(icon, attention), to: Marks

  @doc false
  defdelegate flag_toggle(assigns), to: Marks

  @doc false
  defdelegate tag_chip(assigns), to: Marks

  @doc "A tag as a toggle, styled like `flag_toggle/1`: a muted outlined pill with the tag's colour as a dot, filling with the tag's colour when active."
  defdelegate tag_toggle(assigns), to: Marks

  @doc false
  defdelegate color_swatch(assigns), to: Marks

  @doc "A person's initials in a circle of their own colour: `Slipdock.Palette.person/1`, a chip tint picked by their user id, so they are the same colour on a card, in the header, the share list and the comments."
  defdelegate avatar(assigns), to: Marks

  @doc "An initials avatar for the card's assignee."
  defdelegate assignee_chip(assigns), to: Marks

  @doc "Everybody a card is assigned to, as overlapping initials avatars, the lead first; past `max` the rest are counted rather than drawn."
  defdelegate assignee_chips(assigns), to: Marks

  ## Dates -------------------------------------------------------------------

  @doc false
  defdelegate due_badge(assigns), to: Schedule

  @doc "The card's schedule at a glance: its due date, or the one rolled up from its subcards when it has none, plus a warning when the subcards run past the card's own due date."
  defdelegate schedule_badges(assigns), to: Schedule

  @doc "The sentences used wherever a date overrun is shown."
  defdelegate past_date_label(which, days), to: Schedule

  @doc "The same, said in full: what runs past what, and until when."
  defdelegate past_date_detail(which, days, on), to: Schedule

  @doc "A chip per overrun: one if the subcards start late, one if they finish late, both when both."
  defdelegate slip_chips(assigns), to: Schedule

  @doc false
  defdelegate due_state(date, completed), to: Schedule

  @doc false
  defdelegate format_due(date), to: Schedule

  @doc "How long ago (or ahead) a moment is: `SlipdockWeb.Dates.relative/2`."
  defdelegate relative_time(value), to: Schedule

  @doc "A moment as people read it, in a `<time>` with the machine value in `datetime` and the exact time in `title`: \"5 min ago\" that says \"4 Nov 2026, 11:43 UTC\" on hover."
  defdelegate timestamp(assigns), to: Schedule

  @doc "A card's start and due dates as one range, \"31 Oct → 5 Nov\", for a card front that shows both."
  defdelegate date_range_badge(assigns), to: Schedule

  @doc "A start-to-due range, as in \"31 Oct → 5 Nov\", with the year on a date outside this one."
  defdelegate format_range(start, due), to: Schedule

  @doc "The icon drawn beside a start date."
  defdelegate start_icon(), to: Schedule

  @doc "The icon drawn beside a due date."
  defdelegate due_icon(), to: Schedule

  @doc "When a card starts, said in words and counted from `today`: \"Starts in 11 days\", \"Starts tomorrow\", \"Starts today\", \"Started yesterday\", \"Started 3 days ago\"."
  defdelegate start_words(card, today \\ Date.utc_today()), to: Schedule

  @doc "When the card starts: its own start date, or the one rolled up from its subcards."
  defdelegate start_badge(assigns), to: Schedule

  @doc false
  defdelegate format_day(date), to: Schedule

  ## Health, dependencies, subcards and time ---------------------------------

  @doc "A pill for a card's stated (reported) health."
  defdelegate stated_pill(assigns), to: Progress

  @doc false
  defdelegate health_label(health), to: Progress

  @doc "A pill for a card's rolled-up health."
  defdelegate health_pill(assigns), to: Progress

  @doc "Shows 'blocked by N' when open blockers remain, and how many cards this one blocks."
  defdelegate dependency_badge(assigns), to: Progress

  @doc "Progress of a card's subcards, when it has a sub-board: every leaf beneath the card when a rollup is loaded, else the direct subcards."
  defdelegate subcards_badge(assigns), to: Progress

  @doc "A card's profile: what kind of change it is, as one word."
  defdelegate profile_chip(assigns), to: Progress

  @doc "A card's stated % complete, as a chip with a small bar."
  defdelegate percent_badge(assigns), to: Progress

  @doc "Time spent against the estimate, as a chip: `1.5h/4h` with a small bar coloured by how close it is, or just the time spent without an estimate."
  defdelegate time_badge(assigns), to: Progress

  @doc "A bar of time spent against the estimate."
  defdelegate time_bar(assigns), to: Progress

  @doc "The card panel's time tracking: the unit, time spent and the estimate (each typed in the unit, or with a suffix like `90m`), the bar between them, a timer to start and stop, and a box to log a stretch of time by hand."
  defdelegate time_section(assigns), to: Progress

  ## The card's front, placed pages and stand-ins ----------------------------

  @doc "The facets to show as a MapSet; `nil` means every facet."
  defdelegate show_set(show), to: CardFace

  @doc "The edges of a card's front in their own colours: a strip on each side that has one, clipped to the card's rounded corners and drawn over it, so the card keeps its size whichever edges are coloured."
  defdelegate card_borders(assigns), to: CardFace

  @doc false
  defdelegate card(assigns), to: CardFace

  @doc "How long the card has been in its list, amber past the list's usual stay: the tile's chip, and the open card's on its meta line."
  defdelegate age_chip(assigns), to: CardFace

  @doc "💤 and the day a snoozed card wakes, the note as its tooltip."
  defdelegate snooze_mark(assigns), to: CardFace

  @doc "Whether a thing drawn on a board is a wiki page rather than a card."
  defdelegate page?(item), to: CardFace

  @doc "The id a card or a placed wiki page answers to on the board: `page-7` for a page, a bare number for a card."
  defdelegate item_id(item), to: CardFace

  @doc "The document icon on a placed page's tile: one click opens the page."
  defdelegate doc_link(assigns), to: CardFace

  @doc "The icon for a kind of thing in a list (see `Slipdock.Kinds`): a card, a document — a card whose whole content is the file clipped to it — or a wiki page placed in the list."
  defdelegate kind_icon(kind), to: CardFace

  @doc "The status a stand-in shows for the card it stands for, as `{label, class, icon}`."
  defdelegate stand_in_status(target), to: CardFace

  @doc "The same, as a word: deleted, archived, done, doing, dropped or todo."
  defdelegate stand_in_state(target), to: CardFace

  @doc "The click that opens an item: a card opens the card, a placed wiki page opens its panel, which the view turns into a query parameter so it works over every mode without a route each."
  defdelegate open_item(item), to: CardFace

  ## The modal, favourites, quick add, view switcher and filters -------------

  @doc "A label with one letter marked: the key that jumps to it."
  defdelegate keyed_label(assigns), to: Chrome

  @doc false
  defdelegate modal(assigns), to: Chrome

  @doc "The heart that puts something on `/favourites`, and takes it off again."
  defdelegate favourite_toggle(assigns), to: Chrome

  @doc "A one-line add-a-card row: type, press Enter, type the next."
  defdelegate quick_add_row(assigns), to: Chrome

  @doc "What a board view shows with nothing to draw: why, and a Clear filters button when a filter is set."
  defdelegate view_empty(assigns), to: Chrome

  @doc false
  defdelegate view_tabs_list(), to: Chrome

  @doc false
  defdelegate view_tabs(assigns), to: Chrome

  @doc "The filter dropdown the card views carry, and the wiki carries too: a wiki page answers every one of these, because it holds the card's facets under the card's names (see `Slipdock.Filters`)."
  defdelegate filter_menu(assigns), to: Chrome

  @doc "The boards a support session opens, as links: the way in to what the session grants, which no board list shows (see `Slipdock.Access.supported_boards/1`)."
  defdelegate support_board_links(assigns), to: Chrome

  @doc "How long a support session has left, as \"3h 52m\"."
  defdelegate support_time_left(expires_at, now \\ DateTime.utc_now()), to: Chrome

  @doc "A board's handles as a tooltip: its code (for the CLI and `[[links]]`), its switcher key (b, then it) and the reader's own Ctrl+Shift digit, after an optional first line (the description, say)."
  defdelegate board_handles_title(board, lead \\ nil, hotkey \\ nil), to: Chrome
end

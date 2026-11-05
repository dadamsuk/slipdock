#!/usr/bin/env bash
# End to end in a real browser: one toolbar for every view (#1711). Every
# board view's toolbar has the same order (view switcher, search, Filter, the
# view's own controls, Display, then count, Select, Views and the board's
# buttons on the right) and is one row high at 1280x800 and 1440x900. When
# the view's own controls don't fit they fold into a "View options" popover,
# and a control changed there still posts. On a phone the toolbar is one row
# plus its Options drawer.
#
#   tools/e2e/toolbar-one-row.sh        # SHOTS=<dir> keeps screenshots
#
# MEASURE_ONLY=1 prints the measurements without failing (for a before shot).
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
# A realistic board: five lists, tags, people, and thirty dated cards, so the
# toolbars carry their whole load (the count, the timeline's dates).
mix run -e '
  alias Slipdock.{Accounts, Boards}
  kb = Boards.get_board!('"$KB"')
  for n <- ["Review", "Blocked", "Done"], do: {:ok, _} = Boards.create_column(kb, %{"name" => n})
  kb = Boards.get_board!('"$KB"')
  tags =
    for {n, c} <- [{"Design", "sky"}, {"Backend", "lime"}, {"Urgent", "red"}, {"Docs", "amber"}] do
      {:ok, t} = Boards.create_tag(kb, %{"name" => n, "color" => c})
      t
    end
  today = Date.utc_today()
  for i <- 1..30 do
    col = Enum.at(kb.columns, rem(i, length(kb.columns)))
    start = Date.add(today, i * 3 - 40)
    {:ok, card} =
      Boards.create_card(col, %{
        "title" => "Task #{i}: tidy the release notes for part #{i}",
        "priority" => Enum.at(~w(critical high medium low none), rem(i, 5)),
        "start_date" => Date.to_iso8601(start),
        "due_date" => Date.to_iso8601(Date.add(start, 5 + rem(i, 9)))
      })
    {:ok, _} = Boards.set_card_tags(card, [Enum.at(tags, rem(i, 4))])
  end
  {:ok, _} = Accounts.get_or_create_user_by_email("e2e@example.com")
' > /dev/null
node tools/e2e/toolbar-one-row.mjs "$LINK" "$BASE" "$KB"

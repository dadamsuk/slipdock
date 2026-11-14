#!/usr/bin/env bash
# End to end in a real browser (#1741): the board settings form sized to
# what it holds (a 40rem column, short boxes, stacked labels, the mono
# token for code), the Tags panel's rows (dot and palette popover, rename
# in place on Enter and blur, Escape putting the name back, ⋯ Delete behind
# the confirm, New tag at the top), and the ready-made automations staying
# in their group's column at 1280 and 1440, with the brand switch.
# On a phone (#1862) the settings sheet is the screen's width, opened by
# URL or from a board with something on it wider than the phone.
#
#   PORT=4141 tools/e2e/board-settings.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves screenshots; BEFORE=1 only takes them (for the old screens).
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1
e2e_start

# Two tags and a ready-made rule on Keystone.
mix run -e '
  alias Slipdock.{Accounts, Automations, Boards}
  {:ok, u} = Accounts.get_or_create_user_by_email("e2e@example.com")
  b = Boards.get_board!('"$KB"')
  {:ok, _} = Boards.Tags.create_tag(b, %{"name" => "urgent", "color" => "rose"})
  {:ok, _} = Boards.Tags.create_tag(b, %{"name" => "later", "color" => "sky"})
  {:ok, _} = Automations.create_rule_from_preset(b, "overdue", %{}, created_by: u)
' > /dev/null

node tools/e2e/board-settings.mjs "$LINK" "$BASE" "$KB"

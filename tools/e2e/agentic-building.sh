#!/usr/bin/env bash
# End to end in a real browser (#2011): Agentic Building turned on from
# Board settings' Features tab, its board-menu item opening the page, the
# summary strip and sections, a rule ticked and saved, a sub-board's
# root-only settings read-only with a link to the root, no sideways scroll
# at phone width, and turning the switch off warning which rules still
# hold. Light and dark, 1440 and 390.
#
#   PORT=4141 SHOTS=/tmp/shots tools/e2e/agentic-building.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves screenshots.
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1
e2e_start

# Keystone verifies work with advisory lanes; an epic on it has subcards.
SUB=$(mix run -e '
  alias Slipdock.{Accounts, Boards}
  {:ok, _u} = Accounts.get_or_create_user_by_email("e2e@example.com")
  b = Boards.get_board!('"$KB"')
  {:ok, b} = Boards.update_board(b, %{"verify_work" => true, "verify_pool" => "verify", "evidence_required" => true, "lane_mode" => "advise", "profiles" => true, "ship_via" => "pull_request", "shared_paths" => "docs/manual.md"})
  {:ok, card} = Boards.create_card(hd(b.columns), %{"title" => "Epic"})
  {:ok, t} = Boards.find_template(nil, "Simple")
  {:ok, sub} = Boards.create_sub_board(card, t, code: "epice2e")
  {:ok, _} = Boards.update_board(sub, %{"agentic_building" => true})
  IO.puts("SUB #{sub.id}")
' 2>/dev/null | grep '^SUB' | cut -d' ' -f2) || true

node tools/e2e/agentic-building.mjs "$LINK" "$BASE" "$KB" "$SUB"

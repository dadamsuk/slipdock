#!/usr/bin/env bash
# End to end in a real browser (#1740): every tab bar is `<.tabs>`, with
# one look and the keyboard moves (arrows round the ends, Home, End) on
# board settings (button tabs over panels), Search/Ask (patch links) and
# a Tool's install steps (button tabs over panels).
#
#   PORT=4140 tools/e2e/tabs.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves a screenshot of each bar; BEFORE=1 only takes them (for the old ones).
source "$(dirname "$0")/lib.sh"
e2e_start

# A Tool to open: the tests' small valid package, published as its author.
mix run -e '
  Code.require_file("test/support/tool_packages.ex")
  {:ok, u} = Slipdock.Accounts.get_or_create_user_by_email("e2e@example.com")
  {:ok, _} = Slipdock.Tools.publish(u, Slipdock.ToolPackages.package("tabs-demo"))
' > /dev/null

node tools/e2e/tabs.mjs "$LINK" "$BASE" "$KB" tabs-demo

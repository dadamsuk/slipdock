#!/usr/bin/env bash
# The calmer card face (#1706), end to end in Chromium: its five scripts one
# after another, each on its own throwaway server.
#
#   tools/e2e/card-face.sh            (SHOTS=dir to keep screenshots)
#
#   card-title.sh       a 13-14px title, flush with its tags and meta (#1707)
#   card-chips.sh       the essential facets only; only attention is tinted (#1708)
#   priority-start.sh   priority as signal bars; a start said in words (#1709)
#   list-chrome.sh      quiet list headers and footers, no heart on each (#1710)
#   toolbar-one-row.sh  one toolbar order, one row at 1280 and 1440 (#1711)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
set -e
here="$(dirname "$0")"
for script in card-title card-chips priority-start list-chrome toolbar-one-row; do
  echo "== $script"
  "$here/$script.sh"
done
echo "ok: the calmer card face holds in Chromium"

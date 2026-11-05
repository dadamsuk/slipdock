#!/usr/bin/env bash
# The wiki's reading and writing polish (#1742), end to end in Chromium: its
# three scripts one after another, each on its own throwaway server.
#
#   tools/e2e/wiki-polish.sh            (SHOTS=dir to keep screenshots)
#
#   wiki-measure.sh  one reading measure; one button style in the action row (#1743)
#   wiki-editor.sh   the editor as one pane, encryption in its menu (#1744)
#   wiki-history.sh  history rows open onto their lines; readable tree names (#1745)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
set -e
here="$(dirname "$0")"
for script in wiki-measure wiki-editor wiki-history; do
  echo "== $script"
  "$here/$script.sh"
done
echo "ok: the wiki's reading and writing polish holds in Chromium"

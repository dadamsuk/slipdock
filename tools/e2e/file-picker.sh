#!/usr/bin/env bash
# End to end in a real browser (#1722): the file picker on Account → Import
# & export and on Tools. No native "Choose file / No file chosen" shows; the
# Choose file button opens the browser's chooser; the chosen file's name and
# size show with a remove ×; a wrong kind of file says what is wanted; and a
# board export goes back in.
#
#   tools/e2e/file-picker.sh            (SHOTS=<dir> saves screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1 || true
e2e_start
DIR=$(mktemp -d)
mix run -e '
  {:ok, user} = Slipdock.Accounts.get_or_create_user_by_email("e2e@example.com")
  File.write!("'"$DIR"'/boards.json", user |> Slipdock.Portable.export() |> Jason.encode!())
' > /dev/null
echo "a,b" > "$DIR/boards.csv"
node tools/e2e/file-picker.mjs "$LINK" "$BASE" "$DIR"

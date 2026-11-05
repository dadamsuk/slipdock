#!/usr/bin/env bash
# The browser checks of "Dates and fields" (#1718), one after another, each
# on its own throwaway database and server:
#
#   date-field        the date field: picker, typing, clear, fallback (#1720)
#   date-sweep        the tray and the table save through it (#1721)
#   file-picker       the file picker: chooser, name and size, refusal (#1722)
#   card-back-fields  every card-back field is one field (#1672, #1723)
#
#   tools/e2e/dates-and-fields.sh            (SHOTS=<dir> saves screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. Stops at
# the first that fails, and says which.
set -uo pipefail
cd "$(dirname "$0")/../.."
failed=()
for check in date-field date-sweep file-picker card-back-fields; do
  echo "== $check"
  if ! tools/e2e/$check.sh; then
    failed+=("$check")
    break
  fi
done
if [ ${#failed[@]} -gt 0 ]; then
  echo "FAILED: ${failed[*]}" >&2
  exit 1
fi
echo "all four passed"

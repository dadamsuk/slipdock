#!/usr/bin/env bash
# The browser checks of "Card panel: the card back reads like a document"
# (#1724), one after another, each on its own throwaway database and server:
#
#   card-header      the meta line, the toolbar, one Open board (#1725)
#   card-properties  the sidebar as label/value rows (#1726)
#   card-tags        flags and tags as chips with a picker (#1727)
#   card-sections    key letters on Alt, icons, the subcard add row (#1728)
#   card-phone       properties first on a phone (#1729)
#
#   tools/e2e/card-back.sh            (SHOTS=<dir> saves screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. Stops at
# the first that fails, and says which.
set -uo pipefail
cd "$(dirname "$0")/../.."
checks=(card-header card-properties card-tags card-sections card-phone)
for check in "${checks[@]}"; do
  echo "== $check"
  if ! tools/e2e/$check.sh; then
    echo "FAILED: $check" >&2
    exit 1
  fi
done
echo "all ${#checks[@]} passed"

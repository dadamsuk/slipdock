#!/usr/bin/env bash
# End to end in a real browser: the trust contract (#2581) on Help › Agents
# › Runners and on a machine's page, at desktop and phone widths: every
# heading and bullet of the one text shown, the lists as lists, the
# executors' names as code, and nothing wider than the screen.
#
#   tools/e2e/trust-contract.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves screenshots.
source "$(dirname "$0")/lib.sh"
e2e_start

MACHINE="$(mix run -e '
  alias Slipdock.{Accounts, Machines, Repo}
  user = Accounts.get_user_by_email("e2e@example.com")
  board = Repo.get!(Slipdock.Boards.Board, '"$KB"')
  {:ok, key, _} = Machines.create_enrolment_key(user, [board.id])
  {:ok, {_key, machine}} =
    Machines.enrol_with_key(key, %{"hostname" => "e2e-box", "os" => "linux", "arch" => "amd64"})
  IO.puts("MACHINE #{machine.id}")
' | grep '^MACHINE' | cut -d' ' -f2)"

node tools/e2e/trust-contract.mjs "$LINK" "$BASE" "$MACHINE" daemon/internal/contract/contract.md

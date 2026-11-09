#!/usr/bin/env bash
# End to end in a real browser: the Machines page (#2572). A machine is
# enrolled with a one-time key and reports its ceiling; its owner opens it
# from Account › Machines, adds a runner with a timeout over the ceiling
# (marked with the limit as it is typed) and saves it; the "daemon" (this
# script, with the machine key, over the API) refuses it; and the page shows
# the refusal with its reason and the limit, without a reload.
#
#   tools/e2e/machines-page.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves screenshots.
source "$(dirname "$0")/lib.sh"
e2e_start

read -r MACHINE MACHINE_KEY <<<"$(mix run -e '
  alias Slipdock.{Accounts, Machines, Repo}
  user = Accounts.get_user_by_email("e2e@example.com")
  board = Repo.get!(Slipdock.Boards.Board, '"$KB"')
  {:ok, key, _} = Machines.create_enrolment_key(user, [board.id])
  {:ok, {machine_key, machine}} =
    Machines.enrol_with_key(key, %{"hostname" => "e2e-box", "os" => "linux", "arch" => "amd64"})
  {:ok, _} =
    Slipdock.Runners.MachineRunners.record_ceiling(machine, %{
      "roots" => ["/srv/src"],
      "agents" => ["claude"],
      "max_permission_mode" => "acceptEdits",
      "max_timeout_minutes" => 60,
      "boards" => [board.id],
      "executors" => ["user"]
    })
  IO.puts("MACHINE #{machine.id} #{machine_key}")
' | grep '^MACHINE' | cut -d' ' -f2-)"

node tools/e2e/machines-page.mjs "$LINK" "$BASE" "$MACHINE" "$MACHINE_KEY"

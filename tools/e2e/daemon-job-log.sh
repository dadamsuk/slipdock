#!/usr/bin/env bash
# End to end on a real job through the runner daemon (#2628), as
# job-log.sh was through the shell runner (#1871) until #2582 retired it:
# slipdock-runner, built from daemon/, is enrolled with a one-time key
# against a throwaway server, given a machine runner, and takes a job that
# runs a real `claude -p`, sending its transcript as it goes (every 60 s,
# the daemon's pace). Chromium watches the card's job panel fill in without
# a reload, opens a tool call to its whole input and sees it stay open as
# more lines arrive, sees the log stop updating once the job has ended,
# says when the log will be deleted, and keeps it with Keep this log
# (#1872). Then the server's copy is checked: the job done, a tool call in
# it, and neither the machine key, the enrolment key nor any token.
#
#   tools/e2e/daemon-job-log.sh
#
# The daemon runs from a scratch directory of its own (--home): it never
# touches this machine's enrolled daemon or its service. Its jobs run as
# you (--as-me) in a scratch folder, with acceptEdits and only Bash
# allowed, and local.json's no_skills_update keeps the throwaway server's
# skills out of ~/.claude/skills.
#
# Needs Go (1.22) to build the daemon, playwright-core on NODE_PATH,
# Chromium at CHROME_PATH, and a signed-in `claude` on PATH (AGENT_BIN
# overrides). The job takes about four minutes and a few thousand tokens.
# SHOT and SHOT_KEPT name the screenshots.
source "$(dirname "$0")/lib.sh"
e2e_start

AGENT_BIN="${AGENT_BIN:-$(command -v claude)}"
SCRATCH=$(mktemp -d)
HOME_DIR="$SCRATCH/machine"
WORK="$SCRATCH/work"
mkdir -p "$WORK"

(cd daemon && go build -o "$SCRATCH/slipdock-runner" ./cmd/slipdock-runner)
DAEMON="$SCRATCH/slipdock-runner"

read -r CARD KEY <<<"$(mix run -e '
  alias Slipdock.{Accounts, Boards, Machines, Repo}
  user = Accounts.get_user_by_email("e2e@example.com")
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [todo | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, card} = Boards.create_card(todo, %{"title" => "Watch me work"})
  {:ok, key, _} = Machines.create_enrolment_key(user, [board.id])
  IO.puts("IDS #{card.id} #{key}")
' | grep '^IDS' | cut -d' ' -f2-)"

# Enrolled as the daemon is on a real machine: one-time key, the ceiling
# from the flags, jobs run as this account.
"$DAEMON" init --home "$HOME_DIR" --server "$BASE" --key "$KEY" --as-me --no-setup \
  --root "$SCRATCH" --agent claude --max-mode acceptEdits --max-timeout 15 >"$SCRATCH/init.log" 2>&1 || {
  echo "FAIL: slipdock-runner init"; cat "$SCRATCH/init.log"; exit 1
}
MACHINE=$(sed -n 's/.*"machine_id": *\([0-9]*\).*/\1/p' "$HOME_DIR/machine.json")
MACHINE_KEY=$(cat "$HOME_DIR/machine-key")

# This machine's own definitions, added to what init wrote: claude is
# AGENT_BIN with Bash allowed, and the skills are left alone.
python3 - "$HOME_DIR/local.json" "$AGENT_BIN" <<'PY'
import json, os, sys
path, agent = sys.argv[1], sys.argv[2]
local = json.load(open(path)) if os.path.exists(path) else {}
local.setdefault("agents", {})["claude"] = {"path": agent, "allowed_tools": ["Bash"]}
local["no_skills_update"] = True
json.dump(local, open(path, "w"), indent=2)
PY

JOB=$(mix run -e '
  alias Slipdock.{Boards, Machines, Repo, Runners}
  alias Slipdock.Runners.MachineRunners
  machine = Repo.get!(Slipdock.Machines.Machine, '"$MACHINE"')
  board = Boards.get_board!('"$KB"')
  card = Repo.get!(Slipdock.Boards.Card, '"$CARD"')
  {:ok, _runner} =
    MachineRunners.add_runner(machine, board, %{
      "pool" => "e2e",
      "name" => "e2e box",
      "config" => %{
        "agent" => "claude",
        "directory" => "'"$WORK"'",
        "permission_mode" => "acceptEdits",
        "timeout_minutes" => 10,
        "worktree" => "off",
        "executor" => "me"
      }
    })
  # The link the daemon looks for in the transcript: the one the server sends.
  url = "#{Slipdock.Automations.Runner.base_url()}/boards/#{board.id}/cards/#{card.id}"
  # Four slow calls: the daemon sends every 60 s, and the browser waits to
  # see the log grow twice while the job is still running.
  prompt = """
  This is a test of a job log for #{url}. Use the Bash tool five times, one call at a time:
  `sleep 45 && echo first`, then `sleep 45 && echo second`, then `sleep 45 && echo third`,
  then `sleep 45 && echo fourth`, then `ls -la`. A call may have to run in the background:
  wait for each to finish before the next. Then reply with the word finished.
  """
  {:ok, job} = Runners.queue(card, %{pool: "e2e", kind: "claude", prompt: prompt})
  IO.puts("JOB #{job.id}")
' | grep '^JOB' | cut -d' ' -f2)

"$DAEMON" run --home "$HOME_DIR" --log "$SCRATCH/daemon.log" >"$SCRATCH/daemon.out" 2>&1 &
RUNNER=$!
# The server and its database go in lib.sh's trap; the daemon first.
trap 'kill $RUNNER 2>/dev/null || true; kill $E2E_SERVER 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

node tools/e2e/daemon-job-log.mjs "$LINK" "$BASE" "$KB" "$CARD" "$JOB" || {
  echo "--- daemon"; tail -n 30 "$SCRATCH/daemon.log" "$SCRATCH/daemon.out"
  echo "--- job"; tail -n 20 "$HOME_DIR/jobs/"*/job.log 2>/dev/null
  grep -E "\(error\)|\*\* \(" "$LOG" | tail -20
  exit 1
}
kill $RUNNER 2>/dev/null || true
wait $RUNNER 2>/dev/null || true

mix run -e '
  alias Slipdock.Runners.{Transcript, TranscriptView}
  job = Slipdock.Runners.get_job('"$JOB"')
  raw = Transcript.read(job)
  entries = TranscriptView.entries(raw)
  unless job.status == "done", do: raise("the job ended #{job.status}")
  unless job.runner_id && Slipdock.Repo.get!(Slipdock.Runners.Runner, job.runner_id).machine_id == '"$MACHINE"',
    do: raise("the job was not run by the machine runner")
  unless Enum.any?(entries, &(&1.kind == :tool and &1.text =~ "sleep 45")), do: raise("no tool call in the log")
  if String.contains?(raw, "'"$MACHINE_KEY"'"), do: raise("the machine key is in the log")
  if String.contains?(raw, "'"$KEY"'"), do: raise("the enrolment key is in the log")
  if raw =~ ~r/\bsd[a-z]_[A-Za-z0-9_-]{16,}/, do: raise("a Slipdock token is in the log")
  page = job.transcript_page_id && Slipdock.Wiki.get_page(job.transcript_page_id)
  unless page && page.body =~ "Pass on #", do: raise("the kept page is missing or not a pass log")
  unless is_nil(Slipdock.Runners.TranscriptRetention.expires_at(job)), do: raise("a kept log still expires")
  IO.puts("ok: the server holds #{job.transcript_lines} lines, #{length(entries)} entries, no machine key or token; kept as #{page.code}")
'

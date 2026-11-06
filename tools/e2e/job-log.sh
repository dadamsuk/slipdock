#!/usr/bin/env bash
# End to end on a real job (#1871): the real runner script takes a job from
# a throwaway server and runs a real `claude -p` on it, sending its
# transcript every few seconds; Chromium watches the card's job panel fill
# in without a reload, opens a tool call to its whole input, and sees the
# log stop updating once the job has ended, then says when the log will be
# deleted and keeps it with Keep this log (#1872).
#
#   tools/e2e/job-log.sh
#   MACHINE_HOOKS=1 tools/e2e/job-log.sh
#
# MACHINE_HOOKS=1 (#1873) runs the job through this machine's own hooks and
# hook settings, read from its runner config (RUNNER_CONFIG, by default
# ~/.config/slipdock-runner/config): the job must end with no Pass page
# written, and Keep this log must still keep it. It refuses to run while that
# config turns the pass log on, which would write to that runner's own server.
#
# Needs playwright-core on NODE_PATH, Chromium at CHROME_PATH, and a signed-in
# `claude` on PATH (AGENT_BIN overrides). The job costs a few thousand tokens.
source "$(dirname "$0")/lib.sh"
e2e_start

AGENT_BIN="${AGENT_BIN:-$(command -v claude)}"
SCRATCH=$(mktemp -d)

IDS=$(mix run -e '
  alias Slipdock.{Boards, Repo, Runners}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [todo | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, card} = Boards.create_card(todo, %{"title" => "Watch me work"})
  {:ok, _runner, token} = Runners.create_runner(board, %{"name" => "e2e box", "pool" => "e2e"})
  # The link the runner looks for in the transcript: the one the server sends.
  url = "#{Slipdock.Automations.Runner.base_url()}/boards/#{board.id}/cards/#{card.id}"
  prompt = """
  This is a test of a job log for #{url}. Use the Bash tool three times, one call at a time:
  `sleep 6 && echo first`, then `sleep 6 && echo second`, then `ls -la`. Then reply with the word finished.
  """
  {:ok, job} = Runners.queue(card, %{pool: "e2e", kind: "claude", prompt: prompt})
  IO.puts("IDS #{card.id} #{job.id} #{token}")
' | grep '^IDS' | cut -d' ' -f2-)
read -r CARD JOB TOKEN <<<"$IDS"

HOOKS_PART=""
if [ "${MACHINE_HOOKS:-}" = 1 ]; then
  RUNNER_CONFIG="${RUNNER_CONFIG:-$HOME/.config/slipdock-runner/config}"
  SETTINGS=$(grep -E '^(SLIPDOCK_HOOKS|SLIPDOCK_HOOK_[A-Z]+)=' "$RUNNER_CONFIG")
  if printf '%s\n' "$SETTINGS" | grep -q '^SLIPDOCK_HOOK_PASSLOG='; then
    echo "FAIL: $RUNNER_CONFIG still sets SLIPDOCK_HOOK_PASSLOG (a page per pass)" >&2
    exit 1
  fi
  # This machine's settings, its own log aside, and its installed hooks.
  HOOKS_PART="$SETTINGS
SLIPDOCK_HOOK_LOG='$SCRATCH/hook.log'
export SLIPDOCK_HOOK_LOG SLIPDOCK_HOOK_TRANSCRIPTS SLIPDOCK_HOOK_NOTIFY
unset SLIPDOCK_HOOK_PASSLOG
before_job() { \"\$SLIPDOCK_HOOKS/after-job-hook.sh\" before; }
after_job() { \"\$SLIPDOCK_HOOKS/after-job-hook.sh\" after; }"
fi

cat >"$SCRATCH/config" <<CONFIG
SLIPDOCK_URL='$BASE'
SLIPDOCK_RUNNER_TOKEN='$TOKEN'
POOL=e2e
WAIT=5
HEARTBEAT=5
TRANSCRIPT_EVERY=4
job_claude() {
  cd '$SCRATCH' || exit 1
  '$AGENT_BIN' -p "\$SLIPDOCK_PROMPT" --permission-mode bypassPermissions --allowedTools 'Bash'
}
$HOOKS_PART
CONFIG

priv/runner/slipdock-runner --once --config="$SCRATCH/config" >"$SCRATCH/runner.log" 2>&1 &
RUNNER=$!

node tools/e2e/job-log.mjs "$LINK" "$BASE" "$KB" "$CARD" "$JOB" || {
  echo "--- runner"; tail -20 "$SCRATCH/runner.log"
  grep -E "\(error\)|\*\* \(" "$LOG" | tail -20
  kill $RUNNER 2>/dev/null; exit 1
}
wait $RUNNER || true
if [ "${MACHINE_HOOKS:-}" = 1 ]; then
  grep -q "finished (done, exit 0)" "$SCRATCH/hook.log" || { echo "FAIL: this machine's hook never ran"; cat "$SCRATCH/hook.log"; exit 1; }
  echo "ok: this machine's after-job hook ran: $(grep finished "$SCRATCH/hook.log" | tail -1)"
fi

mix run -e '
  alias Slipdock.Runners.{Transcript, TranscriptView}
  job = Slipdock.Runners.get_job('"$JOB"')
  entries = job |> Transcript.read() |> TranscriptView.entries()
  unless job.status == "done", do: raise("the job ended #{job.status}")
  unless Enum.any?(entries, &(&1.kind == :tool and &1.text =~ "sleep 6")), do: raise("no tool call in the log")
  if job |> Transcript.read() |> String.contains?("'"$TOKEN"'"), do: raise("the runner token is in the log")
  page = job.transcript_page_id && Slipdock.Wiki.get_page(job.transcript_page_id)
  # The job ended with no Pass page but the one Keep this log wrote (#1873).
  import Ecto.Query
  passes = Slipdock.Repo.all(from p in Slipdock.Wiki.Page, where: like(p.title, "Pass %"), select: p.id)
  unless passes == [job.transcript_page_id], do: raise("Pass pages other than the kept one: #{inspect(passes)}")
  unless page && page.body =~ "Pass on #", do: raise("the kept page is missing or not a pass log")
  unless is_nil(Slipdock.Runners.TranscriptRetention.expires_at(job)), do: raise("a kept log still expires")
  IO.puts("ok: the server holds #{job.transcript_lines} lines, #{length(entries)} entries, no token; kept as #{page.code}")
'

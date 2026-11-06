#!/usr/bin/env bash
# End to end on a real job (#1871): the real runner script takes a job from
# a throwaway server and runs a real `claude -p` on it, sending its
# transcript every few seconds; Chromium watches the card's job panel fill
# in without a reload, opens a tool call to its whole input, and sees the
# log fold once the job has ended. Then `slipdock job --follow`'s endpoint
# reads the same lines.
#
#   tools/e2e/job-log.sh
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
CONFIG

priv/runner/slipdock-runner --once --config="$SCRATCH/config" >"$SCRATCH/runner.log" 2>&1 &
RUNNER=$!

node tools/e2e/job-log.mjs "$LINK" "$BASE" "$KB" "$CARD" "$JOB" || {
  echo "--- runner"; tail -20 "$SCRATCH/runner.log"
  grep -E "\(error\)|\*\* \(" "$LOG" | tail -20
  kill $RUNNER 2>/dev/null; exit 1
}
wait $RUNNER || true

mix run -e '
  alias Slipdock.Runners.{Transcript, TranscriptView}
  job = Slipdock.Runners.get_job('"$JOB"')
  entries = job |> Transcript.read() |> TranscriptView.entries()
  unless job.status == "done", do: raise("the job ended #{job.status}")
  unless Enum.any?(entries, &(&1.kind == :tool and &1.text =~ "sleep 6")), do: raise("no tool call in the log")
  if job |> Transcript.read() |> String.contains?("'"$TOKEN"'"), do: raise("the runner token is in the log")
  IO.puts("ok: the server holds #{job.transcript_lines} lines, #{length(entries)} entries, no token")
'

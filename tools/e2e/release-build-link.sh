#!/usr/bin/env bash
# End to end in a real browser (#3005): a running release's build is one
# click from the board's release banner. Release now on the Agentic
# Building page starts one; with the board open, a runner fires the release
# job over HTTP and names its run; the banner links the run without a
# reload, and a click opens it in a new tab. The Agentic page links it too.
#
#   tools/e2e/release-build-link.sh            (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

TOKEN=$(mix run -e '
  alias Slipdock.{Boards, Runners}
  board = Boards.get_board!('"$KB"')

  {:ok, board} =
    Boards.update_board(board, %{
      "delivery_metrics" => true,
      "agentic_building" => true,
      "release_mode" => "batched"
    })

  {:ok, runner, token} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
  Runners.report_kinds(runner, "merge,release")
  IO.puts("TOKEN #{token}")
' | grep '^TOKEN' | cut -d' ' -f2)

RUN="https://github.com/example/app/actions/runs/3005"

node tools/e2e/release-build-link.mjs "$LINK" "$BASE" "$KB" "$TOKEN" "$RUN" "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

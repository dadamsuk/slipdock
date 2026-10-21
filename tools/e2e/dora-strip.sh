#!/usr/bin/env bash
# End to end in a real browser (#1184): the board's delivery strip colours
# each DORA metric by its band (a green, blue, amber or red pill with the band
# in words), on a desktop and a phone width, in light and dark themes, without
# making the page scroll sideways.
#
#   tools/e2e/dora-strip.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

mix run -e '
  alias Slipdock.{Boards, Deployments}
  board = Boards.get_board!('"$KB"')
  {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
  now = DateTime.utc_now()
  at = fn h -> DateTime.add(now, -h * 3600, :second) end
  commit = fn h -> %{"sha" => Base.encode16(:crypto.strong_rand_bytes(5), case: :lower),
    "committed_at" => DateTime.to_iso8601(at.(h)), "subject" => "work"} end
  for {h, status} <- [{50, "succeeded"}, {40, "failed"}, {39, "succeeded"}, {30, "succeeded"}] do
    {:ok, _} = Deployments.start(board, %{environment: "production",
      sha: Base.encode16(:crypto.strong_rand_bytes(10), case: :lower), status: status,
      started_at: at.(h), finished_at: at.(h), commits: [commit.(h + 2)]})
  end
' > /dev/null

node tools/e2e/dora-strip.mjs "$LINK" "$BASE" "$KB" || { grep -E "\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

#!/usr/bin/env bash
# End to end in a real browser (#1116): the Runners panel's Pause asks for a
# reason and keeps its button disabled until there is one; pausing shows a
# banner on the board and on a sub-board, naming the root; the banner's
# Resume lets it off. A pool row pauses and resumes just that pool.
#
#   tools/e2e/pause.sh            (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

SUB=$(mix run -e '
  alias Slipdock.{Boards, Repo, Runners}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [first | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, _, _} = Runners.create_runner(board, %{"name" => "laptop", "pool" => "dev"})
  {:ok, epic} = Boards.create_card(first, %{"title" => "Epic"})
  {:ok, t} = Boards.find_template(nil, "Simple")
  {:ok, sub} = Boards.create_sub_board(epic, t)
  IO.puts("SUB #{sub.id}")
' | grep '^SUB' | cut -d' ' -f2)

node tools/e2e/pause.mjs "$LINK" "$BASE" "$KB" "$SUB" "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

mix run -e '
  board = Slipdock.Boards.get_board!('"$KB"')
  if Slipdock.Runners.pauses(board) != [], do: raise("a pause is still open")

  n = Slipdock.Repo.aggregate(Slipdock.Runners.Pause, :count)
  if n != 2, do: raise("expected 2 pauses made, got #{n}")
  IO.puts("ok: the database agrees (two pauses made, none open)")
'

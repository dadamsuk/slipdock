#!/usr/bin/env bash
# End to end in a real browser (W-1804, #1096): a card with no handoff shows
# only "Leave a handoff" on the meta line under its title; the link opens the
# form there (without following its href); the saved note sits beneath the
# title; Update brings the history; Clear puts the link back.
#
#   tools/e2e/handoff.sh            (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

CARD=$(mix run -e '
  alias Slipdock.{Boards, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [first | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, card} = Boards.create_card(first, %{"title" => "Half done", "description" => "The description."})
  IO.puts("CARD #{card.id}")
' | grep '^CARD' | cut -d' ' -f2)

node tools/e2e/handoff.mjs "$LINK" "$BASE" "$KB" "$CARD" "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

mix run -e '
  h = Slipdock.Boards.current_handoff(%Slipdock.Boards.Card{id: '"$CARD"'})
  if h != nil, do: raise("still a handoff after Clear: #{inspect(h.next_step)}")
  n = length(Slipdock.Boards.handoff_history(%Slipdock.Boards.Card{id: '"$CARD"'}))
  if n != 3, do: raise("history has #{n} rows, want 3 (two notes and a clear)")
  IO.puts("ok: the database agrees (cleared, three rows of history)")
'

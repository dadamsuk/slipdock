#!/usr/bin/env bash
# End to end in a real browser (W-1803, #1058): z on the card under the
# pointer opens Snooze…, z again is tomorrow; the list's footer reveals it
# faded; Wake now brings it back; a note typed (with a "z" in it) survives
# choosing a preset, and an in-progress card goes back to To Do; select mode
# snoozes two at once; Escape closes the picker.
#
#   tools/e2e/snooze.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

IDS=$(mix run -e '
  alias Slipdock.{Boards, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [_backlog, todo, doing | _] = Enum.sort_by(board.columns, & &1.position)
  {:ok, a} = Boards.create_card(todo, %{"title" => "Chase the quote"})
  {:ok, b} = Boards.create_card(todo, %{"title" => "Renew the domain"})
  {:ok, c} = Boards.create_card(doing, %{"title" => "Busy one"})
  {:ok, d} = Boards.create_card(todo, %{"title" => "Pair one"})
  {:ok, e} = Boards.create_card(todo, %{"title" => "Pair two"})
  IO.puts("IDS #{todo.id} #{a.id} #{b.id} #{c.id} #{d.id} #{e.id}")
' | grep '^IDS' | cut -d' ' -f2-)

node tools/e2e/snooze.mjs "$LINK" "$BASE" "$KB" $IDS || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

read -r TODO A B C D E <<<"$IDS"
mix run -e '
  alias Slipdock.Boards.Card
  alias Slipdock.Repo
  get = &Repo.get!(Card, &1)
  c = get.('"$C"')
  unless Card.snoozed?(c) and c.column_id == '"$TODO"' and c.snooze_note == "zzz later",
    do: raise("the in-progress card: #{inspect(Map.take(c, [:snoozed_until, :column_id, :snooze_note]))}")
  unless Card.snoozed?(get.('"$D"')) and Card.snoozed?(get.('"$E"')), do: raise("select mode missed one")
  if Card.snoozed?(get.('"$A"')), do: raise("the woken card is still asleep")
  if Card.snoozed?(get.('"$B"')), do: raise("Escape snoozed a card")
  IO.puts("ok: the database agrees")
'

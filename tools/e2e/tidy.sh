#!/usr/bin/env bash
# End to end in a real browser (W-1807, #1084): Tidy up… in the board menu;
# Look the board over finds a completed card outside Done and a stuck one;
# Apply moves the first, then Snooze (an alternative) snoozes the second and
# the first stays applied; Undo puts the first back.
#
#   tools/e2e/tidy.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

IDS=$(mix run -e '
  import Ecto.Query
  alias Slipdock.{Boards, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  doing = Enum.find(board.columns, &(&1.category == "doing"))
  {:ok, a} = Boards.create_card(doing, %{"title" => "Finished thing", "completed" => true})
  {:ok, b} = Boards.create_card(doing, %{"title" => "Stuck thing"})
  old = DateTime.add(DateTime.utc_now(:second), -30 * 86_400)
  Repo.update_all(from(c in Boards.Card, where: c.id == ^b.id), set: [updated_at: old])
  Repo.update_all(from(x in Boards.Activity, where: x.card_id == ^b.id), set: [inserted_at: old])
  IO.puts("IDS #{doing.id} #{a.id} #{b.id}")
' | grep '^IDS' | cut -d' ' -f2-)

node tools/e2e/tidy.mjs "$LINK" "$BASE" "$KB" $IDS || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

read -r DOING A B <<<"$IDS"
mix run -e '
  alias Slipdock.Boards.Card
  alias Slipdock.Repo
  a = Repo.get!(Card, '"$A"')
  b = Repo.get!(Card, '"$B"')
  unless a.column_id == '"$DOING"', do: raise("undo left the finished card in #{a.column_id}")
  unless Card.snoozed?(b), do: raise("the stuck card is not snoozed")
  IO.puts("ok: the database agrees")
'

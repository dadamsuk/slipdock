#!/usr/bin/env bash
# End to end in a real browser (#1118): two waits on the signed-in person
# put a 2 in the header on every page; My work opens with them; clicking a
# choice answers one with that choice (a real button sends what it sends,
# not what LiveViewTest reads), an answer in words answers the other, and
# the section and the header number go.
#
#   tools/e2e/my-work-waiting.sh            (SHOTS=dir to keep screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

CARDS=$(mix run -e '
  alias Slipdock.{Actor, Boards, Repo}
  board = Boards.get_board!('"$KB"') |> Repo.preload(:columns)
  [first | _] = Enum.sort_by(board.columns, & &1.position)
  user = Slipdock.Accounts.get_user_by_email("e2e@example.com")
  agent = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: user.id, agent: "claude"}

  ids =
    for {title, attrs} <- [
          {"Pick a region", %{"needs" => "Which region?", "choices" => ["eu", "us"]}},
          {"Size it", %{"needs" => "How big?"}}
        ] do
      {:ok, card} = Boards.create_card(first, %{"title" => title})
      {:ok, _} = Boards.open_wait(card, agent, Map.put(attrs, "on_user_id", user.id))
      card.id
    end

  IO.puts("CARDS " <> Enum.join(ids, " "))
' | grep '^CARDS' | cut -d' ' -f2-)
read -r CHOICE WORDS <<<"$CARDS"

node tools/e2e/my-work-waiting.mjs "$LINK" "$BASE" "$KB" "$CHOICE" "$WORDS" "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

mix run -e '
  alias Slipdock.Boards
  card = &%Boards.Card{id: &1}
  a = Boards.last_wait(card.('"$CHOICE"'))
  b = Boards.last_wait(card.('"$WORDS"'))
  if {a.close_reason, a.choice} != {"answered", 2}, do: raise("choice: #{inspect({a.close_reason, a.choice})}")
  if {b.close_reason, b.answer} != {"answered", "Large"}, do: raise("words: #{inspect({b.close_reason, b.answer})}")
  IO.puts("ok: the database agrees (choice 2, \"Large\")")
'

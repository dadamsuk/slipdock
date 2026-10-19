#!/usr/bin/env bash
# End to end in a real browser (#1114): a card waiting on a person shows
# the question beneath its title; clicking a choice answers it with that
# choice (a real button sends what it sends, not what LiveViewTest reads);
# an answer in words answers another; and turning the waiting flag off
# withdraws a third. The tile shows the question until it is answered.
#
#   tools/e2e/wait.sh            (SHOTS=dir to keep screenshots)
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
          {"Size it", %{"needs" => "How big?"}},
          {"Name it", %{"needs" => "What name?"}}
        ] do
      {:ok, card} = Boards.create_card(first, %{"title" => title})
      {:ok, _} = Boards.open_wait(card, agent, attrs)
      card.id
    end

  IO.puts("CARDS " <> Enum.join(ids, " "))
' | grep '^CARDS' | cut -d' ' -f2-)
read -r CHOICE WORDS FLAG <<<"$CARDS"

node tools/e2e/wait.mjs "$LINK" "$BASE" "$KB" "$CHOICE" "$WORDS" "$FLAG" "${SHOTS:-}" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

mix run -e '
  alias Slipdock.Boards
  card = &%Boards.Card{id: &1}
  a = Boards.last_wait(card.('"$CHOICE"'))
  b = Boards.last_wait(card.('"$WORDS"'))
  c = Boards.last_wait(card.('"$FLAG"'))
  if {a.close_reason, a.choice} != {"answered", 2}, do: raise("choice: #{inspect({a.close_reason, a.choice})}")
  if {b.close_reason, b.answer} != {"answered", "Large"}, do: raise("words: #{inspect({b.close_reason, b.answer})}")
  if c.close_reason != "withdrawn", do: raise("flag: #{inspect(c.close_reason)}")
  IO.puts("ok: the database agrees (choice 2, \"Large\", withdrawn)")
'

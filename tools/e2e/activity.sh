#!/usr/bin/env bash
# End to end in a real browser (#1735): the board's Activity panel names who
# did each thing (a person's avatar and name, an agent, a rule, an email, the
# system, "Someone" for old rows), groups entries by day in the reader's
# timezone across midnight, and loads more as the list is scrolled.
#
#   tools/e2e/activity.sh            (SHOTS=dir keeps screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
mix run -e '
  alias Slipdock.{Accounts, Repo}
  alias Slipdock.Boards.Activity
  board_id = '"$KB"'
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  Repo.update!(Ecto.Changeset.change(user, name: "Erin Example", timezone: "Pacific/Auckland"))
  zone = "Pacific/Auckland"
  today = zone |> DateTime.now!() |> DateTime.to_date()
  midnight = today |> DateTime.new!(~T[00:00:00], zone) |> DateTime.shift_zone!("Etc/UTC")
  at = fn s -> midnight |> DateTime.add(s) |> DateTime.truncate(:second) end
  row = fn attrs -> Repo.insert!(struct!(%Activity{board_id: board_id, kind: "card"}, attrs)) end
  # Filler for loading more, three days back.
  for i <- 1..55, do: row.(%{message: "filler #{i}", actor_kind: "system", inserted_at: at.(-3 * 86_400 + i)})
  row.(%{message: "moved “Old card” to Done", inserted_at: at.(-2 * 86_400)})
  row.(%{message: "added automation “Triage”", kind: "automation", actor_kind: "email", user_id: user.id, actor_name: "Erin Example", inserted_at: at.(-120)})
  row.(%{message: "voted for “Pricing”", kind: "vote", actor_kind: "person", actor_name: "Gale Gone", inserted_at: at.(-60)})
  row.(%{message: "commented on “Pricing”", kind: "comment", actor_kind: "automation", actor_name: "Triage", inserted_at: at.(60)})
  row.(%{message: "wrote “Pricing decision”", kind: "page_created", actor_kind: "agent", user_id: user.id, actor_name: "claude", inserted_at: at.(120)})
  row.(%{message: "edited “Pricing decision”", kind: "page_updated", actor_kind: "person", user_id: user.id, actor_name: "Erin Example", inserted_at: at.(180)})
'
node tools/e2e/activity.mjs "$LINK" "$BASE" "$KB"

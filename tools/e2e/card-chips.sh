#!/usr/bin/env bash
# End to end in a real browser (#1708): a board with no saved Display
# settings shows the essential facets only; neutral metadata (a later due
# date, a checklist in progress) is plain text with no outline; overdue, due
# soon, blocked, flagged and waiting keep a tinted fill; medium priority stays
# off the face; and start + due, both shown, draw as one range.
#
#   tools/e2e/card-chips.sh            (SHOTS=<dir> saves screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
ids=$(mix run -e '
  alias Slipdock.{Accounts, Actor, Boards}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  kb = Boards.get_board!('"$KB"')
  [todo, doing | _] = kb.columns
  day = fn n -> Date.utc_today() |> Date.add(n) |> Date.to_iso8601() end
  {:ok, tag} = Boards.Tags.create_tag(kb, %{"name" => "Design", "color" => "sky"})
  {:ok, full} = Boards.create_card(todo, %{"title" => "Repaint the shed before the rain", "priority" => "high",
    "start_date" => day.(10), "due_date" => day.(20), "description" => "Two coats.", "percent_complete" => 40})
  {:ok, _} = Boards.set_card_tags(full, [tag])
  {:ok, _} = Boards.add_comment(full, "Green, not blue", by: user)
  {:ok, _} = Boards.add_checklist_item(full, "Buy paint")
  {:ok, late} = Boards.create_card(todo, %{"title" => "Renew the insurance", "due_date" => day.(-3), "priority" => "medium"})
  {:ok, soon} = Boards.create_card(todo, %{"title" => "Book the skip", "due_date" => day.(1), "flags" => ["flagged"]})
  {:ok, blocker} = Boards.create_card(todo, %{"title" => "Get the quote"})
  {:ok, blocked} = Boards.create_card(todo, %{"title" => "Pay the builder"})
  {:ok, _} = Boards.add_dependency(blocked, blocker)
  {:ok, waiting} = Boards.create_card(doing, %{"title" => "Pick a colour"})
  {:ok, _} = Boards.open_wait(waiting, Actor.web(user), %{"needs" => "Which green?"})
  # What the old ?show= did, as a named card view the URL names (#2031).
  {:ok, _} = Slipdock.CardViews.create(Slipdock.Repo.get_by!(Slipdock.Accounts.User, email: "e2e@example.com"), %{"name" => "e2e-range", "elements" => Map.new(Slipdock.Swimlanes.Config.facet_keys(), &{&1, &1 in ~w(tags priority start_date due_date)})})
  IO.puts("IDS #{full.id} #{late.id} #{soon.id} #{blocked.id} #{waiting.id}")
' | grep '^IDS' | cut -d' ' -f2-)
read -r FULL LATE SOON BLOCKED WAITING <<<"$ids"
node tools/e2e/card-chips.mjs "$LINK" "$BASE" "$KB" "$FULL" "$LATE" "$SOON" "$BLOCKED" "$WAITING"

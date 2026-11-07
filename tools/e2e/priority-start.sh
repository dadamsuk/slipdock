#!/usr/bin/env bash
# End to end in a real browser (#1709): priority draws as signal bars with a
# tooltip naming it on the card face, the outline, the table, the calendar
# and the filter menu; medium stays off the face, the outline and the
# calendar; the start chip's tooltip and the card back say in words when a
# card starts ("Starts in 11 days", "Starts today", "Started 11 days late").
#
#   tools/e2e/priority-start.sh        (SHOTS=<dir> saves screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. PORT picks
# the server's port (default 4112), so two runs can go side by side.
source "$(dirname "$0")/lib.sh"
e2e_start
ids=$(mix run -e '
  alias Slipdock.Boards
  kb = Boards.get_board!('"$KB"')
  [todo | _] = kb.columns
  day = fn n -> Date.utc_today() |> Date.add(n) |> Date.to_iso8601() end
  {:ok, low} = Boards.create_card(todo, %{"title" => "Sweep the yard", "priority" => "low", "start_date" => day.(11), "due_date" => day.(20)})
  {:ok, med} = Boards.create_card(todo, %{"title" => "Sort the post", "priority" => "medium", "start_date" => day.(0), "due_date" => day.(0)})
  {:ok, high} = Boards.create_card(todo, %{"title" => "Fix the gutter", "priority" => "high", "start_date" => day.(0), "due_date" => day.(0)})
  {:ok, crit} = Boards.create_card(todo, %{"title" => "Mend the roof", "priority" => "critical", "start_date" => day.(-14), "due_date" => day.(0)})
  {:ok, t} = Boards.find_template(nil, "Simple")
  {:ok, sub} = Boards.create_sub_board(crit, t, code: "roofe2e")
  [sub_todo | _] = Boards.get_board!(sub.id).columns
  {:ok, _} = Boards.create_card(sub_todo, %{"title" => "Buy slates", "start_date" => day.(-3), "due_date" => day.(0)})
  # What the old ?show= did, as named card views the URL names (#2031).
  {:ok, _} = Slipdock.CardViews.create(Slipdock.Repo.get_by!(Slipdock.Accounts.User, email: "e2e@example.com"), %{"name" => "e2e-start", "elements" => Map.new(Slipdock.Swimlanes.Config.facet_keys(), &{&1, &1 in ~w(tags priority flags start_date)})})
  {:ok, _} = Slipdock.CardViews.create(Slipdock.Repo.get_by!(Slipdock.Accounts.User, email: "e2e@example.com"), %{"name" => "e2e-due", "elements" => Map.new(Slipdock.Swimlanes.Config.facet_keys(), &{&1, &1 in ~w(priority due_date)})})
  IO.puts("IDS #{low.id} #{med.id} #{high.id} #{crit.id}")
' | grep '^IDS' | cut -d' ' -f2-)
read -r LOW MED HIGH CRIT <<<"$ids"
node tools/e2e/priority-start.mjs "$LINK" "$BASE" "$KB" "$LOW" "$MED" "$HIGH" "$CRIT"

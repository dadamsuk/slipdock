#!/usr/bin/env bash
# End to end in a real browser (#2012): the Agentic Building page's four
# tiles (Runners, Findings, Ledger, Health) with their counts, each opened
# in turn, the way back from Findings, Ledger and Health, the Runners panel
# without its old buttons, and the tiles at phone width. Light and dark,
# 1440 and 390.
#
#   PORT=4143 SHOTS=/tmp/shots tools/e2e/agentic-hub.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1
e2e_start

mix run -e '
  import Ecto.Query
  alias Slipdock.{Boards, Repo, Runners}
  alias Slipdock.Boards.Card
  b = Boards.get_board!('"$KB"')
  {:ok, b} = Boards.update_board(b, %{"agentic_building" => true, "verify_work" => true, "lane_mode" => "hold"})
  [_, todo | _] = b.columns
  done = List.last(b.columns)
  now = DateTime.utc_now(:second)
  {:ok, card} = Boards.create_card(todo, %{"title" => "Being built"})
  {:ok, r, _} = Runners.create_runner(b, %{"name" => "Studio", "pool" => "dev"})
  Repo.update!(Ecto.Changeset.change(r, last_seen_at: now))
  {:ok, r2, _} = Runners.create_runner(b, %{"name" => "Laptop", "pool" => "dev"})
  Repo.update!(Ecto.Changeset.change(r2, last_seen_at: DateTime.add(now, -86_400, :second)))
  Repo.insert!(%Slipdock.Runners.Job{board_id: b.id, root_board_id: b.id, card_id: card.id, pool: "dev", kind: "claude", prompt: "Work it", status: "running"})
  for t <- ["Seed data needs a fresh migration", "mix format can need two passes"],
    do: Repo.insert!(%Slipdock.Findings.Finding{board_id: b.id, card_id: card.id, kind: "gotcha", source: "agent", text: t, by: "Builder"})
  for t <- ["Agentic tiles", "Ledger bars", "Back links"] do
    {:ok, c} = Boards.create_card(done, %{"title" => t})
    Repo.update_all(from(x in Card, where: x.id == ^c.id), set: [completed: true, completed_at: DateTime.add(now, -3600, :second)])
  end
  Repo.insert!(%Slipdock.Health.Incident{board_id: b.id, card_id: card.id, detector: "hung_job", fingerprint: "e2e", summary: "Job #1 has not reported for an hour", status: "flagged"})
' > /dev/null

node tools/e2e/agentic-hub.mjs "$LINK" "$BASE" "$KB"

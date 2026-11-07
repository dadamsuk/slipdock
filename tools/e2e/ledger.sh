#!/usr/bin/env bash
# End to end in a real browser (#2013): the Ledger redesigned. Seeds cards
# shipped over two days with lead times from minutes to days, evidence, a
# pull request, a merge, a deploy, an audit and a missed should rule, then
# checks each line's bar (phases, total, a tooltip on hover and on focus),
# each day's summary and bar, the key, and no sideways scroll at 390, and
# takes light and dark screenshots at 1440 and 390.
#
#   PORT=4142 SHOTS=/tmp/shots tools/e2e/ledger.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
mix tailwind slipdock > /dev/null 2>&1
e2e_start

mix run -e '
  import Ecto.Query
  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.{Card, Comment, Wait}
  alias Slipdock.Runners.Job
  b = Boards.get_board!('"$KB"')
  {:ok, b} = Boards.update_board(b, %{"profiles" => true, "verify_work" => true})
  done = List.last(b.columns)
  now = DateTime.utc_now(:second)
  ago = fn s -> DateTime.add(now, -s, :second) end
  h = 3600
  # A card shipped `done_ago` seconds ago after `lead` seconds, and what
  # happened to it on the way, each step at seconds from its start:
  # {:job, kind, queued, claimed, finished}, {:wait, from, to}, {:ci, from, to}.
  ship = fn title, lead, done_ago, steps, fields ->
    start = ago.(done_ago + lead)
    at = fn s -> DateTime.add(start, s, :second) end
    {:ok, c} = Boards.create_card(done, %{"title" => title})
    Repo.update_all(from(x in Card, where: x.id == ^c.id),
      set: [completed: true, completed_at: ago.(done_ago), inserted_at: start] ++ fields)
    for step <- steps do
      case step do
        {:job, kind, q, cl, f} ->
          Repo.insert!(%Job{board_id: b.id, root_board_id: b.id, card_id: c.id, pool: "dev", kind: kind, status: "done", prompt: "Work the card",
            inserted_at: at.(q), updated_at: at.(f), claimed_at: at.(cl), started_at: at.(cl), finished_at: at.(f)})
        {:wait, f, t} ->
          Repo.insert!(%Wait{card_id: c.id, needs: "a decision", question: "Which scale?", kind: "ux", inserted_at: at.(f), closed_at: at.(t)})
        {:ci, f, t} ->
          Repo.insert!(%Comment{card_id: c.id, body: "Build started.", inserted_at: at.(f), updated_at: at.(f)})
          Repo.insert!(%Comment{card_id: c.id, body: "Build passed.", inserted_at: at.(t), updated_at: at.(t)})
      end
    end
    c
  end
  pr = "https://github.com/example/repo/pull/"
  agent = %{"kind" => "agent", "agent" => "verifier", "via" => "cli"}
  a = ship.("Ledger: richer lines and drawn timings", 3 * 86_400 + 5 * h, h,
    [{:job, "work", 0, 6 * h, 16 * h + 40 * 60}, {:ci, 16 * h, 16 * h + 40 * 60},
     {:wait, 17 * h, 50 * h}, {:job, "verify", 50 * h, 53 * h, 54 * h},
     {:job, "work", 54 * h, 54 * h, 62 * h}, {:job, "merge", 62 * h, 62 * h, 62 * h + 20 * 60}],
    verify_state: "accepted", verify_at: ago.(h + 3 * h), verify_by: agent, profile: "feature",
    evidence: "Redesigned the page; tests for every phase share and the day median pass; screenshots on the card.",
    evidence_pr: pr <> "211", merge_sha: "4be1c2d9a7f0",
    verify_checks: %{"rules" => [%{"id" => "UX-4", "result" => "broken", "severity" => "should"}]})
  Repo.insert!(%Comment{card_id: a.id, body: "**Audit: agrees** with the acceptance."})
  Repo.insert!(%Slipdock.Deployments.Deployment{board_id: b.id, environment: "production", sha: "4be1c2d9a7f0", status: "succeeded", started_at: DateTime.utc_now(), finished_at: DateTime.utc_now(), card_ids: [a.id]})
  ship.("Fix the typo in the runner banner", 12 * 60, 2 * h,
    [{:job, "work", 0, 60, 8 * 60}, {:ci, 4 * 60, 8 * 60}, {:job, "verify", 8 * 60, 9 * 60, 12 * 60}],
    verify_state: "accepted", verify_at: ago.(2 * h), verify_by: agent, profile: "fix",
    evidence: "One word changed; the banner test passes.", evidence_pr: pr <> "212")
  ship.("Schema: add the board agentic switch", 9 * h, 3 * h,
    [{:job, "work", 0, 20 * 60, 4 * h}, {:ci, 3 * h, 4 * h}, {:job, "verify", 4 * h, 6 * h, 6 * h + 30 * 60},
     {:wait, 6 * h + 30 * 60, 8 * h + 40 * 60}, {:job, "merge", 8 * h + 40 * 60, 8 * h + 45 * 60, 9 * h}],
    verify_state: "accepted", verify_at: ago.(3 * h), verify_by: %{"kind" => "person", "user_id" => 1}, profile: "schema",
    evidence: "Migration with backfill; every door tested.", evidence_pr: pr <> "210")
  ship.("Docs: the Ledger section of the manual", 40 * 60, 26 * h,
    [{:job, "work", 0, 5 * 60, 35 * 60}], profile: "docs")
  ship.("Rework: tooltips open on tap", 20 * h, 27 * h,
    [{:job, "work", 0, h, 6 * h}, {:ci, 5 * h, 6 * h}, {:job, "verify", 6 * h, 9 * h, 10 * h},
     {:job, "work", 10 * h, 12 * h, 18 * h}, {:job, "verify", 18 * h, 19 * h, 20 * h}],
    verify_state: "accepted", verify_at: ago.(27 * h), verify_by: agent, profile: "feature",
    evidence: "Rejected once for the tap; now focus opens it.")
' > /dev/null

node tools/e2e/ledger.mjs "$LINK" "$BASE" "$KB"

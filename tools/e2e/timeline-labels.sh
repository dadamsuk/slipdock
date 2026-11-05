#!/usr/bin/env bash
# End to end in a real browser (#1732): on a timeline with short bars and
# dependencies, a bar too short for its title shows the whole title beside
# it (on the side with room), no connector draws across a label, the label
# column can be dragged wider and stays that wide after a reload, and the
# Unscheduled tray sits under the last row rather than at the window's foot.
#
#   tools/e2e/timeline-labels.sh            (SHOTS=dir keeps screenshots)
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start
mix run -e '
  alias Slipdock.{Boards, Timeline}
  alias Slipdock.Swimlanes.Config
  board = Boards.get_board!('"$KB"') |> Slipdock.Repo.preload(:columns)
  [list | _] = Enum.sort_by(board.columns, & &1.position)
  # The window the timeline opens on, so every bar lands inside it.
  %{window: %{from: from, days: days}} = Timeline.build(board, Config.defaults("timeline"))
  on = fn n -> Date.add(from, n) |> Date.to_iso8601() end
  mk = fn title, attrs ->
    {:ok, c} = Boards.create_card(list, Map.put(attrs, "title", title))
    c
  end
  wide = mk.("Onboarding flow redesign", %{"start_date" => on.(days - 60), "due_date" => on.(days - 38)})
  short = mk.("Write the release notes", %{"start_date" => on.(days - 37), "due_date" => on.(days - 37)})
  reco = mk.("Record the demo video", %{"start_date" => on.(days - 33), "due_date" => on.(days - 32)})
  _long = mk.("Migrate billing webhooks to the new provider endpoint", %{"start_date" => on.(days - 50), "due_date" => on.(days - 30)})
  due = mk.("Due-only launch checklist", %{"due_date" => on.(days - 28)})
  _edge = mk.("Finalise pricing page copy", %{"start_date" => on.(days - 2), "due_date" => on.(days - 1)})
  _clip = mk.("Runs past the window edge", %{"start_date" => on.(days - 1), "due_date" => on.(days + 20)})
  _ = mk.("No date yet", %{})
  _ = mk.("Also undated", %{})
  {:ok, _} = Boards.add_dependency(short, wide)
  {:ok, _} = Boards.add_dependency(reco, short)
  {:ok, _} = Boards.add_dependency(due, reco)
' > /dev/null
node tools/e2e/timeline-labels.mjs "$LINK" "$BASE" "$KB"

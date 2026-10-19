#!/usr/bin/env bash
# End to end in a real browser (#1157): on a wiki page's transcript, a click
# on a speaker's name opens a box; Enter names that voice throughout the
# transcript and saves the page, Escape leaves it as it was, and the player's
# bar survives the redraw.
#
#   tools/e2e/speaker-name.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"

e2e_start
trap 'kill $E2E_SERVER 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

SLUG=$(mix run -e '
  alias Slipdock.{Accounts, Wiki}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  kb = Slipdock.Boards.get_board!('"$KB"')
  vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n<v Speaker 1>Shall we start?\n\n00:00:04.000 --> 00:00:06.000\n<v Speaker 2>Yes.\n\n00:00:07.000 --> 00:00:09.000\nSpeaker 1: The budget first.\n"
  {:ok, p} = Wiki.create_page(kb, %{"title" => "Standup", "body" => "## Transcript\n\n```vtt\n" <> vtt <> "```\n"}, user: user)
  IO.puts("SLUG #{p.slug}")
' | grep '^SLUG' | cut -d' ' -f2)

node "$(dirname "$0")/speaker-name.mjs" "$LINK" "$BASE" "$KB" "$SLUG"

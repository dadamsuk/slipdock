#!/usr/bin/env bash
# End to end in a real browser (W-1690, #780, #781): a meeting page plays its
# recording, streamed from "Google Drive" through the server, in time with
# its transcript — the highlight follows playback, a click on a turn seeks
# there, so does a tag pressed during it (#785), scrolling by hand stops
# following, search finds turns, and a
# recording that isn't there says so. Drive is tools/e2e/fake-drive.mjs.
#
#   tools/e2e/meeting-player.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"

DRIVE_PORT=$((PORT + 1))
node "$(dirname "$0")/fake-drive.mjs" "$DRIVE_PORT" &
DRIVE=$!
export GOOGLE_API_BASE_URL="http://127.0.0.1:$DRIVE_PORT"
export GOOGLE_CLIENT_ID=e2e GOOGLE_CLIENT_SECRET=e2e

e2e_start
trap 'kill $DRIVE 2>/dev/null || true; kill $E2E_SERVER 2>/dev/null || true; sleep 1; mix ecto.drop --quiet 2>/dev/null || true' EXIT

PAGES=$(mix run -e '
  alias Slipdock.{Accounts, Repo, Vaults, Wiki}
  {:ok, user} = Accounts.get_or_create_user_by_email("e2e@example.com")
  now = DateTime.utc_now() |> DateTime.truncate(:second)
  Repo.insert!(%Slipdock.Google.Connection{user_id: user.id, email: "e2e@example.com",
    refresh_token: Slipdock.Google.encrypt("r"), access_token: Slipdock.Google.encrypt("e2e-access"),
    access_expires_at: DateTime.add(now, 3600)})
  [vault] = Vaults.list_vaults(user)
  vault |> Ecto.Changeset.change(recordings_folder: "Rec") |> Repo.update!()
  kb = Slipdock.Boards.get_board!('"$KB"')
  cues = [{1_500, "Alice", "Shall we start? The budget first."}, {4_000, "Bob", "Yes, the budget."},
          {8_000, "Alice", "Then the hiring plan."}, {12_000, "Bob", "Fine."}] ++
         for(s <- 16..64//4, do: {s * 1000, "Alice", "Point number #{s}."}) ++ [{65_000, "Bob", "And that is all."}]
  ts = fn ms -> h = div(ms, 3_600_000); m = div(rem(ms, 3_600_000), 60_000); s = rem(ms, 60_000) / 1000
     :io_lib.format("~2..0B:~2..0B:~6.3.0f", [h, m, s]) |> IO.iodata_to_binary() end
  vtt = "WEBVTT\n\n" <> Enum.map_join(Enum.with_index(cues, 1), "\n", fn {{ms, who, text}, i} ->
    "#{i}\n#{ts.(ms)} --> #{ts.(ms + 3000)}\n<v #{who}>#{text}\n" end)
  body = "Summary of the meeting.\n\nTags: #decision (0:10)\n\n## Recording\n\n[▶ Play recording and transcript](#recording)\n\n## Transcript\n\n```vtt\n" <> vtt <> "```\n"
  {:ok, p} = Wiki.create_page(kb, %{"title" => "Weekly sync", "front_matter" => "---\ntype: meeting\nrecording: gdrive:Rec/meeting.wav\n---\n\n", "body" => body}, user: user)
  {:ok, gone} = Wiki.create_page(kb, %{"title" => "Lost one", "front_matter" => "---\nrecording: gdrive:Rec/missing.wav\n---\n\n", "body" => "## Recording\n\n[▶ Play recording and transcript](#recording)\n"}, user: user)
  IO.puts("PAGES #{p.slug} #{gone.slug}")
' | grep '^PAGES' | cut -d' ' -f2-)

node "$(dirname "$0")/meeting-player.mjs" "$LINK" "$BASE" "$KB" $PAGES

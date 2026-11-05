#!/usr/bin/env bash
# End to end in a real browser: the Admin area in the settings layout
# (#1738). Every admin page (People, Sign-ups, Overview, Server, Email,
# Meetings, AI, Tools) is under one "Admin" title with the Admin nav beside
# it at 1440 and 1280 and a picker at 390, the current page marked and named
# over its content, the running build in the nav's footer, no tablist left,
# narrow content for the Configuration forms and wide for the rest. The
# People panel still opens and closes, and an ordinary person is refused.
#
#   tools/e2e/admin-nav.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH. SHOTS=<dir>
# saves screenshots; BEFORE=1 only takes them (for the old pages).
source "$(dirname "$0")/lib.sh"
e2e_start
# Sign-up by approval, with somebody waiting, so Sign-ups is listed with a
# count; and an ordinary account to be refused.
mix run -e '
  {:ok, _} =
    Slipdock.Settings.update(%{
      "smtp_host" => "smtp.example.com",
      "smtp_from_email" => "mail@example.com",
      "signup_mode" => :approval
    })
  Slipdock.Accounts.request_signup("hopeful@example.com", note: "From the e2e")
  {:ok, _} = Slipdock.Accounts.get_or_create_user_by_email("someone@example.com")
' > /dev/null
# The server caches the settings row, so it starts again to read them.
kill "$E2E_SERVER"
wait "$E2E_SERVER" 2>/dev/null || true
mix phx.server > "$LOG" 2>&1 &
E2E_SERVER=$!
for _ in $(seq 1 60); do
  curl -sf -o /dev/null "$BASE/login" && break
  sleep 2
done
ORDINARY=$(mix run --no-start -e '
  {:ok, _} = Application.ensure_all_started(:slipdock)
  {:ok, path} = Slipdock.Accounts.write_agentic_login("someone@example.com", &"'"$BASE"'/login/#{&1}")
  IO.write(File.read!(path))
  File.rm(path)
' | tail -1)
node tools/e2e/admin-nav.mjs "$LINK" "$BASE" "$ORDINARY"

#!/usr/bin/env bash
# End to end in a real browser (#828): add a passkey on the account page,
# sign out, sign in with it from the login page, then remove it and see it
# refused. Chromium's virtual authenticator (over CDP) stands in for the
# device, so this runs the real navigator.credentials calls in
# assets/js/passkey.js against the real server checks.
#
#   tools/e2e/passkey.sh
#
# On localhost rather than 127.0.0.1: a passkey belongs to a domain name, and
# browsers refuse to make one for an IP address.
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
export SLIPDOCK_URL_HOST=localhost
source "$(dirname "$0")/lib.sh"
e2e_start

node tools/e2e/passkey.mjs "$LINK" "http://localhost:$PORT"

mix run -e '
  user = Slipdock.Accounts.get_user_by_email("e2e@example.com")
  if Slipdock.Accounts.Passkeys.list(user) != [], do: raise("the passkey was not removed")
  IO.puts("ok: the passkey is gone from the database")
'

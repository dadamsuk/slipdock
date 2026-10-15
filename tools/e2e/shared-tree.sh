#!/usr/bin/env bash
# End to end in a real browser, two people (#817): the owner shares Specs
# from the tree's ⋯ menu; the other person finds it under Shared with me,
# opens and edits Acme call; the owner takes the share back and it leaves
# the other person's Shared view live.
#
#   PORT=4099 tools/e2e/shared-tree.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

FRIEND_LINK=$(mix run --no-start -e '
  {:ok, _} = Application.ensure_all_started(:slipdock)
  {:ok, _} = Slipdock.Accounts.get_or_create_user_by_email("friend@example.com")
  {:ok, path} = Slipdock.Accounts.write_agentic_login("friend@example.com", &"'"$BASE"'/login/#{&1}")
  IO.write(File.read!(path))
  File.rm(path)
' | tail -1)

node tools/e2e/shared-tree.mjs "$LINK" "$FRIEND_LINK" "$BASE" "$KB" "$SPECS" "$PAGE"

mix run -e '
  page = Slipdock.Wiki.get_page!('"$PAGE"')
  unless page.body =~ "Edited by a friend", do: raise("the friend\x27s edit did not land: #{page.body}")
  unless Slipdock.Access.list_grants(Slipdock.Wiki.get_folder('"$SPECS"')) == [], do: raise("still shared")
  IO.puts("ok: the edit landed, and Specs is shared with nobody again")
'

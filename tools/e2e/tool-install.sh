#!/usr/bin/env bash
# End to end (#966): the job-scan Tool published with the real CLI, shared
# by its owner in the browser, then found, read and installed by a second
# person. The setup skill's own calls are made over MCP the way an agent
# makes them — list_tools, install_tool, read_page and write_page — and the
# browser checks what they built.
#
#   PORT=4099 tools/e2e/tool-install.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

token() {
  mix run -e '
    {:ok, u} = Slipdock.Accounts.get_or_create_user_by_email("'"$1"'")
    {t, _} = Slipdock.Accounts.create_api_token(u, "e2e")
    IO.puts("TOKEN " <> t)
  ' | grep '^TOKEN' | cut -d' ' -f2
}

OWNER_TOKEN=$(token e2e@example.com)
FRIEND_TOKEN=$(token friend@example.com)
# A sign-in link works once, so each browser step gets its own.
link() {
  mix run --no-start -e '
    {:ok, _} = Application.ensure_all_started(:slipdock)
    {:ok, path} = Slipdock.Accounts.write_agentic_login("'"$1"'", &"'"$BASE"'/login/#{&1}")
    IO.write(File.read!(path))
    File.rm(path)
  ' | tail -1
}

# Publish with the CLI, as an author would.
(cd cli && SLIPDOCK_URL="$BASE" SLIPDOCK_TOKEN="$OWNER_TOKEN" MIX_ENV=dev \
  mix run -e 'SlipdockCLI.main(["tools", "publish", "../packages/job-scan"])')

mcp() {
  curl -sf "$BASE/mcp" -H "authorization: Bearer $FRIEND_TOKEN" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"
}

# The owner shares it in the browser; the friend reads it before installing.
node tools/e2e/tool-install.mjs share "$LINK" "$BASE"
node tools/e2e/tool-install.mjs browse "$(link friend@example.com)" "$BASE"

# What job-scan-setup does: find the Tool, have the server build the board,
# then fill the pages in with the person's answers.
mcp list_tools '{}' | grep -q '"name":"job-scan"' || { echo "list_tools has no job-scan"; exit 1; }
INSTALL=$(mcp install_tool '{"tool":"job-scan","board_name":"My Job Scan"}')
echo "$INSTALL" | grep -q '"created":true' || { echo "install_tool: $INSTALL"; exit 1; }
CODE=$(echo "$INSTALL" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{console.log(JSON.parse(s).result.structuredContent.board)})')
echo "ok: install_tool built board $CODE"

AGAIN=$(mcp install_tool '{"tool":"job-scan"}')
echo "$AGAIN" | grep -q '"created":false' || { echo "a second install made a board: $AGAIN"; exit 1; }
echo "ok: installing again found the same board"

mcp list_tools '{}' | grep -q "\"board\":\"$CODE\"" || { echo "list_tools has no install record"; exit 1; }
echo "ok: list_tools gives the board from the install record (how job-scan finds it)"

PAGE=$(mcp read_page "{\"board\":\"$CODE\",\"page\":\"Job Scan Decision Rules\"}")
HASH=$(echo "$PAGE" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const f=o=>o&&typeof o=="object"?(o.content_hash||Object.values(o).map(f).find(Boolean)):null;console.log(f(JSON.parse(s)))})')
BODY='# Job Scan Decision Rules\n\n## What I am looking for\n- Titles and level: Head of Platform\n\n## Absolute noes\n- Gambling\n\n## Threshold\n70'
mcp write_page "{\"mode\":\"replace\",\"board\":\"$CODE\",\"page\":\"Job Scan Decision Rules\",\"body\":\"$BODY\",\"base_hash\":\"$HASH\",\"message\":\"filled in at setup\"}" \
  | grep -q '"isError":false' || { echo "write_page failed"; exit 1; }
mcp list_automations "{\"board\":\"$CODE\"}" | grep -q 'Build documents for cards in Generate' \
  || { echo "the Generate rule is missing"; exit 1; }
echo "ok: setup filled Decision Rules and found the Generate rule"

node tools/e2e/tool-install.mjs board "$(link friend@example.com)" "$BASE" "$CODE"

#!/bin/sh
# Recording a deploy on a Slipdock board with curl, git and jq alone — a
# worked example for where the slipdock CLI can't go (no Erlang). It does
# what `slipdock deploy run` does: asks for the environment's last deployed
# sha, sends the commits since it, runs the deploy, and records how it ended.
#
#   SLIPDOCK_URL           the server, e.g. https://slipdock.example.com
#   SLIPDOCK_DEPLOY_TOKEN  the board's deploy token (records deploys, nothing else)
#
#   ./curl.sh production v1.4.0 ./deploy.sh v1.4.0
set -eu

env=$1; tag=$2; shift 2
api="$SLIPDOCK_URL/api/deployments"
auth="Authorization: Bearer $SLIPDOCK_DEPLOY_TOKEN"
head=$(git rev-parse HEAD)

# The last succeeded deploy's sha, or null the first time.
prev=$(curl -fsS -H "$auth" "$api/last?environment=$env" | jq -r '.sha // empty')

# The commits since then (HEAD alone the first time), as JSON. A full clone:
# in CI, fetch the whole history. Card ids (#123) are read from the messages
# by the server.
if [ -n "$prev" ]; then range="$prev..$head"; else range="-1 $head"; fi
commits=$(git log --format='%H%x1f%cI%x1f%B%x1e' $range |
  jq -Rs 'split("\u001e") | map(select(test("\\S")) | ltrimstr("\n") | split("\u001f")
          | {sha: .[0], committed_at: .[1], message: .[2]})')

# A rollback is a deploy of something the last deploy already contained.
rollback=false
if [ -n "$prev" ] && [ "$prev" != "$head" ] && git merge-base --is-ancestor "$head" "$prev"; then
  rollback=true
  commits='[]'
fi

id=$(jq -n --arg env "$env" --arg sha "$head" --arg tag "$tag" --argjson commits "$commits" \
        --argjson rollback "$rollback" \
        '{environment: $env, sha: $sha, tag: $tag, commits: $commits, rollback: $rollback, source: "api"}' |
  curl -fsS -H "$auth" -H 'Content-Type: application/json' --data-binary @- "$api" |
  jq -r '.deployment.id') || id=""

# The deploy itself. Recording it never stops it.
status=succeeded
"$@" || { code=$?; status=failed; }

if [ -n "$id" ]; then
  curl -fsS -X PATCH -H "$auth" -H 'Content-Type: application/json' \
    -d "{\"status\": \"$status\"}" "$api/$id" >/dev/null || echo "warning: deploy $id not finished on the board" >&2
fi

exit "${code:-0}"

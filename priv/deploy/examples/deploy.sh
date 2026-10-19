#!/bin/sh
# Recording deploys on a Slipdock board from a plain shell deploy — a worked
# example, for a deploy run by hand, from cron, or from any CI not covered by
# the other examples.
#
# Needs: git and a full clone of the repository (not a shallow one), Erlang
# (the slipdock CLI is an escript), and in the environment:
#   SLIPDOCK_URL           the server, e.g. https://slipdock.example.com
#   SLIPDOCK_DEPLOY_TOKEN  the board's deploy token (records deploys, nothing else)
set -eu

: "${SLIPDOCK_URL:?set SLIPDOCK_URL}"
: "${SLIPDOCK_DEPLOY_TOKEN:?set SLIPDOCK_DEPLOY_TOKEN}"

# The CLI, once.
if ! command -v slipdock >/dev/null 2>&1; then
  mkdir -p "$HOME/.local/bin"
  curl -fsSL "$SLIPDOCK_URL/cli/slipdock.escript" -o "$HOME/.local/bin/slipdock"
  chmod +x "$HOME/.local/bin/slipdock"
  PATH="$HOME/.local/bin:$PATH"
fi

tag=${1:-$(git describe --tags --always)}

# Try it first: checks the token and shows the commits and cards it would
# record, and records nothing.
#   slipdock deploy run --env production --dry-run -- true

# The deploy, inside `slipdock deploy run … --`. Its exit code is this
# script's: succeeded or failed is recorded from it.
exec slipdock deploy run --env production --tag "$tag" -- ./your-deploy-command "$tag"

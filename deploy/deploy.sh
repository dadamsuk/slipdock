#!/bin/sh
# Deploys one pinned Slipdock image on the production server, and is the
# rollback too: `deploy.sh <previous-tag>` is the same deploy of an older tag.
#
#   /opt/deploy/deploy.sh sha-1a2b3c4     a commit on main
#   /opt/deploy/deploy.sh 1.2.3           a tagged release
#
# The release workflow runs it over Tailscale SSH after an image is published
# (see the deploy job in .github/workflows/release.yml), as
# `sudo -n /opt/deploy/deploy.sh <tag>`, but it is just as much for a person on
# the server. Install it root-owned and not writable by anyone else at
# /opt/deploy/deploy.sh: the deploy user may run it as root and nothing more.
#
# Only the app is pulled and recreated. Postgres is left running as it is, and
# the app migrates its database on boot (see Slipdock.Application), forward
# only: rolling back the image does not roll back the schema.
#
# Nothing secret lives in the repository. GHCR credentials, when the image
# needs them, are read from $GHCR_CREDENTIALS on the server:
#
#   GHCR_USER=your-github-user
#   GHCR_TOKEN=a token with read:packages
#
# Without that file the pull uses whatever `docker login` already left behind,
# which for a public image is nothing at all.
set -eu
umask 077

SLIPDOCK_DIR="${SLIPDOCK_DIR:-/opt/slipdock}"
STATE_DIR="${DEPLOY_STATE_DIR:-/opt/deploy}"
GHCR_CREDENTIALS="${GHCR_CREDENTIALS:-$STATE_DIR/ghcr.env}"
SERVICE="slipdock"
ENV_FILE="$SLIPDOCK_DIR/.env"

say() { echo "deploy: $*"; }
fail() {
  echo "deploy: $*" >&2
  exit 1
}

# A tag pins one image: a commit (`sha-` and its hash, as the release workflow
# tags it) or a full release version. Moving tags — `latest`, `main`, `1.2` —
# are refused, since a deploy of one could not be repeated or rolled back to.
# The character check comes first so that nothing with a newline, a space or a
# shell character in it reaches grep, which matches line by line.
valid_tag() {
  case "$1" in
    "" | *[!0-9A-Za-z.-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ] || return 1
  printf '%s\n' "$1" |
    grep -Eqx 'sha-[0-9a-f]{7,40}|[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?'
}

[ "$#" -eq 1 ] || fail "usage: deploy.sh <image-tag>   (sha-<commit> or a version like 1.2.3)"
TAG="$1"
valid_tag "$TAG" || fail "not a pinned image tag; expected sha-<commit> or a version like 1.2.3"

[ -d "$SLIPDOCK_DIR" ] || fail "no compose project at $SLIPDOCK_DIR"
mkdir -p "$STATE_DIR"
cd "$SLIPDOCK_DIR"

# One deploy at a time, whoever started it. CI already never overlaps its own;
# this covers a rollback by hand while one of those is running.
if command -v flock > /dev/null 2>&1; then
  exec 9> "$STATE_DIR/deploy.lock"
  flock -w 900 9 || fail "another deploy has held the lock for 15 minutes"
fi

current_tag() {
  [ -f "$ENV_FILE" ] && sed -n 's/^SLIPDOCK_TAG=//p' "$ENV_FILE" | tail -n 1
}
PREVIOUS="$(current_tag || true)"
PREVIOUS="${PREVIOUS:-latest}"

if [ -f "$GHCR_CREDENTIALS" ]; then
  # Read, not sourced: the file is data, and sourcing would run it.
  ghcr_user="$(sed -n 's/^GHCR_USER=//p' "$GHCR_CREDENTIALS" | tail -n 1)"
  ghcr_token="$(sed -n 's/^GHCR_TOKEN=//p' "$GHCR_CREDENTIALS" | tail -n 1)"
  [ -n "$ghcr_user" ] && [ -n "$ghcr_token" ] ||
    fail "$GHCR_CREDENTIALS needs both GHCR_USER= and GHCR_TOKEN="
  printf '%s' "$ghcr_token" |
    docker login ghcr.io --username "$ghcr_user" --password-stdin > /dev/null ||
    fail "docker login to ghcr.io failed"
  unset ghcr_token
  say "logged in to ghcr.io as $ghcr_user"
else
  say "no $GHCR_CREDENTIALS; pulling with docker's existing login, if any"
fi

say "deploying $TAG (was $PREVIOUS)"

# Pulled before anything is written down: a tag that does not exist stops
# here, with .env and the running container exactly as they were. The shell
# variable beats .env for compose's interpolation.
SLIPDOCK_TAG="$TAG" docker compose pull "$SERVICE" || fail "pull of $TAG failed; nothing changed"

# Kept in .env, so a plain `docker compose up -d` later on runs the same image
# rather than drifting back to latest. Written over the file in place, which
# keeps its owner and mode.
if [ "$PREVIOUS" != "$TAG" ]; then
  echo "$PREVIOUS" > "$STATE_DIR/previous-tag"
fi
tmp="$STATE_DIR/env.$$"
{
  if [ -f "$ENV_FILE" ]; then grep -v '^SLIPDOCK_TAG=' "$ENV_FILE" || true; fi
  echo "SLIPDOCK_TAG=$TAG"
} > "$tmp"
cat "$tmp" > "$ENV_FILE"
rm -f "$tmp"

# --no-deps: Postgres is neither recreated nor restarted.
SLIPDOCK_TAG="$TAG" docker compose up -d --no-deps "$SERVICE" ||
  fail "starting $TAG failed; to go back: deploy.sh $PREVIOUS"

container="$(docker compose ps -q "$SERVICE")"
[ -n "$container" ] || fail "no $SERVICE container after up; to go back: deploy.sh $PREVIOUS"
image_id="$(docker inspect --format '{{.Image}}' "$container")"
digest="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image_id" | head -n 1)"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $PREVIOUS -> $TAG ${digest:-$image_id}" >> "$STATE_DIR/deploy.log"

say "running $TAG"
say "digest ${digest:-unknown (image $image_id)}"
if valid_tag "$PREVIOUS"; then
  say "to roll back: deploy.sh $PREVIOUS"
else
  say "the previous tag ($PREVIOUS) was not pinned; roll back to a sha- tag from GHCR"
fi

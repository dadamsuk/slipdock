#!/bin/sh
# Makes the container self-contained: it fixes up the data volume, invents a
# SECRET_KEY_BASE the first time if nobody supplied one, and then runs the
# release as an unprivileged user. Migrations are not run here — the app runs
# them itself on boot when it is a release (see Slipdock.Application).
set -eu

DATA_DIR="${SLIPDOCK_DATA_DIR:-/data}"
SECRET_FILE="$DATA_DIR/secret_key_base"

# The volume arrives owned by root on a first run, and the app is not root.
if [ "$(id -u)" = "0" ]; then
  mkdir -p "$DATA_DIR" "${SLIPDOCK_UPLOADS_DIR:-$DATA_DIR/uploads}"
  chown -R slipdock:slipdock "$DATA_DIR"
fi

# A secret nobody chose is better than a secret everybody shares, so one is
# generated into the volume and reused. Supplying SECRET_KEY_BASE yourself
# overrides this and is what you want if you ever run more than one of these.
if [ -z "${SECRET_KEY_BASE:-}" ]; then
  if [ ! -f "$SECRET_FILE" ]; then
    # 64 bytes, base64: what `mix phx.gen.secret` produces, without needing mix.
    openssl rand -base64 64 | tr -d '\n' > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    [ "$(id -u)" = "0" ] && chown slipdock:slipdock "$SECRET_FILE"
    echo "entrypoint: generated a SECRET_KEY_BASE in $SECRET_FILE"
  fi
  SECRET_KEY_BASE="$(cat "$SECRET_FILE")"
  export SECRET_KEY_BASE
fi

# Links in sign-in emails have to point somewhere people can reach. Without
# PHX_HOST the app would say example.com, which is nobody's server.
if [ -z "${PHX_HOST:-}" ]; then
  echo "entrypoint: PHX_HOST is NOT SET in this container, so it is localhost."
  echo "entrypoint:   Sign-in links will point at localhost, and pages opened at"
  echo "entrypoint:   any other name will load and then never update."
  echo "entrypoint:   Set PHX_HOST in the .env beside compose.yaml, then"
  echo "entrypoint:   \`docker compose up -d\` — not \`restart\`, which never"
  echo "entrypoint:   re-reads .env."
  PHX_HOST="localhost"
  export PHX_HOST
else
  # Said out loud on every boot. When the app reports a host somebody did not
  # expect, this is the line that says whether it ever reached the container —
  # which is the difference between "compose did not pass it" and "the app
  # ignored it", and the first thing anybody needs to know.
  echo "entrypoint: PHX_HOST=$PHX_HOST"
fi

# Defaults that only make sense in a container, where the app is behind a
# published port and speaks plain http. They live here rather than in
# compose.yaml's `environment:` block, because that block *overrides* env_file
# — so a value somebody put in .env would lose to an interpolated default.
if [ -z "${SLIPDOCK_URL_SCHEME:-}" ]; then
  SLIPDOCK_URL_SCHEME="http"
  export SLIPDOCK_URL_SCHEME
fi

if [ -z "${SLIPDOCK_URL_PORT:-}" ]; then
  SLIPDOCK_URL_PORT="${PORT:-4000}"
  export SLIPDOCK_URL_PORT
fi

echo "entrypoint: links will be built as ${SLIPDOCK_URL_SCHEME}://${PHX_HOST}:${SLIPDOCK_URL_PORT}"

run() {
  if [ "$(id -u)" = "0" ]; then
    exec setpriv --reuid=slipdock --regid=slipdock --init-groups "$@"
  else
    exec "$@"
  fi
}

case "${1:-start}" in
  start)
    run /app/bin/slipdock start
    ;;
  # A shell in the running app, for looking at things.
  remote|console)
    run /app/bin/slipdock "$1"
    ;;
  # The mix tasks are not in a release, so the two worth having are here.
  #   docker compose run --rm slipdock reindex
  #   docker compose run --rm slipdock ai-key you@example.com sk-or-…
  #   docker compose run --rm slipdock setup --status
  reindex)
    run /app/bin/slipdock eval "Slipdock.Release.reindex()"
    ;;
  ai-key)
    shift
    # The arguments become an Elixir list of strings. Emails and API keys have
    # no quotes in them, which is the only thing this would not survive.
    args=""
    for a in "$@"; do args="${args}\"${a}\","; done
    run /app/bin/slipdock eval "Slipdock.Release.ai_key([${args}])"
    ;;
  migrate)
    run /app/bin/slipdock eval "Slipdock.Release.migrate()"
    ;;
  # Setting the server up without the browser wizard, seeing what it thinks,
  # and the way back in when mail has broken.
  #   docker compose run --rm slipdock setup --admin you@example.com
  #   docker compose run --rm slipdock setup --status
  #   docker compose run --rm slipdock setup --sign-in-link you@example.com
  setup)
    shift
    args=""
    for a in "$@"; do args="${args}\"${a}\","; done
    run /app/bin/slipdock eval "Slipdock.Release.setup([${args}])"
    ;;
  *)
    run "$@"
    ;;
esac

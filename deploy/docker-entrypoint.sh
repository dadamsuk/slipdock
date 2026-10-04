#!/bin/sh
# Makes the container self-contained: it fixes up the data volume, invents a
# SECRET_KEY_BASE the first time if nobody supplied one, works out where
# Postgres is and waits for it, and then runs the release as an unprivileged
# user. Migrations are not run here — the app runs them itself on boot when it
# is a release (see Slipdock.Application).
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
  echo "entrypoint:   Set it either way, then \`docker compose up -d\` — not"
  echo "entrypoint:   \`restart\`, which reuses the container and re-reads neither:"
  echo "entrypoint:     echo PHX_HOST=slipdock.example.com >> .env     <- survives reboots"
  echo "entrypoint:     export PHX_HOST=slipdock.example.com           <- this shell only"
  echo "entrypoint:"
  echo "entrypoint:   If you think you already set it: \`echo \$PHX_HOST\` printing a"
  echo "entrypoint:   value does NOT mean compose can see it. Only *exported* variables"
  echo "entrypoint:   are passed to containers, and a plain \`PHX_HOST=...\` is not one."
  echo "entrypoint:   \`env | grep PHX_HOST\` is the check that tells the truth."
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

# Where Postgres is. A DATABASE_URL of your own always wins; without one it is
# assembled from the same pieces compose hands to the postgres container, so
# the bundled compose.yaml needs to agree on nothing but the password.
if [ -z "${DATABASE_URL:-}" ]; then
  DATABASE_URL="postgres://${POSTGRES_USER:-slipdock}:${POSTGRES_PASSWORD:-slipdock}@${POSTGRES_HOST:-postgres}:${POSTGRES_PORT:-5432}/${POSTGRES_DB:-slipdock}"
  export DATABASE_URL
  echo "entrypoint: DATABASE_URL was not set, using ${POSTGRES_HOST:-postgres}:${POSTGRES_PORT:-5432}/${POSTGRES_DB:-slipdock}"
fi

# Wait for the database to accept connections. compose already holds the app
# back until Postgres reports healthy, so this is for the paths that do not:
# `docker run` by hand, and `docker compose run` on a cold stack. It only
# checks that something is listening — the app itself is the real test — and
# gives up after a minute rather than hanging a container for ever.
wait_for_db() {
  host="$(echo "$DATABASE_URL" | sed -n 's|.*@\([^:/?]*\).*|\1|p')"
  port="$(echo "$DATABASE_URL" | sed -n 's|.*@[^:/?]*:\([0-9]*\).*|\1|p')"
  [ -n "$host" ] || return 0
  [ -n "$port" ] || port=5432

  i=0
  while [ "$i" -lt 60 ]; do
    if nc -z "$host" "$port" 2>/dev/null; then
      [ "$i" -gt 0 ] && echo "entrypoint: $host:$port is up"
      return 0
    fi
    [ "$i" = "0" ] && echo "entrypoint: waiting for $host:$port…"
    i=$((i + 1))
    sleep 1
  done

  echo "entrypoint: gave up waiting for $host:$port after 60s; starting anyway"
}

run() {
  if [ "$(id -u)" = "0" ]; then
    exec setpriv --reuid=slipdock --regid=slipdock --init-groups "$@"
  else
    exec "$@"
  fi
}

# Runs Slipdock.Release.<fun> with the remaining arguments as a list of
# strings. They travel as SLIPDOCK_ARG_1… in the environment, never inside the
# Elixir source given to `eval`, so a quote or a #{} in an email or a key is
# just a character in it.
release_eval() {
  fun="$1"
  shift
  wait_for_db
  n=0
  for a in "$@"; do
    n=$((n + 1))
    export "SLIPDOCK_ARG_$n=$a"
  done
  export SLIPDOCK_ARGC="$n"
  run /app/bin/slipdock eval "Slipdock.Release.${fun}(Slipdock.Release.env_args())"
}

case "${1:-start}" in
  start)
    wait_for_db
    run /app/bin/slipdock start
    ;;
  # A shell in the running app, for looking at things.
  remote|console)
    run /app/bin/slipdock "$1"
    ;;
  # There is no mix in a release, so the tasks worth having are mirrored in
  # Slipdock.Release and dispatched from here:
  #   docker compose run --rm slipdock reindex
  #   docker compose run --rm slipdock ai-key you@example.com sk-or-…
  #   docker compose run --rm slipdock ai-endpoint you@example.com http://llm.local:1234/v1
  #   docker compose run --rm slipdock welcome you@example.com
  #   docker compose run --rm slipdock setup --status
  reindex)
    wait_for_db
    run /app/bin/slipdock eval "Slipdock.Release.reindex()"
    ;;
  ai-key)
    shift
    release_eval ai_key "$@"
    ;;
  # Point somebody at an OpenAI-compatible model server of their own instead
  # of OpenRouter; no key needed for most of them.
  #   docker compose run --rm slipdock ai-endpoint you@example.com http://llm.local:1234/v1
  ai-endpoint)
    shift
    release_eval ai_endpoint "$@"
    ;;
  # The tour board a first sign-in builds, for an account that was here before
  # it existed (see Slipdock.Onboarding).
  #   docker compose run --rm slipdock welcome you@example.com [--force]
  welcome)
    shift
    release_eval welcome "$@"
    ;;
  migrate)
    wait_for_db
    run /app/bin/slipdock eval "Slipdock.Release.migrate()"
    ;;
  # Setting the server up without the browser wizard, seeing what it thinks,
  # and the way back in when mail has broken.
  #   docker compose run --rm slipdock setup --admin you@example.com
  #   docker compose run --rm slipdock setup --status
  #   docker compose run --rm slipdock setup --sign-in-link you@example.com
  setup)
    shift
    release_eval setup "$@"
    ;;
  *)
    run "$@"
    ;;
esac

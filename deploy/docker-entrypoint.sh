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
  # There is no mix in a release, so the tasks worth having are mirrored in
  # Slipdock.Release and dispatched from here:
  #   docker compose run --rm slipdock reindex
  #   docker compose run --rm slipdock ai-key you@example.com sk-or-…
  #   docker compose run --rm slipdock ai-endpoint you@example.com http://llm.local:1234/v1
  #   docker compose run --rm slipdock welcome you@example.com
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
  # Point somebody at an OpenAI-compatible model server of their own instead
  # of OpenRouter; no key needed for most of them.
  #   docker compose run --rm slipdock ai-endpoint you@example.com http://llm.local:1234/v1
  ai-endpoint)
    shift
    args=""
    for a in "$@"; do args="${args}\"${a}\","; done
    run /app/bin/slipdock eval "Slipdock.Release.ai_endpoint([${args}])"
    ;;
  # The tour board a first sign-in builds, for an account that was here before
  # it existed (see Slipdock.Onboarding).
  #   docker compose run --rm slipdock welcome you@example.com [--force]
  welcome)
    shift
    args=""
    for a in "$@"; do args="${args}\"${a}\","; done
    run /app/bin/slipdock eval "Slipdock.Release.welcome([${args}])"
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

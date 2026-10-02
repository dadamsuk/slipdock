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
  chown -R kanban:slipdock "$DATA_DIR"
fi

# A secret nobody chose is better than a secret everybody shares, so one is
# generated into the volume and reused. Supplying SECRET_KEY_BASE yourself
# overrides this and is what you want if you ever run more than one of these.
if [ -z "${SECRET_KEY_BASE:-}" ]; then
  if [ ! -f "$SECRET_FILE" ]; then
    # 64 bytes, base64: what `mix phx.gen.secret` produces, without needing mix.
    openssl rand -base64 64 | tr -d '\n' > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    [ "$(id -u)" = "0" ] && chown kanban:slipdock "$SECRET_FILE"
    echo "entrypoint: generated a SECRET_KEY_BASE in $SECRET_FILE"
  fi
  SECRET_KEY_BASE="$(cat "$SECRET_FILE")"
  export SECRET_KEY_BASE
fi

# Links in sign-in emails have to point somewhere people can reach. Without
# PHX_HOST the app would say example.com, which is nobody's server.
if [ -z "${PHX_HOST:-}" ]; then
  echo "entrypoint: PHX_HOST is not set, using localhost — sign-in links will" \
       "point at localhost, so set it to the address people actually use."
  PHX_HOST="localhost"
  export PHX_HOST
fi

run() {
  if [ "$(id -u)" = "0" ]; then
    exec setpriv --reuid=kanban --regid=kanban --init-groups "$@"
  else
    exec "$@"
  fi
}

case "${1:-start}" in
  start)
    run /app/bin/kanban start
    ;;
  # A shell in the running app, for looking at things.
  remote|console)
    run /app/bin/kanban "$1"
    ;;
  # The mix tasks are not in a release, so the two worth having are here.
  #   docker compose run --rm slipdock reindex
  #   docker compose run --rm slipdock ai-key you@example.com sk-or-…
  #   docker compose run --rm slipdock setup --status
  reindex)
    run /app/bin/kanban eval "Slipdock.Release.reindex()"
    ;;
  ai-key)
    shift
    # The arguments become an Elixir list of strings. Emails and API keys have
    # no quotes in them, which is the only thing this would not survive.
    args=""
    for a in "$@"; do args="${args}\"${a}\","; done
    run /app/bin/kanban eval "Slipdock.Release.ai_key([${args}])"
    ;;
  migrate)
    run /app/bin/kanban eval "Slipdock.Release.migrate()"
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
    run /app/bin/kanban eval "Slipdock.Release.setup([${args}])"
    ;;
  *)
    run "$@"
    ;;
esac

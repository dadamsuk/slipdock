#!/bin/sh
# Writes the .env that `docker compose up -d` reads, by asking rather than by
# expecting you to know which of a dozen variables matter.
#
#   curl -O https://raw.githubusercontent.com/dadamsuk/slipdock/main/setup.sh
#   sh setup.sh
#
# It only writes .env. It does not start anything, touch Docker, or need the
# rest of the repository — so you can read it first, and running it twice is
# safe.
#
# setup.ps1 beside this is its PowerShell twin, for Windows without WSL.
#
# Answers are read from stdin rather than /dev/tty, so they can be piped: handy
# for rebuilding a server from a script, and the only way to test this file.
set -eu

# Everything this writes holds secrets — the database password, perhaps an SMTP
# one — so it is private from the moment it exists, not after a chmod that
# leaves a window and misses the backup copy.
umask 077

ENV_FILE="${1:-.env}"

say() { printf '%s\n' "$*"; }
ask() {
  # ask <variable> <prompt> [default]
  _var="$1"; _prompt="$2"; _default="${3:-}"
  if [ -n "$_default" ]; then
    printf '%s [%s]: ' "$_prompt" "$_default"
  else
    printf '%s: ' "$_prompt"
  fi
  read -r _answer || _answer=""
  [ -z "$_answer" ] && _answer="$_default"
  eval "$_var=\$_answer"
}
yes_no() {
  # yes_no <variable> <prompt> <default y|n>
  _var="$1"; _prompt="$2"; _default="$3"
  if [ "$_default" = "y" ]; then printf '%s [Y/n]: ' "$_prompt"
  else printf '%s [y/N]: ' "$_prompt"; fi
  read -r _answer || _answer=""
  [ -z "$_answer" ] && _answer="$_default"
  case "$_answer" in [Yy]*) eval "$_var=y" ;; *) eval "$_var=n" ;; esac
}
ask_secret() {
  # ask_secret <variable> <prompt> — as ask, but not echoed while it is typed.
  _var="$1"; _prompt="$2"
  printf '%s: ' "$_prompt"
  if [ -t 0 ]; then
    stty -echo
    trap 'stty echo' EXIT INT TERM
    read -r _answer || _answer=""
    stty echo
    trap - EXIT INT TERM
    printf '\n'
  else
    read -r _answer || _answer=""
  fi
  eval "$_var=\$_answer"
}
# A value from an existing env file, or nothing.
env_value() {
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1
}
# 32 random characters that need no quoting in a URL or a .env.
random_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

say ""
say "Setting up Slipdock. Five questions, then a .env you can edit by hand"
say "afterwards. Press enter to take the suggestion in brackets."
say ""

DB_PASSWORD=""; KEEP_DB_DEFAULT=n
if [ -e "$ENV_FILE" ]; then
  say "There is already a $ENV_FILE here."
  yes_no OVERWRITE "Replace it? (a copy is kept as $ENV_FILE.bak)" n
  if [ "$OVERWRITE" != "y" ]; then
    say "Left alone. Nothing written."
    exit 0
  fi
  rm -f "$ENV_FILE.bak"
  cp "$ENV_FILE" "$ENV_FILE.bak"
  chmod 600 "$ENV_FILE.bak" 2>/dev/null || true
  say "Kept the old one as $ENV_FILE.bak."
  # Postgres sets its password once, when its volume is first created, so an
  # install that already has one must keep it — and one that never set it is
  # still on the old default, which a new password here would lock out.
  DB_PASSWORD="$(env_value "$ENV_FILE" POSTGRES_PASSWORD)"
  [ -n "$DB_PASSWORD" ] || KEEP_DB_DEFAULT=y
  say ""
fi

# 1 ─ the name people type -----------------------------------------------------
say "1. The hostname people will see in the browser's address bar."
say "   Not the domain you own — the exact name they type. If Cloudflare or"
say "   nginx serves this at app.example.com, that is the answer, even when"
say "   you also own example.com."
say "   Sign-in links are built from it, and live updates are refused for any"
say "   other name, so this is the setting that most needs to be right."
ask HOST "   Hostname" "$(hostname 2>/dev/null || echo localhost)"

while [ -z "$HOST" ]; do ask HOST "   Hostname (required)" ""; done

# 2 ─ what sits in front -------------------------------------------------------
say ""
say "2. Is there a TLS proxy in front of it — Cloudflare, Caddy, nginx, a"
say "   tunnel? Answer yes if people reach it over https."
yes_no PROXIED "   Behind https" n

if [ "$PROXIED" = "y" ]; then
  SCHEME="https"
  ask URL_PORT "   Port people connect to" "443"
else
  SCHEME="http"
  URL_PORT=""
fi

# 3 ─ the port this machine listens on -----------------------------------------
say ""
say "3. The port on *this* machine for Slipdock to listen on."
if [ "$PROXIED" = "y" ]; then
  say "   Your proxy forwards to it. It does not need to be reachable from"
  say "   outside, so the suggestion listens on this machine only. If the"
  say "   proxy is on another machine, answer 4000 to listen on every address."
  ask PUBLISH "   Listen on" "127.0.0.1:4000"
else
  ask PUBLISH "   Listen on" "4000"
fi

# When nothing is in front, the port people connect to is the one it listens on.
if [ "$PROXIED" != "y" ]; then
  URL_PORT="$(printf '%s' "$PUBLISH" | sed 's/.*://')"
fi

# 4 ─ who runs it --------------------------------------------------------------
say ""
say "4. Your email address. Setting it makes you the admin and skips the"
say "   browser setup wizard; leave it empty to use the wizard instead."
ask ADMIN "   Admin email" ""

# 5 ─ mail ---------------------------------------------------------------------
say ""
say "5. A mail server, so sign-in codes can be emailed. Without one they are"
say "   written to the log, which is fine for a server only you use."
yes_no WANT_MAIL "   Set up email now" n

SMTP_HOST=""; SMTP_PORT=""; SMTP_USER=""; SMTP_PASS=""; SMTP_FROM=""
if [ "$WANT_MAIL" = "y" ]; then
  ask SMTP_HOST "   SMTP host" ""
  ask SMTP_PORT "   SMTP port" "587"
  ask SMTP_FROM "   Send from" "${ADMIN:-slipdock@$HOST}"
  ask SMTP_USER "   Username (empty for an IP-authorised relay)" ""
  [ -n "$SMTP_USER" ] && ask_secret SMTP_PASS "   Password (not shown)"
fi

# The bundled Postgres' password. A new install gets a random one rather than
# the published default.
[ -n "$DB_PASSWORD" ] || [ "$KEEP_DB_DEFAULT" = y ] || DB_PASSWORD="$(random_password)"

# ─ write it out ---------------------------------------------------------------
{
  echo "# Written by setup.sh on $(date -u '+%Y-%m-%d %H:%M UTC')."
  echo "# Edit freely; .env.example lists every setting with its default."
  echo "#"
  echo "# After changing anything here: docker compose up -d"
  echo "# Not 'restart' — that reuses the container and re-reads nothing."
  echo ""
  echo "PHX_HOST=$HOST"
  echo "SLIPDOCK_PUBLISH=$PUBLISH"
  echo "SLIPDOCK_URL_SCHEME=$SCHEME"
  echo "SLIPDOCK_URL_PORT=$URL_PORT"
  [ -n "$ADMIN" ] && echo "SLIPDOCK_ADMIN_EMAIL=$ADMIN"
  echo ""
  if [ "$KEEP_DB_DEFAULT" = y ]; then
    echo "# The database password is still compose.yaml's default. Postgres only"
    echo "# reads POSTGRES_PASSWORD when its volume is first created, so change it"
    echo "# with ALTER USER inside the database before setting it here."
  else
    echo "# Read by Postgres once, when its volume is first created; see compose.yaml."
    echo "POSTGRES_PASSWORD=$DB_PASSWORD"
  fi
  if [ -n "$SMTP_HOST" ]; then
    echo ""
    echo "SLIPDOCK_SMTP_HOST=$SMTP_HOST"
    echo "SLIPDOCK_SMTP_PORT=$SMTP_PORT"
    echo "SLIPDOCK_SMTP_FROM=$SMTP_FROM"
    [ -n "$SMTP_USER" ] && echo "SLIPDOCK_SMTP_USER=$SMTP_USER"
    [ -n "$SMTP_PASS" ] && echo "SLIPDOCK_SMTP_PASSWORD=$SMTP_PASS"
  fi
} > "$ENV_FILE"

# umask covers a new file; an existing one keeps the mode it had.
chmod 600 "$ENV_FILE" 2>/dev/null || true

say ""
say "Written $ENV_FILE:"
say ""
sed 's/^\(SLIPDOCK_SMTP_PASSWORD=\).*/\1********/; s/^\(POSTGRES_PASSWORD=\).*/\1********/; s/^/    /' "$ENV_FILE"
say ""
say "Slipdock will answer to ${SCHEME}://${HOST}$([ "$URL_PORT" = "443" ] || [ "$URL_PORT" = "80" ] && echo "" || echo ":${URL_PORT}")"
say ""
say "Next:"
say "    docker compose up -d"
say "    docker compose logs -f slipdock"
say ""
if [ -z "$ADMIN" ]; then
  say "The log will show a setup wizard link with a one-time token. Open it."
else
  say "You are the admin ($ADMIN). Ask for a sign-in code at the login page;"
  say "with no mail server configured it is written to the log."
fi
say ""

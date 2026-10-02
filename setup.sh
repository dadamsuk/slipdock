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
# Answers are read from stdin rather than /dev/tty, so they can be piped: handy
# for rebuilding a server from a script, and the only way to test this file.
set -eu

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

say ""
say "Setting up Slipdock. Five questions, then a .env you can edit by hand"
say "afterwards. Press enter to take the suggestion in brackets."
say ""

if [ -e "$ENV_FILE" ]; then
  say "There is already a $ENV_FILE here."
  yes_no OVERWRITE "Replace it? (a copy is kept as $ENV_FILE.bak)" n
  if [ "$OVERWRITE" != "y" ]; then
    say "Left alone. Nothing written."
    exit 0
  fi
  cp "$ENV_FILE" "$ENV_FILE.bak"
  say "Kept the old one as $ENV_FILE.bak."
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
  say "   outside, and 127.0.0.1:4000 is a good answer if the proxy is local."
fi
ask PUBLISH "   Listen on" "4000"

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
  [ -n "$SMTP_USER" ] && ask SMTP_PASS "   Password" ""
fi

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
  if [ -n "$SMTP_HOST" ]; then
    echo ""
    echo "SLIPDOCK_SMTP_HOST=$SMTP_HOST"
    echo "SLIPDOCK_SMTP_PORT=$SMTP_PORT"
    echo "SLIPDOCK_SMTP_FROM=$SMTP_FROM"
    [ -n "$SMTP_USER" ] && echo "SLIPDOCK_SMTP_USER=$SMTP_USER"
    [ -n "$SMTP_PASS" ] && echo "SLIPDOCK_SMTP_PASSWORD=$SMTP_PASS"
  fi
} > "$ENV_FILE"

# It can hold an SMTP password.
chmod 600 "$ENV_FILE" 2>/dev/null || true

say ""
say "Written $ENV_FILE:"
say ""
sed 's/^\(SLIPDOCK_SMTP_PASSWORD=\).*/\1********/; s/^/    /' "$ENV_FILE"
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

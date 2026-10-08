#!/bin/sh
# Installs slipdock-runner: takes jobs from a Slipdock board's runner queue
# and runs a coding agent on them, on this machine. Needs sh and curl.
#
#   curl -fsSL https://your-server/runner/install.sh | sh -s -- \
#     --url https://your-server --token sdr_... [options]
#
# The same file for everybody: nothing in it depends on who fetched it, and
# its SHA-256 is published beside it (/runner/SHA256SUMS), so it can be
# checked before it is run. It writes, for this user only:
#
#   ~/.local/bin/slipdock-runner              the runner
#   ~/.config/slipdock-runner/config          its settings and job kinds (mode 600)
#   ~/.config/systemd/user/slipdock-runner.service   (Linux, with systemd), or
#   ~/Library/LaunchAgents/us.slipdock.runner.plist  (macOS)
#
# Options:
#   --url URL              the Slipdock server (required)
#   --token TOKEN          the runner's token, sdr_... (required the first time;
#                          left out, the one in the config already there is kept)
#   --pool NAME            the pool it takes jobs for (default: default)
#   --agent claude|codex|custom   what a job runs (default: claude)
#   --kind NAME            the job kind that runs it (default: the agent's name)
#   --command CMD          for --agent custom: the command, run with sh -c;
#                          the prompt is in $SLIPDOCK_PROMPT
#   --cwd DIR              where jobs run (default: your home)
#   --permission-mode M    for claude: its --permission-mode (default: acceptEdits)
#   --timeout SECONDS      the longest a job may run (default: 3600)
#   --service auto|systemd|launchd|none   how it keeps running (default: auto)
#   --instructions TEXT    standing instructions, added after every job's prompt
#   --before-job CMD       shell run before each job; the job runs only if it succeeds
#   --after-job CMD        shell run after each job, however it ended, with
#                          $SLIPDOCK_EXIT and $SLIPDOCK_STATUS (done, failed,
#                          cancelled or timeout)
#   --no-start             write everything, start nothing
#
# Nothing here runs as root, and nothing outside your home is touched.
set -eu

URL=
TOKEN=
POOL=default
AGENT=claude
KIND=
COMMAND=
CWD=$HOME
PERMISSION_MODE=acceptEdits
TIMEOUT=3600
SERVICE=auto
START=1
INSTRUCTIONS=
BEFORE_JOB=
AFTER_JOB=

die() {
  echo "slipdock-runner install: $*" >&2
  exit 1
}

need() { [ $# -ge 2 ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --url) need "$@"; URL=$2; shift 2 ;;
    --token) need "$@"; TOKEN=$2; shift 2 ;;
    --pool) need "$@"; POOL=$2; shift 2 ;;
    --agent) need "$@"; AGENT=$2; shift 2 ;;
    --kind) need "$@"; KIND=$2; shift 2 ;;
    --command) need "$@"; COMMAND=$2; shift 2 ;;
    --cwd) need "$@"; CWD=$2; shift 2 ;;
    --permission-mode) need "$@"; PERMISSION_MODE=$2; shift 2 ;;
    --timeout) need "$@"; TIMEOUT=$2; shift 2 ;;
    --service) need "$@"; SERVICE=$2; shift 2 ;;
    --no-start) START=; shift ;;
    --instructions) need "$@"; INSTRUCTIONS=$2; shift 2 ;;
    --before-job) need "$@"; BEFORE_JOB=$2; shift 2 ;;
    --after-job) need "$@"; AFTER_JOB=$2; shift 2 ;;
    -h | --help) sed -n '2,33p' "$0" 2>/dev/null || echo "see the comments at the top of install.sh"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done

[ -n "$URL" ] || die "--url is required: the Slipdock server's address"
CONFIG_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/slipdock-runner/config
# Installing again with new settings keeps the token it has.
if [ -z "$TOKEN" ] && [ -r "$CONFIG_FILE" ]; then
  TOKEN=$( (. "$CONFIG_FILE" >/dev/null 2>&1 && printf '%s' "${SLIPDOCK_RUNNER_TOKEN:-}") || true)
fi
[ -n "$TOKEN" ] || die "--token is required: make a runner on the board to get one"
case "$URL" in http://* | https://*) ;; *) die "--url must start with http:// or https://" ;; esac
case "$POOL" in '' | *[!a-z0-9_-]*) die "--pool must be lower case letters, digits, - or _" ;; esac
case "$AGENT" in claude | codex | custom) ;; *) die "--agent must be claude, codex or custom" ;; esac
[ -n "$KIND" ] || KIND=$AGENT
case "$KIND" in '' | *[!a-z0-9_-]*) die "--kind must be lower case letters, digits, - or _" ;; esac
case "$TIMEOUT" in '' | *[!0-9]*) die "--timeout must be a number of seconds" ;; esac
[ "$AGENT" != custom ] || [ -n "$COMMAND" ] || die "--agent custom needs --command"
case "$SERVICE" in auto | systemd | launchd | none) ;; *) die "--service must be auto, systemd, launchd or none" ;; esac
command -v curl >/dev/null 2>&1 || die "curl is needed and was not found"

# Single quotes around anything, with any quote in it closed, escaped and
# reopened: inside them the shell reads nothing.
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# A heredoc delimiter the text can't contain: random, and drawn again in the
# unlikely event it is in there.
delimiter() {
  while :; do
    d=SLIPDOCK_EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    case "$1" in *"$d"*) ;; *) printf '%s' "$d"; return ;; esac
  done
}

FN=job_$(printf '%s' "$KIND" | tr '-' '_')
BIN_DIR=$HOME/.local/bin
CONF_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/slipdock-runner
BIN=$BIN_DIR/slipdock-runner
CONFIG=$CONF_DIR/config

mkdir -p "$BIN_DIR" "$CONF_DIR"

# The runner itself.
cat >"$BIN.tmp" <<'SLIPDOCK_RUNNER_EOF'
__SLIPDOCK_RUNNER__
SLIPDOCK_RUNNER_EOF
chmod 755 "$BIN.tmp"
mv "$BIN.tmp" "$BIN"

# A service has almost nothing on its PATH, so the agent is found now, while
# the person's own PATH is here to find it with.
agent_bin() {
  found=$(command -v "$1" 2>/dev/null || true)
  if [ -z "$found" ]; then
    echo "slipdock-runner install: warning: $1 is not on your PATH; jobs will fail until it is" >&2
    found=$1
  fi
  printf '%s' "$found"
}

case "$AGENT" in
  claude)
    AGENT_BIN=$(agent_bin claude)
    JOB="$FN() {
  cd \"\$WORKDIR\" || exit 1
  \"\$AGENT_BIN\" -p \"\$SLIPDOCK_PROMPT\" --permission-mode \"\$PERMISSION_MODE\"
}"
    ;;
  codex)
    AGENT_BIN=$(agent_bin codex)
    JOB="$FN() {
  cd \"\$WORKDIR\" || exit 1
  \"\$AGENT_BIN\" exec \"\$SLIPDOCK_PROMPT\"
}"
    ;;
  custom)
    AGENT_BIN=
    JOB="$FN() {
  cd \"\$WORKDIR\" || exit 1
  sh -c \"\$CUSTOM_COMMAND\"
}"
    ;;
esac

# A config already there is kept beside the new one, never lost.
if [ -e "$CONFIG" ]; then
  cp -p "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d%H%M%S)"
fi

# Standing instructions go in a quoted heredoc — inside it nothing is
# expanded or run — inside a function, which every sh parses the same way.
EXTRA=
if [ -n "$INSTRUCTIONS" ]; then
  D=$(delimiter "$INSTRUCTIONS")
  EXTRA="$EXTRA
# Added after every job's prompt.
job_instructions() {
  cat <<'$D'
$INSTRUCTIONS
$D
}
JOB_INSTRUCTIONS=\$(job_instructions)
"
fi
if [ -n "$BEFORE_JOB" ]; then
  EXTRA="$EXTRA
# Runs before each job; the job runs only if this succeeds.
before_job() {
$BEFORE_JOB
}
"
fi
if [ -n "$AFTER_JOB" ]; then
  EXTRA="$EXTRA
# Runs after each job however it ended, with \$SLIPDOCK_EXIT and \$SLIPDOCK_STATUS
# (done, failed, cancelled or timeout).
after_job() {
$AFTER_JOB
}
"
fi

umask 077
cat >"$CONFIG.tmp" <<EOF
# slipdock-runner config — written by install.sh, yours to edit. It is sourced
# by sh, so it is shell. It holds the runner's token: keep it mode 600.
#
# A job of kind K runs the function job_K below (a - in K is an _ here). The
# server never says what to run: a kind with no function here is refused.
# Each job gets SLIPDOCK_PROMPT, SLIPDOCK_JOB_ID, SLIPDOCK_JOB_KIND,
# SLIPDOCK_CARD and SLIPDOCK_CARD_URL in its environment; pass the prompt on
# only ever as "\$SLIPDOCK_PROMPT", in double quotes.

SLIPDOCK_URL=$(q "$URL")
SLIPDOCK_RUNNER_TOKEN=$(q "$TOKEN")
POOL=$(q "$POOL")
WORKDIR=$(q "$CWD")
JOB_TIMEOUT=$TIMEOUT
PERMISSION_MODE=$(q "$PERMISSION_MODE")
AGENT_BIN=$(q "$AGENT_BIN")
CUSTOM_COMMAND=$(q "$COMMAND")
PATH=$(q "$PATH")
export PATH CUSTOM_COMMAND

$JOB

# A kind to try the pipeline with: queue a job of kind echo and its output is
# the prompt it was sent.
job_echo() {
  printf '%s\n' "\$SLIPDOCK_PROMPT"
}
$EXTRA
EOF
chmod 600 "$CONFIG.tmp"
mv "$CONFIG.tmp" "$CONFIG"
umask 022

if [ "$SERVICE" = auto ]; then
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    SERVICE=launchd
  elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    SERVICE=systemd
  else
    SERVICE=none
  fi
fi

echo "slipdock-runner: installed $BIN"
echo "slipdock-runner: config in $CONFIG (pool $POOL, kind $KIND)"

case "$SERVICE" in
  systemd)
    UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
    mkdir -p "$UNIT_DIR"
    cat >"$UNIT_DIR/slipdock-runner.service" <<EOF
[Unit]
Description=Slipdock runner (pool $POOL)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
    echo "slipdock-runner: systemd user unit in $UNIT_DIR/slipdock-runner.service"
    if [ -n "$START" ]; then
      systemctl --user daemon-reload
      systemctl --user enable --now slipdock-runner.service
      echo "slipdock-runner: started. Logs: journalctl --user -u slipdock-runner -f"
      echo "slipdock-runner: to keep it running while you are logged out: loginctl enable-linger $(id -un)"
    else
      echo "slipdock-runner: start it with: systemctl --user enable --now slipdock-runner"
    fi
    ;;
  launchd)
    AGENTS=$HOME/Library/LaunchAgents
    PLIST=$AGENTS/us.slipdock.runner.plist
    mkdir -p "$AGENTS" "$HOME/Library/Logs"
    cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>us.slipdock.runner</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/slipdock-runner.log</string>
</dict>
</plist>
EOF
    echo "slipdock-runner: launchd agent in $PLIST"
    if [ -n "$START" ]; then
      launchctl unload "$PLIST" 2>/dev/null || true
      launchctl load -w "$PLIST"
      echo "slipdock-runner: started. Logs: ~/Library/Logs/slipdock-runner.log"
    else
      echo "slipdock-runner: start it with: launchctl load -w $PLIST"
    fi
    ;;
  none)
    echo "slipdock-runner: no service manager set up. Run it with:"
    echo "  nohup $BIN >>\$HOME/slipdock-runner.log 2>&1 &"
    ;;
esac

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
# One machine can run several runners — one per board, say — each installed
# with its own --name: runner NAME has config-NAME, slipdock-runner-NAME.service
# and us.slipdock.runner.NAME, and the others are left alone.
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
#   --cwd DIR              where jobs run (default: your home); ~/… is your home,
#                          even quoted
#   --permission-mode M    for claude: its --permission-mode (default: acceptEdits)
#   --mcp-servers A,B      for claude: the Slipdock MCP servers whose tools a job
#                          may use without asking, as Claude Code names them
#                          (default: claude_ai_Slipdock,slipdock); '' for none
#   --timeout SECONDS      the longest a job may run (default: 3600)
#   --service auto|systemd|launchd|none   how it keeps running (default: auto)
#   --instructions TEXT    standing instructions, added after every job's prompt
#   --before-job CMD       shell run before each job; the job runs only if it succeeds
#   --after-job CMD        shell run after each job, however it ended, with
#                          $SLIPDOCK_EXIT and $SLIPDOCK_STATUS (done, failed,
#                          cancelled or timeout)
#   --name NAME            this runner's name on this machine, so it runs beside
#                          the others (default: none, the machine's one runner)
#   --replace              replace the config even if it is another runner's
#                          (another server or pool); kept beside it as a .bak
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
MCP_SERVERS=claude_ai_Slipdock,slipdock
TIMEOUT=3600
SERVICE=auto
START=1
INSTRUCTIONS=
BEFORE_JOB=
AFTER_JOB=
NAME=
REPLACE=

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
    --mcp-servers) need "$@"; MCP_SERVERS=$2; shift 2 ;;
    --timeout) need "$@"; TIMEOUT=$2; shift 2 ;;
    --service) need "$@"; SERVICE=$2; shift 2 ;;
    --no-start) START=; shift ;;
    --name) need "$@"; NAME=$2; shift 2 ;;
    --replace) REPLACE=1; shift ;;
    --instructions) need "$@"; INSTRUCTIONS=$2; shift 2 ;;
    --before-job) need "$@"; BEFORE_JOB=$2; shift 2 ;;
    --after-job) need "$@"; AFTER_JOB=$2; shift 2 ;;
    -h | --help) sed -n '2,50p' "$0" 2>/dev/null || echo "see the comments at the top of install.sh"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done

[ -n "$URL" ] || die "--url is required: the Slipdock server's address"
case "$NAME" in *[!a-z0-9_-]* | [!a-z0-9]*) die "--name must be lower case letters, digits, - or _" ;; esac
CONF_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/slipdock-runner
# What this runner's files are called: unnamed, the machine's one runner.
if [ -n "$NAME" ]; then
  CONFIG=$CONF_DIR/config-$NAME
  UNIT=slipdock-runner-$NAME
  LABEL=us.slipdock.runner.$NAME
else
  CONFIG=$CONF_DIR/config
  UNIT=slipdock-runner
  LABEL=us.slipdock.runner
fi

# A setting of the config already there, read the way the runner reads it.
existing() {
  (. "$CONFIG" >/dev/null 2>&1 && eval "printf '%s' \"\${$1:-}\"") || true
}

if [ -r "$CONFIG" ]; then
  # Another server or pool is another runner: installing over it would stop
  # it, so that takes --replace — or a --name of its own, to run beside it.
  OLD_URL=$(existing SLIPDOCK_URL)
  OLD_POOL=$(existing POOL)
  if [ -z "$REPLACE" ] && { [ "${OLD_URL%/}" != "${URL%/}" ] || { [ -n "$OLD_POOL" ] && [ "$OLD_POOL" != "$POOL" ]; }; }; then
    die "$CONFIG is another runner's (${OLD_POOL:+pool $OLD_POOL on }$OLD_URL), and installing would replace it. To run this one beside it, give it a name: --name NAME. To replace it, add --replace."
  fi
  # Installing again with new settings keeps the token it has.
  [ -n "$TOKEN" ] || TOKEN=$(existing SLIPDOCK_RUNNER_TOKEN)
fi
[ -n "$TOKEN" ] || die "--token is required: make a runner on the board to get one"
case "$URL" in http://* | https://*) ;; *) die "--url must start with http:// or https://" ;; esac
case "$POOL" in '' | *[!a-z0-9_-]*) die "--pool must be lower case letters, digits, - or _" ;; esac
case "$AGENT" in claude | codex | custom) ;; *) die "--agent must be claude, codex or custom" ;; esac
[ -n "$KIND" ] || KIND=$AGENT
case "$KIND" in '' | *[!a-z0-9_-]*) die "--kind must be lower case letters, digits, - or _" ;; esac
case "$CWD" in
  '~' | '~/'*) ;;
  '~'*) die "--cwd can't be another user's ~: use a full path, or ~/ for the runner's own home" ;;
esac
case "$TIMEOUT" in '' | *[!0-9]*) die "--timeout must be a number of seconds" ;; esac
[ "$AGENT" != custom ] || [ -n "$COMMAND" ] || die "--agent custom needs --command"
case "$SERVICE" in auto | systemd | launchd | none) ;; *) die "--service must be auto, systemd, launchd or none" ;; esac
case "$MCP_SERVERS" in *[!A-Za-z0-9_,-]*) die "--mcp-servers must be names of letters, digits, - or _, separated by commas" ;; esac
command -v curl >/dev/null 2>&1 || die "curl is needed and was not found"

# Single quotes around anything, with any quote in it closed, escaped and
# reopened: inside them the shell reads nothing.
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# The working directory as the config spells it: ~ and ~/… become "$HOME",
# which sh would not expand inside the quotes.
workdir() {
  case "$1" in
    '~') printf '"$HOME"' ;;
    '~/'*) printf '"$HOME"/%s' "$(q "${1#??}")" ;;
    *) q "$1" ;;
  esac
}

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
BIN=$BIN_DIR/slipdock-runner
# A named runner is told its config; the machine's one runner finds it.
RUN=$BIN
[ -z "$NAME" ] || RUN="$BIN --config=$CONFIG"

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

# Every tool of each Slipdock MCP server: in -p nobody is there to approve one.
ALLOWED_TOOLS=
for server in $(printf '%s' "$MCP_SERVERS" | tr ',' ' '); do
  ALLOWED_TOOLS=${ALLOWED_TOOLS:+$ALLOWED_TOOLS,}mcp__$server
done

case "$AGENT" in
  claude)
    AGENT_BIN=$(agent_bin claude)
    ALLOW=
    [ -z "$ALLOWED_TOOLS" ] || ALLOW=' --allowedTools "$ALLOWED_TOOLS"'
    JOB="$FN() {
  cd \"\$WORKDIR\" || exit 1
  \"\$AGENT_BIN\" -p \"\$SLIPDOCK_PROMPT\" --permission-mode \"\$PERMISSION_MODE\"$ALLOW
}"
    ;;
  codex)
    ALLOWED_TOOLS=
    AGENT_BIN=$(agent_bin codex)
    JOB="$FN() {
  cd \"\$WORKDIR\" || exit 1
  \"\$AGENT_BIN\" exec \"\$SLIPDOCK_PROMPT\"
}"
    ;;
  custom)
    ALLOWED_TOOLS=
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
WORKDIR=$(workdir "$CWD")
JOB_TIMEOUT=$TIMEOUT
PERMISSION_MODE=$(q "$PERMISSION_MODE")
ALLOWED_TOOLS=$(q "$ALLOWED_TOOLS")
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
echo "slipdock-runner: config in $CONFIG (pool $POOL, kind $KIND${NAME:+, name $NAME})"

case "$SERVICE" in
  systemd)
    UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
    mkdir -p "$UNIT_DIR"
    cat >"$UNIT_DIR/$UNIT.service" <<EOF
[Unit]
Description=Slipdock runner ${NAME:+$NAME }(pool $POOL)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$RUN
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
    echo "slipdock-runner: systemd user unit in $UNIT_DIR/$UNIT.service"
    if [ -n "$START" ]; then
      systemctl --user daemon-reload
      # Restarted, not just started: installing again changes what it runs.
      systemctl --user enable "$UNIT.service"
      systemctl --user restart "$UNIT.service"
      echo "slipdock-runner: started. Logs: journalctl --user -u $UNIT -f"
      echo "slipdock-runner: to keep it running while you are logged out: loginctl enable-linger $(id -un)"
    else
      echo "slipdock-runner: start it with: systemctl --user enable --now $UNIT"
    fi
    ;;
  launchd)
    AGENTS=$HOME/Library/LaunchAgents
    PLIST=$AGENTS/$LABEL.plist
    PROGRAM="<string>$BIN</string>"
    [ -z "$NAME" ] || PROGRAM="$PROGRAM<string>--config=$CONFIG</string>"
    mkdir -p "$AGENTS" "$HOME/Library/Logs"
    cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>$PROGRAM</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/$UNIT.log</string>
</dict>
</plist>
EOF
    echo "slipdock-runner: launchd agent in $PLIST"
    if [ -n "$START" ]; then
      launchctl unload "$PLIST" 2>/dev/null || true
      launchctl load -w "$PLIST"
      echo "slipdock-runner: started. Logs: ~/Library/Logs/$UNIT.log"
    else
      echo "slipdock-runner: start it with: launchctl load -w $PLIST"
    fi
    ;;
  none)
    echo "slipdock-runner: no service manager set up. Run it with:"
    echo "  nohup $RUN >>\$HOME/$UNIT.log 2>&1 &"
    ;;
esac

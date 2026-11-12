#!/bin/sh
# Installs the slipdock command on this Linux or macOS machine, for you alone,
# from __SLIPDOCK_BASE_COMMENT__:
#
#   curl -fsSL __SLIPDOCK_BASE_COMMENT__/cli/install.sh | sh
#       install it, or update it: running it again fetches the CLI afresh
#   curl -fsSL __SLIPDOCK_BASE_COMMENT__/cli/install.sh | sh -s /some/where/slipdock
#       install it somewhere other than ~/.local/bin/slipdock
#
# This is the CLI. The agent skills are a different script, the server's
# /install.sh (no /cli/ in it).
#
# It writes, with no root of its own:
#   ~/.local/bin/slipdock     the CLI (or the path you gave), checked against
#                             /cli/SHA256SUMS, and against the release key's
#                             signature when the server serves one
#   ~/.config/slipdock/url    this server's address (unless it names another)
#
# The CLI is an Erlang escript, so it needs Erlang/OTP 27 or later. If there
# is none this stops and says how to install it (brew on macOS, your
# distribution's package on Linux): it never runs anything as root itself.
set -eu

BASE='__SLIPDOCK_BASE__'
# The public half of the project's release key (SlipdockWeb.CLIInstallController
# writes it in), for /cli/slipdock.escript.sig. Empty on a server built without it.
RELEASE_KEY='__SLIPDOCK_RELEASE_KEY__'
DEST="${1:-$HOME/.local/bin/slipdock}"

say() { printf 'slipdock: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

# Erlang first, so a machine without it is told before anything is fetched
# or written.
erlang_help() {
  case $(uname -s) in
    Darwin)
      echo "  brew install erlang        (Homebrew: https://brew.sh)"
      ;;
    Linux)
      id=''
      like=''
      if [ -r /etc/os-release ]; then
        id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
        like=$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"')
      fi
      case " $id $like " in
        *" debian "* | *" ubuntu "*) echo "  sudo apt-get install erlang-nox" ;;
        *" fedora "* | *" rhel "* | *" centos "*) echo "  sudo dnf install erlang" ;;
        *" arch "*) echo "  sudo pacman -S erlang" ;;
        *" alpine "*) echo "  sudo apk add erlang" ;;
        *" suse "* | *" opensuse "*) echo "  sudo zypper install erlang" ;;
        *) echo "  your distribution's erlang package" ;;
      esac
      echo "  (if its Erlang is older than 27: https://www.erlang.org/downloads, or asdf/mise)"
      ;;
    *)
      echo "  https://www.erlang.org/downloads"
      ;;
  esac
}

if ! command -v erl >/dev/null 2>&1 || ! command -v escript >/dev/null 2>&1; then
  say "Erlang/OTP 27 or later is needed and was not found; nothing was installed."
  say "Install it, then run this again:"
  erlang_help >&2
  exit 1
fi

otp=$(erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)),halt().' 2>/dev/null || true)
case $otp in
  '' | *[!0-9]*) say "warning: couldn't tell which Erlang/OTP $(command -v erl) is; the CLI needs 27 or later" ;;
  *)
    if [ "$otp" -lt 27 ]; then
      say "$(command -v erl) is Erlang/OTP $otp; the CLI needs 27 or later. Nothing was installed."
      say "Update it, then run this again:"
      erlang_help >&2
      exit 1
    fi
    ;;
esac

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL -o "$2" "$BASE/$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$BASE/$1"; }
else
  die "needs curl or wget"
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die "needs sha256sum or shasum to check what it downloads"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

fetch cli/SHA256SUMS "$tmp/SHA256SUMS" ||
  die "can't download $BASE/cli/SHA256SUMS (a server built without the slipdock CLI answers 404); nothing was installed"
want=$(sed -n 's/^\([0-9a-f]\{64\}\)  *slipdock\.escript *$/\1/p' "$tmp/SHA256SUMS" | head -n 1)
[ -n "$want" ] || die "$BASE/cli/SHA256SUMS has no checksum for slipdock.escript; nothing was installed"

fetch cli/slipdock.escript "$tmp/slipdock.escript" ||
  die "can't download $BASE/cli/slipdock.escript; nothing was installed"
got=$(sha256 "$tmp/slipdock.escript")
[ "$got" = "$want" ] ||
  die "the CLI downloaded from $BASE does not match its published checksum (got $got, expected $want); nothing was installed"

# A signed release serves a signature beside it; a server built from source
# has none (404), and the checksum is all there is to go on.
if fetch cli/slipdock.escript.sig "$tmp/slipdock.escript.sig" 2>/dev/null; then
  case $RELEASE_KEY in
    ssh-ed25519\ *) ;;
    *) die "$BASE serves a signature but this installer has no release key to check it with; nothing was installed" ;;
  esac
  if command -v ssh-keygen >/dev/null 2>&1; then
    printf 'slipdock-release namespaces="slipdock-cli" %s\n' "$RELEASE_KEY" >"$tmp/allowed_signers"
    if ! ssh-keygen -Y verify -f "$tmp/allowed_signers" -I slipdock-release -n slipdock-cli \
      -s "$tmp/slipdock.escript.sig" <"$tmp/slipdock.escript" >"$tmp/verify.out" 2>&1; then
      cat "$tmp/verify.out" >&2
      die "REFUSED: the CLI from $BASE is not signed with the project's release key; nothing was installed"
    fi
    say "signature checked against the release key"
  else
    say "warning: no ssh-keygen here, so the signature wasn't checked (the checksum was)"
  fi
fi

# Into the same folder first, so the move is one rename and a running
# slipdock never sees half a file.
dir=$(dirname "$DEST")
mkdir -p "$dir"
part="$dir/.slipdock.$$.part"
cp "$tmp/slipdock.escript" "$part"
chmod 755 "$part"
mv -f "$part" "$DEST"

# A url already pointing somewhere else is left alone: the token beside it
# belongs to that server, and quietly re-pointing it would send the token
# here on the next call.
CONF="$HOME/.config/slipdock"
mkdir -p "$CONF"
chmod 700 "$CONF"
CURRENT="$(cat "$CONF/url" 2>/dev/null || true)"
if [ -z "$CURRENT" ]; then
  (umask 077 && printf '%s\n' "$BASE" >"$CONF/url")
elif [ "$CURRENT" != "$BASE" ]; then
  say "$CONF/url already names $CURRENT; left it alone."
  say "  To use this server: slipdock url $BASE"
fi

echo "slipdock: installed $DEST"
case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "slipdock: $dir is not on your PATH; add it (export PATH=\"$dir:\$PATH\") or run $DEST" ;;
esac
cat <<'NEXT'

Next, sign in (it shows a code to approve in your browser):

  slipdock auth
  slipdock whoami
NEXT

#!/bin/sh
# Installs slipdock-runner, the Slipdock runner daemon, on Linux (WSL
# included) or macOS:
#
#   curl -fsSL https://github.com/dadamsuk/slipdock/releases/latest/download/install.sh | sh
#
# It downloads the latest release's manifest and its signature, checks the
# signature against the project's release key written into this script
# (with ssh-keygen -Y verify, which OpenSSH has), and only then downloads
# the binary for this machine, checks its SHA-256 against the signed
# manifest and puts it in place. Nothing unchecked is ever installed.
#
# What this can't do is vouch for itself: the key comes inside this script,
# so the first install is only as trustworthy as the download of the
# script. After that the daemon checks every update against the key built
# into it, whichever host serves the update. (The manual's Machines page.)
#
#   SLIPDOCK_RUNNER_BIN     where to put it (default ~/.local/bin)
#   SLIPDOCK_RUNNER_SOURCE  where releases come from (default: GitHub);
#                           https only, unless --allow-http is given
#
#   --allow-http  allow a plain http:// SLIPDOCK_RUNNER_SOURCE, such as a
#                 release host on this machine (curl -fsSL <url> | sh -s -- --allow-http)
set -eu

# Written in by the release job from daemon/internal/release/release_key.pub.
RELEASE_KEY='__SLIPDOCK_RELEASE_KEY__'
SOURCE=${SLIPDOCK_RUNNER_SOURCE:-https://github.com/dadamsuk/slipdock/releases/latest/download}
BIN=${SLIPDOCK_RUNNER_BIN:-$HOME/.local/bin}

say() { printf 'slipdock-runner install: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

allow_http=
for arg in "$@"; do
  case $arg in
    --allow-http) allow_http=1 ;;
    *) die "unknown option $arg (the one there is: --allow-http)" ;;
  esac
done

# Plain http would let anyone on the way swap what is downloaded. The
# signature check still refuses a swapped release, but https is the rule
# and http needs saying so (#2797).
case $SOURCE in
  https://*) protos='=https' ;;
  http://*)
    [ -n "$allow_http" ] ||
      die "$SOURCE is plain http: use https, or pass --allow-http (curl -fsSL <url> | sh -s -- --allow-http)"
    say "warning: downloading over plain http from $SOURCE (--allow-http)"
    protos='=https,http'
    ;;
  *) die "$SOURCE is not an https:// address" ;;
esac

case $RELEASE_KEY in
  ssh-ed25519\ *) ;;
  *) die "this installer has no release key, so it can't check what it downloads: use the install.sh from a release" ;;
esac

case $(uname -s) in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) die "$(uname -s) isn't supported here: on Windows, use install.ps1" ;;
esac
case $(uname -m) in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) die "no build for $(uname -m)" ;;
esac

command -v ssh-keygen >/dev/null 2>&1 ||
  die "needs ssh-keygen (OpenSSH 8.1 or later) to check the release's signature"

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL --proto "$protos" --proto-redir "$protos" -o "$2" "$SOURCE/$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$SOURCE/$1"; }
else
  die "needs curl or wget"
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
else
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

fetch release.json "$tmp/release.json" || die "can't download release.json from $SOURCE"
fetch release.json.sig "$tmp/release.json.sig" || die "can't download release.json.sig from $SOURCE"

printf 'slipdock-release namespaces="slipdock-runner" %s\n' "$RELEASE_KEY" >"$tmp/allowed_signers"
if ! ssh-keygen -Y verify -f "$tmp/allowed_signers" -I slipdock-release -n slipdock-runner \
  -s "$tmp/release.json.sig" <"$tmp/release.json" >"$tmp/verify.out" 2>&1; then
  cat "$tmp/verify.out" >&2
  die "REFUSED: release.json from $SOURCE is not signed with the project's release key; nothing was installed"
fi

# Signed, so its lines are the project's: one platform to a line.
version=$(sed -n 's/^  "version": "\(v[0-9][0-9A-Za-z.-]*\)",$/\1/p' "$tmp/release.json")
line=$(grep "^    \"$os/$arch\": " "$tmp/release.json" || true)
name=$(printf '%s\n' "$line" | sed -n 's/.*"name": "\([A-Za-z0-9._-]*\)".*/\1/p')
want=$(printf '%s\n' "$line" | sed -n 's/.*"sha256": "\([0-9a-f]\{64\}\)".*/\1/p')
[ -n "$version" ] && [ -n "$name" ] && [ -n "$want" ] || die "release ${version:-?} has no build for $os/$arch"

fetch "$name" "$tmp/slipdock-runner" || die "can't download $name from $SOURCE"
got=$(sha256 "$tmp/slipdock-runner")
[ "$got" = "$want" ] ||
  die "REFUSED: $name's SHA-256 is $got, but the signed manifest says $want; nothing was installed"

mkdir -p "$BIN"
chmod 755 "$tmp/slipdock-runner"
mv "$tmp/slipdock-runner" "$BIN/.slipdock-runner.new"
mv -f "$BIN/.slipdock-runner.new" "$BIN/slipdock-runner"

say "installed slipdock-runner $version in $BIN, its signature and checksum checked"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) say "$BIN is not on your PATH: add it, or run $BIN/slipdock-runner" ;;
esac
say "next: slipdock-runner init"

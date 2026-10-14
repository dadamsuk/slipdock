#!/usr/bin/env bash
# Builds CodeMirror 6 and atomic-editor's live-preview extensions into
# assets/vendor/codemirror.js (and its stylesheet into
# assets/css/codemirror.css) — run by hand when the versions in package.json
# change, and the output committed, so neither the Docker image nor CI needs
# Node for it. The app's own esbuild then bundles it into app.js like any
# other vendored file.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
vendor="$here/../vendor"
css="$here/../css"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp -r "$here/package.json" "$here/entry.js" "$here/react-stub" "$here/html-stub.js" "$work/"
[ -f "$here/package-lock.json" ] && cp "$here/package-lock.json" "$work/"
cd "$work"
npm ci --no-audit --no-fund 2>/dev/null || npm install --no-audit --no-fund
cp package-lock.json "$here/package-lock.json"

npx esbuild entry.js --bundle --format=esm --minify --target=es2020 \
  --outfile="$vendor/codemirror.js" --alias:react=./react-stub --alias:@codemirror/lang-html=./html-stub.js \
  --legal-comments=none

{
  echo "/* atomic-editor's live-preview styles, copied by assets/codemirror/build.sh. */"
  cat node_modules/@atomic-editor/editor/dist/styles/inline-preview.css
} > "$css/codemirror.css"

version="$(node -p "require('./node_modules/@atomic-editor/editor/package.json').version")"
cm="$(node -p "require('./node_modules/@codemirror/view/package.json').version")"
sed -i "1i // CodeMirror (view $cm) and @atomic-editor/editor $version, built $(date -u +%F) by assets/codemirror/build.sh. MIT licensed." "$vendor/codemirror.js"
du -sh "$vendor/codemirror.js"

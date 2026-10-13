#!/usr/bin/env bash
# Builds the Excalidraw editor into priv/static/vendor/excalidraw/ — run by
# hand when the versions in package.json change, and the output committed, so
# neither the Docker image nor CI needs Node for it. Fonts come along (bar the
# 13 MB CJK one) so the editor never fetches anything from a CDN.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../../priv/static/vendor/excalidraw"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp "$here/package.json" "$here/entry.js" "$here/stub.js" "$work/"
[ -f "$here/package-lock.json" ] && cp "$here/package-lock.json" "$work/"
cd "$work"
npm ci --no-audit --no-fund 2>/dev/null || npm install --no-audit --no-fund
cp package-lock.json "$here/package-lock.json"

rm -rf "$out"
mkdir -p "$out"
npx esbuild entry.js --bundle --conditions=production --format=esm --splitting --minify --target=es2020 \
  --outdir="$out" --entry-names=excalidraw --chunk-names=chunks/[name]-[hash] \
  --alias:@excalidraw/mermaid-to-excalidraw=./stub.js \
  --define:process.env.NODE_ENV='"production"' --legal-comments=none \
  --loader:.woff2=file --asset-names=assets/[name]-[hash]

# Excalidraw falls back to esm.sh for any font it can't find here; point
# that at this origin instead, so nothing is ever fetched from elsewhere (the
# CSP would refuse it anyway, noisily).
grep -l 'https://esm.sh/' "$out"/*.js "$out"/chunks/*.js | while read -r f; do
  sed -i 's#`https://esm.sh/\${#`${location.origin}/vendor/excalidraw/fallback/${#' "$f"
done
if grep -q 'esm.sh' "$out"/*.js "$out"/chunks/*.js; then echo "esm.sh is still named in the bundle" >&2; exit 1; fi

dist=node_modules/@excalidraw/excalidraw/dist/prod
mkdir -p "$out/fonts"
for font in "$dist"/fonts/*; do
  [ "$(basename "$font")" = Xiaolai ] && continue
  cp -r "$font" "$out/fonts/"
done
cp node_modules/@excalidraw/excalidraw/package.json "$work/excalidraw-package.json"
version="$(node -p "require('./excalidraw-package.json').version")"
echo "Excalidraw $version, built $(date -u +%F) by assets/excalidraw/build.sh" > "$out/VERSION"
du -sh "$out"

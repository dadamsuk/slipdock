#!/usr/bin/env bash
# End to end: publishing a Tool from the browser. The job-scan package is
# uploaded on the Tools page and opens as a new Tool; its package is
# downloaded back from its page; a bumped copy is uploaded there as the
# next version; and a file that isn't a package is refused with the reason.
#
#   PORT=4099 tools/e2e/tool-publish.sh
#
# Needs playwright-core on NODE_PATH and Chromium at CHROME_PATH.
source "$(dirname "$0")/lib.sh"
e2e_start

WORK=$(mktemp -d)
cp -r packages/job-scan "$WORK/job-scan"
tar czf "$WORK/job-scan-1.0.0.tgz" -C "$WORK" job-scan
sed -i 's/"version": "1.0.0"/"version": "1.0.1"/' "$WORK/job-scan/tool.json"
tar czf "$WORK/job-scan-1.0.1.tgz" -C "$WORK" job-scan
echo "not a package" > "$WORK/notes.tgz"

node tools/e2e/tool-publish.mjs "$LINK" "$BASE" "$WORK" || { grep -E "HANDLE EVENT|\(error\)|\*\* \(" "$LOG" | tail -30; exit 1; }

# The download is a package: it reads back as the version it came from.
tar tzf "$WORK/downloaded.tar.gz" | grep -qx 'tool.json' || { echo "the download has no tool.json"; exit 1; }
mix run -e '
  bytes = File.read!("'"$WORK"'/downloaded.tar.gz")
  {:ok, p} = Slipdock.Tools.Package.read(bytes)
  tool = Slipdock.Repo.get_by!(Slipdock.Tools.Tool, slug: "job-scan")
  v1 = Slipdock.Tools.get_version(tool, "1.0.0")
  if Slipdock.Tools.Package.sha(p.entries) != v1.sha, do: raise("the download is not 1.0.0")
  latest = Slipdock.Tools.latest_version(tool).version
  if latest != "1.0.1", do: raise("latest is #{latest}")
  IO.puts("ok: the database agrees (the download is 1.0.0 to the sha, latest is 1.0.1)")
'
rm -rf "$WORK"

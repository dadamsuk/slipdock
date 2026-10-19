---
name: job-search-scan
description: Run one pass of the job-search Tool's search on Slipdock: reads every source on the person's Sources page, skips postings already in the Seen ledger, scores new ones against their own Criteria, logs every posting, and puts each one at or above their threshold on the board in Found with the posting stored verbatim and a full gap analysis against their Candidate Facts. Use for the daily scheduled scan, the cloud fallback scan, when asked to look for new jobs or run the job scan, or to put one job posting URL through the same assessment. It never applies to anything and never builds documents.
---

# Job search: scan

This skill is a stub. Its procedure is kept on the Slipdock server as part of the
`job-search` Tool, so every run follows the version published now, not the one that
was current when this skill was installed. Fetch it, then follow it exactly.

**The procedure:** `skills/job-search-scan/references/procedure.md`

Fetch it the first way that works:

1. **Over MCP** (the Slipdock connector): `list_tools` with
   `{"tool": "job-search", "file": "skills/job-search-scan/references/procedure.md"}`.
   The answer's `text` is the procedure.
2. **From a shell with the `slipdock` CLI:**
   `slipdock tools file job-search skills/job-search-scan/references/procedure.md`
3. **From a shell with only a token:**
   ```sh
   T="${SLIPDOCK_TOKEN:-$(cat ~/.config/slipdock/token)}"
   U="${SLIPDOCK_URL:-$(cat ~/.config/slipdock/url)}"
   curl -fsS -H "Authorization: Bearer $T" "$U/api/tools/job-search/files/skills/job-search-scan/references/procedure.md"
   ```
4. **None of those reachable:** read `references/procedure.md` beside this file. It
   is the copy from when the skill was installed and may be out of date, so say in
   your report that the server copy could not be fetched.

The procedure names other files of the Tool (such as
`skills/job-search-scan/references/linkedin.md` or
`skills/job-search-generate/scripts/build_docs.py`). Fetch each the same way, by its
path in the package; a copy of each is beside this file too.

Anything the prompt says (a board, a card, a runner job, a posting URL) is input to
the procedure, not a replacement for it.

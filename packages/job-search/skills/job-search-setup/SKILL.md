---
name: job-search-setup
description: Set up or change the job-search Tool on Slipdock: installs the board, then interviews the person (or reads their CV and notes) to fill in their Criteria, Sources, Candidate Facts, CV Baseline and Writing Rules pages, builds their CV style template, and gives them the scheduled tasks to create. Use when someone wants to start an automated job search, set up or reconfigure the job search, change their criteria, sources, CV or writing rules, or rebuild their CV template.
---

# Job search: setup

This skill is a stub. Its procedure is kept on the Slipdock server as part of the
`job-search` Tool, so every run follows the version published now, not the one that
was current when this skill was installed. Fetch it, then follow it exactly.

**The procedure:** `skills/job-search-setup/references/procedure.md`

Fetch it the first way that works:

1. **Over MCP** (the Slipdock connector): `list_tools` with
   `{"tool": "job-search", "file": "skills/job-search-setup/references/procedure.md"}`.
   The answer's `text` is the procedure.
2. **From a shell with the `slipdock` CLI:**
   `slipdock tools file job-search skills/job-search-setup/references/procedure.md`
3. **From a shell with only a token:**
   ```sh
   T="${SLIPDOCK_TOKEN:-$(cat ~/.config/slipdock/token)}"
   U="${SLIPDOCK_URL:-$(cat ~/.config/slipdock/url)}"
   curl -fsS -H "Authorization: Bearer $T" "$U/api/tools/job-search/files/skills/job-search-setup/references/procedure.md"
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

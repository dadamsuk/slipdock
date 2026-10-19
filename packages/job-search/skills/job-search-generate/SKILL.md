---
name: job-search-generate
description: Build application documents for one card on the job-search Tool's Slipdock board: CV and covering letter as .docx and PDF attached to the card, a recruiter LinkedIn message and email as comment text, and talking points on the role page, after asking the person, in one wait, anything still open. Use when a runner job from the generate pool arrives, for the hourly generate task that claims those jobs, or when asked to build the CV, cover letter or documents for a role on the job search board.
---

# Job search: generate

This skill is a stub. Its procedure is kept on the Slipdock server as part of the
`job-search` Tool, so every run follows the version published now, not the one that
was current when this skill was installed. Fetch it, then follow it exactly.

**The procedure:** `skills/job-search-generate/references/procedure.md`

Fetch it the first way that works:

1. **Over MCP** (the Slipdock connector): `list_tools` with
   `{"tool": "job-search", "file": "skills/job-search-generate/references/procedure.md"}`.
   The answer's `text` is the procedure.
2. **From a shell with the `slipdock` CLI:**
   `slipdock tools file job-search skills/job-search-generate/references/procedure.md`
3. **From a shell with only a token:**
   ```sh
   T="${SLIPDOCK_TOKEN:-$(cat ~/.config/slipdock/token)}"
   U="${SLIPDOCK_URL:-$(cat ~/.config/slipdock/url)}"
   curl -fsS -H "Authorization: Bearer $T" "$U/api/tools/job-search/files/skills/job-search-generate/references/procedure.md"
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

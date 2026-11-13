**Evidence on completion.** Completing a card takes what you checked:
`evidence` (in words), `evidence_commit` and `evidence_branch`,
`evidence_tests` (the test files you added or changed) and
`evidence_suite` (`{"result": "passed"|"failed", "passed": N, "failed":
N}`). Give what applies: `complete_card` `evidence` / `commit` /
`branch` / `tests` / `suite`, `slipdock done ID --evidence -
--evidence-commit SHA --branch B --tests a.exs,b.exs --suite
passed:38:0` (the text on stdin), or the same fields on `PATCH /api/cards/:id` with
`"completed": true`. The server checks their shape, not their truth: a
second agent does that. Completing with none of them, moving the card
into a done list without it, or creating a card already done (in a
done list, or with `"completed": true`) without it, is refused
(`422`). So is evidence that is a bare `-` once trimmed, on any board:
a client that doesn't read stdin sends the dash for `--evidence -`, so
pass the text itself, or pipe it with `--evidence -` from a CLI that
reads stdin (evidence that merely starts with `-` goes through). An
agent's `description` or `bar` that is a bare `-` is refused the same
way, on a create or an update (`422`, naming the field): it is what
such a client sends for `--desc -` or `--bar -`, and the card would
keep a dash for a body; a person's own write is never refused. An
agent's verdict whose reason is a bare `-` is refused the same way
(`422`), on accept, reject, agree and disagree, so the piped reason is
never lost behind the dash; a person is never refused. The
evidence is posted on the card as a comment; reopening the card clears
it, so the next completion brings its own.

**Evidence and a reason are lines, not a paragraph.** A first line
that stands alone, a blank line, then one short line per point; the
parts go in their fields (`--check`, or the evidence's `--evidence-commit`,
`--branch`, `--tests`, `--suite`, `--pr`), not repeated in the text.
Words on the command line lose their line breaks, so send it on stdin
with a quoted heredoc (`--evidence -`, `--reason -`):

```sh
slipdock done 12 --evidence-commit abc1234 --suite passed:38:0 --evidence - <<'EOF'
Built and tested; CI green.

- the export keeps archived cards (`Export.run/1`)
- Handbook: updated W-3 §Exports
EOF
```

A verifier's or an auditor's reason is the same (`verify_card`'s
`reason`; `slipdock verify ID reject|disagree --reason -`):

```sh
slipdock verify 12 reject --check bar:2=fail:"no test" --reason - <<'EOF'
bar 2: the export drops archived cards

- `Export.run/1` filters on `archived_at`
- no test exports an archived card
EOF
```

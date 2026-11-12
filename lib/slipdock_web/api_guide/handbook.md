
## The handbook

A board can keep a **handbook**: wiki pages in its root board's
`Handbook/` folder describing the project as it is now (<%= @handbook_titles %>), one page per decision in
`Handbook/Decisions`, and an Index that lists them. Each page's front
matter says when to read it (`read_when:`) and which paths it covers
(`covers:`).

**Principles and Playbook** (Handbook Tool 1.5.0) say how the project
decides and plans. Principles are the tie-breakers between two right
ways: a short paragraph each and a `PRIN-n should · judgement` rule in
its `## Rules`, which covers every path, so a verifier weighs them like
any other rule. The Playbook is how an idea becomes cards (when it
applies, sizing, the stages, card shape, the person's defaults), read
only by an agent asked to plan, never when a card is made. A board
makes both its own by editing them. Installing 1.5.0 over an older
handbook adds the two pages and changes no other.

```sh
slipdock tools install-board handbook --board <board>   # or install_tool {tool: "handbook", board}
slipdock handbook <board>       # the index and the decisions (GET /api/boards/:board/handbook)
slipdock handbook <card>        # what that card should read
```

On a handbook board, `get_card` and `GET /api/cards/:id` carry a
`handbook` key: `index` (code, title, summary, `read_when` of each page)
and `suggested`, up to five `{page, title, section, why}` to read before
building: `slipdock page section <page> "<section>"`, or the whole page
when `section` is null. A subcard gets its root board's handbook.

**Rules.** Each section page keeps its rules in a `## Rules` section,
one list item each, parts separated by ` · `:

```
- **UX-4** must · test/app_web/design_tokens_test.exs · No colour literals in templates.
- **DATA-2** should · scope priv/repo/migrations/** · judgement · Never edit a migration that has run.
```

The id is the page's prefix
(`SPEC ARCH UX COMP DATA MOD TEST OPS PRIN PLAY`) and a number, never
reused; `must` means a verifier rejects work that
breaks it, `should` that it is noted. The optional `scope` globs
narrow it (default: the page's `covers:`, or everywhere when that is
empty). The check is the test that enforces it, or `judgement`. Cite a
rule by its id; tidying a page, keep its rules as they are.
`slipdock handbook <board>` (its `rules`) counts them and lists any
item that doesn't parse, with its page and line.

**The rules for some paths:** `slipdock handbook <board> --paths a,b`
(REST `GET /api/boards/:board/handbook?paths=a,b`) gives every rule
whose scope covers them, `must` first, and the pages whose `covers:`
take them in (`pages`, with how many each); for a whole change,
`git diff --name-only main | slipdock handbook <board> --paths-from -`. A card with lane `paths` carries
them in its `handbook` block as `rules` (`rules_more` counts any cut).
Read them before building and check the diff against them before
submitting: a verifier uses the same list. A rule is a person's call:
one a card adds, rewords or drops goes in as a proposal (`slipdock
garden propose`), not an edit, and an agent's edit to a rule is flagged
for a person to keep or revert (`rule_changed`).

**Before closing, the docs gate.** Check the diff against the handbook:

| The card… | Updates… |
|---|---|
| added user-visible behaviour | Specification |
| changed structure or boundaries | Architecture / Data model |
| chose between alternatives | a new page in `Handbook/Decisions` |
| added something reusable | Shared modules / Components |
| added or changed a UI pattern | UX & UI |
| changed how to test, build or deploy | Testing & tooling / Operations |

Edit by section with `--message "#<card> …"`, and put one line in the
closing comment: `Handbook: updated W-3 §Contexts, new W-41`, or
`Handbook: no change (<why>)`. A card that names a page ("Document in:
Architecture") must update it. The gardener flags done cards without
the line.

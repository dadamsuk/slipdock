[Slipdock — the manual](../manual.md)

## Incidents

What broke after it shipped, and which check should have caught it, is the
measure of whether the checks are getting better. A card says it is an
**incident** with two optional fields, set by a person (or an agent told to):

- **Caused by**: the card whose shipping caused it, on any board you can read.
- **Missed by**: the check that should have caught it: `bar` (the card's bar
  left it out), `rules` (no handbook rule covered it), `ci`, `verify` (the
  verifier passed it), `audit`, or `none` (no check could have).

Set them on the card's **Incident** line, under Dependencies: type the
causing card's number (`#123` or `123`), pick the check, **Save**; **Clear**
takes both off. The incident shows *Caused by #123 …* with a *missed by …*
badge, and the causing card lists each incident it caused (*Caused incident
#456 …*). A card you can't read can't be named, and is refused in the same
words as one that isn't there; an incident whose cause somebody else named
shows only its number to a reader who can't see it, and the cause lists only
the incidents its reader can.

While an incident names both, the causing card carries one `process` finding
with source `incident`: "#456 (incident) was missed by ci". Changing the
check (or the cause) changes that finding rather than adding another;
clearing either takes it away, unless a person has already promoted or
dismissed it. So the [Findings](findings.md) page and `slipdock findings
<board> --source incident` list them, and the card's chat reads them with its
other findings. Nothing is automatic and there is no dashboard: at a small
team's scale incidents are a list.

```sh
slipdock edit 456 --caused-by 123 --missed-by ci   # also on add; --no-caused-by, --no-missed-by
```

```
PATCH /api/cards/:id {"caused_by": 123, "missed_by": "ci"}   (null clears; also on create)
update_card / create_card  caused_by, missed_by
```

`GET /api/cards/:id` (and `get_card`) carries `caused_by` and `missed_by`,
`caused_by_card` (the cause, or `{id, hidden: true}`) and `incidents` (the
incidents it caused that you can read, each with `missed_by`).

---

← [Dependencies](dependencies.md) · [Contents](../manual.md) · [Subcards and templates](subcards-and-templates.md) →

[Slipdock — the manual](../manual.md)

## Activity

A board's **Activity** panel is its log: cards added, moved, edited and
finished, lists and automations changed, pages written. Every entry says who
did it: a person, with the avatar their cards show; an agent, by its
token's name; *Automation: <rule>* for a rule's work; *Email from <name>*
for a card sent in by email; and *System* for the server's own jobs.
Entries from before actors were recorded say *Someone*, and a deleted
person's entries keep the name they had. Entries are grouped by day in
your own timezone (*Today*, *Yesterday*, then the date), each kind of
change has its own icon, and older entries load as you scroll to the
bottom.

The same log is `slipdock activity <board>` (`--card ID` for one card's),
one line an entry with when and who, the same way the panel puts it:
`2026-11-14 18:28  dedev loop moved “Fix the build” to Done`. Over the
API and MCP each entry carries an `actor`, its kind and its name.

---

← [Prioritise](prioritise.md) · [Contents](../manual.md) · [Your boards](your-boards.md) →

[Slipdock — the manual](../manual.md)

## Custom fields, scoring and votes

Board settings (root boards) hold the tree's **fields**, and only a writer
of the root board adds, changes or removes one, from any door, as with tags;
anyone who can edit a card sets its values. The fields are: number (with
optional min, max, unit), rating (1–5 by default), choice (each option with
an optional weight and colour), date, text, and **formula**. Every field
has a short key, used in formulas as `{key}`; a formula is an arithmetic
expression such as `{reach} * {impact} * ({confidence} / 100) / {effort}`,
and may use `{votes}`, `{subcards}` and `{done}` too. A formula stored as a
*weighted* score (API only, for now) normalises each input to 0–100 across
the board's cards and combines them by weight, so effort-like inputs with a
negative weight pull a score down. Presets set a scheme up in one click:
**RICE**, **ICE** and **Value ÷ Effort**.

Fields are edited in the card modal (stars for ratings), shown as table
columns (*Display*), sortable, and rating and choice fields can be swimlane
axes — *Value* on one axis and *Effort* on the other is the prioritisation
matrix, and dragging a card between cells rescores it. A number or rating
field marked *Σ* rolls up the tree (totals per card, done and all) and
totals in table group headers.

The board's **Filter** menu has a *Fields* section with one filter per
field, suited to its type: options to pick for a choice, a least number of
stars for a rating, a min and max for a number or formula, a from and to
for a date, and words to find for text. Every view's Filter menu has the
same section, and the filters are kept in the address and in a saved view
like the others, so a reload or a saved view brings them back; a filter on
a field since deleted is dropped. A view shared with someone shows them
only the cards its field filters select.

**Votes.** Everyone has a budget of votes to spend across a board tree
(board settings: votes per person, max per card). The card modal shows the
total and a stepper for your own; votes are a table column, a sort and
`{votes}` in formulas.

---

← [Roadmapping](roadmapping.md) · [Contents](../manual.md) · [Links and goals](links-and-goals.md) →

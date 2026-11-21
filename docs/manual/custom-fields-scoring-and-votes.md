[Slipdock — the manual](../manual.md)

## Custom fields, scoring and votes

Board settings (root boards) hold the tree's **fields**, and only a writer
of the root board adds, changes or removes one, from any door, as with tags;
anyone who can edit a card sets its values. The fields are: number (with
optional min, max, unit), rating (1–5 by default), choice (each option with
an optional weight and colour), date, text, URL (one http or https link,
shown as its host and opening in a new tab; anything else is refused),
checkbox (on or off; an empty
one counts as off, and it is 1 or 0 in a formula), person (several of the
board tree's members), and **formula**. Every field
has a short key, used in formulas as `{key}`; a formula is an arithmetic
expression such as `{reach} * {impact} * ({confidence} / 100) / {effort}`,
and may use `{votes}`, `{subcards}` and `{done}` too. A formula stored as a
*weighted* score (API only, for now) normalises each input to 0–100 across
the board's cards and combines them by weight, so effort-like inputs with a
negative weight pull a score down. Presets set a scheme up in one click:
**RICE**, **ICE** and **Value ÷ Effort**.

A choice field can switch on **Allow several**, in board settings (or
`slipdock new-field … --kind select --several`, or `"config": {"several":
true}` over the API): each card then holds any number of its options, ticked
in the card and the table and shown to a reader as chips, in the field's
option order. Set it with keys or labels, a list or a comma-separated
string (`slipdock set 12 area=Web,API`); the API, MCP and a page's `fields`
give the list of keys, and an option the field doesn't have is refused. Its
filter keeps a card holding any of the options picked; on a swimlane axis
the card sits in each of its options' lanes, as with tags, and dragging it
between two swaps that one option and keeps the rest; in a formula it is
the sum of the chosen options' weights; it sorts by its first option.
Switching Allow several off where cards hold several asks first, then keeps
each card's first option; over the API, changing the field's `config` does
the same without asking.

A **person** field holds several of the board tree's members, the people
who can read its root board, in the order they were picked. The card and
the table offer a box per member; set it with emails, user ids or `me`, a
list or comma-separated (`slipdock set 12 reviewers=me,ann@example.com`),
and anyone who isn't a member is refused, naming them. It reads as their
names; the API, MCP and a page's `fields` give each as `id`, `name` and
`email`, as a card's assignees are. Someone who leaves the board keeps
their place on the cards that hold them, marked *(former member)* and
struck through, with `"former": true` over the API: they can be taken off
but not picked for a card again. Its filter offers *Me* (whoever is
looking, even in a shared view or a saved address) and each member, and
keeps a card holding any of those picked; as a swimlane axis it has a lane
per person its cards hold and one for nobody, a card sits in each of its
people's lanes, and dragging it between two swaps that one person and
keeps the rest. It sorts by its first person's name, and is no number in
a formula. An import keeps a person only where they are a member of the
new board, and reports the rest.

Each field has a **Show on cards** switch in board settings, off until you
turn it on: the card front then shows that field's value as a small chip,
in field order, leaving out the fields a card has no value for, and a
compact card shows the first two. A card view hides them all as one
element, *Fields* (see [Card views](card-views.md)). From the command line,
`slipdock new-field … --on-cards`; over the API, `show_on_cards`.

Fields are edited in the card modal (stars for ratings), shown as table
columns (*Display*), sortable, and rating, choice, checkbox and person fields can
be swimlane axes (a checkbox's two lanes are *✓ Name* and *Not Name*; a
checked one shows on the card front as *✓ Name*) — *Value* on one axis and
*Effort* on the other is the prioritisation matrix, and dragging a card
between cells rescores it. A date field is an axis too, grouped by the
view's unit (week, month and the rest) as due dates are, with the undated
cards in a lane of their own; dragging a card into a lane sets the date to
its start. A number or rating
field marked *Σ* rolls up the tree (totals per card, done and all) and
totals in table group headers.

The board's **Filter** menu has a *Fields* section with one filter per
field, suited to its type: options to pick for a choice, a least number of
stars for a rating, a min and max for a number or formula, a from and to
for a date, words to find for text or a URL, On or Off for a checkbox (Off
keeps the cards with it empty), and Me and the members for a person field. Every view's Filter menu has the
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

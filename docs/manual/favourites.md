[Slipdock — the manual](../manual.md)

## Favourites

A board holds more than anyone works on at once. The board you live in is one
of nine, the list you actually move cards through is one of six on it, and the
card you report against every day is one of hundreds — three or four taps
every time, and the last one a hunt.

Press the heart on a **saved view** (in the Views menu), **Favourite this
list** in a list's `⋯` menu, or the heart on an open **card** (beside the close
button) or a **wiki page** (beside its code, at the top of the page) and it
lands on `/favourites` — the
heart in the header bar on a desktop, the fifth tab on a phone. So anything you go back to often is two taps from
anywhere: the heart, then the thing.

- A favourited **list** opens its board scrolled to that list, which on a
  phone — where the board shows one list at a time — is the difference between
  arriving and swiping to find it. Only a favourite list shows a heart on its
  header; the rest keep their headers quiet, and the `⋯` menu is where you
  favourite one, or stop.
- A favourited **view** opens in the mode it was saved in, as the view
  switcher's favourites always have.
- A favourited **wiki page** opens the page; a draft only stays on the list
  while you could still edit it. From the CLI: `slipdock fav page W-31`.
- Favourites are **yours**. Two people on the same board keep different ones,
  and sharing a board never hands your shortcuts to anybody else. Marking one
  changes nothing about the thing itself, so read access is enough.
- The page prunes itself: each row carries its own heart, and anything you
  lose access to, or archive, drops off the list without a trace.

The heart is deliberately not a star — a card already *has* a star, the
"Starred" flag, which is the board's and everyone's.

They are in the API and the CLI too (`GET /api/favourites`,
`slipdock favourites`), where they are worth reading at the start of an agent's
session: they say where a person actually works, which a list of boards does
not.

---

← [The header and the avatar menu](the-header-and-the-avatar-menu.md) · [Contents](../manual.md) · [On a phone](on-a-phone.md) →

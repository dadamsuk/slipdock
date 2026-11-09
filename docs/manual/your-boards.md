[Slipdock — the manual](../manual.md)

## Your boards

The index at `/` is where the boards themselves are looked after, and how it
reads is yours: two controls sit beside **New board**, and both are
remembered between visits. Your wiki isn't a card here: **Wiki** opens it
(see [Your wiki](wiki.md#your-wiki)), and your Knowledge Base, being a wiki and not
a board to work on, isn't listed.

**Layout.** The cards are the default — a colour strip, the name, the lists
and cards on it and how much is done. The board's code, its switcher key when
it has one and your Ctrl+Shift digit when you have given it one show when you
point at a tile or move to it with the keyboard, and in the name's tooltip;
**Copy board code** is in the tile's menu. The compact layout is the same boards as a
table, a row each, with the board's colour, code, switcher key, description,
lists, cards, how far along it is and when anything last happened anywhere in
its tree. Worth switching to once there are more boards than fit on a screen.

**Order.** *My order* is the default, and it starts as the order the boards
were made in. Drag the handle on a card or a row to move a board or a multiboard,
or use **Move up** / **Move down** in its menu for the same thing without a
mouse. For more than one move, press **Reorder** in the toolbar: every board
and multiboard is then a dashed tile you can grab anywhere, nothing on
it opens when pressed, and each drop is saved as you make it. It switches to
*My order* if another sort was on. **Done** (or Escape) ends it.
Your wiki's tree takes the same order at its top, after the Knowledge Base.
The other orders — name, recently active, newest, oldest, most cards — sort
without disturbing yours: switch back to *My order* and every board is where
you left it. **The order is yours alone.** A board shared with four people
sits in four different places, and rearranging your index never moves anyone
else's — the same way a favourite is one person's.

**Archiving.** A board that is finished with can be archived, from its menu on
the index or from **Board settings** on the board itself. Only its owner can.
An archived board comes off the index, the board switcher (`b`), quick add and
the list of boards a card can be moved to — but nothing on it is deleted: the
link still opens it (with an *archived* badge in the header), its cards still
turn up in search and in **My work**, and the API and CLI still read and write
it. Archived boards collect in an **Archived** section at the foot of the
index, in whichever layout is on, and **Restore** puts one back where it was.
Delete is still there for what should really go, and still permanent.

On the command line:

```sh
slipdock boards --all                          # archived ones too
slipdock archive-board errands                 # and restore-board to undo
slipdock order-boards qvm-v1-rem errands 3     # your own order
```

---

← [Activity](activity.md) · [Contents](../manual.md) · [The header and the avatar menu](the-header-and-the-avatar-menu.md) →

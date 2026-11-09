[Slipdock — the manual](../manual.md)

## At the foot of every list

One row of three small buttons — the list is narrow, and what is in it
matters more than how to add to it. All three are shortcuts to the same
thing, one more item on the board; hover for the names:

- **Add** — the one-line card form: a title, Enter.
- **Add a page** (the document icon) — straight into the wiki's own editor,
  Markdown and all, carrying the list with it. Save, and the page is placed
  there: a tile on the board, and a page in the wiki tree. The editor says
  which list it will land in.
- **Add a document** (the paperclip) — pick a file and it lands as a card of
  its own, titled after the filename with the file attached. A spec somebody
  emailed you belongs on the board, not in a folder.

Each can be turned off for the whole board under **List settings → At the
foot of every list** (any list's; only the board's owner sees it), or from
the command line:

```sh
slipdock set-board qvm-v1-rem --no-add-document   # …and --add-document to put it back
```

A board's JSON carries `add: {card, page, document}`, so a client that draws
the list draws the same three.

The **Filter** bar's *Kind* section narrows a list to any of the three again:
*Cards*, *Documents* or *Wiki pages*, on the board and in every other view.
There are only two rows behind the three names, so a document is recognised
rather than recorded: a card whose whole content is the file on it — nothing
written in the description, nothing to tick off, no subcards beneath it.
Write a description on it and it is a card about the work again, which is the
honest answer. (Comments don't count: "here's the spec" / "thanks" is what a
document on a board is for.)

Over the API and the CLI it is `kind=document` on a card listing (`slipdock cards
<board> --kind document`) and `kinds=` on a view (`--kind page`, repeatable),
where all three are counted together.

---

← [Keyboard](keyboard.md) · [Contents](../manual.md) · [A list's order and groups](a-lists-order-and-groups.md) →

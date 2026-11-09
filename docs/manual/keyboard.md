[Slipdock — the manual](../manual.md)

## Keyboard

Press `?` anywhere for this list on screen. Nothing fires while you are typing
in a field. An open card takes the keyboard for itself (see below); other
dialogs leave the page's keys alone.

**Anywhere**

- `Ctrl-P` — **commands**: one box for everywhere you can go and everything
  you can set off. Type what you want — a page, a board, one of this board's
  views or pages, *quick add*, *alerts*, *sign out*. Matching walks out from
  the exact to the vague, so `bs` finds *Board settings*. The arrows walk the
  answer, `Enter` follows the row you are on, `Esc` closes it.
- `Ctrl-O` — **open a card**: type a title and jump to it, on any board you
  can open. Type a card's id (`123` or `#123`) or paste its link and that
  card comes first — even an archived one, marked *archived*, which opens in
  its board's archive to be restored — and likewise a wiki page's code
  (`W-31`) for that page. Titles find live cards only. On a wiki it is
  the **note switcher** instead (`Cmd-O` on a Mac): type a few letters of a
  note's title, one of its aliases or its path, in order but not necessarily
  together (`acmcall` finds `Projects/Acme/Call`), across your whole wiki,
  or the board alone. Nothing typed lists the notes
  changed most lately, and a page's code still goes straight to it. On a
  shell, `slipdock page switch <board> <letters…>`
- `Ctrl-Shift-1` … `9`, `0` — **open a board** (or your wiki) you gave that digit (see
  [A board's hotkey](#a-boards-hotkey), [Switching to your wiki](#switching-to-your-wiki))
- `Shift-Alt-S` — **search everything** (`Shift-Option-S` on a Mac): the [search
  page](deep-search-and-ask.md), with the cursor in its box. Already there, it just puts the
  cursor back, your results intact; from Ask it switches to Search and takes
  the question with it
- `Shift-Alt-N` — **a quick note** (`Shift-Option-N` on a Mac), from anywhere, even
  mid-sentence; the same key shuts it. See [Quick notes](quick-notes.md)
- `Shift-Alt-F` — **Favourites** (`Shift-Option-F` on a Mac), from anywhere
- `Shift-Alt-A` — **Ask about everything** (`Shift-Option-A` on a Mac), from anywhere
- `h` — all boards (the board takes this one while the keyboard is on it)
- `b` — **switch board**: every board you can open, then your wiki, with
  its own key; press that key to go there
- `q` — quick add a card (see below)
- `l` — alerts (the board takes this one too, while it holds the keyboard)
- `?` — the shortcut sheet
- `Esc` — close whatever is open

**On a board**

- `v` — **switch view**: Board `b`, Outline `o`, Swimlanes `s`, Table `t`,
  Timeline `i`, Calendar `c`, Narrative `n`, Prioritise `p`
- `/` — the board's search box
- `a` — chat about the page with AI
- `j` — **labels**: one appears on every card on screen; type it to open that
  card
- `J` — **pick a card up**: the same labels, but choosing one picks the card
  up rather than opening it
- `c` — **step into a list**: a label appears on every list; choosing one puts
  the keyboard on that list's first card
- `z` — **snooze** the card the keyboard is on, or the one under the pointer
  (labels, if neither); `z` again is tomorrow — see [Snoozing cards](snoozing-cards.md)

Both `Ctrl-P` and `Ctrl-O` work from anywhere at all — mid-sentence, over a
card, over another palette. The keyed palettes (`b`, `v`, `?`) are picked from
by typing a row's own key; the typed ones (`Ctrl-P`, `Ctrl-O`) by typing what
you are after and walking the answer with the arrows.

**On an open card**

A card dialog answers the keyboard itself, so the page and the board behind it
stand down while it is up (`?` still reaches the sheet, `Esc` still closes the
card).

- `↑` `↓` or `j` `k` scroll it, `PgUp` `PgDn` a screenful at a time,
  `Home` `End` the top or the bottom
- `h` `l` step to the section before or after, for when the letter escapes you
- a section's own letter jumps to it — hold **Alt** (**Option** on a Mac) to
  see each heading's letter underlined:
  `f` Flags, `t` Tags, `d` Description, `a` Attachments, `e` Ch**e**cklist,
  `s` Subcards, `p` De**p**endencies, `n` Li**n**ks, `w` Web links,
  `c` Comments. `f` and `t` also open the section's picker: the card shows
  only the flags and tags it has, as chips with an ×, and **+ Add** (or the
  key) lists the rest to tick. In the tag picker, typing narrows the list,
  and Enter makes a new tag of what is typed and puts it on the card.

Four sections do not get their first letter: Comments and Description were
there first, so Checklist and Dependencies gave way, and `h` `j` `k` `l` belong
to moving about, so Checklist and Links gave way again. The underline in the
heading (with Alt held) is always the authority.

Once the keyboard is on the board, a strip along the bottom says what it is on
and what the keys will do. Carrying a card (after `J`):

- `←` `→` or `h` `l` move it to the list either side, keeping its place in the
  order as closely as the shorter list allows
- `↑` `↓` or `j` `k` move it one place up or down within its list
- `Enter` drops it; `Esc` lets go, leaving it where it is

Stepping through a list (after `c`):

- `↑` `↓` or `j` `k` the card above or below, `←` `→` or `h` `l` the list
  either side
- `Enter` opens the card, `J` picks it up, `c` adds a card to the list, `z`
  snoozes it (`z z` until tomorrow)
- `Esc` stops

Vim's `h` `j` `k` `l` do everything the arrows do while the keyboard is on the
board, so a hand need not leave the home row. They are the board's for as long
as it holds the keyboard: `h` and `l` walk it rather than going to all boards
or opening the alerts, and `j` walks down rather than labelling the cards
again — `Esc` hands all three back.

Labels favour the home keys (`a s d f k j l`) and are single characters while
they last; a board showing more cards than there are characters gets pairs,
which reuse the home keys first in both positions — the way a Vim browser
plugin labels links. Only things you can actually see are labelled, so scroll
and press the key again to reach the rest. While labels are up, `Backspace`
un-types a character and `Esc` dismisses them.

Each arrow moves a carried card for real rather than previewing the move, so
the board on screen is always the board as it stands — `Esc` and `Enter` differ
only in that `Esc` says nothing more is coming. Picking a card up needs write
access and the board view; the labels for opening a card work in every view.

### A board's own key

Every board has a **shortcut key**: one or two characters that reach it under
`b`. It is taken from the board's name when the board is created — "Marketing"
is `m`, and the next board wanting `m` gets the next free letter of its own
name — so unlike the labels above it does not move around as the board fills
up. Change it under *Shortcut key* in board settings, or with
`slipdock set-board <board> --shortcut K`; clear it to take a fresh one from the
name. It is in the `shortcut` field of the API and the KEY column of
`slipdock boards`, and it addresses nothing — the board **code** is what names a
board in a URL or on the command line.

### A board's hotkey

`Ctrl-Shift` and a digit (`Cmd-Shift` on a Mac; the number pad counts too)
opens a board straight from any page, even mid-sentence in a field. Pick the
digit under *Hotkey* in board settings, or with
`slipdock hotkey <board> <0-9|none>`; `slipdock hotkeys` lists yours. The digits
are yours alone — ten to go round, so they are not the board's: somebody you
share a board with keeps their own, and a board shared with you can take one of
yours from the shell (`PUT /api/boards/<board>/hotkey`). Giving a digit to one
board takes it off whichever had it. A digit with no board, or on a board you
can no longer open or have archived, says so rather than going anywhere.

### Switching to your wiki

<a id="switching-to-a-vault"></a>

Your wiki is reached the same two ways. It has a shortcut key from the
same set as the boards' — so `b` then a key never means two things — and is
listed in the switcher after your boards (and in the command palette,
`Ctrl-P`, as *Your wiki*). It can also have one of your `Ctrl-Shift` digits;
giving it one takes the digit off whichever board had it. Set both under
*Shortcut key* and *Hotkey* in Wiki settings, or with `slipdock wiki set
--shortcut K --hotkey <0-9|none>` (`PATCH /api/wiki {"shortcut": "nt",
"hotkey": 2}`). `slipdock wiki show` says which keys open it, and
`slipdock hotkeys` lists its digit with the boards'.

### Header links

Boards you go to all day, and your wiki, can be pinned to the header, at the
top right of every page just left of the quick add button, each as an icon
you choose (the same set wiki folders and pages wear); hover one for its name.
Pin them under *Header links* in [Account › Preferences](/account/settings):
choose the board (or your wiki) and its icon, then *Pin to header*. The arrows move
one along and *Remove* unpins it. Up to eight; pinning one already pinned
changes its icon.

They are yours alone, like hotkeys: any board you can open, and your wiki. A board you can no longer open, or have archived, drops off the header
(an archived one comes back with it). A phone's header has no room for them —
the Favourites tab is the same idea there.

From the shell: `slipdock header` lists yours and the icons,
`slipdock header add board <ref> --icon NAME` or `slipdock header add wiki
--icon NAME` pins one (`POST /api/header-links` with `board`, or
`{"wiki": true}`),
`slipdock header move <id> left|right` and `slipdock header rm <id>`
(`GET`/`POST /api/header-links`, `PATCH`/`DELETE /api/header-links/<id>`).

---

← [AI tools beside a page](ai-tools-beside-a-page.md) · [Contents](../manual.md) · [At the foot of every list](at-the-foot-of-every-list.md) →

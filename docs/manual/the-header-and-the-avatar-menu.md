[Slipdock — the manual](../manual.md)

## The header and the avatar menu

On a laptop or wider, the left of the header is the mark, then **Boards**,
**My work** and **Wiki** as links, with the one you are in marked, then where
you are (a board's name, say). The right-hand end is in the same order on
every page, and is about the app as a whole:

- a **search field** ("Search or ask…", `Shift-Alt-S`), which opens
  [Search everything](deep-search-and-ask.md), where **Ask** is the other half
  of the toggle;
- **quick add** (`+`, `q`), whose box also has **Quick note instead**;
- **Favourites**, the heart (`Shift-Alt-F`);
- the **alerts** bell (`l`). Its count adds what is waiting on you to the
  alerts, and its panel opens with a row that goes to My work;
- your avatar.

On a tablet there is no room for the links, and the right-hand end is icons
instead: quick add, quick note, Search everything, Ask, Favourites, a hand
with the count of what is waiting on you, the bell, and your avatar. Each
icon's tooltip says what it is and its key. Either way, a page's own buttons,
where it has any, come first, ruled off from the app's.

What belongs to the board you are on is on the board's own toolbar, the row
below. Every view of the board lays it out in the same order: the view
switcher, search, **Filter**, the view's own controls (a dated view's
previous/today/next, its span, group and sort), **Display**; then, at the
right-hand end, the card count, **Select**, **Views**, and the board's own
buttons (its sprint buttons, the AI chat about the board and the board's `…`
menu). It stays one row: when the window is too narrow for the view's own
controls they fold into a **View options** button, whose popover holds them
and changes them as before, rather than wrapping onto a second line.

The **avatar menu** is in sections, and marks the page you are on:

- **Places**: Boards, My work, Wiki (also links in the header on a laptop).
  Search, Ask and Favourites are not repeated here: they are in the header
  beside it.
- **Set up**: Templates, Groups, Tools, Set up an agent.
- **You**: **Account & settings** (one entry: Preferences, API tokens, Import &
  export and the rest are sections in the Account page's side nav), Help, and the theme as a
  row of three buttons — system, light, dark.
- **Admin**, for admins only: Overview, Users, Tool listings and
  Configuration, folded into one group that opens by itself on its own pages.
  While it is folded it carries the count of signups and tool listings
  waiting. Each opens the **Admin** area: one page with a side nav (People,
  Sign-ups, Overview; Server, Email, AI; Tools) and the running
  build under it. On a phone the nav is a picker at the top. The people
  table only reads: **Manage** on a row (or the row itself) opens that
  person's panel, which holds their limit, paid-up date, permissions,
  support access and, in a danger zone, Disable and Close.
- **Sign out**.

A board's **`…` menu** is in three groups: what you do with the board (Share
this board, Copy board code, Tidy
up…), how it is set up (Tags, Automations, Agentic Building while it is on,
Board settings), and what it has
done (Activity, Archived cards). **Share** is also a button of its own on the
board's toolbar: it opens Board settings on the Sharing tab. The board's name
in the header carries its code and switcher key in its tooltip.

**Board settings** is in tabs: **General** (name, code, shortcut key, hotkey,
description, default view, votes, sprint and simple board, colour),
**Features** (pulse, delivery metrics, the **Agentic Building** switch,
permitted senders, card features on wiki pages), **Planning**
(fields, milestones, where sprints are planned from), **Deploys** (Track
deployments), **Gardening**, **Sharing** and **Manage** (save the lists as a
template, archive, delete). One Save covers General and Features, and what is
typed on one is kept while you look at the other. `?tab=gardening` on the
settings address opens on that tab.

### Agentic Building

A board that coding agents build on has a page for how they do it.
Turn on **Agentic Building** in Board settings, Features (`slipdock
set-board <board> --agentic-building on`, `update_board`
`agentic_building`, `PATCH /api/boards/:board {"agentic_building": true}`)
and the board menu gains **Agentic Building**, beside Automations, for the
board's owner. It opens `/boards/<id>/agentic`. At its top are five tiles, the places
you look every day, each with a count that says whether it needs a look
(read again every half minute): **Right now** (runners working, cards in
progress and jobs queued; it opens [Right now](right-now.md)), **Runners** (online of all, jobs running
and queued; it opens Automations, where the Runners panel is),
**Findings** (open), **Ledger** (shipped since 07:00 yesterday) and
**Health** (stuck, and how many need a person). A tile that needs a look
has a dot; one with no runner online while work is queued, or with work
flagged for a person, is ringed. Findings, Ledger and Health each lead
back to Agentic Building beside the board's name. With the switch off they
still open by their addresses. Under the tiles is a strip of the rules
that are on, each a jump to its section, then the sections:

- **Verified work**: a bar before work starts, evidence on completion, a
  second agent verifies, and with it the verify pool, the rejection limit,
  audits and how accepted work ships.
- **Lanes**: what an overlap does, and the shared paths.
- **Profiles**, and the human tier by profile.
- **Who gets asked**: who each kind of question goes to.
- **Handoffs**: their label and the instructions for Auto generate.
- **Findings**: when a finding is promoted to a proposed rule.
- **Runners**: WIP limits holding automated work, and how long runner job
  logs stay.

One **Save** at the foot of the page covers them all. Anyone else who can
read the board sees the page read-only. On a sub-board the settings kept
for the whole tree (the human tier and the job logs) are shown read-only,
with a link to the root board's page where they are set.

Turning the switch off hides the menu item and the page. It changes no
setting, so rules already set go on holding: the switch warns, naming
them, before you save, and so do the API, the CLI and MCP when it is
turned off. Boards that had any of these set when the page arrived have it
turned on, and a card's subcards take their parent board's switch.

---

← [Your boards](your-boards.md) · [Contents](../manual.md) · [Favourites](favourites.md) →

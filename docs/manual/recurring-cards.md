[Slipdock — the manual](../manual.md)

## Recurring cards

Repeating work — "every Monday: review invoices", "first of the month: renew
the certificate", "water the plants three days after I last did" — lives on
the card it repeats. The card is the series' current instance; when the next
one comes due, the server makes it by **copying the current instance as it is
then**, so a checklist or description you improve carries forward. The title
stays the same; each occurrence's short name adds its due date
(`Weekly review 2026-11-02`), so a series' folders tell themselves apart.

**Setting it.** On the card, under **Repeat**, press **Repeat…**. Pick a
preset, worded for the card's date — daily, every weekday, weekly on its day,
monthly on its date, monthly on (say) the second Tuesday, yearly, or a week
after the last one is done — or **Custom…** and write a rule of your own.
Then the time each one is made (07:00 unless you say), how many days early to
make it, what happens if the last one is still open, and when it ends (never,
on a date, or after a number of times). The form shows the rule in words —
*Every 2 weeks on Mon and Thu, 07:00 Europe/London* — and the next three
dates before you save. Afterwards the same place shows what is next, with
**Skip next**, **Pause**/**Resume**, **Change…** and **Stop**, and the card's
front carries a **↻**, the rule as its tooltip.

A card with no due date becomes the series' first occurrence: it is given the
first date the rule falls on from today.

**Rules.** The phrases quick add, the CLI and the API take:

| Phrase | Means |
| --- | --- |
| `day`, `3d` | every day, every 3 days |
| `weekday` | Monday to Friday |
| `mon`, `mon,thu`, `2w mon thu` | weekly on those days, every 2 weeks |
| `week`, `2w`, `fortnight` | on the first instance's weekday |
| `month`, `month 1`, `month 15th`, `month last` | monthly on the first instance's date, the 1st, the 15th, the last day |
| `month first mon`, `month last fri`, `3m 1` | the first Monday, the last Friday; every 3 months on the 1st |
| `year` | yearly on the first instance's date |
| `3d after`, `2w after`, `month after` | that long after the last one is **done** |

Or an RRULE subset: `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY` with `INTERVAL`,
`BYDAY` (`MO`, or `1MO`/`-1FR` in a monthly or yearly rule) and `BYMONTHDAY`
(`-1` is the last day). A day past the end of a short month — the 31st in
April, 29 February in 2027 — falls on that month's last day rather than
being skipped.

**When the next one is made.** Each instance is made at its time, in the
series' timezone, on the day it is due (or the days early you set), copied to
the top of the list you named, else the board's **Scheduled** list when it
has one, else its ready list:

- title, description, priority, cover, tags, the estimate, and on a board
  that verifies work the bar's text, the paths and the profile come along
  (but the Sweep Tool's *Sweep the code* card takes the Tool's template bar,
  which names no Rotation cell, not the last run's text; see
  [Tools](tools.md));
- the checklist comes along unticked, and subcards are copied into a new
  sub-board, every one reopened in its ready list;
- the next instance **starts clean**: none of the last one's work state comes
  with it — no assignees, no flags, no % complete, no handoff, no waits, no
  evidence and no bar lock. A runner that worked the last one assigned it to
  itself, and the runners' rules take only unassigned cards, so a copy that
  kept it would sit unworked;
- comments, dates other than the new due date, time spent, attachments, links
  and dependencies don't.

Each later instance says which it was copied from — **Copied from #N** under
**Repeat**, `Copied from:` in `slipdock card`, `copied_from` in the card's
JSON — so a surprise in one is one click from where it came from.

**Not stacking up.** If the last one is still open when the next is due, the
default (*Move its due date on*, `bump`) moves its due date to the new
occurrence and comments "Missed occurrence of …", so a forgotten weekly chore
is one card, not six. *Skip this one* (`skip`) leaves it alone and lets the
occurrence go; *Make another anyway* (`stack`) makes the new one regardless —
right for timesheets. A server that was down catches up once, to the latest
occurrence, never one per missed date.

**The Scheduled list.** A list in the `scheduled` category is where
recurring agent work lands: the nightly sweep, the handbook's reconcile and
triage, anything a runner should do on a day. Nobody picks from it, people
or agents. The agent guide never reads it as the ready list (it shows it as
`scheduled: worked by feed rules, never take work from it`), so the daily
cards no longer push in above your own To Do. Its *Work a list with a
runner* rules (`list_top`) send each card to the runners on its day:

- the stock **Slipdock** and **Simple** templates have one, called
  Scheduled, after To Do; a sub-board made from them (an epic's, a
  sprint's) leaves it out;
- any list can be given the category from its menu, `slipdock set-column B
  Scheduled --category scheduled`, `PATCH /api/boards/:board/columns/:id
  {"category": "scheduled"}` or MCP `create_list`;
- when a list becomes the Scheduled list, each *Work To Do with the … runners*
  rule on the ready list gets a sibling, *Work Scheduled with the … runners*,
  with the same pool and settings, and setting up a runner that works the
  ready list adds one too. A pool with a rule on Scheduled already gets no
  second;
- the Sweep and Handbook Tools put their daily cards there when the board
  has one;
- a Scheduled card still there after the end of its due day (in the board
  owner's time zone) means its feed didn't take it: it comes onto the owner's
  **Waiting on you** as *Scheduled for Sun 8 Nov, not started*
  (`scheduled_missed`). Its time in the list is never "over usual", and the
  gardener's stale and abandoned checks leave it alone.

A series with a list of its own still uses that list.

**The Housekeeping list.** A list in the `housekeeping` category (a new
list called Housekeeping takes it by itself) is where the small fixes and
investigations the sweep, findings triage, the health monitor and agents
file wait. It gets the same siblings as Scheduled, *Work Housekeeping with
the … runners*, made at the same times, but each is a **backfill** feed
(`backfill: true` on its `list_top` trigger; it reads *… only when To Do
and Scheduled have nothing this pool could start*). It sends a card only
while its pool's rules on the ready list and Scheduled have nothing they
could send: a card that is blocked, flagged blocked or waiting, snoozed,
held by its lane or already has a job doesn't count. So the order is To
Do, then Scheduled, then Housekeeping, and a card moved into To Do goes
before the next Housekeeping one. A Housekeeping job already running is
never stopped for To Do work. The health monitor's *Feed sitting idle*
leaves a backfill feed alone while it waits its turn, and the agent guide
marks the list `housekeeping: worked by runners after the ready list`.

**After done.** An after-done series makes nothing until its current instance
is completed; then the next is due that long after the day it was done (in
the series' timezone), and it waits again.

**Timezones.** Times are in the timezone of whoever set the series, kept on
the series, so it doesn't move if they travel. Yours is taken from your
browser the first time you sign in and can be changed under **Account →
Profile**. The older *schedule* automation trigger still runs in UTC.

**What else touches it.** Archiving the current instance pauses the series
(the card says so); deleting it stops the series. Moving the card to another
board takes the series with it. Exports between servers carry the series and
carry on from where it had got to. If the board's owner is out of cards, the
series pauses and the card says why, rather than trying every minute.

From a terminal and over the API:

```sh
slipdock repeat 12 "every mon" --at 08:00          # or --lead 2, --ends 2027-06-30, --count 10
slipdock repeat 12 "month last fri" --on-missed stack
slipdock repeat 12                                 # how it repeats, and the next three dates
slipdock repeat 12 --skip | --pause | --resume | --off
slipdock recurring ops                             # every card on the board that repeats
```

```
PUT    /api/cards/:id/recurrence       {"rule": "every mon", "at": "08:00", …}
GET    /api/cards/:id/recurrence
DELETE /api/cards/:id/recurrence
POST   /api/cards/:id/recurrence/skip
GET    /api/boards/:board/recurring
```

A card's JSON carries `recurrence` (and `series_id` on every instance); over
MCP, `get_card` shows it and `update_card` takes `recurrence` (an object, or
`null` to stop it).

**Duplicate.** The same copy, made by hand: **Duplicate** in the card's
**⋯** menu (top right, beside the heart) puts a copy straight after it and opens it (`slipdock copy 12`,
`POST /api/cards/:id/copy`, with `board`, `column`, `title` or `at: top`).

---

← [Delivery metrics: deploys and DORA](delivery-metrics-deploys-and-dora.md) · [Contents](../manual.md) · [Snoozing cards](snoozing-cards.md) →

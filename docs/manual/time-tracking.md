[Slipdock — the manual](../manual.md)

## Time tracking

Every card has a **Time** section in its panel, under the list, priority and
dates:

- **Spent** and **Estimate** are typed in the card's **unit** — minutes, hours,
  days, weeks or months, hours unless you change it. A bare number is in that
  unit; a suffix says otherwise, so `90m`, `1.5h`, `2d`, `1w`, `1mo` and
  `1h 30m` all work wherever a time is asked for. Leave the estimate empty to
  have none.
- Both are kept in minutes, and the unit is only how they are shown: switching
  a card from hours to days changes nothing recorded. The longer units are
  working time — **a day is 8 hours, a week 5 days, a month 4 weeks** — so an
  estimate of `2d` is 16 hours of work, not 48 of the clock.
- **Start timer** runs a clock on the card, counting up on the button; **Stop**
  adds what it ran, to the nearest minute, to the time spent. Starting a timer
  that somebody else already started leaves theirs running. The time is kept
  on the server, so closing the tab does not stop it.
- **Log time** adds a stretch by hand — `45m`, `2h`. A minus sign (`-30m`)
  takes time off, never below nothing.
- The **bar** is time spent (with a running timer's time so far) against the
  estimate. It is green below 80%, amber from 80% to 100% and red past it; over
  the estimate it fills and a tick marks where the estimate fell, and the text
  says by how much it ran over.

On the board, **Time tracked** is a card element (show it in your
[card views](card-views.md)): a clock chip, `1.5h/4h` with a small bar in the same colours, pulsing while a timer
runs. The table has a **Time** column. Every change — set, logged, timer
started and stopped — goes in the board's activity, and exports carry time
spent, the estimate and the unit.

From the CLI:

```sh
slipdock edit 12 --estimate 2d --unit days      # the estimate, and how the card shows time
slipdock edit 12 --spent 3h                     # set what has been spent;  --no-estimate clears one
slipdock log 12 45m                             # add time by hand  (edit 12 --log=-15m takes some off)
slipdock timer 12 start                         # ... later:
slipdock timer 12 stop                          # adds the minutes it ran
slipdock card 12                                # Time: 1.25d spent of 2d estimated (63%)
```

---

← [Calendar](calendar.md) · [Contents](../manual.md) · [Where it was left (handoffs)](where-it-was-left-handoffs.md) →

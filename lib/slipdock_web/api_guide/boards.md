
## Your boards right now

<%= @body %>

The name in backticks after each board is its `code` — the short name for
it, and the one to use when you address a board by anything but its id.

**Never take work from a Scheduled list.** A list marked `scheduled`
(category `scheduled`) is where recurring agent work lands: a recurring
card's next one is made there. Feed rules work it, sending its top card
to a runner pool. People don't, and nor does an agent asked what to do
next: it is never the ready list or the backlog, and the boards below
mark it `scheduled: worked by feed rules`.
<%= @housekeeping %>
Sub-boards are not listed here — they hang off their epic's `sub_board`.
<%= @archived %>

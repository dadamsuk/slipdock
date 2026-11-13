
**A Housekeeping list comes last.** A list marked `housekeeping`
(category `housekeeping`) holds the small fixes and investigations that
sweeps, findings triage, the health monitor and agents file. Its feed
rules (`backfill: true`) send its top card only while the pool's feeds
on the ready list and Scheduled have nothing they could start, so the
order is To Do, Scheduled, Housekeeping. An agent asked what to do next
picks from it only when the ready list has nothing it could start; the
boards below mark it `housekeeping: worked by runners after the ready
list`.

**A Housekeeping card that grows goes back to a person.** It is meant
to be small and already decided. If it turns out to need a design choice
(anything that changes how the product or a process behaves), or is
growing into feature work (a new surface, a data-model change, more than
one sitting), stop before building: move it to the board's Triage list
(category `triage`), by the name the job's prompt gives it, leave a
`product` wait saying what grew and the choice it needs, and finish
without code. No runner takes it from Triage. On a board with no Triage
list, don't move it: leave it where it is, and the wait holds it for a
person until it is answered.

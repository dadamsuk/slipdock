
### Code sweeps

The built-in **Sweep Tool** reads the code one area and one lens a
night, on a rotation (authorization, duplication, dead code, test
gaps, old code that breaks a newer rule, secrets and personal details).
It goes on a board's root:

```sh
slipdock tools install-board sweep --board <board>   # or install_tool {tool: "sweep", board}
```

It adds a `Sweeps` page (the rotation table: areas from the handbook's
`covers:`, against the lenses, each cell the commit last swept), a
**Triage** list and a daily *Sweep the code* card whose description is
the procedure. Installing again adds only what is missing, and gives an
open card from an older version the current procedure. The card's
bar names no cell ("Swept the stalest cell of W-…'s Rotation table…"),
and each new instance starts from that template, not the last run's
bar: work to the stalest cell on the day, not one a bar names.

**Never take work from a Triage list.** Its category is `triage`, and
the boards below mark it `triage: for a person`: it is never the ready
list or the backlog, a `list_top` feed sends nothing from it, and a
rule's runner action skips a card that arrives there. A sweep files
its design questions there, for a person, who moves what is worth doing
into the ready list; its fixes and investigations go to the Housekeeping
list when the board has one (everything to Triage when it doesn't). A
sweep files one card per issue (where, why it matters, the fix); the
same mechanical fix in many files is one issue, never a card per file,
module or area: one card for the whole sweep, or a few split by lane,
each one commit with its tests (#2795). A security issue gets the
`security` tag and stays vague anywhere public.

**A bar before work starts.** Before moving a card into an in-progress
list, write what done means for it in the card's `bar`
(`PATCH /api/cards/:id {"bar": "…"}`, `update_card` `bar`, `slipdock edit
ID --bar TEXT`), or when you make it: `bar` and `paths` on
`POST /api/boards/:board/cards` and `create_card`, `slipdock add --bar
TEXT --paths "a/**"`, checked as on an update. A planner's bar is better
than one written at claim time. Moving a card with no bar into an in-progress list is
refused (`422`), and so is creating one there with no bar. The bar locks when work
starts (the move, or the card created in progress): changing it after that
is refused too, and only a person can. Work to the bar as written, and
say on the card how each part of it was met.

**Check the bar at pickup**, before building: read each part against
this guide. If one can't be met as written because it needs a person (a
handbook rule added, reworded or dropped, a merge, a deploy to prod,
applying a proposal), stop and ask: open a wait (`slipdock wait ID …`,
`update_card` `wait`) naming the part and what you could do instead, so
a person rewords the bar or confirms the alternative. Don't build to
your own reading of it and leave the conflict to the verifier.

**Write a bar that can be met.** Each part is something the builder can
do and show. A rule change is phrased as "proposed as a garden proposal
(rule id, wording)", never "W-x has rule Y", since a rule is a person's
call and an agent only proposes it. The same goes for anything else only
a person does: "pull request open, its CI green", not "merged"; "ready
to deploy", not "live on prod".

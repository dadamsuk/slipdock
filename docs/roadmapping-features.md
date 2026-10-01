# Roadmapping features: what the field does, and what fits here

Date: 2026-09-26. Status: investigation only, nothing implemented. Sources
are the vendors' own docs as of September 2026 (list at the end); a few
2026 release-note details rest on search snippets where the pages would not
render.

Tools reviewed: Jira Product Discovery (JPD; still that name, now inside
Atlassian's "Product Collection" bundle with a separate Feedback tool),
Aha! Roadmaps and Aha! Ideas, Productboard, Linear, ProductPlan, Tempo
Strategic Roadmaps (ex-Roadmunk), airfocus, ProdPad, Craft.io, Shortcut,
GitHub Projects, Asana, Notion and monday.com templates.

## 1. What we already have

The tree model covers more of the roadmap problem than most of these tools
do out of the box, so the gaps are narrower than the feature lists suggest.

| Roadmap concern | Already here |
|---|---|
| Hierarchy (goal → initiative → epic → task) | Cards with sub-boards to any depth; the Roadmap template (Now · Next · Later · Done) at the top |
| Progress roll-up | `Slipdock.Rollup`: leaves done/total, effective dates, slip, blocked, overdue, health |
| Timeline / Gantt | Timeline view with zoom, drag, group-by, nested subcards, dashed derived bars |
| Now / Next / Later | A template of lists; swimlanes and table give columns on any attribute |
| Table / pivot | Table view with grouping, column chooser, inline edit; swimlanes as a two-axis pivot |
| Parking lot | The Unscheduled tray on the timeline |
| Dependencies | Blocked-by / blocks with cycle detection, badges, a swimlane axis |
| Saved and shared views | Saved views per board, shareable read-only or editable with people and groups |
| Assignees, my work | Assignee field, `/work` across boards |
| Activity | Per-board activity log |
| API / CLI | JSON API and `slipdock` CLI for everything above |

## 2. The landscape in one paragraph each

**Jira Product Discovery** is "custom fields plus views". An idea is a work
item with typed fields (number with colour thresholds, 1–5 rating, 1–100
slider, select whose options carry numeric weights, date, interval, people,
team). Formula fields are roll-ups (sum), weighted scores (each input
normalised 0–100 across the space, times a weight; negative weights for
effort), or free expressions. Views are list, board (columns = values of any
field, drag changes the value), matrix (two numeric fields as axes, a third
as bubble size, drag to change), timeline (start and target date fields,
weekly to quarterly scale, named coloured time markers), and tree (Premium,
up to ten levels built from "connection" fields). Insights are evidence
attached to an idea: rich text, an unfurled link, an impact rating, labels;
their count and impact feed formulas. Delivery linkage creates or links Jira
epics and rolls status and progress back by count or story points; a date
field can autofill from the earliest or latest linked item. Votes are
budget voting (N votes per person, max per idea). Stakeholders see published
read-only views by link. Free contributors can add ideas, insights, votes
and comments but cannot edit views.

**Aha!** is the maximal object model: vision → goals (with success metric,
time frame, progress calculated from linked work) → initiatives → releases
(internal and external dates, phases, milestones, templates) → epics →
features → requirements, with roll-up across workspace lines. Roadmap types
are strategy (initiative bars), portfolio (release bars per workspace),
features (features grouped by release), now/next/later (columns driven by a
chosen date field with fixed, rolling or custom ranges), Gantt (drag a ball
to create a dependency; late links go red; optional auto-shift of dependents)
and custom (any record type as bars or dots, grouped by any field, undated
records as infinite bars, manual milestone lines). Scorecards are weighted
metrics with an editable equation; a prioritisation page stack-ranks with
"priority limit lines" showing what fits a time frame. Record links have
eight relationship types (relates to, depends on, blocks, impacts, contains,
duplicates, has research in, release notes in) across workspaces. Ideas
portals add voting, proxy votes weighted by customer revenue, merge and
promote. Reports, dashboards and presentations publish live views as web
pages. Enterprise+ adds automation rules, capacity scenarios, custom tables.

**Productboard** is the evidence chain: a note (from Zendesk, Slack, email,
Chrome extension) is highlighted and linked to a feature as an insight with
an importance rating; the feature's Customer Importance Score sums those,
capped at 3 per company so one loud customer cannot dominate, and segments
(hand-picked VIPs or rule-based on ARR) become grid columns showing where a
score comes from. Drivers are 0–5 criteria with weights. Roadmaps are
columns boards (abstract buckets: now/next/later, releases, objectives) or
timeline boards (a timeframe field positions bars, four nesting levels,
time horizons snap cards to whole units, Shift-drag moves a row without
changing dates). A portal shows Under consideration / Planned / Launched
and votes flow back as insights.

**Linear** derives the roadmap from execution data. Initiatives → projects →
milestones → issues. Projects have start and target dates at chosen
precision (day, month, quarter, half, year), a progress graph with a scope
line and velocity forecast bands, and updates (on track / at risk / off
track plus text) on an admin-set cadence with reminders; updates roll up to
the initiative and can be drafted by AI from recent activity. Project
dependencies draw as lines, red when the dates violate them; dragging a
project drags dependents that are still planned. Triage is an inbox with
accept/decline/duplicate/snooze and rotation.

**ProductPlan** has lanes (rows) × legend (colour) as its two axes, bars and
expandable containers, and a parking lot that keeps hidden dates and
restores them on unpark. Portfolio views union several roadmaps with
explicit policies for how legends and lanes merge.

**Tempo Strategic Roadmaps** treats a roadmap as a table of items with
fields; every view is a pivot. Swimlane view puts any field on either axis
with a second row-group level. Bucketed date fields give fuzzy scheduling;
key dates are named phase markers pinned inside a bar that move with it,
distinct from roadmap-level milestones. Portfolio roadmaps roll up chosen
views from several roadmaps with two-way edits.

**airfocus** composes workspaces from apps. Priority Poker is planning poker
for prioritisation: invited people (including non-users on a phone) rate
each criterion blind, the owner flips the results to expose disagreement.
Item mirroring shows one item in several workspaces; check-ins are status
updates with a confidence value.

**ProdPad** invented now/next/later and insists time lives on the objective,
not the item. **Shortcut** splits objectives into tactical (epic roll-up)
and strategic (key results with start/current/target). **GitHub Projects**
roadmap layout drives bars from any date or iteration field and shows
numeric sums in group headers. **Asana** derives goal progress from linked
projects. **Notion** and **monday.com** are databases with views and no
roadmap object.

## 3. Feature catalogue against this app

Each row: what the tools do, what we have, and how it would fit the existing
schema. "Fit" is a rough size: S is a day or two, M a week, L longer.

### 3.1 Time: horizons, fuzzy dates, markers

| Feature | Elsewhere | Here | Fit |
|---|---|---|---|
| Date precision | Linear projects target a day, month, quarter, half or year; Tempo has bucketed date fields; JPD an interval field | Cards have exact `start_date` and `due_date` only | S. Add `date_precision` (day/week/month/quarter/half/year) on the card. Timeline draws the whole bucket as a bar with a soft edge; calendar and due filters use the bucket end. Drag snaps to the bucket. Roll-ups already compute from dates. |
| Horizon columns tied to dates | Aha! now/next/later columns are ranges on a date field (fixed, rolling 60/90 days, or custom); Productboard time horizons snap cards to whole units | The Roadmap template's lists are plain lists with no dates | S–M. Optional `horizon_start` / `horizon_end` (or a rolling `horizon_days`) on a column. Dropping a card into the column sets its due date to the bucket end at the column's precision, exactly as the date swimlane axis already does. A card whose date leaves the range gets a "drifted" hint. Keeps the list model, adds meaning. |
| Milestones / time markers | JPD named coloured vertical lines; Aha! manual milestones; GitHub iteration markers; Linear diamond markers with % complete; Tempo key dates pinned inside bars | Nothing beyond "today" | S. A `milestones` table on the root board (name, date, colour, optional card). Drawn on timeline and calendar, listed in the outline header. Pinning a milestone to a card gives Tempo's key dates for free. |
| Colour legend on timeline | ProductPlan legend; Aha! colour by status/assignee/type; Linear health colour | Timeline bars use cover colour; health as chips | S. A "colour by" display option (cover, list, priority, health, assignee, tag) on timeline and swimlanes, with a legend. Pure view work. |
| Move a row without changing dates | Productboard Shift-drag | Not applicable yet | Comes with timeline row reordering if that is ever added. |

### 3.2 Dependencies on the plan

| Feature | Elsewhere | Here | Fit |
|---|---|---|---|
| Dependency lines on the timeline | Linear and Aha! draw connectors; red when the dependent is scheduled before the blocker | Dependencies exist, but the timeline does not draw them | S–M. SVG overlay from blocker bar end to blocked bar start; red when `blocked.start < blocker.due`. A "violated dependencies" filter, as Linear has. Uses effective (rolled-up) dates so parent cards work. |
| Auto-shift dependents | Aha! workspace setting; Linear drags planned dependents with the project, Cmd pins, Shift moves the chain | Drag moves one card | M. When a bar is dragged and its dependents are not started or done, offer to shift them by the same delta. Needs a "started" notion: the column being the first, or a start date in the past. |
| Typed links | Aha! eight relationship types across workspaces; JPD connection fields across spaces | Only blocked-by, only within one board | M. Generalise `card_dependencies` to `card_links` with a `kind` (blocks, relates, duplicates, contains) and allow cross-board links within one tree, or across trees. `blocks` keeps the cycle check and the rollup semantics; the rest are informational. This is also how goals get done (3.4). |

### 3.3 Prioritisation

| Feature | Elsewhere | Here | Fit |
|---|---|---|---|
| Custom fields | JPD: number with colour thresholds, rating, slider, select with weighted options, date, people, team; Aha! and Tempo similar; Productboard drivers 0–5 | Fixed fields: priority, flags, tags, dates, colour | L, and foundational. `field_definitions` on the root board (name, type, options with weights, position) and `card_field_values` (card, field, number / text / date / option). Show in the card modal, table columns, table and swimlane axes, filters, sort, API and CLI. Everything below in this section depends on it. |
| Scoring / formula field | JPD weighted score normalised 0–100 per input; Aha! scorecard with editable equation; Productboard weighted drivers; airfocus RICE presets | None | M once custom fields exist. A field of type formula with a small expression language over other fields (`{reach} * {impact} * {confidence} / {effort}`), or the JPD weighted form (weights per input, negative for effort). Computed on load like the rollup; sortable; shown as a chip. Ship RICE, ICE and value/effort as presets. |
| Effort × impact matrix | JPD matrix with bubble size and drag; Productboard prioritisation matrix; airfocus chart | Swimlanes already put any attribute on two axes and change values on drop | S once numeric fields exist. Let a numeric or rating field be a swimlane axis, bucketed (1–5, or quintiles). A 5 × 5 swimlane grid with drag-to-rescore is the matrix. A true scatter can come later. |
| Estimates rolled up | Aha! estimates roll from requirements to features; GitHub sums numerics in group headers; JPD progress by story points | Roll-up counts leaves only | S. A numeric `estimate` field (or any numeric custom field flagged "sum") added to the rollup: `estimate_total`, `estimate_done`. Progress bars can then weight by estimate; table group headers show sums. |
| Priority limit line | Aha! stack-rank with a line showing what fits a time frame | Board order is a stack rank | S once estimates and capacity exist: a per-column "capacity" number (extending `wip_limit`, which counts cards) so the column shows how far down the rank the capacity reaches. |
| Voting | JPD budget voting (N per person, max per idea, one round per field); Aha! votes and revenue-weighted proxy votes; airfocus Priority Poker | None | M. A `votes` table (card, user, count, comment) with a per-board budget. Sum as a sortable value and a formula input. Priority Poker is a nice later addition: a session where each person scores blind and results flip together. |

### 3.4 Strategy objects: goals and themes

| Feature | Elsewhere | Here | Fit |
|---|---|---|---|
| Goals / objectives linked to work | Aha! goals with metric and progress from linked work; JPD Goals field with group-by; Shortcut key results; Asana goal progress derived from projects | A top-level card in the Roadmap template plays the goal; its subcards are the work. Nothing links work on *other* boards to it | M. Two options. (a) Cheap: a `goal` flag or card kind, plus typed `relates`/`contributes to` links from cards anywhere to a goal card; a Goal axis on swimlanes and table. Roll-up progress for a goal then counts linked cards as well as subcards. (b) Nothing new: keep goals as top cards and rely on the tree. Recommend (a) only if cross-board work is common; otherwise the tree already does it. |
| Key results | Shortcut start/current/target numbers; Aha! success metric | None | S after custom fields: a "metric" field type with start, current and target giving a percentage. |
| Themes | JPD theme select; Aha! release themes; ProductPlan legend | Tags | Done. Tags plus colour-by cover it. |

### 3.5 Status, health and history

| Feature | Elsewhere | Here | Fit |
|---|---|---|---|
| Status updates with a stated health | Linear on track / at risk / off track with text, cadence reminders, roll-up to the initiative, AI-drafted; airfocus check-ins with confidence; Asana status builder | Health is computed from the tree; comments exist | S–M. A `status_updates` table (card, user, health, body, inserted_at), or a comment with a `health` column. The card shows the latest stated health beside the computed one, and the outline and timeline use stated health when present. Optional cadence reminder later. |
| Progress and scope graph | Linear project graph with scope line, velocity forecast, optimistic/pessimistic bands | Roll-up is a point in time | M. Nightly `rollup_snapshots` (card, date, done, total, estimate figures). Draw done and total over time; a straight-line forecast from the last N weeks gives an expected finish to compare with the due date. |
| Time in column / cycle time | Common in kanban tools rather than roadmap tools | Activity log records moves | S. Derive from activity; show "in this list for 12 days" on the card. |

### 3.6 Evidence and intake

| Feature | Elsewhere | Here | Fit |
|---|---|---|---|
| Insights attached to a card | JPD: text, unfurled link, impact rating, labels, count feeds formulas; Productboard: highlighted note linked with importance, capped per company | Comments and attachments | M. An `insights` table (card, body, url, impact −2..+2 or 0..3, source label, optional customer/company). Card modal tab, a count chip, `insight_count` and `insight_impact` as formula inputs. Capping per source as Productboard does is a one-liner in the aggregate. |
| Capture channels | JPD Chrome extension, Slack and Teams shortcuts, service-desk intake, API; Productboard email and forms | JSON API and CLI | S. The CLI can gain `kanban insight <card> --url --impact`, and an inbound mail address or a public form is a small controller. A browser extension is out of scope. |
| Triage inbox | Linear triage with accept/decline/duplicate/snooze and rotation | An "Inbox" list on a board does most of this | S. A board setting naming an intake list, a "merge into" action that moves insights, links and comments to the target card and archives the source (JPD and Aha! both have merge). |
| Ideas portal with public voting | Aha!, Productboard, airfocus | None | L. Skip; this is a product of its own. A published read-only view (3.7) plus the form above is the lightweight version. |

### 3.7 Sharing, portfolio, publishing

| Feature | Elsewhere | Here | Fit |
|---|---|---|---|
| Published read-only view by link | JPD published views with public link, no login; Aha! secure web pages syncing every five minutes; Tempo live URL | Saved views can be shared with signed-in users only | S–M. A `public_token` on a saved view; `/p/:token` renders the view read-only with a chosen set of fields, no account needed. Revoke by regenerating. Optional password as Aha! does. |
| View comments | JPD per-view discussion | None | S if wanted. |
| Portfolio view across root boards | Aha! portfolio roadmap; ProductPlan portfolio with legend and lane merge policies; Tempo master roadmaps; JPD cross-space roadmaps needing global fields | `/work` already crosses boards; views are per board | M. A "portfolio" that names several root boards and offers timeline, table and outline over their top-level cards, one lane per board. Custom fields would need to be defined per portfolio or matched by name, the same problem JPD solves with global fields. |
| Export | CSV everywhere; PNG and PDF in Aha! and Tempo; Confluence embed | JSON via API | S. CSV from the table view; the CLI already prints tables. |
| Presentations, dashboards | Aha! dashboards up to twenty panels and live slides | None | Skip. Published views cover the need. |

### 3.8 Configuration and automation

| Feature | Elsewhere | Here | Fit |
|---|---|---|---|
| Workflows with status categories | Aha! statuses mapped to Not started / In progress / Done / Shipped / Will not do; JPD per-type workflows | Lists are the workflow; `completed` is the only category | S. A `category` on a column (todo / doing / done / dropped). Moving into a done column completes the card; rollups and cycle time use the category. Templates carry it. |
| Automation rules | Aha! trigger + conditions + actions; JPD via Jira Automation incl. manual triggers | None | M–L. Skip for now. Board-level rules like "when a card completes, complete its checklist" are cheap, but the general engine is not, and the API plus a cron script gets most of the value. |
| Card types with their own fields | JPD idea types (problem, opportunity, solution, bet) with per-type fields | Templates decide the lists at each level, which is a similar idea | Skip. Depth in the tree already stands in for type. Revisit if custom fields want per-level defaults. |
| AI drafting and summarising | Everyone, 2026 | None | Skip for now. The one cheap and useful piece is Linear's "draft the status update from recent activity", which is a prompt over the activity log. |
| Capacity planning | Aha! scenarios, teams, work schedules; Craft.io velocity comparison | None | Skip. Column capacity plus estimates (3.3) is the small version. |

## 4. Recommendation

Three tiers, in order. Each item names the sections above.

**Tier 1, small and clearly worth it.** They use the schema as it stands and
make the timeline and outline read as a roadmap rather than a Gantt of tasks.

1. Milestones on the root board, drawn on timeline and calendar (3.1).
2. Dependency lines on the timeline with red for violated dates, and a
   "violated" filter (3.2).
3. Date precision on cards, so a card can target a month or a quarter and
   the Now/Next/Later columns can carry date ranges that set it on drop (3.1).
4. Colour-by with a legend on timeline and swimlanes (3.1).
5. Stated health: status updates with on track / at risk / off track shown
   beside the computed health (3.5).
6. Column categories so "done" and "dropped" are known to the roll-up (3.8).
7. Public read-only links for saved views (3.7).
8. CSV export from the table (3.7).

**Tier 2, one foundational change and what it unlocks.** Custom fields are
the single thing every tool here shares and we lack; almost every
prioritisation feature is a view over them.

1. Custom fields per board tree: number, rating, select with weights, date,
   text (3.3).
2. Formula field with RICE, ICE and value/effort presets (3.3).
3. Numeric fields as swimlane axes, giving the effort × impact matrix (3.3).
4. Estimate roll-up and sums in group headers (3.3).
5. Typed cross-board links, which also gives goals a way to collect work
   from other boards (3.2, 3.4).

**Tier 3, later.** Insights with impact and a per-source cap; budget voting
and maybe Priority Poker; roll-up snapshots and the progress graph; auto-shift
of dependents on drag; portfolio views over several root boards; merge card;
intake by mail or form; automation rules.

**Skip.** Ideas portals, capacity scenarios, presentations and dashboards,
whiteboards, AI features beyond drafting a status update, per-type card
schemas.

## 5. Ideas worth stealing outright

- **Normalise scores across the board, not by hand** (JPD): each formula
  input is scaled 0–100 over the cards present, so fields with different
  ranges combine without the user thinking about units.
- **Cap evidence per source** (Productboard): one customer's ten complaints
  count as three, so the score reflects breadth.
- **Red dependency lines** (Linear, Aha!): the cheapest possible warning that
  a plan is inconsistent, no scheduler needed.
- **Time lives on the horizon, not the card** (ProdPad, Aha! now/next/later
  ranges): the column says "next quarter"; the card's date is derived. Our
  drag-onto-date-axis already behaves this way.
- **Stated health beside computed health** (Linear): the roll-up says what
  the data implies, the owner says what they believe, and the gap is the
  interesting bit, just as slip already is for dates.
- **Undated items as infinite bars** (Aha! custom roadmap) is one option
  for the timeline; our unscheduled tray is the other. Offer both.
- **Parking lot keeps its dates** (ProductPlan): if a card is ever
  "parked", keep its dates hidden rather than clearing them.

## Sources

Jira Product Discovery: product page and pricing at atlassian.com/software/jira/product-discovery;
support.atlassian.com/jira-product-discovery/docs/ (fields reference,
expression-based formulas, what-are-insights, create-a-matrix-view,
create-a-timeline-view, understand-tree-view, share-project-views,
create-a-roadmap, configure-the-delivery-progress-field,
configure-autofill-dates, integrate-with-atlas, about-automation);
community.atlassian.com JPD articles on Q1 2026 shipping, weekly timeline
granularity, tree view early access, connection fields GA, Insights API;
atlassian.com/blog/company-news/introducing-product-collection.

Aha!: support.aha.io articles on strategy introduction, goals, initiatives,
features introduction, roadmaps introduction, strategy / portfolio /
now-next-later / custom roadmaps, customize Gantt view, custom scorecards,
prioritize initiatives, capacity planning, ideas and portals, releases and
release templates, release dependencies, record links, custom fields,
workflows, automation, dashboards, presentations, Jira integration 2.0;
aha.io/roadmaps/pricing; aha.io blog posts on multiple scorecards and Q1/Q2
2026 features.

Productboard: support.productboard.com articles on roadmaps quick start,
timeline boards, Customer Importance Score, customer segments, drivers and
prioritization scores, prioritization matrix, portals.

Linear: linear.app/docs on initiatives, projects, project milestones,
initiative and project updates, project graph, project dependencies,
timeline, cycles, triage; changelog entries of 2026-07-02 and 2026-08-13.

ProductPlan: support.productplan.com on roadmap hierarchy, table layout,
parked items, portfolio view. Tempo: help.tempo.io/roadmaps on swimlane
view, key dates, portfolio roadmapping, publishing. airfocus:
airfocus.com/product and Lucid help on Priority Poker and Priority Ratings.
ProdPad, Craft.io, Shortcut, GitHub Projects, Asana: their help centres.
Comparisons: productplan.com best product roadmap software 2026;
storyflow.so best product planning tools 2026.

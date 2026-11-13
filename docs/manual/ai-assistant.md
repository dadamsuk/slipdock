[Slipdock — the manual](../manual.md)

## AI assistant

With a model configured — an OpenRouter key, or an endpoint of your own; see
*Running* — three features appear. Without one they stay hidden, and nothing
is ever sent to a model unless you ask.

- **Chat about this** — the *Chat* button in the header of every board
  page (in any mode) and of *My work* opens a drawer. Each message is sent
  with the page as context: the board, its lists, tags and people, the
  cards the current view shows (title, list, priority, dates, assignee,
  tags, flags, progress, health, blockers), the board's **wiki pages** —
  listed separately, by code and title, because a document is not a card —
  and, when a card is open, that card in full (description, checklist,
  comments, status updates, relations, subcards). The open card also has
  its own *Ask AI about this card* section at the foot of its modal.
  *Open card 123* (or *show card id 123*, *go to #123*) opens that card,
  on any board you can open, without asking the model at all.
- **Ask a card how its work went** — with a card open, the chat also has
  tools over the server's record of that card and every card beneath it,
  so it can answer *why did CI fail?*, *how many times was it verified?*,
  *what is the runner doing on this epic?*:
  - `read_card`, `card_comments` (every comment, a page at a time),
    `card_handoffs`, `card_links` and `card_subcards`;
  - `card_jobs` and `read_job`: each runner job's kind, pool, runner,
    status, when it was queued, claimed, started and finished, every step
    its agent reported (`job-progress --step`) with its time, its exit
    status, error and summary, and its prompt on request;
  - `card_timeline`: the lists it sat in and for how long, each wait with
    its question and answer, and its activity log (flags, snoozes, edits);
  - `card_verification`: the bar, the evidence, each verdict and rejection
    with its reason, audits, the verify and merge jobs, the merge commit,
    and the deploys that shipped it where the board records deploys;
  - `card_lead_time`: where its time went. Its lead time, from creation
    to the first deploy that shipped it (or to done, or now while it is
    open), split into phases: backlog, waiting for a runner (naming the
    jobs that kept the pool busy meanwhile), build, CI, waiting on a
    person, waiting for verification, verify, rework after a rejection,
    merge and deploy. Each second goes to one phase; where things overlap
    the later stage wins (a merge job over the verify job, a wait over the
    job it parked, CI over the build it ran in). CI runs come from the
    `Build started` / `Build failed` / `Build passed` comments a runner
    writes and from steps that mention CI. Time the record holds nothing
    for is *unexplained*, a phase of its own. On an epic it gives each
    subcard's breakdown too, a subcard's build credited to the epic's job
    that ran while it was in progress, and the subcards added up. Beside
    each, what the jobs spent by phase, from their logs: model and tool
    time, and tokens where a log carried them. Ask
    *where did this card's time go?* or *why did #1856 take 78 minutes?*;
  - `job_log_summary` and `job_log`: a job's live log, while the job
    runs, once it has finished, or kept with *Keep this log*. The
    summary comes first, because a log is far too long to read whole: what
    the agent said, step by step; where its time went, split between the
    model and its tools, and the tools by kind (tests, checks such as
    compile, format and credo, CI waits, git, `slipdock`, reading and
    editing code, subagents); its longest calls; and every call that
    failed, with what it said. Each names its line in the log, and
    `job_log` reads a stretch of up to 120 lines in full. A log that has
    expired says so, and when. Ask *where did job #719's time go?* or *what
    failed in the last build?*

  They run as you: a card you can't open isn't read, and a card outside
  the open card's tree is refused. The answer names the jobs and comments
  it used (*job #712*, *comment #4410*) and says plainly what the record
  doesn't hold, such as a CI log beyond what the evidence recorded. Steps
  are kept for every job since this release; an older job shows only its
  last one. Ask in the open card's *Ask AI about this card* section, or in
  the drawer with the card open.
- **Edit mode** — the *Edit* toggle in the drawer (for people who can
  write) turns a request into a list of concrete changes: set or clear
  dates, priority, assignee, flags and tags, the cover colour and the
  colour of each edge (*frame it in red*, *make the top edge blue*), rename, rewrite a
  description, move between lists, complete or reopen, create cards,
  comment, add or tick checklist items, archive cards (one or many:
  *archive the done cards* is a step per card). Ask for a tag the board
  doesn't have yet and it makes it: the step reads *Create tag “x” and add
  it to …*, and the tag (in the default colour, on the top board so its
  sub-boards share it) is only made when you apply. A new tag needs write
  on the board: someone who writes the card by a grant alone can still add
  or remove the tags the board has, but a tag it lacks comes back struck
  through, *only someone who can edit the board makes a new tag; pick one
  it has*. Ask for a tag on several
  cards at once (*tag everything in Doing as urgent*) and it is one step per
  tag naming every card it touches — *Add tag “urgent” to 3 cards: …* —
  leaving out any that already have it. It can also **archive a
  wiki page**, named by its code or its exact title — the one change it
  makes to the wiki, since a document is written in the wiki's own editor
  rather than dictated here. Relative dates are
  resolved from today. Nothing changes until you click *Apply*; every
  step is checked against the page and your permissions first, and
  anything the model got wrong (a tag to remove that isn't there, a card
  not on the page)
  is shown struck through with the reason.
- **Generator** — on the narrative page, *Generate narrative* offers
  five levels — one-liner, three-liner, summary, stakeholder update,
  detailed — and writes prose covering everything the narrative view
  shows (its range, filters, grouping and *Display* choices all apply),
  with a Copy button.

The code lives in `Slipdock.AI` (the client, and which endpoint, key and model
each request resolves to), `Slipdock.AI.Context`
(what the model is told), `Slipdock.AI.Assistant` and `Slipdock.AI.Actions`
(chat, proposals and applying them), `Slipdock.AI.CardRecord` (the card
chat's tools over a card's record), `Slipdock.AI.Narrator` (the generator),
`Slipdock.AI.Researcher` (the tool-calling assistant behind *Ask*, with
`Slipdock.Work` for one person's cards across every board) and the
`SlipdockWeb.AIChatComponent` / `SlipdockWeb.NarrativeGeneratorComponent`
live components. Tests stub the API through `Req.Test` (`Slipdock.AIStub`).

---

← [Deep search and Ask](deep-search-and-ask.md) · [Contents](../manual.md) · [Automations and alerts](automations-and-alerts.md) →

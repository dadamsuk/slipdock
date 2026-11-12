defmodule Slipdock.Handbook do
  @moduledoc """
  A board's handbook (#1261, spec W-1934): wiki pages that describe the
  project as it is now — specification, architecture, UX, components, data
  model, shared modules, testing, operations, principles, the playbook and
  decisions — that every
  coding-loop pass reads before it builds and updates before it closes a
  card.

  It is a **built-in Tool**, `handbook`. A published Tool builds a board of
  its own; a handbook belongs to a board that already exists, so it is
  installed onto one (`install/3`), always the root of its tree: epics are
  sub-boards, and a subcard resolves up to the root board's handbook.

  What makes a board a handbook board is on the wiki itself, so nothing
  else has to record it: a `Handbook` folder holding the Index, the page
  whose front matter says `handbook: index`. Every page in the folder can
  carry `handbook:`, `read_when:` (for an agent choosing what to read) and
  `covers:` (paths whose changes should touch it), and keeps its rules in a
  `## Rules` section (`Slipdock.Handbook.Rules`, #1773).
  """

  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Blueprint
  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Repo
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Folders, FrontMatter, Page}

  @name "handbook"
  @version "1.9.0"
  @folder "Handbook"
  @decisions "Handbook/Decisions"

  def name, do: @name
  def version, do: @version
  def folder, do: @folder
  def decisions_folder, do: @decisions

  @doc "Whether `ref` names the built-in Handbook Tool."
  def tool?(ref) when is_binary(ref), do: String.downcase(String.trim(ref)) == @name
  def tool?(_), do: false

  ## The Tool --------------------------------------------------------------------

  # The section every Testing & tooling page has (#1878): every check CI
  # enforces runs locally through one command, and builders are told it.
  @before_you_push """
  ## Before you push

  _The one command that runs locally what CI enforces on a pull request, in CI's order with CI's arguments, and how long it takes. Then any CI check with no local equivalent (a Windows runner, a hosted scan), each with why. Builders run this before every push._
  """

  # Principles and Playbook (1.5.0, #2040): how this project decides between
  # two right ways, and how an idea becomes cards. A board makes them its own
  # by editing them. These are the skeletons #2040 shipped: a page still
  # holding one is replaced by the seed below on the next install (#2041).
  @principles_skeleton """
  ## Principles

  _The tie-breakers between two right ways: where a card could reasonably go either way, which way this project goes. One short paragraph each, the two ways and why this one, with a matching item in `## Rules` (`- **PRIN-n** should · judgement · …`) so a verifier weighs it like any other rule. Adding, rewording or dropping one is a rule change, so a person's call. The one below is a worked example: edit it or delete it._

  **One date helper.** A date can be formatted where it is shown, or through one shared helper. This project formats every date through the one helper, so a format changes in one place and two screens never disagree.
  """

  @principles_rules_skeleton """
  - **PRIN-1** should · judgement · Every date is formatted through the one shared helper, never where it is shown.
  """

  @playbook_skeleton """
  ## When this applies

  _Read by an agent asked to plan, or to put a plan on the board (the `slipdock-plan` skill); never by the server when a card is made. Sizing comes first, and a card-sized ask gets one card, shaped as Card shape says, and nothing else._

  ## Sizing

  _The sizes (card, feature, system), the triggers for each, written so an agent applies them the same way twice, and the stages each size takes._

  ## Stages

  _One `###` per stage: what it asks, the skill it uses (the plan skill's own text, or a named skill when that is installed), what it produces, and the handbook page or card it writes to._

  ## Card shape

  _How a one-sentence ask becomes a card on this board. It overrides the agent guide's Card shape._

  ## Defaults

  _The page holding the person's own defaults (stack, hosting), as `defaults: W-123`. The decide stage proposes each, with its rationale, and asks; with none named it asks from scratch. A default is never imposed._
  """

  # The baseline seed (#2041): what an agent reads before planning on a board
  # whose owner has changed nothing. Kept short, since it is read alongside a
  # card: the aim is that every agent plans the same way, not a textbook.
  @principles """
  ## How to write one

  A principle settles a choice between two right ways, where a card could reasonably go either way. Write a short paragraph: the two ways, the one this project takes, and why. Then add the matching item to `## Rules`, the next unused number: `- **PRIN-n** should · judgement · <the rule, in one line>`. A verifier weighs it like any other rule. Adding, rewording or dropping one is a rule change, so a person's call: an agent proposes it, a person applies it.

  The three below are a baseline that suits most projects: edit them or delete them.

  ## Baseline

  **One place for each concern.** A helper can be written where it is needed, or the existing one found and reused. This project keeps one place for each concern (one date helper, one HTTP client, one validation) and reuses it, so a change is made once and two screens never disagree. (PRIN-1)

  **The obvious reading.** An ambiguous ask can be stopped on, or built. This project builds the obvious reading and notes the other one on the card, and asks only when the two differ materially. (PRIN-2)

  **Extend before adding, and split when it grows.** A new page, module or component can be written beside an existing one, or the existing one extended. This project extends what is there. Extending has a limit, though: when the thing being extended has grown big, hard to follow or about more than one thing, the change that extends it refactors it first, so it ends as two things each about one thing and never as one huge object. (PRIN-3)
  """

  @principles_rules """
  - **PRIN-1** should · judgement · Each concern (a date format, an HTTP client, a validation) has one place, and new code reuses it rather than writing its own.
  - **PRIN-2** should · judgement · An ambiguous ask is built to its obvious reading, with the other reading noted on the card; asking is for readings that differ materially.
  - **PRIN-3** should · judgement · An existing page, module or component is extended before a new one is written beside it; one that has grown big or hard to follow is split in the same change, each part about one thing.
  """

  # PRIN-3 as 1.5.0 seeded it (#2041), before it split what grows (#2112): a
  # Principles page still holding that seed, unedited, gets this one's place.
  @principles_1_5 String.replace(
                    @principles,
                    "**Extend before adding, and split when it grows.** A new page, module or component can be written beside an existing one, or the existing one extended. This project extends what is there. Extending has a limit, though: when the thing being extended has grown big, hard to follow or about more than one thing, the change that extends it refactors it first, so it ends as two things each about one thing and never as one huge object. (PRIN-3)",
                    "**Extend before adding.** A new page, module or component can be written, or an existing one extended. This project extends what is there, and starts a new one only when the old one would stop being about one thing. (PRIN-3)"
                  )

  @principles_rules_1_5 String.replace(
                          @principles_rules,
                          "beside it; one that has grown big or hard to follow is split in the same change, each part about one thing.",
                          "beside it."
                        )

  @card_shape """
  ## Card shape

  _The agent guide's Card shape, until this board edits it here._

  - **One card** when the ask fits one sitting, one agent and one PR and
    was said in a sentence; an epic with subcards only when it doesn't.
    Never an epic with one subcard, nor subcards the person didn't imply.
  - **Where:** under the epic it serves if there is one (search first);
    otherwise top level, without making an epic to hold it.
  - **Three things in the description**, each in proportion: what, in the
    person's words; where, if known; and a **done-when** line, the stop
    condition the evidence answers. One or two lines; no Given/When/Then
    unless the board's Playbook asks for it.
  - **Don't add** an estimate, priority, tags, a due date or an assignee
    unless the person said so or the board's convention does.
  - **Don't repeat the repo's rules** (tests, every door, the handbook
    line): whoever builds it reads those from the handbook and the repo.
  - **Two readings:** write the obvious one and note the other in the
    description; ask only when they differ materially, once, before filing.
  - **A bar item made moot** by a later, cited decision or rule: read it
    the obvious way and say so. Not a wait.
  - **Dependencies:** `blocked_by` means *can't start until*, not *should
    come after*: set it where a card builds on another's code, schema or
    decision, and use list position for mere preference. A one-card ask
    gets none unless the person said "after X". None on a simple board.
  """

  # The Spike stage (1.7.0, #2352): between Grill and Spec, for a question
  # only building can answer. A board whose Playbook it edited gets it as a
  # gardener proposal instead (`propose_spike/3`).
  @spike """
  ## Spike

  - **Asks:** of the brief's open questions, which pass all three: only building answers it (not a person, not reading); a "no" changes the spec (say how); a late "no" costs more than the spike, counting flow time and lane contention as well as rework. One that fails only the third gets its card first in build order instead. None pass: the stage is skipped, and the agent says why.
  - **Skill:** the plan skill's Spike. The agent proposes the candidates and a person confirms them; unattended, they go to a person as one `product` wait on the epic.
  - **Produces:** one card tagged `spike` per confirmed question, one sitting each, its bar the question and what counts as an answer. A spike holds no lane and merges nothing: its answer is a page, its prototype stays on a branch.
  - **Writes to:** the epic's sub-board; each answer to a page pinned to the epic. Planning stops there and resumes at Spec once every spike is accepted, from their answers.
  """

  # The Playbook as 1.5.0 and 1.6.0 seeded it, before the Spike stage
  # (#2352): an unedited one gets the 1.7.0 seed in its place.
  @playbook_1_6 """
  ## When this applies

  An agent reads this page when it is asked to plan: "plan this", "I want to build…", "break this into cards", "spec this out", "where do we start" (the `slipdock-plan` skill). Never when a card is simply asked for, and never by the server. Sizing comes first. A card-sized ask gets one card, shaped as Card shape says, and nothing else: no grill, no spec, no epic.

  Each stage below says what it asks, the skill it uses, what it produces and where it writes. A stage whose output already exists on the board (a Decision, the spec on the epic) is skipped, and the agent says so. A board changes how it plans by editing this page.

  ## Sizing

  Check the sizes in this order and take the first whose trigger matches:

  - **System**: a new deployable or service, a new repository, or a board with no code yet. Stages: Grill, Decide, Principles, Spec, Cards.
  - **Feature**: a new user-facing surface (a page, a command, an API resource), a new external integration, a change to the data model, or more than one sitting's work. Stages: Grill, Spec, Cards.
  - **Card**: anything else. One sitting, one agent, one PR, said in a sentence. Make the card, as Card shape says. No stages.

  Between two sizes, take the smaller and say so. If the grill turns up more, grow it.

  ## Grill

  - **Asks:** one question at a time, until the agent can say back what is built, for whom, what done looks like and what is out of scope. It doesn't ask what the board already answers (the handbook, earlier Decisions).
  - **Skill:** the plan skill's Grill. To use an installed skill instead, add `skill: <its name>` here.
  - **Produces:** a brief: the problem, who it is for, done-when, out of scope, open questions.
  - **Writes to:** the epic's description, making the epic if there is none.

  ## Decide

  - **Asks:** each choice the work needs before code: stack, hosting, deployment, data store, auth. When Defaults names a page, the agent proposes each default with its rationale, and asks.
  - **Skill:** the plan skill's Decide.
  - **Produces:** one Decision per choice: the context, the choice, the alternatives and why not, and where it was decided.
  - **Writes to:** a new page in `Handbook/Decisions` titled `Decision: <what was chosen>`, named on the epic.

  ## Principles

  - **Asks:** where two right ways exist (naming, errors, how deep tests go, one place for each concern), which one this project takes.
  - **Skill:** the plan skill's Principles.
  - **Produces:** for each, a short paragraph and a `PRIN-n should · judgement` item.
  - **Writes to:** the Principles page, appended when the person agreed it in the conversation. Unattended, it goes in as a proposal (`slipdock garden propose`), because a rule is a person's call.

  ## Spec

  - **Asks:** what each part does for the person using it, its rules and edge cases, and what is out of scope.
  - **Skill:** the plan skill's Spec.
  - **Produces:** goals, non-goals, behaviour part by part, and done-when for the whole.
  - **Writes to:** a wiki page on the epic, named in its Docs. For a system, also the first sections of the Specification page.

  ## Cards

  - **Asks:** nothing new. It turns the spec into cards.
  - **Skill:** the plan skill's Cards.
  - **Produces:** subcards under the epic in build order, each shaped as Card shape says, with a bar where the board verifies work and `blocked_by` where one card builds on another's output.
  - **Writes to:** the epic's sub-board.

  #{String.trim_trailing(@card_shape)}

  ## Defaults

  defaults: none

  _Replace `none` with the page holding the person's own defaults (stack, hosting), as `defaults: W-123`: their Knowledge Base. Decide reads it, proposes each default with its rationale, asks, and records the outcome as a Decision on this project. A default is never imposed. With none named, it asks from scratch._
  """

  # The 1.5.0 Playbook seed before Card shape read a moot bar item the
  # obvious way (#2096).
  @playbook_1_5 String.replace(
                  @playbook_1_6,
                  "- **A bar item made moot** by a later, cited decision or rule: read it\n  the obvious way and say so. Not a wait.\n",
                  ""
                )

  @playbook """
  ## When this applies

  An agent reads this page when it is asked to plan: "plan this", "I want to build…", "break this into cards", "spec this out", "where do we start" (the `slipdock-plan` skill). Never when a card is simply asked for, and never by the server. Sizing comes first. A card-sized ask gets one card, shaped as Card shape says, and nothing else: no grill, no spec, no epic.

  Each stage below says what it asks, the skill it uses, what it produces and where it writes. A stage whose output already exists on the board (a Decision, the spec on the epic) is skipped, and the agent says so. A board changes how it plans by editing this page.

  ## Sizing

  Check the sizes in this order and take the first whose trigger matches:

  - **System**: a new deployable or service, a new repository, or a board with no code yet. Stages: Grill, Spike (when one is needed), Decide, Principles, Spec, Cards.
  - **Feature**: a new user-facing surface (a page, a command, an API resource), a new external integration, a change to the data model, or more than one sitting's work. Stages: Grill, Spike (when one is needed), Spec, Cards.
  - **Card**: anything else. One sitting, one agent, one PR, said in a sentence. Make the card, as Card shape says. No stages.

  Between two sizes, take the smaller and say so. If the grill turns up more, grow it.

  ## Grill

  - **Asks:** in numbered rounds. A round is every question whose prerequisites are settled, each with a recommended answer that a yes accepts. With nobody there, a round goes into one wait, a question each. It stops when the next answer wouldn't change the plan: the agent can say back what is built, for whom, what done looks like and what is out of scope. It doesn't ask what the board already answers (the handbook, earlier Decisions).
  - **Skill:** the plan skill's Grill. To use another, add `skill: <its name>` here, the name in its front matter (`grilling`, with no collection's prefix): the one enabled on this board from the skills registry, else one installed where the agent runs.
  - **Produces:** a brief: the problem, who it is for, done-when, out of scope, open questions.
  - **Writes to:** the epic's description, making the epic if there is none.

  #{String.trim_trailing(@spike)}

  ## Decide

  - **Asks:** each choice the work needs before code: stack, hosting, deployment, data store, auth. When Defaults names a page, the agent proposes each default with its rationale, and asks.
  - **Skill:** the plan skill's Decide.
  - **Produces:** one Decision per choice: the context, the choice, the alternatives and why not, and where it was decided.
  - **Writes to:** a new page in `Handbook/Decisions` titled `Decision: <what was chosen>`, named on the epic.

  ## Principles

  - **Asks:** where two right ways exist (naming, errors, how deep tests go, one place for each concern), which one this project takes.
  - **Skill:** the plan skill's Principles.
  - **Produces:** for each, a short paragraph and a `PRIN-n should · judgement` item.
  - **Writes to:** the Principles page, appended when the person agreed it in the conversation. Unattended, it goes in as a proposal (`slipdock garden propose`), because a rule is a person's call.

  ## Spec

  - **Asks:** what each part does for the person using it, its rules and edge cases, and what is out of scope.
  - **Skill:** the plan skill's Spec.
  - **Produces:** goals, non-goals, behaviour part by part, and done-when for the whole.
  - **Writes to:** a wiki page on the epic, named in its Docs. For a system, also the first sections of the Specification page.

  ## Cards

  - **Asks:** nothing new. It turns the spec into cards.
  - **Skill:** the plan skill's Cards.
  - **Produces:** subcards under the epic in build order, each shaped as Card shape says, with a bar where the board verifies work and `blocked_by` where one card builds on another's output.
  - **Writes to:** the epic's sub-board.

  #{String.trim_trailing(@card_shape)}

  ## Defaults

  defaults: none

  _Replace `none` with the page holding the person's own defaults (stack, hosting), as `defaults: W-123`: their Knowledge Base. Decide reads it, proposes each default with its rationale, asks, and records the outcome as a Decision on this project. A default is never imposed. With none named, it asks from scratch._
  """

  # The 1.8.0 Playbook seed, whose Grill asked one question at a time
  # (#2065): unattended that was a wait per question. Its Skill line gave no
  # example of a name either.
  @playbook_1_8 @playbook
                |> String.replace(
                  "in numbered rounds. A round is every question whose prerequisites are settled, each with a recommended answer that a yes accepts. With nobody there, a round goes into one wait, a question each. It stops when the next answer wouldn't change the plan: the agent can say back",
                  "one question at a time, until the agent can say back"
                )
                |> String.replace(
                  " here, the name in its front matter (`grilling`, with no collection's prefix): the one enabled",
                  " here: the one enabled"
                )

  # The 1.7.0 Playbook seed, whose Grill named only an installed skill, not
  # one enabled on the board from the skills registry (#2601).
  @playbook_1_7 String.replace(
                  @playbook_1_8,
                  "To use another, add `skill: <its name>` here: the one enabled on this board from the skills registry, else one installed where the agent runs.",
                  "To use an installed skill instead, add `skill: <its name>` here."
                )

  # The machine-setup stub under Local setup (1.8.0, #2579): what a runner
  # machine needs. Set up this machine with Claude reads it, and writes back
  # what it got wrong.
  @runner_machine """
  ### A runner machine

  _What a machine that runs this board's jobs needs: the tools and their versions, the logins, the services, and the checks that prove it works. **Set up this machine with Claude** (the machine's page, or `slipdock-runner setup`) follows this section and corrects what it gets wrong._
  """

  @sections [
    {"Specification", "specification", "What the product does, feature by feature.",
     "adding or changing user-visible behaviour",
     "## Features\n\n_One section per feature: what it does for the person using it, and its rules._\n"},
    {"Architecture", "architecture",
     "Contexts, processes, boundaries and data flow, as they are now.",
     "adding a context, a process or a supervisor, or crossing a module boundary",
     "## Contexts\n\n_The main modules and what each owns._\n\n## Processes\n\n_What runs, and who supervises it._\n\n## Data flow\n\n_How a request or a job moves through the system._\n"},
    {"UX & UI", "ux", "Patterns, layout and interaction rules for the interface.",
     "building or changing a screen, a form, a menu or any UI interaction",
     "## Patterns\n\n_Layouts and interactions the app uses everywhere._\n"},
    {"Components", "components", "Reusable UI pieces, and when to use each.",
     "adding UI that may already exist as a component, or making a reusable one",
     "## Components\n\n_One section per component: what it is for and how it is called._\n"},
    {"Data model", "data-model", "Schemas, their relations and invariants.",
     "adding or changing a schema, a migration or a constraint",
     "## Schemas\n\n_One section per schema: its fields, relations and invariants._\n"},
    {"Shared modules", "shared-modules", "Utilities and helpers worth reusing.",
     "writing a helper that may already exist, or one worth sharing",
     "## Modules\n\n_One section per module: what it does and when to reach for it._\n"},
    {"Testing & tooling", "testing", "How to test, CI, local setup.",
     "writing tests, changing CI, the build or the local setup",
     "## Tests\n\n_How the suite is laid out and run._\n\n## CI\n\n_What runs on every push._\n\n" <>
       @before_you_push <>
       "\n## Local setup\n\n_From a clean checkout to a running app._\n\n" <> @runner_machine},
    {"Operations", "operations", "Deploys, configuration and runbooks.",
     "changing deploys, configuration, secrets or anything run in production",
     "## Deploy\n\n_How a change reaches production._\n\n## Configuration\n\n_Settings and where they come from._\n\n## Runbooks\n\n_What to do when something breaks._\n"},
    {"Principles", "principles", "The tie-breakers: which of two right ways this project takes.",
     "making a choice the card leaves open, or planning a feature or a system", @principles},
    {"Playbook", "playbook", "How an idea becomes cards here: sizing, then the stages.",
     "planning: turning an idea, a feature or a new system into an epic and cards", @playbook}
  ]

  @triage_log """
  ## Triage

  _The triage card records each run here, newest last: the date, the findings read, merged, dismissed and promoted, and the proposals filed._
  """

  @index_body """
  # Handbook

  How this project is built, as it is now. Coding passes read the sections a
  card needs before building, and update them before closing it (a
  `Handbook:` line in the closing comment). Pages added to this folder join
  the list by themselves.

  Each section page keeps its rules in a `## Rules` section, one item each
  (`- **UX-1** must · <test path or judgement> · <the rule>`), so a change
  can be checked against them and a review can cite one by its id.

  ```slipdock
  pages: Handbook
  fields: title, summary, read_when
  ```

  ## Decisions

  One page per decision, in `Handbook/Decisions`. A superseded decision gets
  a new page that links back to it.

  ```slipdock
  pages: Handbook/Decisions
  fields: title, summary
  empty: "No decisions written yet."
  ```

  ## Log

  _The reconcile card records each commit range it covered here, newest last._

  #{String.trim_trailing(@triage_log)}
  """

  @seed_title "Seed the handbook"
  @reconcile_title "Reconcile the handbook"
  @triage_title "Triage findings"
  @reconcile_repeat "every day"

  @seed_description """
  Write the first real version of this board's handbook (the `Handbook/` folder, see its Index). Its pages are skeletons until this card is done. Spec: the Handbook Tool, W-1934.

  **Procedure**

  1. Read the codebase this board's work lands in: the README, CLAUDE.md / AGENTS.md, the top-level layout, the main modules, the schemas and migrations, the tests and CI config, the deploy scripts.
  2. Read what the board already knows: `slipdock page ls <board>` for specs, design records and decision notes, and the last few dozen done cards for recurring patterns.
  3. For each section page (Specification, Architecture, UX & UI, Components, Data model, Shared modules, Testing & tooling, Operations; Principles and Playbook as the last bullet says):
     - write the body as the project is **now**, by `##` section, one subject per section, short, linking to code paths in backticks. Not history: decisions go in their own pages;
     - set the front matter: `read_when:` (the kinds of card that should read it, in a line) and `covers:` (the path globs whose changes should touch it, like `[lib/app/accounts/**, priv/repo/migrations/**]`);
     - keep the page's summary to one line;
     - keep `covers:` narrow: the files whose change would make this page wrong, not whole trees. A glob like `lib/**` matches nearly every card and pushes better suggestions out;
     - keep each `##` section short (under about 1,500 characters): suggestions point at sections, and a longer one is split in parts for search;
     - put the page's rules in its `## Rules` section, one list item each and nowhere else: `- **UX-1** must · test/app_web/tokens_test.exs · No colour literals in templates.` (id with the page's prefix, `must` or `should`, an optional `scope <globs>` part, then the check: the test that enforces it, or `judgement`). A rule with an obvious mechanical check and no test yet is `judgement`: list it in the closing comment as a candidate test. Prose elsewhere can cite a rule by its id. `slipdock handbook <board>` counts the rules and lists any item that doesn't parse, with its page and line.
     - Principles and Playbook say how this project decides and plans, which is a person's call: leave them as they are, and suggest in the closing comment any principle the code plainly keeps (one place for dates, say), for a person to add.

     Write the body with `slipdock page edit <page> --file F --summary S --message "#<this card> seed"`, and the front matter with `slipdock page props <page> --file F` (the YAML alone: `handbook:`, `read_when:`, `covers:`). Drafting pages in parallel and reviewing each before writing works well.
  4. Before you push: for every check CI runs on a pull request (each job and step the workflows run for one), write on Testing & tooling's `## Before you push` how to run it locally, and gather them into the one command that runs them all, in CI's order with CI's arguments. A check with no local equivalent (a Windows runner, a hosted service) is named there, with why. Where the repo has no such command, don't add one unasked: list the separate commands there meanwhile, and propose the one command (an alias, a make target or a script, with the steps it would run) in the closing comment.
  5. Write one page per decision you find in the existing design records, specs and comments, filed in `Handbook/Decisions`: title `Decision: <what was chosen>`, then context, the choice, the alternatives and why not, and a link to where it was decided.
  6. Add one line to the repo's CLAUDE.md (or AGENTS.md) pointing at the Index: `Project handbook: <Index code> on the <board> board — read the sections a card needs before building, and update them before closing it (a Handbook: line in the closing comment).` The wiki is the source of truth: do not copy the handbook into the repo.
  7. Commit the CLAUDE.md change with this card's id, and close the card with a `Handbook:` line listing every page written.
  8. Check the result: `slipdock handbook <a few past card ids>` should point a UI card at UX & UI, a schema change at Data model, and so on. Tighten `read_when`/`covers` where it doesn't.

  **Done when:** every section page has real content and front matter, Before you push names the one command (or the closing comment proposes it), the decisions found have pages, CLAUDE.md points at the Index, and a person has been asked (in the closing comment) to read the drafts once.
  """

  @reconcile_description """
  Bring the handbook (the `Handbook/` folder, see its Index) back in line with the code, a small range at a time. Passes update it as they close cards; this catches what they missed, implementation choices above all. It comes every night and lands on top of the ready list, so keep it short. Spec: W-1934 §Drift.

  1. Find where the last reconcile stopped: the last line of the Index's `## Log` (a commit range, `<from>..<to>`). None yet: start from the commit that seeded the handbook. A `<to>` that is no longer in the default branch's history (it was rewritten): find its equivalent by its subject.
  2. `git fetch`, then `git log --oneline --reverse <to>..origin/<default branch>`. Nothing new: close the card with `Handbook: no change (nothing landed)`, and leave the Log alone.
  3. Take at most 20 of those commits, oldest first: the range is `<to>..<the 20th>`. The rest wait for the next night.
  4. Find what the range touches: `git log --name-only --format= <range> | sort -u | slipdock handbook <board> --paths-from -`. It lists the pages whose `covers:` match those paths, and the rules the paths fall under. Read only those pages, by section (`slipdock page section`), against the range's diffs.
  5. For each change, check those pages and the checklist: user-visible behaviour → Specification; structure or boundaries → Architecture / Data model; a choice between alternatives → a new page in `Handbook/Decisions`; something reusable → Shared modules / Components; a UI pattern → UX & UI; how to test, build or deploy → Testing & tooling / Operations. A changed path that no page covers but one should: add it to that page's `covers:`.
  6. A range that touches CI config (`.github/workflows/**`, `.gitlab-ci.yml`, `.circleci/**`, `Jenkinsfile`, and the like): read Testing & tooling's `## Before you push` against the workflows as they now are, and fix the drift there. Every check CI runs on a pull request runs through its one command or is named as having no local equivalent, with why. A new check the command doesn't run: say so in the section, and propose the change to the command in the closing comment rather than making it unasked.
  7. Update what drifted, by section, with `--message "#<this card> reconcile <range>"`. Facts, links and splits are yours to fix. A rule (`## Rules`) or a decision that looks wrong is a person's call: don't rewrite it, say so as a finding (`handbook-wrong:` or `rule:`) in the closing comment.
  8. Append the range to the Index's `## Log`: `- <date>: <from>..<to> (<n> commits), updated <codes>` (or `nothing drifted`).
  9. Close the card with a `Handbook:` line. The next one comes by itself tomorrow.
  """

  @triage_description """
  Turn what passes learned (their `Findings:` blocks, and what the board recorded by itself) into handbook changes, so the handbook improves from use without an agent rewriting its rules. It comes every night; with nothing to triage it closes at once. Spec: W-2310 §Upkeep.

  1. Read: `slipdock findings <board> --status open`. None open: close the card with `Handbook: no change (no open findings)` and stop; the Triage log is left alone.
  2. Tidy: group them by what they are about. Merge duplicates into the oldest (`slipdock finding <id> merge --into <id>`, which adds up the counts). Dismiss one-offs that don't generalise, with the reason (`slipdock finding <id> dismiss --note "…"`).
  3. Promote what recurs (seen on two or more cards, or a count of two or more) or shows the handbook wrong:
     - a description that is wrong or missing (a fact, a link, a gotcha that is now settled): write it into the page yourself, by section, with `--message "#<this card> triage"`;
     - a new or changed **rule**, or a decision: don't edit it. File it as a proposal for a person to apply (`slipdock garden propose <board> <file.json>`, an `edit_section` step on the page's `## Rules`, the findings' ids as `findings`);
     - a rule whose check could be a test: file a card for the test instead (`slipdock add <board> "Test for <rule id>: …"`), and say so on the finding;
     - then `slipdock finding <id> promote --note "<what it became: W-12 §Tests, proposal #34, card #56>"`.
  4. Decide every leftover. A finding that was already open at the last triage (older than the last line of the Index's `## Triage`) has had its night: it must be decided now, never left open a second time. It becomes a card (a fix or investigation in the Housekeeping list, which runners work after the ready list: `slipdock add <board> "…" --desc "…" --column Housekeeping --origin findings`, or the backlog on a board with no Housekeeping list; a design question, whose answer would change how the product or a process behaves, in Triage for a person, `--column Triage --origin findings`; `--desc -` with a heredoc for more than a line, since `--desc -` reads the description from stdin; then `promote --note "card #<id>"`), a proposal or a promotion as in step 3, or it is dismissed with the reason (`dismiss --note "left open on <date>; <why it isn't worth keeping>"`). Only a finding that arrived since the last triage may stay open, and only with a reason in the log line.
  5. Read the numbers: `slipdock quality <board> --rules` (the last 30 days) gives the rejections by part and by rule id, each rule with its page, the disputed `Handbook:` lines and rework by area. A rule that keeps being broken needs clearer wording or a test, as a proposal or a card. Disputed lines point at a page the docs gate keeps missing, and an area with a lot of rework at a section to read again. Say which rules you acted on in the log line.
  6. Log it: append to the Index's `## Triage` a line `- <date>: <n> read, <n> merged, <n> dismissed, <n> promoted, <n> filed as cards; <n> leftovers decided; <n> left open (<ids>: why); proposals <ids or none>`.
  7. Close the card with a `Handbook:` line naming what was written, and the proposals filed. The next one comes by itself tomorrow.
  """

  @doc """
  The empty `## Rules` section a page with `handbook: key` starts with (see
  `Slipdock.Handbook.Rules` for the format its items take).
  """
  def rules_skeleton(key) do
    prefix = Slipdock.Handbook.Rules.prefix(key)

    """
    ## Rules

    _One list item per rule: `- **#{prefix}-1** must · test/path/to_test.exs · What it says.` Severity `must` or `should`; the check is a test path or `judgement`; add `· scope lib/app/** ·` after the severity to narrow it from this page's `covers:`. Ids are never reused._
    """
  end

  @doc """
  The `## Rules` section a new page with `handbook: key` starts with: the
  skeleton, and on Principles its worked example after it (1.5.0).
  """
  def seed_rules("principles"), do: rules_skeleton("principles") <> "\n" <> @principles_rules
  def seed_rules(key), do: rules_skeleton(key)

  # A Principles or Playbook page exactly as 1.5.0 first made it (#2040),
  # which the seed replaces (#2041).
  defp skeleton("principles"),
    do: {@principles_skeleton, rules_skeleton("principles") <> "\n" <> @principles_rules_skeleton}

  defp skeleton("playbook"), do: {@playbook_skeleton, rules_skeleton("playbook")}
  defp skeleton(_), do: nil

  # The earlier seeds an install replaces when a page still holds one
  # unedited, each with how the report names it: the skeleton (#2041), and
  # on Principles the 1.5.0 seed, whose PRIN-3 didn't split what grows (#2112).
  defp replaceable("principles") do
    [
      {skeleton("principles"), "seed added"},
      {{@principles_1_5, rules_skeleton("principles") <> "\n" <> @principles_rules_1_5},
       "seed updated"}
    ]
  end

  # On Playbook, its 1.8.0 seed, whose Grill asked one question at a time
  # (#2065), its 1.7.0 seed, whose Grill named no registry skill (#2601),
  # its 1.6.0 seed and the 1.5.0 one before Card shape read a moot bar item
  # the obvious way (#2096), neither with a Spike stage (#2352).
  defp replaceable("playbook") do
    rules = rules_skeleton("playbook")

    [
      {skeleton("playbook"), "seed added"},
      {{@playbook_1_8, rules}, "seed updated"},
      {{@playbook_1_7, rules}, "seed updated"},
      {{@playbook_1_6, rules}, "seed updated"},
      {{@playbook_1_5, rules}, "seed updated"}
    ]
  end

  defp replaceable(key) do
    case skeleton(key) do
      nil -> []
      skeleton -> [{skeleton, "seed added"}]
    end
  end

  @doc false
  # The body a Principles or Playbook page had as 1.5.0 first made it, for
  # the upgrade's tests.
  def skeleton_body(key) do
    {title, _key, summary, _, _} = Enum.find(@sections, &(elem(&1, 1) == key))
    {body, rules} = skeleton(key)
    page_body(title, summary, body, rules)
  end

  @doc false
  # The body a Principles page had as 1.5.0 seeded it (#2041), before PRIN-3
  # split what grows (#2112), for the upgrade's tests.
  def seed_1_5_body("principles") do
    {title, _key, summary, _, _} = Enum.find(@sections, &(elem(&1, 1) == "principles"))

    page_body(
      title,
      summary,
      @principles_1_5,
      rules_skeleton("principles") <> "\n" <> @principles_rules_1_5
    )
  end

  @doc false
  # The body a Playbook page had as 1.8.0 seeded it, before its Grill asked
  # in numbered rounds (#2065), as 1.7.0 did before its Grill named a
  # registry skill (#2601), as 1.6.0 did before the Spike stage (#2352), and
  # as 1.5.0 did before #2096, for the upgrade's tests.
  def seed_body("playbook", "1.8.0"), do: playbook_body(@playbook_1_8)
  def seed_body("playbook", "1.7.0"), do: playbook_body(@playbook_1_7)
  def seed_body("playbook", "1.6.0"), do: playbook_body(@playbook_1_6)
  def seed_body("playbook", "1.5.0"), do: playbook_body(@playbook_1_5)

  defp playbook_body(body) do
    {title, _key, summary, _, _} = Enum.find(@sections, &(elem(&1, 1) == "playbook"))
    page_body(title, summary, body, rules_skeleton("playbook"))
  end

  defp page_body(title, summary, body, rules), do: "# #{title}\n\n#{summary}\n\n#{body}\n#{rules}"

  @doc "The `handbook:` key of each built-in section page, in the handbook's order."
  def section_keys, do: for({_title, key, _, _, _} <- @sections, do: key)

  # How running prose names a section page where its title won't do
  # ("pages for the specification, UX, testing, …"); the rest are the title
  # in lower case.
  @prose_names %{"ux" => "UX", "testing" => "testing"}

  @doc """
  The built-in section pages, in the handbook's order: each one's `title`,
  its `handbook:` `key` and the `name` running prose gives it (#2045).
  Every list of the handbook's pages is built from this or held to it
  (`test/slipdock/handbook_page_lists_test.exs`).
  """
  def sections do
    for {title, key, _, _, _} <- @sections do
      %{title: title, key: key, name: Map.get(@prose_names, key, String.downcase(title))}
    end
  end

  def seed_title, do: @seed_title
  def reconcile_title, do: @reconcile_title
  def triage_title, do: @triage_title

  @doc """
  The handbook as a board blueprint (see `Slipdock.Blueprint`): the folders,
  the Index and a skeleton page per section, each with its front matter.
  """
  def blueprint do
    index = %{
      "title" => "Index",
      "folder" => @folder,
      "summary" => "The handbook's pages, what each covers and when to read it.",
      "front_matter" => "handbook: index\nread_when: starting any card\ncovers: []",
      "body" => @index_body
    }

    sections =
      for {title, key, summary, read_when, body} <- @sections do
        %{
          "title" => title,
          "folder" => @folder,
          "summary" => summary,
          "front_matter" => "handbook: #{key}\nread_when: #{read_when}\ncovers: []",
          "body" => page_body(title, summary, body, seed_rules(key))
        }
      end

    %{
      "lists" => [],
      "folders" => [@folder, @decisions],
      "tags" => [],
      "pages" => [index | sections],
      "automations" => [],
      "cards" => [
        %{"title" => @seed_title, "description" => @seed_description},
        %{
          "title" => @reconcile_title,
          "description" => @reconcile_description,
          "repeat" => @reconcile_repeat
        },
        %{
          "title" => @triage_title,
          "description" => @triage_description,
          "repeat" => @reconcile_repeat
        }
      ]
    }
  end

  @doc """
  `blueprint` with its repeating cards put in `board`'s Scheduled list, when
  it has one (#2100) and the card names no list of its own: recurring agent
  work lands there, out of the ready list, for feed rules to work. A board
  without one leaves them to the ready list, as before.
  """
  def scheduled_cards(%{"cards" => cards} = blueprint, %Board{} = board) do
    case Boards.scheduled_column(board) do
      nil -> blueprint
      column -> %{blueprint | "cards" => Enum.map(cards, &into_list(&1, column.name))}
    end
  end

  def scheduled_cards(blueprint, _board), do: blueprint

  defp into_list(%{"repeat" => repeat} = card, name) when not is_nil(repeat),
    do: Map.put_new(card, "list", name)

  defp into_list(card, _name), do: card

  @doc """
  Installs the handbook on `board`'s root board for `user`, who must be able
  to write to it. Installing again adds only what is missing — a page somebody
  deleted, a folder — and never touches a page that is there.

  Returns `{:ok, %{board:, created:, upgraded:, version:, install:, report:}}`
  (the shape a Tool install reports), or `{:error, message}`.
  """
  def install(%User{} = user, %Board{} = board, _opts \\ []) do
    root = root(board)

    with :ok <- can_write(user, root) do
      created = is_nil(find(root))

      case Blueprint.apply(root, scheduled_cards(blueprint(), root),
             user: user,
             message: "installed by the Handbook Tool, #{@version}"
           ) do
        {:ok, report} ->
          after_seed(root, report.added["cards"])
          report = add_before_you_push(root, user, report)
          report = add_runner_machine(root, user, report)
          report = add_rules_sections(root, user, report)
          report = add_triage_log(root, user, report)
          report = seed_skeletons(root, user, report)
          {report, upgraded} = upgrade_reconcile(root, user, report)
          {report, triaged} = upgrade_triage(root, user, report)
          upgraded = upgraded or triaged

          {:ok,
           %{
             board: Boards.get_board!(root.id),
             created: created,
             upgraded: upgraded,
             version: %{version: @version},
             install: %{version: @version},
             report: report
           }}

        {:error, message} ->
          {:error, message}
      end
    end
  end

  # A handbook installed before rules (1.0.0) gets an empty `## Rules` on
  # each section page that has none, appended so nothing written is touched;
  # a page that has one already is left alone. Reported as "<title> (Rules
  # section added)" among the pages.
  defp add_rules_sections(root, user, report) do
    case find(root) do
      nil ->
        report

      handbook ->
        keys = for {_title, key, _, _, _} <- @sections, into: MapSet.new(), do: key

        added =
          for page <- handbook.pages,
              MapSet.member?(keys, key(page)),
              not rules_section?(page),
              {:ok, _} <-
                [
                  Wiki.append(page, rules_skeleton(key(page)),
                    user: user,
                    message: "Rules section added by the Handbook Tool, #{@version}"
                  )
                ],
              do: page.title <> " (Rules section added)"

        update_in(report, [:added, "pages"], &(&1 ++ added))
    end
  end

  defp rules_section?(page), do: has_heading?(page, "rules")

  # A Principles or Playbook page still holding the 1.5.0 skeleton gets the
  # seed in its place (#2041), and a Principles page still holding the 1.5.0
  # seed gets 1.6.0's (#2112), as a Playbook still holding an earlier seed
  # gets today's (#2352, #2601, #2065): nobody has written on it, so nothing
  # is lost.
  # One somebody edited is the board's own and is left alone. Reported as
  # "<title> (seed added)" or "<title> (seed updated)" among the added pages,
  # and as "<title> (edited: left alone)" among the skipped ones.
  defp seed_skeletons(root, user, report) do
    case find(root) do
      nil ->
        report

      handbook ->
        # In the handbook's order, so the report reads the same every time.
        handbook.pages
        |> Enum.sort_by(&Enum.find_index(section_keys(), fn key -> key == key(&1) end))
        |> Enum.reduce(report, &seed_skeleton(&1, user, &2))
    end
  end

  defp seed_skeleton(page, user, report) do
    with {title, _key, summary, _, seed} <- Enum.find(@sections, &(elem(&1, 1) == key(page))),
         [_ | _] = earlier <- replaceable(key(page)) do
      body = String.trim(page.body || "")
      seeded = page_body(title, summary, seed, seed_rules(key(page)))

      replaced = Enum.find_value(earlier, &replaced_as(&1, body, title, summary))

      cond do
        body == String.trim(seeded) -> report
        replaced -> put_seed(page, seeded, replaced, user, report)
        true -> left_alone(page, user, report)
      end
    else
      _ -> report
    end
  end

  # How the report names replacing `body`, if it is this earlier seed unedited.
  defp replaced_as({{old, old_rules}, how}, body, title, summary) do
    if body == String.trim(page_body(title, summary, old, old_rules)), do: how
  end

  defp put_seed(page, seeded, how, user, report) do
    opts = [user: user, message: "#{how} by the Handbook Tool, #{@version}"]

    case Wiki.update_page(page, %{"body" => seeded}, opts) do
      {:ok, _} -> update_in(report, [:added, "pages"], &(&1 ++ [page.title <> " (#{how})"]))
      _ -> report
    end
  end

  # An edited page is the board's own. An edited Playbook with no Spike
  # stage gets one proposed instead (#2352), for a person to apply.
  defp left_alone(page, user, report) do
    note =
      case key(page) == "playbook" and propose_spike(page, user) do
        {:ok, _suggestion} -> "edited: left alone; Spike stage proposed"
        _ -> "edited: left alone"
      end

    update_in(report, [:skipped, "pages"], &mark_edited(&1, page.title, note))
  end

  @doc """
  Files a gardener proposal adding the Spike stage to `page`, an edited
  Playbook without one (#2352): an `edit_section` on its `## Grill` that
  keeps the section and adds `## Spike` after it, or on its `## Spec`,
  adding it before. A Playbook with a `## Spike`, or with neither section,
  gets none. Filing it again finds the same proposal (`Gardener.propose/4`),
  so installing again adds no second one. `{:ok, suggestion}` or `:none`.
  """
  def propose_spike(%Page{} = page, user) do
    headings = Wiki.Section.headings(page.body)

    with false <- Enum.any?(headings, &h2?(&1, "spike")),
         {:ok, step} <- spike_step(page, headings),
         {:ok, suggestion, :new} <-
           Slipdock.Gardener.propose(Boards.get_board!(page.board_id), user, %{
             "explanation" =>
               "The Handbook Tool #{@version} adds a Spike stage to the Playbook, between Grill and Spec: " <>
                 "an open question only building can answer becomes a `spike` card, answered on a page and never merged, before the spec is written. " <>
                 "This Playbook is the board's own, so it is proposed rather than written. " <>
                 "Sizing may also want `Spike (when one is needed)` after Grill for Feature and System.",
             "steps" => [step]
           }) do
      {:ok, suggestion}
    else
      _ -> :none
    end
  end

  defp spike_step(page, headings) do
    case {Enum.find(headings, &h2?(&1, "grill")), Enum.find(headings, &h2?(&1, "spec"))} do
      {%{path: path}, _} -> spike_step(page, path, &(&1 <> "\n\n" <> @spike))
      {nil, %{path: path}} -> spike_step(page, path, &(@spike <> "\n" <> &1))
      _ -> :none
    end
  end

  defp spike_step(page, path, with_spike) do
    {:ok, text} = Wiki.Section.read(page.body, path)

    {:ok,
     %{
       "op" => "edit_section",
       "page" => page.id,
       "section" => path,
       "body" => with_spike.(String.trim_trailing(text))
     }}
  end

  defp mark_edited(skipped, title, note) do
    note = title <> " (#{note})"

    if Enum.member?(skipped, title),
      do: Enum.map(skipped, &if(&1 == title, do: note, else: &1)),
      else: skipped ++ [note]
  end

  @doc "The `## Before you push` section a Testing & tooling page starts with (#1878)."
  def before_you_push_skeleton, do: @before_you_push

  # A handbook from before 1.4.0 has no `## Before you push` on its Testing &
  # tooling page: added after its `## CI` section when it has one, else at
  # the end, so nothing written there is touched. A page that has the
  # section is left alone. Reported as "<title> (Before you push added)".
  # (Reinstalling also gives the reconcile card its CI step: see
  # `upgrade_reconcile/3`.)
  defp add_before_you_push(root, user, report) do
    with %{pages: pages} <- find(root),
         %Page{} = page <- Enum.find(pages, &(key(&1) == "testing")),
         false <- has_heading?(page, "before you push"),
         {:ok, _} <- append_before_you_push(page, user) do
      update_in(report, [:added, "pages"], &(&1 ++ [page.title <> " (Before you push added)"]))
    else
      _ -> report
    end
  end

  defp append_before_you_push(page, user) do
    opts = [user: user, message: "Before you push added by the Handbook Tool, #{@version}"]

    case Enum.find(Wiki.Section.headings(page.body), &h2?(&1, "ci")) do
      nil -> Wiki.append(page, @before_you_push, opts)
      ci -> Wiki.append_section(page, ci.path, @before_you_push, opts)
    end
  end

  @doc "The `### A runner machine` stub a Local setup section ends with (#2579)."
  def runner_machine_skeleton, do: @runner_machine

  # A handbook from before 1.8.0 has no `### A runner machine`: added at the
  # end of its `## Local setup`, or with a `## Local setup` of its own at the
  # end of the page when it has none, so nothing written is touched. A page
  # that has the heading at any level is left alone. Reported as "<title> (A
  # runner machine added)".
  defp add_runner_machine(root, user, report) do
    with %{pages: pages} <- find(root),
         %Page{} = page <- Enum.find(pages, &(key(&1) == "testing")),
         false <- Enum.any?(Wiki.Section.headings(page.body), &titled?(&1, "a runner machine")),
         {:ok, _} <- append_runner_machine(page, user) do
      update_in(report, [:added, "pages"], &(&1 ++ [page.title <> " (A runner machine added)"]))
    else
      _ -> report
    end
  end

  defp append_runner_machine(page, user) do
    opts = [user: user, message: "A runner machine added by the Handbook Tool, #{@version}"]

    case Enum.find(Wiki.Section.headings(page.body), &h2?(&1, "local setup")) do
      nil -> Wiki.append(page, "## Local setup\n\n" <> @runner_machine, opts)
      local -> Wiki.append_section(page, local.path, @runner_machine, opts)
    end
  end

  defp titled?(heading, title), do: String.downcase(String.trim(heading.title)) == title

  defp h2?(heading, title),
    do: heading.level == 2 and String.downcase(String.trim(heading.title)) == title

  # A handbook installed before 1.2.0 reconciled weekly, over everything
  # since the last run. Installing over it moves the reconcile card (the
  # series' current instance, else the newest of that title) to the nightly
  # procedure: its description, and a series' rule when it is on another.
  # Nothing else on the card or the series changes, and a card already
  # current is left alone. Reported as "<title> (updated: nightly)".
  defp upgrade_reconcile(root, user, report) do
    with false <- Enum.member?(report.added["cards"], @reconcile_title),
         {card, series} <- reconcile_card(root),
         true <- upgrade(card, series, user) do
      {note_card(report, "#{@reconcile_title} (updated: nightly)"), true}
    else
      _ -> {report, false}
    end
  end

  # Whether anything changed. Neither write stops the install: what fails
  # is just not reported.
  defp upgrade(card, series, user) do
    {:ok, daily} = Slipdock.Recurrence.Rule.parse_phrase(@reconcile_repeat)
    nightly = is_nil(series) or series.rule == Slipdock.Recurrence.Rule.to_string(daily)

    described_now =
      card.description != @reconcile_description and
        match?(
          {:ok, _},
          Boards.update_card(card, %{"description" => @reconcile_description}, by: user)
        )

    nightly_now =
      not nightly and
        match?({:ok, _}, Slipdock.Recurrence.set(card, %{"rule" => @reconcile_repeat}, user))

    described_now or nightly_now
  end

  # 1.9.0 (#2779): the triage card files leftovers as fixes to Housekeeping
  # and design questions to Triage. Installing over an older handbook moves
  # the newest open *Triage findings* card to the current procedure; one
  # already current is left alone. Reported as "<title> (updated: procedure)".
  defp upgrade_triage(root, user, report) do
    with false <- Enum.member?(report.added["cards"], @triage_title),
         %{completed: false, description: description} = card <- newest_card(root, @triage_title),
         true <- description != @triage_description,
         {:ok, _} <- Boards.update_card(card, %{"description" => @triage_description}, by: user) do
      {note_card(report, "#{@triage_title} (updated: procedure)"), true}
    else
      _ -> {report, false}
    end
  end

  defp note_card(report, name), do: update_in(report, [:added, "cards"], &(&1 ++ [name]))

  defp reconcile_card(root) do
    cards =
      from(c in Slipdock.Boards.Card,
        where: c.board_id == ^root.id and c.title == @reconcile_title,
        order_by: [desc: c.id]
      )
      |> Repo.all()

    with_series =
      Enum.find_value(cards, fn card ->
        if series = Slipdock.Recurrence.for_card(card), do: {card, series}
      end)

    cond do
      with_series -> with_series
      card = List.first(cards) -> {card, nil}
      true -> nil
    end
  end

  # The first reconcile and triage wait for the seed: there is nothing to
  # reconcile, nor anything to promote findings into, until the pages have
  # been written, and a loop skips a blocked card. Only a card this install
  # made is made to wait.
  defp after_seed(root, added) do
    waiting = Enum.filter([@reconcile_title, @triage_title], &Enum.member?(added, &1))

    with [_ | _] <- waiting,
         %{completed: false} = seed <- newest_card(root, @seed_title) do
      for title <- waiting, card = newest_card(root, title), do: Boards.add_dependency(card, seed)
    end
  end

  defp newest_card(root, title) do
    from(c in Slipdock.Boards.Card,
      where: c.board_id == ^root.id and c.title == ^title,
      order_by: [desc: c.id],
      limit: 1
    )
    |> Repo.one()
  end

  # A handbook from before 1.3.0 has no `## Triage` on its Index: appended,
  # so nothing written there is touched. Reported as "Index (Triage log added)".
  defp add_triage_log(root, user, report) do
    with %{index: index} <- find(root),
         false <- has_heading?(index, "triage"),
         {:ok, _} <-
           Wiki.append(index, @triage_log,
             user: user,
             message: "Triage log added by the Handbook Tool, #{@version}"
           ) do
      update_in(report, [:added, "pages"], &(&1 ++ ["Index (Triage log added)"]))
    else
      _ -> report
    end
  end

  defp has_heading?(page, title) do
    page.body
    |> Wiki.Section.headings()
    |> Enum.any?(&h2?(&1, title))
  end

  defp can_write(user, board) do
    if Slipdock.Access.can_write?(Slipdock.Access.board_permission(user, board)),
      do: :ok,
      else: {:error, "installing a handbook needs write access to #{board.name}"}
  end

  ## Finding one -----------------------------------------------------------------

  @doc "The root of `board`'s tree: a sub-board's handbook is its root board's."
  def root(%Board{root_id: nil} = board), do: board
  def root(%Board{root_id: id}), do: Boards.get_board!(id)

  @doc """
  The handbook of `board`'s tree, or nil when its root board has none:
  `%{board:, folder:, index:, pages:, installed_at:}`, where `pages` are the
  pages filed in the Handbook folder (the Index first), unarchived.
  """
  def find(%Board{} = board) do
    root = root(board)

    with {:ok, folder} <- Folders.find(root, "/" <> @folder),
         pages = folder_pages(root, folder),
         %Page{} = index <- Enum.find(pages, &(key(&1) == "index")) do
      %{
        board: root,
        folder: folder,
        index: index,
        pages: [index | Enum.reject(pages, &(&1.id == index.id))],
        installed_at: index.inserted_at
      }
    else
      _ -> nil
    end
  end

  def find(_), do: nil

  @doc """
  Where `board`'s handbook says what to run before a push (#1878): the
  Testing & tooling page's code and the path `slipdock page section` reads,
  as `%{page: "W-12", path: "Testing & tooling/Before you push"}`, or nil
  when the tree has no handbook or that page has no such section.
  """
  def before_you_push(%Board{} = board) do
    with %{pages: pages} <- find(board),
         %Page{} = page <- Enum.find(pages, &(key(&1) == "testing")),
         %{path: path} <-
           Enum.find(Wiki.Section.headings(page.body), &h2?(&1, "before you push")) do
      %{page: page.code, path: path}
    else
      _ -> nil
    end
  end

  def before_you_push(_), do: nil

  @doc """
  Where `board`'s handbook says how to set up a machine (#2579): the Testing
  & tooling page's code and the path of its `## Local setup`, as
  `%{page: "W-12", path: "Testing & tooling/Local setup"}`, or nil when the
  tree has no handbook or that page has no such section. A runner machine's
  needs are a `### A runner machine` inside it, read with the rest.
  """
  def local_setup(%Board{} = board) do
    with %{pages: pages} <- find(board),
         %Page{} = page <- Enum.find(pages, &(key(&1) == "testing")),
         %{path: path} <- Enum.find(Wiki.Section.headings(page.body), &h2?(&1, "local setup")) do
      %{page: page.code, path: path}
    else
      _ -> nil
    end
  end

  def local_setup(_), do: nil

  @doc "The decision pages: those filed in `Handbook/Decisions`."
  def decisions(%{board: root}) do
    case Folders.find(root, "/" <> @decisions) do
      {:ok, folder} -> folder_pages(root, folder)
      _ -> []
    end
  end

  defp folder_pages(root, folder) do
    from(p in Page,
      where:
        p.board_id == ^root.id and p.folder_id == ^folder.id and is_nil(p.archived_at) and
          p.template == false,
      order_by: [asc: p.position, asc: p.title]
    )
    |> Repo.all()
  end

  ## What a pass should read (#1264) -----------------------------------------------

  # The ten built-in pages always fit, however long their fields (#1283, #2040).
  @index_cap 2560
  @field_chars 80
  @suggestions 5
  # So one long page can't fill every slot (#1281).
  @per_page 2

  @doc """
  What a pass on `card` should read, for `reader`: nil when the card's root
  board has no handbook or `reader` can't read that board, otherwise

      %{board: code, index_page: code, index: [%{code:, title:, summary:, read_when:}],
        suggested: [%{page:, title:, section:, why:}], more: n}

  `index` is every handbook page but the Index itself, its fields cut short
  so the whole stays under #{@index_cap} bytes of JSON (`more` says how many
  pages that left out). `suggested` is up to #{@suggestions} sections, best
  first: pages whose `covers:` globs match a path the card mentions, then
  sections ranked against the card's title and description, by semantic
  search when the server has it and by the words they share otherwise.

  Options: `:token`, the API token asking, which narrows `reader`'s reach.
  """
  def for_card(%Slipdock.Boards.Card{} = card, reader, opts \\ []) do
    board = Repo.get!(Board, card.board_id)

    with %{} = handbook <- find(board),
         true <- readable?(reader, handbook.board, opts[:token]) do
      {index, more} = index(handbook)

      %{
        board: handbook.board.code,
        index_page: handbook.index.code,
        index: index,
        more: more,
        suggested: suggest(handbook, card, reader, opts)
      }
      |> put_card_rules(handbook, card)
    else
      _ -> nil
    end
  end

  @doc "The index alone, for a board (`slipdock handbook <board>`); nil as `for_card/3`."
  def for_board(%Board{} = board, reader, opts \\ []) do
    with %{} = handbook <- find(board),
         true <- readable?(reader, handbook.board, opts[:token]) do
      {index, more} = index(handbook)

      %{
        board: handbook.board.code,
        index_page: handbook.index.code,
        index: index,
        more: more,
        decisions: Enum.map(decisions(handbook), &%{code: &1.code, title: &1.title}),
        rules: rules_summary(handbook)
      }
    else
      _ -> nil
    end
  end

  ## The rules for a set of paths (#1774) ------------------------------------------

  @rules_cap 2048
  @rule_text 160

  @doc """
  The rules of `handbook` (as `find/1` gives it) whose scope overlaps any of
  `paths`: file paths, folders or globs (a card's lane paths), matched as
  lanes are (`Slipdock.Lanes.glob_overlap?/2`). A rule with no scope of its
  own has its page's `covers:`, or everywhere when that is empty (see
  `Slipdock.Handbook.Rules`). `must` rules come first, then `should`, each in
  the handbook's order. No handbook, or no paths, is no rules.
  """
  def rules_for(nil, _paths), do: []

  def rules_for(handbook, paths) do
    case clean_paths(paths) do
      [] ->
        []

      paths ->
        handbook
        |> Slipdock.Handbook.Rules.rules()
        |> Enum.filter(fn rule -> Slipdock.Lanes.overlap?(rule.scope, paths) end)
        |> Enum.sort_by(&if(&1.severity == "must", do: 0, else: 1))
    end
  end

  @doc """
  The rules of `board`'s handbook for `paths`, for `reader`:
  `%{board:, index_page:, paths:, pages:, rules:}` with the pages whose
  `covers:` take in any of them (`pages_for/2`) and every matching rule, or
  nil when the tree keeps no handbook or `reader` can't read it. Options as
  `for_card/3`.
  """
  def rules_for_board(%Board{} = board, reader, paths, opts \\ []) do
    with %{} = handbook <- find(board),
         true <- readable?(reader, handbook.board, opts[:token]) do
      paths = clean_paths(paths)

      %{
        board: handbook.board.code,
        index_page: handbook.index.code,
        paths: paths,
        pages: pages_for(handbook, paths),
        rules: rules_for(handbook, paths)
      }
    else
      _ -> nil
    end
  end

  @doc """
  The handbook's pages (not the Index) whose `covers:` take in any of
  `paths`, matched as lanes are: `%{code:, title:, paths:}`, where `paths`
  counts the ones the page covers, most first and then in the handbook's
  order. What a reconcile reads for a range of commits (#1787). A page with
  no `covers:` claims nothing, so it is never listed.
  """
  def pages_for(handbook, paths), do: handbook |> pages_for_each([paths]) |> hd()

  @doc """
  `pages_for/2` for each of `path_lists`, in order. Each distinct path is
  matched against the pages' `covers:` once, however many lists hold it
  (#1977: a quality report reads hundreds of cards that touch the same
  files).
  """
  def pages_for_each(nil, path_lists), do: Enum.map(path_lists, fn _ -> [] end)

  def pages_for_each(handbook, path_lists) do
    path_lists = Enum.map(path_lists, &clean_paths/1)

    pages =
      handbook.pages
      |> Enum.reject(&(&1.id == handbook.index.id))
      |> Enum.with_index()
      |> Enum.map(fn {page, order} -> {order, page, covers(page)} end)
      |> Enum.reject(fn {_order, _page, globs} -> globs == [] end)

    # Each path: the orders of the pages covering it.
    covering =
      path_lists
      |> Enum.concat()
      |> Enum.uniq()
      |> Map.new(fn path ->
        {path, for({order, _, globs} <- pages, Slipdock.Lanes.overlap?(globs, [path]), do: order)}
      end)

    Enum.map(path_lists, &ranked_pages(pages, &1, covering))
  end

  # The pages covering any of `paths`, with how many: most first, then in
  # the handbook's order.
  defp ranked_pages(pages, paths, covering) do
    counts = paths |> Enum.flat_map(&covering[&1]) |> Enum.frequencies()

    pages
    |> Enum.filter(fn {order, _page, _globs} -> Map.has_key?(counts, order) end)
    |> Enum.sort_by(fn {order, _page, _globs} -> {-counts[order], order} end)
    |> Enum.map(fn {order, page, _globs} ->
      %{code: page.code, title: page.title, paths: counts[order]}
    end)
  end

  # The page's `covers:` globs; none claims nothing.
  defp covers(page), do: page |> field("covers") |> List.wrap() |> Enum.filter(&is_binary/1)

  defp clean_paths(paths) do
    paths
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # A card with lane paths carries the rules for them, `must` first, cut to
  # fit #{@rules_cap} bytes of JSON like the index (`rules_more` counts what
  # that left out: `slipdock handbook <board> --paths …` has them all).
  defp put_card_rules(reading, handbook, card) do
    case card.paths || [] do
      [] ->
        reading

      paths ->
        entries =
          for rule <- rules_for(handbook, paths) do
            %{
              id: rule.id,
              severity: rule.severity,
              page: rule.page,
              section: rule.section,
              check: rule.check,
              text: cut(rule.text, @rule_text)
            }
          end

        {rules, more} = fit(entries, [], @rules_cap)
        Map.merge(reading, %{rules: rules, rules_more: more})
    end
  end

  @doc false
  def rules_cap, do: @rules_cap

  # How many rules the handbook has, and what didn't parse (#1773): the
  # writer of a rule finds out here that it isn't one.
  defp rules_summary(handbook) do
    {rules, problems} = Slipdock.Handbook.Rules.parse(handbook)

    %{
      count: length(rules),
      must: Enum.count(rules, &(&1.severity == "must")),
      problems: problems
    }
  end

  defp readable?(nil, _board, _token), do: false

  defp readable?(reader, board, token) do
    level = Slipdock.Access.board_permission(reader, board)
    {level, _} = Slipdock.Access.narrow(level, token, board.id)
    Slipdock.Access.can_read?(level)
  end

  @doc false
  def index_cap, do: @index_cap

  defp index(%{pages: [_index | pages]}) do
    entries =
      Enum.map(pages, fn page ->
        %{
          code: page.code,
          title: page.title,
          summary: cut(page.summary),
          read_when: cut(text_field(page, "read_when"))
        }
      end)

    fit(entries, [], @index_cap)
  end

  # Keeps entries while the whole still fits, so a folder somebody filled
  # with fifty pages can't swamp every card it is shown on.
  defp fit([], kept, _cap), do: {Enum.reverse(kept), 0}

  defp fit([entry | rest] = left, kept, cap) do
    if byte_size(Jason.encode!(Enum.reverse([entry | kept]))) <= cap,
      do: fit(rest, [entry | kept], cap),
      else: {Enum.reverse(kept), length(left)}
  end

  defp cut(text, chars \\ @field_chars)
  defp cut(nil, _chars), do: nil
  defp cut(text, chars) when byte_size(text) <= chars, do: text
  defp cut(text, chars), do: String.slice(text, 0, chars - 1) <> "…"

  defp text_field(page, key) do
    case field(page, key) do
      list when is_list(list) -> Enum.join(list, ", ")
      other -> other
    end
  end

  ## Ranking ----------------------------------------------------------------------

  defp suggest(handbook, card, reader, opts) do
    pages = Enum.reject(handbook.pages, &(&1.id == handbook.index.id))
    text = card_text(card)

    covered = covered(pages, mentioned_paths(text))
    words = lexical(pages, text)
    # A short page is one chunk in the search index, so a match on it names
    # no section: the section of it the card shares most words with, if any.
    best = words |> Enum.reverse() |> Map.new(&{&1.page, &1})

    semantic =
      handbook
      |> semantic(pages, text, reader, opts)
      |> Enum.map(fn
        %{section: nil} = s -> if b = best[s.page], do: %{s | section: b.section}, else: s
        s -> s
      end)

    (covered ++ semantic ++ words)
    |> Enum.uniq_by(&{&1.page, &1.section})
    # A page whose covers matched stands for all of it: its sections add nothing.
    |> drop_covered_sections(covered)
    |> per_page(@per_page)
    |> Enum.take(@suggestions)
  end

  defp card_text(card), do: Enum.join([card.title, card.description || ""], "\n")

  defp per_page(suggestions, n) do
    suggestions
    |> Enum.reduce({[], %{}}, fn s, {kept, seen} ->
      count = Map.get(seen, s.page, 0)
      if count < n, do: {[s | kept], Map.put(seen, s.page, count + 1)}, else: {kept, seen}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp drop_covered_sections(suggestions, covered) do
    whole = MapSet.new(covered, & &1.page)
    Enum.reject(suggestions, &(&1.section != nil and MapSet.member?(whole, &1.page)))
  end

  # Paths the card names: anything with a slash, or a file with an extension.
  # `u` reads the text as characters: without it `\w` takes the first byte of a
  # "…" or "é" after a path, and the half character breaks the card's JSON.
  @path ~r{(?<![\w@])(?:[\w.\-]+/)+[\w.*\-]*|\b[\w\-]+\.(?:exs?|heex|eex|js|ts|tsx|css|md|json|ya?ml|sh|py|sql|toml)\b}u

  @doc false
  def mentioned_paths(text) do
    text = Regex.replace(~r{\w+://\S+}u, text || "", " ")

    @path
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp covered(_pages, []), do: []

  defp covered(pages, paths) do
    for page <- pages,
        globs = List.wrap(field(page, "covers")),
        path = Enum.find(paths, fn path -> Enum.any?(globs, &glob_match?(&1, path)) end),
        do: %{page: page.code, title: page.title, section: nil, why: "covers #{path}"}
  end

  @doc """
  Whether `path` falls under `glob`: `**` crosses folders, `*` doesn't. A
  path the card names may be a folder (`lib/app/`), which matches a glob for
  anything under it.
  """
  def glob_match?(glob, path) when is_binary(glob) and is_binary(path) do
    regex =
      glob
      |> String.trim()
      |> String.split("**")
      |> Enum.map_join(".*", fn part ->
        part |> String.split("*") |> Enum.map_join("[^/]*", &Regex.escape/1)
      end)

    path = String.trim_leading(path, "./")
    String.match?(path, ~r/\A#{regex}\z/) or String.match?(path <> "x", ~r/\A#{regex}\z/)
  end

  def glob_match?(_, _), do: false

  defp semantic(handbook, pages, text, reader, opts) do
    if Slipdock.AI.Embeddings.configured?() do
      by_id = Map.new(pages, &{&1.id, &1})

      case Slipdock.Search.search(reader, text,
             kind: :page,
             board_id: handbook.board.id,
             limit: 20,
             token: opts[:token]
           ) do
        {:ok, results} ->
          for %{page: %Page{id: id}, matches: matches} <- results,
              page = by_id[id],
              match <- matches,
              do: %{
                page: page.code,
                title: page.title,
                section: section_path(match[:section], page),
                why: "matches the card"
              }

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  A search chunk's section as a path `page section` can read, or nil for
  the whole page (#1281). A long section is chunked in parts (`Deploy#2`):
  the part is the section. The page's lone top heading is all of it.
  """
  def section_path(raw, page) do
    path = Regex.replace(~r/#\d+\z/, raw || "", "")

    cond do
      path == "" -> nil
      not String.contains?(path, "/") and top_heading?(page, path) -> nil
      true -> path
    end
  end

  defp top_heading?(page, path) do
    page.body |> Wiki.Section.headings() |> Enum.any?(&(&1.level == 1 and &1.path == path))
  end

  # Words the card shares with each section, its page's title, summary and
  # read_when counting double: a page says when it should be read.
  defp lexical(pages, text) do
    wanted = words(text)

    pages
    |> Enum.flat_map(fn page ->
      about =
        words(
          Enum.join([page.title, page.summary || "", text_field(page, "read_when") || ""], " ")
        )

      page_score = 2 * MapSet.size(MapSet.intersection(wanted, about))

      page
      |> sections()
      |> Enum.map(fn {path, body} ->
        score = page_score + MapSet.size(MapSet.intersection(wanted, words(body)))
        {score, %{page: page.code, title: page.title, section: path, why: "shares words"}}
      end)
    end)
    |> Enum.filter(fn {score, _} -> score > 0 end)
    |> Enum.sort_by(fn {score, _} -> -score end)
    |> Enum.map(&elem(&1, 1))
  end

  # A page's `##` sections (deeper ones roll into theirs); a page with none
  # is one section, addressed by nothing.
  defp sections(page) do
    case Enum.filter(Wiki.Section.headings(page.body), &(&1.level == 2)) do
      [] ->
        [{nil, page.body || ""}]

      headings ->
        for h <- headings do
          {:ok, body} = Wiki.Section.read(page.body, h.path)
          {h.path, body}
        end
    end
  end

  @stop ~w(a an and are as at be by can do for from has have in into is it its of on or
           our so that the their them then this to was we what when which with you your
           any all not new one way get set use make add adding added)

  defp words(text) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(text || ""))
    |> List.flatten()
    |> Enum.map(&stem/1)
    |> Enum.reject(&(Enum.member?(@stop, &1) or String.length(&1) < 2))
    |> MapSet.new()
  end

  defp stem(word) do
    cond do
      String.length(word) > 5 and String.ends_with?(word, "ing") -> String.slice(word, 0..-4//1)
      String.length(word) > 4 and String.ends_with?(word, "es") -> String.slice(word, 0..-3//1)
      String.length(word) > 3 and String.ends_with?(word, "s") -> String.slice(word, 0..-2//1)
      String.length(word) > 4 and String.ends_with?(word, "ed") -> String.slice(word, 0..-3//1)
      true -> word
    end
  end

  ## The docs gate's record (#1266) ---------------------------------------------

  # `Handbook: …` on a line of its own, as a list item or bold or quoted,
  # with something after it: what was updated, or `no change (why)`.
  @gate_line ~r/^[ \t>]*(?:[-*+][ \t]+)?(?:\*\*|__)?Handbook:(?:\*\*|__)?[ \t]*(\S[^\n]*)$/m

  @doc """
  What a closing comment's `Handbook:` line says (`"updated W-3 §Contexts"`,
  `"no change (tests only)"`), or nil when `text` has none. The loop writes
  the line; the gardener reads it.
  """
  def gate_line(text) when is_binary(text) do
    case Regex.run(@gate_line, text) do
      [_, said] -> String.trim(said)
      _ -> nil
    end
  end

  def gate_line(_), do: nil

  @doc "A page's `handbook:` key (`architecture`, `index`, …), or nil."
  def key(%Page{} = page), do: field(page, "handbook")

  @doc "A front-matter value of a handbook page, as a string or a list of strings."
  def field(%Page{front_matter: header}, key),
    do: header |> FrontMatter.yaml() |> FrontMatter.get(key)
end

defmodule SlipdockWeb.HelpLive.Flow do
  @moduledoc """
  Help › Agents › How work flows (`/help/agents/flow`, #1885): one card on a
  board worked by runners, from being written to being deployed, with who
  acts at each stage and where a person has to.

  The facts are the manual's (*Verified work*, *Lanes*, *Waiting on a
  person*, *Tidying up*, *Findings*), `docs/agents.md` and the API guide;
  this page joins them up and links out rather than repeating every option.
  Every `slipdock …` command it shows is checked against `cli/help.txt`, and
  every setting in `settings/0` against the board's Agentic Building page, by
  `SlipdockWeb.HelpLive.FlowTest`, so a rename breaks a test, not the page.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.HelpLive.Components

  alias SlipdockWeb.HelpLive.Agents

  # The stages, in order: the diagram and the sections below are both drawn
  # from this. `person` is true where a person has to act at that stage;
  # `steps` are the step statuses the server posts there (#2022,
  # `Slipdock.StepStatus`).
  @stages [
    %{
      id: "writing",
      steps: [],
      title: "Writing the card",
      actors: [:person],
      person: true,
      gist: "You write the ask and a bar that can be met."
    },
    %{
      id: "claimed",
      steps: ["Writing code", "Reworking after verify failed"],
      title: "Queued and claimed",
      actors: [:board, :builder],
      person: false,
      gist: "A rule queues a job; a runner pulls it; the bar locks."
    },
    %{
      id: "building",
      steps: ["Waiting for human"],
      title: "Building",
      actors: [:builder],
      person: true,
      gist: "Keeps to the handbook's rules, runs the pre-push checks. Waits on you if stuck."
    },
    %{
      id: "shipping",
      steps: [],
      title: "Shipping",
      actors: [:builder, :ci],
      person: false,
      gist: "Pushes main, or opens a pull request whose CI is the full test run."
    },
    %{
      id: "submitting",
      steps: ["Verifying", "Waiting for human to accept"],
      title: "Submitting",
      actors: [:builder],
      person: false,
      gist: "Completes with evidence, a Handbook line and Findings."
    },
    %{
      id: "verifying",
      steps: [
        "Verify failed; queued for rework",
        "Waiting for human (rejection limit)",
        "Waiting for human (held before merge)",
        "Accepted; merging",
        "Merged",
        "Done"
      ],
      title: "Verifying",
      actors: [:verifier, :person],
      person: true,
      gist: "A second agent accepts or rejects. You decide without one, or past the limit."
    },
    %{
      id: "afterwards",
      steps: ["Shipped to production", "Reopened"],
      title: "Afterwards",
      actors: [:ci, :person],
      person: true,
      gist: "Deploy, then you triage findings and apply the gardener's proposals."
    }
  ]

  # The board settings this page names: the label on the board's Agentic
  # Building page (#2011), and the CLI that sets it. FlowTest checks both still exist.
  @settings [
    {"A bar before work starts", "slipdock set-board B --bar-required",
     "Agents write each card's bar before they may start it; it locks then."},
    {"Lanes", "slipdock set-board B --lane-mode hold",
     "Hold: an agent can't start a card whose paths overlap a card in progress. Advise: it starts, and its prompt names that card."},
    {"Profiles", "slipdock set-board B --profiles on",
     "A card an agent starts gets one word for what kind of change it is; a schema or security card an agent accepts waits for a person before it merges, and a spike merges nothing and holds no lane. A docs card gets no verify job, and a schema or security card's verifier also reviews it for defects. A fix, feature, schema or security card's verifier breaks a few of the changed lines to see that a test fails."},
    {"Human tier, by profile", "slipdock set-board B --profile-tier schema=none",
     "Change what an agent's acceptance of a profile does: none, ledger or before_merge."},
    {"Shared paths", "slipdock set-board B --shared-paths docs/manual.md,README.md",
     "Files nearly every card edits: an overlap there never holds a card or a job."},
    {"WIP limits hold automated work", "slipdock set-board B --automation-wip",
     "A full first in-progress list holds runner jobs too."},
    {"Evidence on completion", "slipdock set-board B --evidence-required",
     "An agent completing a card says what it checked."},
    {"A second agent verifies", "slipdock set-board B --verify-work",
     "An agent's completion is a submission, decided by someone else."},
    {"Runner pool for verify jobs", "slipdock set-board B --verify-pool checkers",
     "Sends each submission to that pool as a verify job. Blank: you decide."},
    {"Ship accepted work by", "slipdock set-board B --ship-via pull-request",
     "Push (the default) or pull request. Pull request needs verification on."},
    {"Rejections before a person decides", "slipdock set-board B --verify-rejection-limit 2",
     "The rejection after this many opens a wait on the board's owner (2; 0 never)."},
    {"Audit 1 in N accepted cards", "slipdock set-board B --verify-audit 10",
     "Another runner rechecks about one accepted card in N (0, the default, none)."},
    {"An approval's proposal stands after", "slipdock set-board B --wait-default-after 4h",
     "An unanswered approval wait (kind other, with a proposed choice) goes ahead with its proposal (off by default)."}
  ]

  def stages, do: @stages
  def settings, do: @settings

  attr :topics, :list, required: true

  def page(assigns) do
    assigns = assign(assigns, stages: @stages, settings: @settings)

    ~H"""
    <Agents.topic_nav topics={@topics} current="flow" />

    <article id="help-flow" class="space-y-6">
      <header class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <.page_header
          title="How work flows"
          subtitle="What happens to a card on a board that runners work, from the moment you write it to the deploy: who acts at each stage, what the board checks, and where it waits for you."
          class=""
        >
          <:leading>
            <.icon name="hero-arrow-path-rounded-square" class="size-6 text-primary" />
          </:leading>
        </.page_header>
        <p class="mt-2 text-sm text-base-content/70">
          The other help pages say how to connect an agent. This one says what it does once
          connected. Each check below is a board setting, off until you turn it on; with them
          all off, an agent's <em>done</em> is simply done.
        </p>
        <p id="flow-step-statuses" class="mt-2 text-sm text-base-content/70">
          At each stage the board posts the card's <strong>step status</strong>
          itself, as an <em>On track</em>
          status update by Slipdock: it shows at the top of the card and in its Status updates, and,
          being routine, tells nobody following the card. Agents needn't post these; a person's own
          update (at risk, off track) still tells them. A finished card shows its outcome there
          instead of a next step: done when, accepted by whom, merged and shipped.
        </p>
      </header>

      <.diagram stages={@stages} />

      <.part :for={s <- @stages} id={"flow-#{s.id}"} title={stage_heading(s, @stages)}>
        <.actors actors={s.actors} />
        <.steps id={s.id} steps={s.steps} />
        <.stage id={s.id} />
      </.part>

      <.part id="flow-settings" title="The settings, in one place">
        <p>
          Each is on the board's <strong>Agentic Building</strong>
          page: turn on Agentic Building in Board settings, Features, then open it from the board menu. From a terminal,
          <code>slipdock set-board</code>
          sets each. A card's subcards take their parent board's choices.
        </p>
        <dl class="divide-y divide-base-content/10">
          <div :for={{label, cli, what} <- @settings} class="py-2">
            <dt class="font-medium text-base-content">{label}</dt>
            <dd class="mt-0.5">{what}</dd>
            <dd class="mt-1"><code class="break-words">{cli}</code></dd>
          </div>
        </dl>
      </.part>

      <.part id="flow-overseer" title="The overseer: when to look">
        <p>
          The board's owner can turn on an eye on outcomes, in the board's Automations panel
          under <strong>Overseer</strong>, or with <code>slipdock overseer B --on</code>.
          Every minute the server checks the tree for work going round (a second rejection, a
          third runner pass), something waiting on you while nothing runs, a card past the
          board's P85 or a job on one step for 30 minutes, idle runners beside a full ready
          list or jobs queued behind one lane, and an epic whose open subcards are all blocked.
        </p>
        <p>
          Each fires once: an alert, an email, and the top of My work's <em>Waiting on you</em>,
          saying why and what to do. It clears itself when the condition ends. A cheap model on
          one of your runners (a <code>job_overseer</code>
          in its config) reads only those and the pulse, never a card or a log, and writes a
          digest on the board's <em>Overseer</em>
          card: every 10 minutes while cards are active, longer when little or nothing is in
          flight. It flags; it never acts.
        </p>
      </.part>

      <.part id="flow-more" title="More detail">
        <ul class="list-disc space-y-1 pl-5">
          <li>
            <.link patch={~p"/help/agents/runners"} class="link">Runners</.link>: connecting one,
            and the rules that send it work.
          </li>
          <li>
            <a href={~p"/api/guide"} class="link">The agent guide</a>
            (its <em>Verified work</em>, <em>Lanes</em>
            and <em>Shipping by pull request</em>
            parts):
            exactly what agents are told.
          </li>
          <li>
            <.link patch={~p"/help/agents/cli/reference"} class="link">Every CLI command</.link>,
            with each option.
          </li>
          <li>
            The manual (<code>docs/manual.md</code>
            in the source): <em>Verified work</em>, <em>Lanes</em>, <em>Waiting on a person</em>, <em>Tidying up</em>,
            <em>The overseer</em>
            and <em>Findings</em>,
            and <code>docs/agents.md</code>
            on the handbook's rules and runners.
          </li>
        </ul>
      </.part>
    </article>
    """
  end

  defp stage_heading(stage, stages) do
    n = Enum.find_index(stages, &(&1.id == stage.id)) + 1
    "#{n}. #{stage.title}"
  end

  # ── The diagram ───────────────────────────────────────────────────────────
  # A column of stages joined by arrows, so it never needs to scroll
  # sideways: each says who acts, and the ones where a person must act are
  # ringed in the warning colour with a hand. The two ways back (a
  # rejection, a wait) hang off the stages they leave from.

  attr :stages, :list, required: true

  defp diagram(assigns) do
    ~H"""
    <section
      id="flow-diagram"
      aria-labelledby="flow-diagram-title"
      class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
    >
      <h2 id="flow-diagram-title" class="section-title">The flow at a glance</h2>
      <p class="mt-1 text-sm text-base-content/70">
        Who acts at each stage.
        <.icon name="hero-hand-raised" class="size-4 align-text-bottom text-warning" />
        <strong class="text-base-content">Ringed</strong>
        stages are where a person has to act.
      </p>
      <.legend />
      <ol class="mt-4 space-y-0">
        <li :for={{s, i} <- Enum.with_index(@stages, 1)} id={"flow-node-#{s.id}"}>
          <div
            class={[
              "flex min-w-0 items-start gap-3 rounded-xl p-3",
              (s.person && "bg-warning/10 ring-2 ring-warning") || "bg-base-200/60"
            ]}
            data-person={s.person && "true"}
          >
            <span class="flex size-7 shrink-0 items-center justify-center rounded-full bg-base-100 text-sm font-semibold tabular-nums ring-1 ring-base-content/15">
              {i}
            </span>
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                <a href={"#flow-#{s.id}"} class="link font-semibold">{s.title}</a>
                <span :for={a <- s.actors} class={["badge badge-sm", actor_class(a)]}>
                  {actor_label(a)}
                </span>
                <span
                  :if={s.person}
                  class="inline-flex items-center gap-1 text-xs font-medium text-base-content"
                >
                  <.icon name="hero-hand-raised" class="size-4 text-warning" /> You act here
                </span>
              </div>
              <p class="mt-1 text-sm text-base-content/70">{s.gist}</p>
              <.branch :if={s.id == "building"} icon="hero-pause-circle">
                Stuck on something only you can give: a <strong>wait</strong>
                on you. Your answer sends it back to work.
              </.branch>
              <.branch :if={s.id == "verifying"} icon="hero-arrow-uturn-left">
                <strong>Rejected:</strong> back to 2, the reason as its next brief.
              </.branch>
              <.branch :if={s.id == "verifying"} icon="hero-hand-raised">
                <strong>Rejected past the limit:</strong>
                a wait on you: rework it, or accept it as is.
              </.branch>
            </div>
          </div>
          <div
            :if={i < length(@stages)}
            class="flex justify-start py-1 pl-5 text-base-content/40"
            aria-hidden="true"
          >
            <.icon name="hero-arrow-down" class="size-4" />
          </div>
        </li>
      </ol>
    </section>
    """
  end

  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp branch(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-start gap-1.5 text-xs text-base-content/70">
      <.icon name={@icon} class="mt-px size-4 shrink-0 text-warning" />
      <span>{render_slot(@inner_block)}</span>
    </p>
    """
  end

  defp legend(assigns) do
    ~H"""
    <p class="mt-3 flex flex-wrap gap-2 text-xs text-base-content/70">
      <span :for={a <- [:person, :builder, :verifier, :ci, :board]} class="flex items-center gap-1">
        <span class={["badge badge-sm", actor_class(a)]}>{actor_label(a)}</span>
        {actor_note(a)}
      </span>
    </p>
    """
  end

  attr :actors, :list, required: true

  defp actors(assigns) do
    ~H"""
    <p class="flex flex-wrap items-center gap-1.5">
      <span class="font-medium text-base-content">Who acts:</span>
      <span :for={a <- @actors} class={["badge badge-sm", actor_class(a)]}>{actor_label(a)}</span>
    </p>
    """
  end

  attr :id, :string, required: true
  attr :steps, :list, required: true

  # The step statuses the server posts at a stage (#2022): On track, by
  # Slipdock, on the card's status updates and at the top of the card.
  defp steps(assigns) do
    ~H"""
    <div :if={@steps != []} id={"flow-#{@id}-steps"} class="flex flex-wrap items-center gap-1.5">
      <span class="font-medium text-base-content">Step status:</span>
      <span :for={step <- @steps} class="badge badge-sm badge-success badge-soft">{step}</span>
    </div>
    """
  end

  defp actor_label(:person), do: "Person"
  defp actor_label(:builder), do: "Builder"
  defp actor_label(:verifier), do: "Verifier"
  defp actor_label(:ci), do: "CI"
  defp actor_label(:board), do: "The board"

  defp actor_note(:person), do: "you, or whoever owns the board"
  defp actor_note(:builder), do: "the agent doing the card"
  defp actor_note(:verifier), do: "a second agent"
  defp actor_note(:ci), do: "your repository's checks"
  defp actor_note(:board), do: "its rules and checks"

  defp actor_class(:person), do: "badge-warning"
  defp actor_class(:builder), do: "badge-info badge-soft"
  defp actor_class(:verifier), do: "badge-success badge-soft"
  defp actor_class(:ci), do: "badge-ghost"
  defp actor_class(:board), do: "badge-ghost italic"

  # ── The stages ────────────────────────────────────────────────────────────

  attr :id, :string, required: true

  defp stage(%{id: "writing"} = assigns) do
    ~H"""
    <p>
      The card's description is <strong>the ask</strong>: what you want and why. Its
      <strong>bar</strong>
      says what done means, one line per part, and is what the work is judged against. On a
      board with <em>A bar before work starts</em>
      on, an agent can't start a card without one (<code>slipdock edit 12 --bar "…"</code>).
    </p>
    <.person_note>
      <strong>Write a bar that can be met.</strong>
      An agent may not take a step that is yours: changing a handbook rule, merging, deploying to
      production, applying a proposal. Phrase those as what an agent can do: "proposed as a garden
      proposal (rule id, wording)" rather than "W-12 has rule Y", and "pull request open, its CI
      green" rather than "merged". A bar asking for a person's step is caught at pickup and comes
      back to you as a wait.
    </.person_note>
    <p>
      On a board with <em>Lanes</em>
      on, give the card its <strong>paths</strong>: the files its work will touch, as globs
      (<code>slipdock edit 12 --paths "lib/billing/**,docs/manual.md"</code>). Two agents can't
      work cards whose paths overlap at once; the second waits. Set lanes to <em>Advise</em>
      (<code>slipdock set-board B --lane-mode advise</code>) and the second starts anyway, its job's
      prompt naming the card already in those files. Files nearly every card edits,
      such as the manual, go in the board's <strong>shared paths</strong>
      (<code>slipdock set-board B --shared-paths docs/manual.md,README.md</code>): cards can
      declare them without holding each other, and their edits are left to merge.
    </p>
    <p>
      An epic planned with the plan skill can start with <strong>spikes</strong>: a question only
      building can answer, which you confirm, becomes a card with the <code>spike</code>
      profile (<code>slipdock add 12 "Spike: does the API page?" --profile spike</code>), its
      bar the question. A spike needs no paths and holds no lane, and its code is never merged:
      its answer is a page pinned to the epic. Planning waits until the last is accepted, then
      a product wait on the epic asks you to resume, and the Spec is written from the answers.
    </p>
    <p>
      On a board with a <strong>handbook</strong>
      (its <code>Handbook/</code>
      wiki pages), the card lists the sections the builder should read first, and the rules
      that cover its paths (<code>slipdock card 12</code>).
    </p>
    """
  end

  defp stage(%{id: "claimed"} = assigns) do
    ~H"""
    <p>
      An automation rule queues a <strong>job</strong>
      for a <strong>pool</strong>: <em>Send cards to a runner</em>
      when a card arrives in a list, or <em>Work a list with a runner</em>, which sends the top
      card, one at a time. A runner in that pool pulls the job, or a session takes it with <code>slipdock claim-job B --pool loop</code>.
    </p>
    <p>
      Recurring agent work (a nightly sweep, the handbook's reconcile) lands in the board's
      <strong>Scheduled</strong>
      list, when it has one: a list in the <code>scheduled</code>
      category, after To Do. Nobody picks from it, people or agents asked what to do next. Its
      own <em>Work Scheduled with a runner</em>
      rules send each card on its day: when a list becomes Scheduled, every rule working the
      ready list gets one beside it, for the same pool. A Scheduled card still there after its
      due day is on its owner's <strong>Waiting on you</strong>.
    </p>
    <p>
      The agent moves the card into progress, and the <strong>bar locks</strong>: from then on
      only a person can change it. A job is held, saying why, while the board is paused, its WIP
      limit is full (<em>WIP limits hold automated work</em>), another card is in progress, or
      its lane overlaps one.
    </p>
    <p>
      While the job is claimed or running, the card's Assignees show the <strong>loop</strong>:
      the runner and the job's kind (build or verify), linked to the job. It goes when the job
      ends. The agent doesn't assign the card to anyone, since it signs in with a person's token.
    </p>
    <.person_note>
      <strong>A pause is yours to lift.</strong>
      Agents may pause runner work (<code>slipdock pause B --reason "…"</code>), and an agent
      that sees it takes nothing. Only a person resumes it: <code>slipdock resume B</code>
      or the Runners panel.
    </.person_note>
    """
  end

  defp stage(%{id: "building"} = assigns) do
    ~H"""
    <p>
      The builder reads the card and its handoff, and checks each part of the bar can be met.
      It keeps to the <strong>handbook's rules</strong>
      for the files it touches (<code>slipdock handbook B --paths lib/a.ex,lib/b.ex</code>):
      breaking a <code>must</code>
      rule gets the card rejected, a <code>should</code>
      is noted. It runs the project's own pre-push checks, the ones its <code>CLAUDE.md</code>
      or contributing guide lists, and comments on the card as it goes.
    </p>
    <.person_note>
      <strong>Answer its waits.</strong>
      Nobody watches a job, so an agent that needs something only you can give (a decision, a
      credential, a bar it can't meet) opens a <strong>wait</strong>
      and stops. The job is parked and the card goes back on top of its list. Answer it on the
      card, in My work's <em>Waiting on you</em>
      (<code>slipdock work</code>), or with <code>slipdock answer 12 "…"</code>, and the card is
      sent again with your answer at the top of its prompt.
      A wait is for what is yours to decide: readings that differ in cost or in what you see,
      product, UX, security and release calls, and your steps (merging, a handbook rule, a
      deploy). A bar item a later decision made moot isn't one: the agent reads it the obvious
      way, says so on the card with the citation, and the verifier judges it. A wait that offers
      choices names the one the agent proposes, so your answer can be one click; with
      <em>An approval's proposal stands after</em>
      set, an unanswered one of kind other goes ahead with it and you are told. A wait that has
      gone moot (answered elsewhere, the bar edited) is withdrawn by the next agent to find it,
      with a comment saying why.
    </.person_note>
    """
  end

  defp stage(%{id: "shipping"} = assigns) do
    ~H"""
    <p>
      <em>Ship accepted work by</em> chooses how the work reaches the default branch, and so
      the deploy.
    </p>
    <ul class="list-disc space-y-1 pl-5">
      <li>
        <strong>By push</strong>
        (the default): the builder pushes the default branch. If a push to main deploys, the work
        is live before anyone has checked it.
      </li>
      <li>
        <strong>By pull request</strong>: the builder never pushes the default branch. It pushes a
        <code>card-12</code>
        branch and opens a pull request. That pull request's CI is the one full test run: the
        builder runs only the tests it changed and the pre-push checks first, then watches the checks
        with <code>gh pr checks card-12 --watch --fail-fast</code>, so a failure is seen when it
        happens. A card that changes no code (a sweep, a handbook reconcile) has no pull request: it
        completes with <code>slipdock done 12 --no-code "why"</code>, and accepting it merges nothing.
      </li>
    </ul>
    """
  end

  defp stage(%{id: "submitting"} = assigns) do
    ~H"""
    <p>
      The builder completes the card with its <strong>evidence</strong>: what it checked, the
      commit, the tests it added or changed, the suite's result, and the pull request
      (<code>slipdock done 12 --evidence-commit abc1234 --suite passed:412:0 --pr URL</code>). With
      <em>Evidence on completion</em>
      on, a completion without any is refused. Evidence that is a bare <code>-</code>
      is refused on any board: it is what a client that doesn't read stdin sends for <code>--evidence -</code>, so pass the text itself, or pipe it from a CLI that reads stdin.
    </p>
    <p>
      On a board with a handbook, the closing comment has a <strong><code>Handbook:</code> line</strong>, the sections it updated or why none needed it, and a <strong><code>Findings:</code> block</strong>: what the card taught that the code and
      handbook don't show, for the daily triage to handle. An item already dealt with says where
      and is kept promoted, not open: <code>[done: W-1950 §Local setup]</code>
      after its kind, or <code>→ #2087</code>
      at its end for a card filed for it. A fix is a card, not a finding: a concrete change
      someone could be handed (a missing test, a stale doc, a tooling bug) goes on the board
      as a card at once, and the block names it with the arrow; a finding is only for what is
      uncertain, cuts across cards, or shows the handbook wrong.
    </p>
    <.person_note>
      <strong>No verifier, no check.</strong>
      With <em>A second agent verifies</em>
      off, the agent's completion is final: the card is done and in Done. Read the evidence
      yourself if you want it looked at.
    </.person_note>
    """
  end

  defp stage(%{id: "verifying"} = assigns) do
    ~H"""
    <p>
      With <em>A second agent verifies</em>
      on, the completion is a <strong>submission</strong>: the card stays in progress, awaiting
      verification. With <em>Runner pool for verify jobs</em>
      set, a <strong>verifier</strong>
      in that pool, never the runner that built it, judges in order: does the bar cover the ask;
      is each part of the bar met; did the suite pass (on a pull request board, the pull
      request's checks); are the rules kept (<code>must</code>
      and <code>should</code>; a rule broken only in code the change didn't touch is reported as
      pre-existing and kept as a finding, never a rejection); and is the Handbook line honest. A
      rejection names every instance found: once a rule is broken, the verifier looks for every
      other instance of the same break (the same list, the same string, the same door) and lists
      them all under that one rule, each with its file and line, so one round fixes them all. With
      profiles on, a <code>docs</code>
      card gets no verifier (the server accepts it on its suite), and a <code>schema</code>
      or <code>security</code>
      card's verifier also reviews the diff for defects, rejecting on an Important one. On a <code>fix</code>, <code>feature</code>,
      <code>schema</code>
      or <code>security</code>
      card the verifier also mutates the change: it breaks 3 to 5 of the lines the change added
      or changed, one at a time, runs only the card's tests and restores each line. A break no
      test catches (a surviving mutant) is a rejection naming the mutation and the test to
      write; on a fix, one break undoes the fix, which the regression test must catch. A
      survivor in lines the change didn't touch is kept as a finding. The
      profile is checked against the change the agent completes with
      (<code>slipdock done 12 --diff-base origin/main</code>): a migration makes it <code>schema</code>, a security path <code>security</code>, and over 400 changed lines a
      <code>fix</code>
      or <code>docs</code>
      card a <code>feature</code>, never lower. Then <code>slipdock verify 12 accept</code>
      or <code>slipdock verify 12 reject --reason "bar 2: …"</code>.
    </p>
    <p>
      <strong>On a bug, the ask is the reported symptom</strong>: the check is would the reporter
      now see it fixed, not does the work meet the bar. The builder reproduces the reported symptom
      on the reporter's scenario and posts the repro as its own comment; a clean repro that doesn't
      show it opens a wait saying what was seen and asking for a screenshot or steps (which screen,
      which control), never conditions built until something fails. The verifier rejects (<code>the ask: …</code>) a bug card whose card or evidence says the reported symptom or its cause
      was never seen, however good the tests.
    </p>
    <ul class="list-disc space-y-1 pl-5">
      <li>
        <strong>Accepted</strong>
        by push: the card is done. By pull request: a runner merges it, and the merge completes the
        card. A failed merge comes back as a rejection.
      </li>
      <li>
        <strong>Rejected</strong>: the card goes back to the top of its list, and the reason is the
        next pass's brief. Submitted again, it is judged on what failed and what the new commits
        touch; a part that passed before and nothing since touches is carried, shown as
        <em>carried from</em>
        the commit it passed at.
      </li>
      <li>
        <strong>Audits check the checker</strong>: with <em>Audit 1 in N accepted cards</em>
        set, another runner rechecks about one accepted card in N. It changes nothing; a
        disagreement raises an alert for the board's owner.
      </li>
    </ul>
    <.person_note>
      <strong>You decide when no verifier can.</strong>
      <ul class="mt-1 list-disc space-y-1 pl-5">
        <li>
          With no verify pool, or no runner in it other than the builder's, the card waits for you:
          <strong>Accept</strong>
          or <strong>Reject</strong>
          on the card, or <code>slipdock accept 12</code>. It is in My work's <em>Waiting on you</em>.
        </li>
        <li>
          A second rejection, or one for a rule an earlier rejection named, says the card is
          going round in circles: it stays flagged <strong>review</strong>
          until it is accepted, a comment lists the rounds and what failed in each, an alert goes up
          and you are emailed, and it heads My work's <em>Waiting on you</em>. The runners still
          rework it; look at whether it needs a different approach or a reworded bar.
        </li>
        <li>
          After <em>Rejections before a person decides</em>
          (2 by default), the next rejection opens a wait on the board's owner: rework it as
          rejected, or accept it as is. It lists what failed each time, and asks whether the
          approach, not the fix, is wrong. You can reword the bar first.
        </li>
        <li>
          When no runner can merge, merge the pull request yourself and press
          <strong>Merged it myself</strong>
          (<code>slipdock verify 12 merged</code>).
        </li>
        <li>An audit that disagrees is yours to follow up.</li>
      </ul>
    </.person_note>
    """
  end

  defp stage(%{id: "afterwards"} = assigns) do
    ~H"""
    <p>
      Your CI deploys what reaches the default branch. With delivery metrics on, it records the
      deploy (<code>slipdock deploy run --env production -- ./deploy.sh</code>), and the cards
      it names get a <em>Shipped</em> line.
    </p>
    <p>
      The <strong>handbook improves from use</strong>. The nightly <em>Reconcile the handbook</em>
      card brings its pages up to date with what landed, and <em>Triage findings</em>
      merges repeated findings and promotes what recurs, filing a new rule or decision as a
      proposal for you.
    </p>
    <.person_note>
      <strong>The proposals are yours to apply.</strong>
      <ul class="mt-1 list-disc space-y-1 pl-5">
        <li>
          A rule is a person's call. An agent proposes one
          (<code>slipdock garden propose B proposal.json</code>), and you apply or dismiss it on the
          board's <strong>Tidy-up page</strong>
          (<strong>Tidy up…</strong>
          in the board's menu, or <code>slipdock garden B</code>). A rule an agent edited itself
          shows there too, for you to keep or put back.
        </li>
        <li>
          Findings are handled by the daily triage and the server. A finding seen three times
          (the board's setting) is drafted as a rule on the Tidy-up page, and those proposals
          are what wait for you: the board's <strong>Findings page</strong>
          (a tile on the board's <em>Agentic Building</em>
          page, counting them; a card with open findings links to it) and
          <code>slipdock findings B</code>
          lead with them. The findings below are reference, to promote, merge or dismiss
          by hand when you want (<code>slipdock finding 41 promote --note "…"</code>).
        </li>
        <li>
          What shipped is on the board's <strong>Ledger page</strong>
          (a tile on <em>Agentic Building</em>), or <code>slipdock ledger B [--since 7]</code>: since 07:00
          yesterday, each card with who accepted it, its evidence, the <em>should</em>
          rules it missed, where its time went and what its jobs spent (the model's and
          the tools' time, and tokens where the logs carried them). Skim it each morning,
          and open any card's chat from it. A card a runner worked shows the same
          under <em>Lead time</em>
          in its panel, phase by phase.
        </li>
      </ul>
    </.person_note>
    """
  end

  slot :inner_block, required: true

  defp person_note(assigns) do
    ~H"""
    <div data-person="true" class="flex gap-2 rounded-xl bg-warning/10 p-3 ring-1 ring-warning">
      <.icon name="hero-hand-raised" class="mt-0.5 size-4 shrink-0 text-warning" />
      <div class="min-w-0 text-base-content">
        <span class="sr-only">A person acts here: </span>{render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end

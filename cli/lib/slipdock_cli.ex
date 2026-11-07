defmodule SlipdockCLI do
  @moduledoc "Command-line client for the Slipdock board API."

  import SlipdockCLI.Util, only: [fail: 1, bad_usage: 1]

  alias SlipdockCLI.{
    Admin,
    Auth,
    Automations,
    Boards,
    Deploy,
    Findings,
    Garden,
    Health,
    Inbound,
    Lanes,
    Ledger,
    Runners,
    Skills,
    Sync,
    Tools,
    Util,
    WholeWiki,
    Wiki
  }

  # The help text is a plain file so the web app's command reference
  # (SlipdockWeb.HelpLive.CLIReference) reads exactly what this prints.
  @help_path Path.expand("../help.txt", __DIR__)
  @external_resource @help_path
  @help File.read!(@help_path)

  @switches [
    json: :boolean,
    short_names: :boolean,
    from: :string,
    scope: :string,
    remove: :boolean,
    rotate: :boolean,
    ack: :string,
    key: :string,
    embed: :string,
    url: :string,
    column: :keep,
    tag: :keep,
    set_tag: :keep,
    no_tags: :boolean,
    priority: :keep,
    flag: :keep,
    rows: :string,
    cols: :string,
    unit: :string,
    sort: :string,
    descending: :boolean,
    view: :string,
    show_empty: :boolean,
    name: :string,
    code: :string,
    shortcut: :string,
    add_card: :boolean,
    add_page: :boolean,
    add_document: :boolean,
    page_card_features: :boolean,
    wiki_sort: :string,
    show_pulse: :boolean,
    show_age: :boolean,
    show_images: :boolean,
    # `slipdock deploy` (#1134).
    env: :string,
    sha: :string,
    revoke: :boolean,
    from_tags: :boolean,
    from_runs: :string,
    ci: :string,
    prompt: :boolean,
    incident_tag: :string,
    hotfix_hours: :integer,
    handoff_label: :string,
    inbound_senders: :string,
    handoff_prompt: :string,
    handoff_prompt_file: :string,
    card_ref_pattern: :string,
    pattern: :string,
    delivery_metrics: :boolean,
    automation_wip: :boolean,
    bar_required: :boolean,
    bar: :string,
    lanes: :boolean,
    lane_mode: :string,
    shared_paths: :string,
    paths: :string,
    # A card's profile (#1951), and whether a board infers them.
    profile: :string,
    no_profile: :boolean,
    profiles: :string,
    # The board's Agentic Building item and page in the web app (#2011).
    agentic_building: :string,
    paths_from: :string,
    evidence_required: :boolean,
    verify_work: :boolean,
    verify_pool: :string,
    verify_rejection_limit: :integer,
    verify_audit: :integer,
    findings_propose_at: :integer,
    # How long runner job logs stay (#1872), and `job <id> --keep`.
    job_log_hours: :integer,
    failure_log_hours: :integer,
    keep_log: :boolean,
    ship_via: :string,
    pr: :string,
    # Why a card changes no code (#1938): `done --no-code REASON`.
    no_code: :string,
    # The actual change (#2017): `done --diff-base REF`, or given by hand.
    diff_base: :string,
    changed_lines: :integer,
    changed_files: :string,
    evidence: :string,
    evidence_commit: :string,
    branch: :string,
    tests: :string,
    suite: :string,
    default_view: :string,
    sprints: :boolean,
    clear: :boolean,
    delete: :boolean,
    # `slipdock handoff <id> --next …`.
    next: :string,
    simple: :boolean,
    days: :integer,
    # `slipdock quality <board> --rules`: every broken rule, not the top five.
    rules: :boolean,
    # `slipdock garden <board> --run --check K`, `garden apply <id> --keep N --choice C`.
    run: :boolean,
    # Also `verify <id> … --check bar:2=fail:why`, repeated (#1778).
    check: :keep,
    checks_file: :string,
    keep: :string,
    # `garden apply <id> --choice C`; `wait <id> … --choice X --choice Y`.
    choice: :keep,
    # `slipdock wait <id> --withdraw`, `--job ID`, and `--on EMAIL` (read
    # as `--wait-on`, since `--on` is a switch elsewhere: see `main/1`).
    withdraw: :boolean,
    job: :string,
    wait_on: :string,
    needs: :string,
    goal: :string,
    template: :string,
    save_template: :string,
    list: :keep,
    fields: :string,
    group: :string,
    search: :string,
    open: :boolean,
    done: :boolean,
    archived: :boolean,
    deps: :string,
    limit: :integer,
    # `wiki changes --since N` (a cursor) and `ledger --since` (days, a date
    # or a time) both send it as given.
    since: :string,
    board: :string,
    title: :string,
    desc: :string,
    short_name: :string,
    # An incident (#1946): `add`/`edit --caused-by N --missed-by X`.
    caused_by: :string,
    no_caused_by: :boolean,
    missed_by: :string,
    no_missed_by: :boolean,
    due: :string,
    no_due: :boolean,
    assignee: :keep,
    add_assignee: :keep,
    remove_assignee: :keep,
    no_assignee: :boolean,
    start: :string,
    no_start: :boolean,
    percent: :integer,
    no_percent: :boolean,
    spent: :string,
    no_spent: :boolean,
    estimate: :string,
    no_estimate: :boolean,
    log: :string,
    color: :string,
    no_color: :boolean,
    # Each edge of a card's front in its own colour (#1209).
    border: :string,
    border_top: :string,
    border_right: :string,
    border_bottom: :string,
    border_left: :string,
    no_border: :boolean,
    icon: :string,
    no_icon: :boolean,
    top: :boolean,
    bottom: :boolean,
    index: :integer,
    off: :boolean,
    # `slipdock snooze <id> mon --note T --notify`, `slipdock cards B --snoozed only`.
    note: :string,
    notify: :boolean,
    snoozed: :string,
    # `slipdock cards B --stuck --driver agent` (#1117).
    stuck: :boolean,
    driver: :string,
    # `slipdock repeat <id> "every mon" --at 07:00 --lead 2 --ends DATE|--count N`.
    at: :string,
    lead: :integer,
    tz: :string,
    on_missed: :string,
    ends: :string,
    count: :integer,
    skip: :boolean,
    # `slipdock wait <id> --question Q --question Q` and
    # `slipdock answer <id> --answer A --answer A` (#1220): one per question.
    question: :keep,
    answer: :keep,
    pause: :boolean,
    resume: :boolean,
    read: :boolean,
    comment: :boolean,
    write: :boolean,
    wip: :integer,
    category: :string,
    kind: :keep,
    # Who each kind of question goes to (#1949): set-board --route K=EMAIL.
    route: :keep,
    no_route: :keep,
    # Each profile's human tier (#1952): set-board --profile-tier P=TIER.
    profile_tier: :keep,
    label: :string,
    hide_on_card: :boolean,
    replace: :boolean,
    wait: :boolean,
    options: :string,
    formula: :string,
    sum: :boolean,
    date: :string,
    spec: :string,
    preset: :string,
    text: :string,
    on: :boolean,
    tree: :boolean,
    all: :boolean,
    full: :boolean,
    ask: :boolean,
    mode: :string,
    id: :string,
    parent: :string,
    root: :boolean,
    folder: :string,
    no_folder: :boolean,
    recent: :boolean,
    note_tag: :string,
    also: :keep,
    not_in: :keep,
    summary: :string,
    # `slipdock pause <board> --reason "…"`.
    reason: :string,
    message: :string,
    # `slipdock job-progress --step "…"` (#1668).
    step: :string,
    # `slipdock job <id> --follow` (#1871).
    follow: :boolean,
    base_hash: :string,
    section: :string,
    hint: :string,
    in_place: :boolean,
    passphrase_file: :string,
    purge_history: :boolean,
    body: :string,
    file: :string,
    rev: :string,
    against: :string,
    position: :string,
    draft: :boolean,
    publish: :boolean,
    purge: :boolean,
    force: :boolean,
    dry_run: :boolean,
    by: :string,
    per: :string,
    added: :boolean,
    contents: :boolean,
    recordings_folder: :string,
    hotkey: :string,
    append: :string,
    card: :string,
    into: :integer,
    source: :string,
    page: :string,
    dir: :string,
    # `slipdock tools show|install|install-board`: a version other than the latest.
    version: :string,
    out: :string,
    overwrite: :boolean,
    before: :string,
    undone: :boolean,
    format: :string,
    set: :keep,
    q: :string,
    pool: :string,
    status: :string,
    scenario: :string,
    agent: :string,
    cwd: :string,
    timeout: :integer,
    permission_mode: :string,
    service: :string,
    install_name: :string,
    command: :string,
    where: :string,
    repo: :string,
    verbosity: :string,
    instructions: :string,
    before_job: :string,
    after_job: :string,
    hooks: :string,
    in_progress: :boolean,
    assign: :boolean,
    commit: :boolean,
    push: :boolean,
    move_done: :boolean,
    complete: :boolean,
    percent_100: :boolean,
    slipdock_tools: :boolean,
    worktree: :boolean,
    self_update: :boolean,
    wait_while_doing: :boolean,
    requeue_stuck: :integer,
    hook_prompt: :boolean,
    alert: :boolean,
    mcp_servers: :string,
    # `slipdock sync`.
    vault: :string,
    watch: :boolean,
    interval: :integer,
    help: :boolean
  ]

  @doc false
  # The options every command is parsed with.
  def switches, do: @switches

  def main(argv) do
    {opts, args, invalid} =
      OptionParser.parse(wait_on(argv), strict: @switches, aliases: [h: :help, j: :json])

    if invalid != [] do
      fail("unknown option(s): " <> Enum.map_join(invalid, ", ", &elem(&1, 0)))
    end

    if opts[:url], do: System.put_env("SLIPDOCK_URL", opts[:url])

    try do
      case {args, opts[:help]} do
        {_, true} -> IO.puts(@help)
        {[], _} -> IO.puts(@help)
        {["help" | _], _} -> IO.puts(@help)
        {[cmd | rest], _} -> run(cmd, rest, opts)
      end
    rescue
      # stdout closed early (e.g. piped into `head`): exit quietly. Only that
      # — a blanket rescue here twice swallowed a real bug (`not nil`, which
      # raises) and made a broken command look like a silent success. Anything
      # else is reraised, including an exception with no `:original` at all.
      error ->
        if Map.get(error, :original) in [:terminated, :epipe, :ebadf],
          do: System.halt(0),
          else: reraise(error, __STACKTRACE__)
    end
  end

  # `slipdock wait <id> "…" --on EMAIL`: everywhere else `--on` is a switch
  # with no value (`automation <id> --on`), so for `wait` it is read as
  # `--wait-on`, which takes one.
  @doc false
  def wait_on([cmd | rest]) when cmd in ["wait", "finish-job"],
    do: [cmd | Enum.map(rest, &if(&1 == "--on", do: "--wait-on", else: &1))]

  # `job <id> --keep` (#1872): --keep is also garden's `--keep N`, a value.
  def wait_on(["job" | rest]),
    do: ["job" | Enum.map(rest, &if(&1 == "--keep", do: "--keep-log", else: &1))]

  def wait_on(argv), do: argv

  # Each area module lists the command names it answers to; the first that
  # claims a name gets every clause of it, so a name must live in one place.
  @areas [
    Auth,
    Admin,
    Boards,
    Garden,
    Health,
    Findings,
    Ledger,
    Inbound,
    Automations,
    Runners,
    Wiki,
    WholeWiki,
    Sync,
    Skills,
    Tools,
    Deploy,
    Lanes
  ]

  defp run(cmd, args, o) do
    case Enum.find(@areas, &(cmd in &1.commands())) do
      nil -> bad_usage(cmd)
      area -> area.run(cmd, args, o)
    end
  end

  # Kept callable here, where the tests (and anyone scripting against the
  # module) have always found them.
  @doc false
  defdelegate contained(dir, path), to: Util

  @doc false
  defdelegate await_device_approval(started, interval, sleep \\ &Process.sleep/1), to: Auth
end

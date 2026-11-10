defmodule Slipdock.Runners.Setup do
  @moduledoc """
  The "Connect a runner" wizard's answers turned into exactly what to paste,
  for each of the four ways of running an agent against a board:

    * `daemon` — a machine running the runner daemon (#2572, epic #2569):
      install it, enrol it with a one-time enrolment key made for the
      board, and add its runner on the machine's page. Offered first.
    * `loop` — Claude Code on your own machine, in a `/loop`
    * `cloud` — a Claude Desktop scheduled task, or a cloud routine
    * `chatgpt` — ChatGPT, through the Slipdock connector

  One generator behind the web wizard, the API and `slipdock runner new`, so
  the three can't tell people different things. It writes text and nothing
  else; `connect/4` is what makes the enrolment key and the rule.

  None of them makes a runner token: a machine's runners authenticate with
  its machine key, and a Claude or ChatGPT session takes jobs with the
  sign-in it already has (see `Slipdock.Runners.session_runner/4`).

  The `server` and `windows` scenarios, the shell and PowerShell runners'
  installs, were retired for the daemon (#2582, W-2544 §10). A runner made
  with one keeps its token and its saved answers, and `regenerate/4` gives
  it the steps to move onto a machine instead (`retired?/1`).
  """

  alias Slipdock.Automations
  alias Slipdock.Automations.Spec
  alias Slipdock.Boards.Board
  alias Slipdock.Runners.Runner

  @scenarios ~w(daemon loop cloud chatgpt)

  # The shell and PowerShell runners' scenarios, retired for the daemon
  # (#2582): asked for, they are refused with where to go instead.
  @retired ~w(server windows)
  @retired_message "the shell and PowerShell runners were retired for the runner daemon: " <>
                     "use the daemon scenario, a machine whose runners you add on its page " <>
                     "(Account › Machines)"

  @permission_modes ~w(default acceptEdits plan bypassPermissions)
  @wheres ~w(desktop cloud)
  @verbosities ["nothing", "", "quiet", "normal", "verbose"]
  @hook_modes ~w(prompt hook)

  # What a pass does to the card and the repository, each on or off and all
  # off unless ticked: whether any of it is wanted depends on the board.
  # `assign` is still read from a saved setup but no longer asked or obeyed:
  # a job never assigns the card (#2027, `assign_text/1`).
  @toggles ~w(in_progress assign commit push move_done complete percent_100)

  # Ready-written paragraphs for how much to write on the card.
  @verbosity_text %{
    "nothing" =>
      "Don't comment on the card at all: not when you start, not as you go, not when you " <>
        "finish. Report on the job with job_progress (or slipdock job-progress) without a " <>
        "note: a note is posted on the card as a comment.",
    "quiet" =>
      "Keep the card's comments short: one line when you start, one when you finish, " <>
        "and only blockers in between.",
    "normal" =>
      "Comment on the card when you start, at each decision or surprise, and when you finish.",
    "verbose" =>
      "Keep a detailed running log on the card: comment at every step with what you tried, " <>
        "what you found and what you decided, and end with a full summary."
  }

  @defaults %{
    "scenario" => "daemon",
    "kind" => "",
    "cwd" => "/tmp",
    "permission_mode" => "acceptEdits",
    "pool" => "default",
    "where" => "desktop",
    "repo" => "",
    "verbosity" => "nothing",
    "instructions" => "",
    "before_job" => "",
    "after_job" => "",
    "hooks" => "prompt",
    "in_progress" => false,
    "assign" => false,
    "commit" => false,
    "push" => false,
    "move_done" => false,
    "complete" => false,
    "percent_100" => false
  }

  # Shown in the daemon's steps until the wizard makes the key itself.
  @enrolment_key_placeholder "sde_YOUR_ENROLMENT_KEY"

  def scenarios, do: @scenarios
  def permission_modes, do: @permission_modes
  def defaults, do: @defaults
  def verbosities, do: @verbosities
  def hook_modes, do: @hook_modes
  def toggles, do: @toggles

  @doc """
  Where jobs run when nobody says: a scratch directory, so a new session
  touches nothing of yours.
  """
  def default_cwd(_scenario), do: "/tmp"

  @doc "What each scenario is called in the wizard."
  def label("daemon"), do: "A machine with the daemon"
  def label("loop"), do: "Claude Code on my machine"
  def label("cloud"), do: "Claude, scheduled"
  def label("chatgpt"), do: "ChatGPT"

  @doc """
  Whether `runner` is one the retired scenarios made (#2582): a runner with
  a token of its own, neither a machine's nor a Claude session's. Every
  such runner was the shell or PowerShell script, or one somebody wrote
  against the runner protocol themselves; it still takes jobs with its
  token, but its setup is now the move onto a machine.
  """
  def retired?(%Runner{} = runner),
    do: not Runner.session?(runner) and not Runner.machine?(runner)

  @doc """
  The answers, checked and filled in from the defaults: `{:ok, answers}` or
  `{:error, message}`. Keys and values are strings, as a form sends them.
  """
  def normalise(answers) do
    given =
      for {k, v} <- answers || %{}, Map.has_key?(@defaults, to_string(k)), into: %{} do
        {to_string(k), if(is_binary(v), do: String.trim(v), else: v)}
      end

    answers = Map.merge(@defaults, given)

    # A working directory not given at all is the scenario's own default; one
    # given blank is the home directory, as it always was.
    answers =
      if Map.has_key?(given, "cwd"),
        do: answers,
        else: %{answers | "cwd" => default_cwd(answers["scenario"])}

    answers =
      answers
      |> Map.update!("pool", &(&1 |> to_string() |> String.downcase()))
      |> Map.update!("kind", &(&1 |> to_string() |> String.downcase()))
      |> Map.merge(Map.new(@toggles, &{&1, flag(answers[&1])}))

    case Enum.find_value(checks(), fn {wrong?, message} -> wrong?.(answers) && message end) do
      nil -> {:ok, answers}
      message when is_function(message, 1) -> {:error, message.(answers)}
      message -> {:error, message}
    end
  end

  # What `normalise/1` refuses, in order: a test of the answers that is true
  # when they are wrong, and what to say (a function, when it depends on them).
  defp checks do
    format = Runner.name_format()
    long? = fn a, key, max -> String.length(to_string(a[key])) > max end

    [
      {&Enum.member?(@retired, &1["scenario"]), @retired_message},
      {&(not Enum.member?(@scenarios, &1["scenario"])),
       "scenario must be one of #{Enum.join(@scenarios, ", ")}"},
      {&(not Regex.match?(format, &1["pool"])),
       "pool must be lower case letters, digits, - or _"},
      {&(&1["kind"] != "" and not Regex.match?(format, &1["kind"])),
       "kind must be lower case letters, digits, - or _"},
      {&(&1["scenario"] == "chatgpt" and &1["commit"] == true),
       "ChatGPT has no repository to commit to: leave commit and push off"},
      {&(not Enum.member?(@permission_modes, &1["permission_mode"])),
       "permission mode must be one of #{Enum.join(@permission_modes, ", ")}"},
      {&(not Enum.member?(@wheres, &1["where"])), "where must be desktop or cloud"},
      {&(not Enum.member?(@verbosities, &1["verbosity"])),
       "verbosity must be nothing, quiet, normal or verbose"},
      {&(not Enum.member?(@hook_modes, &1["hooks"])), "hooks must be prompt or hook"},
      {&(bad_toggle(&1) != nil), &"#{bad_toggle(&1)} must be true or false"},
      {&(&1["push"] == true and &1["commit"] != true),
       "push needs commit: a pass can only push a commit it made"},
      {&long?.(&1, "instructions", 4000), "the instructions are over 4,000 characters"},
      {&(long?.(&1, "before_job", 2000) or long?.(&1, "after_job", 2000)),
       "a hook is over 2,000 characters"},
      {&someone_elses_home?(&1["cwd"]),
       "the working directory can't be another user's ~: use a full path, or ~/ for the " <>
         "runner's own home"}
    ]
  end

  defp bad_toggle(answers), do: Enum.find(@toggles, &(not is_boolean(answers[&1])))

  # A checkbox: true or "true" / "on" from a form, false or "false" / "" when
  # it isn't ticked.
  defp flag(value) when value in [true, "true", "on"], do: true
  defp flag(value) when value in [false, "false", "off", ""], do: false
  defp flag(value), do: value

  # ~ and ~/… are the runner's own home; ~bob/… would be somebody else's, which
  # the config can't spell without the shell's help.
  defp someone_elses_home?("~" <> rest),
    do: not (rest == "" or String.starts_with?(rest, ["/", "\\"]))

  defp someone_elses_home?(_), do: false

  @doc """
  The standing instructions every job is given, after the card's own
  prompt: the verbosity paragraph, then the free text. What to do to the
  card and the repository is said in the prompt itself (`card_text/1`).
  """
  def instructions(a) do
    [@verbosity_text[a["verbosity"]], a["instructions"]]
    |> Enum.reject(&Enum.member?([nil, ""], &1))
    |> Enum.join("\n\n")
  end

  @doc """
  Whether the scenario can run hooks: not in Anthropic's cloud or in ChatGPT,
  neither of which is your machine.
  """
  def hooks?(%{"scenario" => "cloud", "where" => "cloud"}), do: false
  def hooks?(%{"scenario" => "chatgpt"}), do: false
  def hooks?(_), do: true

  @doc "Whether the scenario has a repository to commit to: ChatGPT has none."
  def commits?(%{"scenario" => "chatgpt"}), do: false
  def commits?(_), do: true

  defp hooks_given?(a), do: a["before_job"] != "" or a["after_job"] != ""

  @doc "The job kind the answers queue and run: the one named, else claude (chatgpt's own)."
  def kind(%{"kind" => kind}) when kind not in [nil, ""], do: kind
  def kind(%{"scenario" => "chatgpt"}), do: "chatgpt"
  def kind(_answers), do: "claude"

  ## Doing it -----------------------------------------------------------------

  @doc """
  The whole wizard: checks the answers, puts the rule in place (a new
  *send to runner* rule on `answers["column"]` — or, with `"feed" => "top"`,
  one sending that list's top card one at a time — an existing one named by
  `answers["rule_id"]`, or none), makes the daemon's enrolment key, and
  generates the text. With `"alert" => "yes"` it also adds a rule
  raising an alert when one of the pool's jobs times out or its card is put
  back or given up on. Answers `{:ok, %{setup, runner, token, rule,
  alert_rule}}` or `{:error, message}`.
  """
  def connect(%Board{} = board, params, user, base_url) do
    with {:ok, answers} <- normalise(params),
         {:ok, key} <- enrolment_key(board, answers, user),
         {:ok, rule} <- rule(board, params, answers, user),
         {:ok, alert_rule} <- alert_rule(board, params, answers, user) do
      ctx = %{base_url: base_url, board: board, rule: rule, enrolment_key: key}
      setup = generate(answers, ctx)

      # No scenario makes a runner or a token any more (#2582): the keys stay
      # so the answer reads the same.
      {:ok,
       %{
         setup: setup,
         runner: nil,
         token: nil,
         rule: rule,
         alert_rule: alert_rule,
         enrolment_key: key
       }}
    end
  end

  # A machine with the daemon (#2572) enrols with a one-time key, made for
  # the board's tree: the machine then serves it.
  defp enrolment_key(board, %{"scenario" => "daemon", "pool" => pool}, user) do
    case Slipdock.Machines.create_enrolment_key(user, [Board.root_id(board)], "#{pool} runner") do
      {:ok, key, _record} -> {:ok, key}
      {:error, :invalid, message} -> {:error, message}
    end
  end

  defp enrolment_key(_board, _answers, _user), do: {:ok, nil}

  # "Tell me when a job times out or a card is given up": a rule of its own,
  # raising an alert for the pool's jobs (see the `runner_trouble` preset).
  defp alert_rule(board, params, answers, user) do
    if Enum.member?(["yes", "true", true], params["alert"]) do
      case Automations.create_rule_from_preset(
             board,
             "runner_trouble",
             %{"pool" => answers["pool"], "notify" => "alert"},
             created_by: user
           ) do
        {:ok, rule} -> {:ok, rule}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_message(changeset)}
        {:error, message} -> {:error, message}
      end
    else
      {:ok, nil}
    end
  end

  defp rule(board, params, answers, user) do
    column = blank(params["column"])
    rule_id = blank(to_string(params["rule_id"] || ""))

    cond do
      rule_id ->
        case Automations.get_board_rule(board.id, rule_id) do
          nil -> {:error, "no such rule on this board"}
          rule -> {:ok, rule}
        end

      column ->
        with {:ok, list} <- find_list(board, column) do
          preset = if params["feed"] == "top", do: "feed_runner", else: "send_to_runner"

          params = %{
            "column" => list.name,
            "pool" => answers["pool"],
            "kind" => kind(answers),
            "wait" => params["wait"],
            "requeue" => params["requeue"]
          }

          case Automations.create_rule_from_preset(board, preset, params, created_by: user) do
            {:ok, rule} -> scheduled_sibling(board, rule, user)
            {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_message(changeset)}
            {:error, message} -> {:error, message}
          end
        end

      true ->
        {:ok, nil}
    end
  end

  # A feed on the ready list gets a sibling on the board's Scheduled list
  # (#2100), where the recurring agent work lands: the rule answered is
  # still the one asked for.
  defp scheduled_sibling(board, rule, user) do
    if Spec.feed?(rule.spec),
      do: Automations.ScheduledFeed.ensure(board, by: user)

    {:ok, rule}
  end

  defp find_list(board, name) do
    case Slipdock.Boards.find_column(board, name) do
      {:ok, column} -> {:ok, column}
      _ -> {:error, "there's no list called “#{name}” on this board"}
    end
  end

  @doc """
  The steps for a runner made earlier, which now are the move onto a
  machine: every runner with a token of its own ran a script the server no
  longer serves (`retired?/1`, #2582), or was somebody's own client of the
  runner protocol. Its token was shown once and is not kept; a fresh `token`
  (see `Slipdock.Runners.rotate_token/1`) is shown in a step of its own.
  """
  def regenerate(%Runner{} = runner, %Board{} = board, base_url, token \\ nil) do
    %{
      scenario: "retired",
      title: "A retired shell runner",
      intro:
        "This runner was the shell or PowerShell script, which this server no longer serves " <>
          "(#2582): it keeps the script it has, but can't update itself or be installed " <>
          "again. Move it onto the runner daemon, between jobs, so no job is cut short.",
      steps: retired_steps(runner, board, base_url) ++ token_step(token),
      warnings: [],
      cost: cost("daemon")
    }
  end

  @doc false
  def retired_message, do: @retired_message

  defp retired_steps(runner, board, base_url) do
    [
      %{
        text:
          "Set the daemon up on its machine: Connect a runner › #{label("daemon")}, or " <>
            "this, and follow the steps it prints.",
        lang: "sh",
        code:
          "slipdock runner new #{board.code || board.id} --scenario daemon --pool #{runner.pool}"
      },
      %{
        text:
          "On the machine's page (#{base_url}/account/machines), add a runner for the " <>
            "#{runner.pool} pool with the same agent, directory and permission mode as this " <>
            "one, and probe it until it is green."
      },
      %{
        text: "Stop this one, still between jobs (on Windows, remove the Slipdock runner task):",
        lang: "sh",
        code:
          "systemctl --user disable --now slipdock-runner.service   # Linux, WSL\n" <>
            "launchctl bootout gui/$(id -u)/us.slipdock.runner         # macOS"
      },
      %{
        text:
          "Then revoke this runner here, so its pool isn't counted twice. The manual's " <>
            "Machines page has the rest."
      }
    ]
  end

  defp token_step(nil), do: []

  defp token_step(token),
    do: [
      %{
        text:
          "Its new token, shown this once: until it moves, put it in place of " <>
            "SLIPDOCK_RUNNER_TOKEN in the installed runner's config by hand.",
        lang: "text",
        code: token
      }
    ]

  @doc """
  The steps for `answers` (already normalised): a map with the scenario,
  its `title`, an `intro`, the `steps` (each `%{text, code, lang}`, code
  optional), `warnings` and a `cost` note.
  """
  def generate(answers, ctx) do
    scenario = answers["scenario"]
    ctx = Map.merge(%{rule: nil, board: nil, enrolment_key: nil}, ctx)

    %{
      scenario: scenario,
      title: label(scenario),
      intro: intro(scenario, answers),
      steps: steps(scenario, answers, ctx),
      warnings: warnings(scenario, answers, ctx),
      cost: cost(scenario)
    }
  end

  defp intro("daemon", a),
    do:
      "Run the runner daemon on the machine that should do the work: one program, enrolled " <>
        "once, whose runners you then add and change from the machine's page rather than " <>
        "from a shell. It takes #{a["pool"]} jobs once you add a runner for that pool, and " <>
        "the machine's own ceiling limits what the page may set."

  defp intro("loop", a),
    do:
      "Claude Code itself takes #{a["pool"]} jobs, in a /loop in a terminal you leave open. " <>
        "Nothing is installed but the skills; it signs in through your browser."

  defp intro("cloud", %{"where" => "cloud"} = a),
    do:
      "A Claude Code routine takes #{a["pool"]} jobs on a schedule, in Anthropic's cloud, " <>
        "even while your computer is off."

  defp intro("chatgpt", a),
    do:
      "ChatGPT takes #{a["pool"]} jobs through the Slipdock connector, in a chat or a " <>
        "scheduled task. Nothing is installed; it signs in through your browser. It has no " <>
        "repository or shell, so it suits cards whose work can be done in a conversation: " <>
        "writing, research, planning, triage."

  defp intro("cloud", a),
    do:
      "A Claude Desktop scheduled task takes #{a["pool"]} jobs on a schedule, on this " <>
        "computer, while the Desktop app is open."

  defp cost("daemon"),
    do:
      "A runner costs nothing while it waits: it asks the server for work and only " <>
        "starts the agent when there is a job."

  defp cost("chatgpt"),
    do:
      "Nothing to install, but every check for work is a ChatGPT turn and uses your " <>
        "ChatGPT usage, even when nothing is queued."

  defp cost(_),
    do:
      "Nothing to install, but every check for work is a Claude turn and uses your Claude " <>
        "usage, even when nothing is queued."

  defp warnings(scenario, a, ctx) do
    base_warnings(scenario, a, ctx) ++
      cwd_warnings(scenario, a) ++
      if(hooks_given?(a) and not hooks?(a),
        do: [
          "Hooks can't run in #{hookless(scenario)}: it runs on #{hookless_owner(scenario)} " <>
            "machines, not yours, so they are left out. The instructions still go in its prompt."
        ],
        else: []
      )
  end

  defp base_warnings("chatgpt", _a, ctx),
    do: [
      "ChatGPT reaches Slipdock from OpenAI's servers, so #{ctx.base_url} must be " <>
        "reachable from the internet over https. The hosted service is; a self-hosted " <>
        "server behind a firewall or only on your tailnet is not — use another scenario.",
      "ChatGPT can't commit, push or run your tests: send it only cards it can finish in a " <>
        "conversation, from a list or pool of their own."
    ]

  defp base_warnings("cloud", %{"where" => "cloud"}, ctx),
    do: [
      "The routine works on a fresh clone of a GitHub repository each run, so the code " <>
        "must be on GitHub.",
      "Claude reaches Slipdock from Anthropic's servers, so #{ctx.base_url} must be " <>
        "reachable from the internet over https. The hosted service is; a self-hosted " <>
        "server behind a firewall or only on your tailnet is not — use another scenario.",
      "Routines run at most once an hour."
    ]

  defp base_warnings("daemon", _a, %{enrolment_key: nil}),
    do: [
      "The enrolment key is made when you show the steps, and shown that once: it goes " <>
        "in place of #{@enrolment_key_placeholder}."
    ]

  defp base_warnings(_, _, _), do: []

  defp hookless("chatgpt"), do: "ChatGPT"
  defp hookless(_), do: "a cloud routine"

  defp hookless_owner("chatgpt"), do: "OpenAI's"
  defp hookless_owner(_), do: "Anthropic's"

  # Claude Code loads a project's own commands, skills and settings only from
  # the directory it starts in. A cloud routine works in its repository.
  defp cwd_warnings("cloud", %{"where" => "cloud"}), do: []
  defp cwd_warnings("chatgpt", _a), do: []
  # The daemon's runners get their directory on the machine's page.
  defp cwd_warnings("daemon", _a), do: []

  defp cwd_warnings(_scenario, %{"cwd" => ""}),
    do: [
      "No working directory: jobs start in your home directory, so the project's own " <>
        "commands, skills and .claude/settings.json won't be loaded. Set it to the " <>
        "project's folder."
    ]

  defp cwd_warnings(scenario, %{"cwd" => cwd}) do
    if cwd == default_cwd(scenario),
      do: [
        "The working directory is #{cwd}, the default, so the project's own commands, " <>
          "skills and .claude/settings.json won't be loaded. Set it to the project's folder."
      ],
      else: []
  end

  ## Steps --------------------------------------------------------------------

  defp steps("daemon", a, ctx) do
    key = ctx.enrolment_key || @enrolment_key_placeholder

    [
      %{
        text:
          "Get the daemon onto the machine: one file, no dependencies, for Linux (WSL " <>
            "included), macOS and Windows. Until its signed releases are out, build it " <>
            "from Slipdock's repository with Go:",
        lang: "sh",
        code: "cd daemon && go build -o ~/.local/bin/slipdock-runner ./cmd/slipdock-runner"
      },
      %{
        text:
          "Enrol the machine with this one-time key. It works once, within " <>
            "#{Slipdock.Machines.EnrolmentKey.validity_hours()} hours, and the machine " <>
            "then serves this board. init also writes the machine's ceiling: the limits on " <>
            "what the board may set there.",
        lang: "sh",
        code: "slipdock-runner init --server #{ctx.base_url} --key #{key}"
      },
      %{
        text: "Keep it running as a service of your account:",
        lang: "sh",
        code: "slipdock-runner service install"
      },
      %{
        text:
          "Then open the machine from Account › Machines (#{ctx.base_url}/account/machines) " <>
            "and add a runner for the #{a["pool"]} pool: its agent, working directory, " <>
            "permission mode and timeout, inside the machine's ceiling."
      }
    ]
  end

  defp steps("loop", a, ctx) do
    [
      %{
        text:
          "Connect Claude Code to Slipdock (it signs in through your browser the first time):",
        lang: "sh",
        code: "claude mcp add --transport http slipdock #{ctx.base_url}/mcp"
      },
      skills_step("Install the Slipdock skills, which /slipdock-loop is one of", a, ctx),
      start_step(a),
      %{
        text:
          "And in it, run this. With no interval, /loop paces itself: soon while there is " <>
            "work, rarely while the queue is empty.",
        lang: "text",
        code: "/loop " <> loop_prompt(a, ctx)
      }
    ] ++ claude_hook_step(a) ++ rule_step(a, ctx)
  end

  defp steps("cloud", %{"where" => "cloud"} = a, ctx) do
    [
      %{
        text:
          "Add Slipdock as a connector on your Claude account, at " <>
            "claude.ai/customize/connectors → Add custom connector, with this URL. " <>
            "(A server added with claude mcp add stays on your machine and isn't seen by routines.)",
        lang: "text",
        code: "#{ctx.base_url}/mcp"
      },
      %{
        text:
          "At claude.ai/code/routines, New routine (or /schedule in Claude Code). Choose " <>
            "#{repo(a)} as the repository, keep the Slipdock connector, pick an hourly " <>
            "schedule, and give it this prompt:",
        lang: "text",
        code: cloud_prompt(a, ctx)
      }
    ] ++ rule_step(a, ctx)
  end

  defp steps("cloud", a, ctx) do
    [
      %{
        text: "Connect Claude Code to Slipdock:",
        lang: "sh",
        code: "claude mcp add --transport http slipdock #{ctx.base_url}/mcp"
      },
      skills_step("Install the Slipdock skills", a, ctx),
      %{
        text:
          "In Claude Desktop, Code tab → Routines → New routine → Local. Folder: " <>
            "#{cwd(a)}; permission mode: #{a["permission_mode"]}; schedule: Hourly (for more " <>
            "often, ask Claude in any session, e.g. \"run my Slipdock task every 15 minutes\"). " <>
            "Instructions:",
        lang: "text",
        code: loop_prompt(a, ctx)
      },
      %{
        text:
          "Click Run now once and approve what it asks for, choosing \"always allow\", so " <>
            "later runs don't stop for permission. It only runs while the app is open and " <>
            "the computer awake."
      }
    ] ++ rule_step(a, ctx)
  end

  defp steps("chatgpt", a, ctx) do
    [
      %{
        text:
          "Add Slipdock to ChatGPT as a connector: Settings → Apps & Connectors → Create " <>
            "(turn on developer mode under Advanced settings if Create isn't there), with " <>
            "this URL and OAuth, and sign in when Slipdock asks.",
        lang: "text",
        code: "#{ctx.base_url}/mcp"
      },
      %{
        text:
          "In a new chat with the Slipdock connector turned on, give it this prompt. It " <>
            "does one job and stops: paste it again for the next, or make it a scheduled " <>
            "task to have ChatGPT check the queue by itself.",
        lang: "text",
        code: chatgpt_prompt(a, ctx)
      },
      %{
        text:
          "The first time, approve the Slipdock tools it asks to use, choosing to always " <>
            "allow them, so later jobs don't stop for permission."
      }
    ] ++ rule_step(a, ctx)
  end

  # The skills go in the home directory of whoever runs Claude, so a Windows
  # machine gets the PowerShell installer: install.sh run under WSL would put
  # them in the WSL home, where Windows' Claude never looks.
  defp skills_step(text, a, ctx) do
    if windows_path?(cwd(a)) do
      %{
        text: text <> " (in PowerShell, into %USERPROFILE%\\.claude\\skills):",
        lang: "powershell",
        code: "irm #{ps_q(ctx.base_url <> "/install.ps1")} | iex"
      }
    else
      %{
        text:
          text <> " (on Windows, use the PowerShell one: irm #{ctx.base_url}/install.ps1 | iex):",
        lang: "sh",
        code: "curl -fsSL #{ctx.base_url}/install.sh | sh"
      }
    end
  end

  defp start_step(a) do
    if windows_path?(cwd(a)) do
      %{
        text: "Start Claude Code where the work is (in PowerShell):",
        lang: "powershell",
        code: "Set-Location #{ps_q(cwd(a))}; claude --permission-mode #{a["permission_mode"]}"
      }
    else
      %{
        text: "Start Claude Code where the work is:",
        lang: "sh",
        code: "cd #{sh_path(cwd(a))} && claude --permission-mode #{a["permission_mode"]}"
      }
    end
  end

  @doc """
  Whether a working directory is spelled the Windows way — a drive letter,
  `~\\…` or a share — so the steps to get there are PowerShell's.
  """
  def windows_path?(path) when is_binary(path),
    do: Regex.match?(~r/^([A-Za-z]:[\\\/]|~\\|\\\\)/, path)

  def windows_path?(_), do: false

  # Hooks for a Claude session: written into its prompt (Claude is asked to
  # run them — best effort), or as Claude Code hooks it runs itself.
  defp claude_hook_step(%{"hooks" => "hook"} = a) do
    if hooks_given?(a) do
      [
        %{
          text:
            "Claude Code runs these hooks itself: put this in .claude/settings.json in the " <>
              "working directory. The before hook runs after every claim_job call (including " <>
              "ones that find nothing queued), the after hook after every finish_job — so " <>
              "it doesn't run if a pass dies before finishing its job. Each gets the tool " <>
              "call as JSON on stdin, not the SLIPDOCK_* variables a runner sets.",
          lang: "json",
          code: claude_hooks_json(a)
        }
      ]
    else
      []
    end
  end

  defp claude_hook_step(_a), do: []

  @doc false
  def claude_hooks_json(a) do
    hooks =
      [
        {a["before_job"], "mcp__slipdock__claim_job"},
        {a["after_job"], "mcp__slipdock__finish_job"}
      ]
      |> Enum.reject(fn {command, _} -> command == "" end)
      |> Enum.map(fn {command, matcher} ->
        %{"matcher" => matcher, "hooks" => [%{"type" => "command", "command" => command}]}
      end)

    Jason.encode!(%{"hooks" => %{"PostToolUse" => hooks}}, pretty: true)
  end

  defp rule_step(_a, %{rule: %{} = rule}),
    do: [
      %{
        id: :rule,
        text: "On the board, the rule “#{rule.name}” sends cards: #{Spec.summary(rule.spec)}"
      }
    ]

  defp rule_step(a, _ctx),
    do: [
      %{
        id: :rule,
        text:
          "Nothing is sent until a rule sends it: add one under Automations with the " <>
            "Send cards to a runner preset (pool #{a["pool"]}, kind #{kind(a)}).",
        pool: a["pool"],
        kind: kind(a)
      }
    ]

  ## The text itself ----------------------------------------------------------

  # A session whose connector was added before the job tools existed has
  # none: working the lists directly would race the runners and leave the
  # job queued, so it stops and says why instead.
  @no_job_tools "Take work only from the job queue: if neither the claim_job tool nor the " <>
                  "slipdock claim-job command is available, don't work the board's lists " <>
                  "directly. Stop, and say the Slipdock connector needs reconnecting (or the " <>
                  "slipdock CLI installing) to get the job tools."

  @doc false
  def no_job_tools, do: @no_job_tools

  @doc "What a /loop or a Desktop task is told: take a job from the pool, and nothing else."
  def loop_prompt(a, ctx) do
    board = ctx.board

    ("/slipdock-loop against #{ctx.base_url}/boards/#{board.id} (board code: #{board.code}), " <>
       "taking a job from the #{a["pool"]} pool's queue#{mcp_note(a)}. Do exactly one card per " <>
       "pass. #{card_text(a)} Then finish the job and stop. " <> @no_job_tools)
    |> append(prompt_hooks(a))
    |> append(standing(a))
  end

  # What a pass does to the card and the repository, a sentence for each
  # toggle. Off is said too: the slipdock-loop skill does all of it unless
  # told not to, so leaving it unsaid would mean yes.
  @doc false
  def card_text(a), do: Enum.join(start_text(a) ++ finish_text(a), " ")

  defp start_text(a) do
    [
      if(a["in_progress"],
        do: "Move the card to the doing list when you start.",
        else: "Don't move the card to the doing list: leave it where it is."
      ),
      assign_text(a)
    ]
  end

  # A job's agent signs in with its owner's token, so assigning "me" would
  # name that person, not the runner (#2027). While its job holds the card,
  # the card shows the runner as its loop beside its assignees, so a job
  # never assigns, whatever an older setup's `assign` answer says; the
  # answer is still taken so a saved setup reads as it did.
  defp assign_text(_a),
    do:
      "Don't assign the card to anyone: while this job holds it, the card shows this " <>
        "runner as its loop beside the assignees."

  defp finish_text(a) do
    [
      commit_text(a),
      if(a["move_done"],
        do: "Move the card to the done list when you finish.",
        else: "Don't move the card to the done list."
      ),
      if(a["complete"],
        do: "Mark the card complete when you finish.",
        else: "Don't mark the card complete."
      ),
      if(a["percent_100"],
        do: "Set the card's % complete to 100 when you finish.",
        else: "Don't set the card's % complete at all."
      )
    ]
  end

  defp commit_text(%{"commit" => false}), do: "Don't commit or push anything."

  defp commit_text(%{"push" => false}),
    do:
      "If the working directory is a git repository, commit with the card id in the message, " <>
        "but don't push; if it isn't one, skip the commit."

  defp commit_text(_),
    do:
      "If the working directory is a git repository, commit with the card id in the message " <>
        "and push; if it isn't one, skip the commit."

  @doc """
  The words the prompts use to turn each toggle off, which the slipdock-loop
  skill names in what it lets an invocation override.
  """
  def off_wording do
    %{
      "in_progress" => "Don't move the card to the doing list",
      "assign" => "Don't assign the card to anyone",
      "commit" => "Don't commit or push anything",
      "push" => "but don't push",
      "move_done" => "Don't move the card to the done list",
      "complete" => "Don't mark the card complete",
      "percent_100" => "Don't set the card's % complete at all"
    }
  end

  # Hooks Claude runs itself fire on the MCP tools, so the pass must use them.
  defp mcp_note(%{"hooks" => "hook"} = a) do
    if hooks_given?(a),
      do: " with the Slipdock MCP tools claim_job, job_progress and finish_job (not the CLI)",
      else: ""
  end

  defp mcp_note(_), do: ""

  defp prompt_hooks(%{"hooks" => "prompt"} = a) do
    [
      a["before_job"] != "" &&
        "Before starting work on a job, run this in the shell, and only go on if it succeeds: " <>
          a["before_job"],
      a["after_job"] != "" &&
        "After every job, however it ended — even if it failed or was cancelled — run this in " <>
          "the shell: " <> a["after_job"]
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  defp prompt_hooks(_), do: ""

  defp standing(a) do
    case instructions(a) do
      "" -> ""
      text -> "Standing instructions for every job:\n" <> text
    end
  end

  defp append(text, ""), do: text
  defp append(text, more), do: text <> "\n\n" <> more

  @doc """
  What a cloud routine is told. Self-contained: the routine has the Slipdock
  connector's tools but not the skills, which live on your machine.
  """
  def cloud_prompt(a, ctx) do
    """
    Take one job from the Slipdock job queue and do it.

    1. Call the Slipdock tool claim_job with board "#{ctx.board.code}" and pool "#{a["pool"]}". If it answers "nothing queued", stop: there is nothing to do this run. If there is no claim_job tool, stop and say the Slipdock connector needs reconnecting to get the job tools; don't work the board's lists directly.
    2. Otherwise the job names a card. Read it with get_card. #{cloud_start(a)}
    3. Do the work in this repository. #{cloud_progress(a)}
    4. Run the tests if there are any. #{commit_text(a)}
    5. #{cloud_finish(a)} Then call finish_job with outcome "done" and a one-line summary. If you could not finish, flag the card, say why#{if silent?(a), do: " in finish_job's summary", else: ""}, and finish the job "failed".
    """
    |> String.trim_trailing()
    |> append(standing(a))
  end

  @doc """
  What ChatGPT is told. Self-contained, as a cloud routine's is: it has the
  connector's tools but neither the skills nor a machine, so it works the
  card in the conversation and hands back what needs one.
  """
  def chatgpt_prompt(a, ctx) do
    """
    Take one job from the Slipdock job queue and do it, using the Slipdock connector's tools.

    1. Call claim_job with board "#{ctx.board.code}" and pool "#{a["pool"]}". If it answers "nothing queued", stop: there is nothing to do this time. If there is no claim_job tool, stop and say the Slipdock connector needs adding or reconnecting; don't work the board's lists directly.
    2. Otherwise the job names a card. Read it with get_card. #{cloud_start(a)}
    3. Do the work the card asks for, here in the conversation: write, research, plan or answer it. #{cloud_progress(a)}
    4. You have no repository, shell or tests. If the card needs one (a code change, a commit, a deploy), don't pretend: #{handback(a)} and finish the job "failed".
    5. #{cloud_finish(a, "what was done, with the result itself or where it went")} Then call finish_job with outcome "done" and a one-line summary. If you could not finish, flag the card, say why#{if silent?(a), do: " in finish_job's summary", else: ""}, and finish the job "failed".
    """
    |> String.trim_trailing()
    |> append(standing(a))
  end

  defp handback(a) do
    if silent?(a),
      do: "say what it needs in finish_job's summary",
      else: "comment on the card what it needs and why you stopped"
  end

  # "Nothing" written on the card: the job's lease is still renewed, with no note.
  defp silent?(a), do: a["verbosity"] == "nothing"

  defp cloud_start(a) do
    comment =
      if silent?(a), do: [], else: ["Comment that you have picked it up and what you plan."]

    Enum.join(start_text(a) ++ comment, " ")
  end

  defp cloud_progress(a) do
    if silent?(a),
      do:
        "Call job_progress with the job id and no note at each step — at least every 15 " <>
          "minutes. If it answers \"cancel\", stop and call finish_job with outcome \"cancelled\".",
      else:
        "Call job_progress with the job id and a short note at each step — at least every 15 " <>
          "minutes. If it answers \"cancel\", stop, say so on the card, and call finish_job " <>
          "with outcome \"cancelled\"."
  end

  defp cloud_finish(a, what \\ "what was done (files, tests, any commit)") do
    comment =
      if silent?(a),
        do: [],
        else: ["Comment on the card #{what}."]

    Enum.join(comment ++ tl(finish_text(a)), " ")
  end

  ## Helpers ------------------------------------------------------------------

  defp cwd(%{"cwd" => ""}), do: "~"
  defp cwd(%{"cwd" => cwd}), do: cwd

  defp repo(%{"repo" => ""}), do: "your project's GitHub repository"
  defp repo(%{"repo" => repo}), do: repo

  @doc false
  # Single quotes, with any quote inside closed, escaped and reopened.
  def sh_q(value), do: "'" <> String.replace(to_string(value), "'", ~S('\'')) <> "'"

  @doc false
  # A path for sh: quoted like any value, except that ~ and ~/… become the
  # home directory of whoever runs it — inside quotes sh wouldn't expand them.
  def sh_path("~"), do: ~S("$HOME")
  def sh_path("~/" <> rest), do: ~S("$HOME"/) <> sh_q(rest)
  def sh_path(path), do: sh_q(path)

  @doc false
  # PowerShell's literal string: a quote inside is doubled.
  def ps_q(value), do: "'" <> String.replace(to_string(value), "'", "''") <> "'"

  defp blank(nil), do: nil

  defp blank(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp blank(_), do: nil

  defp changeset_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end

defmodule Slipdock.Runners.Setup do
  @moduledoc """
  The "Connect a runner" wizard's answers turned into exactly what to paste,
  for each of the four ways of running an agent against a board:

    * `server` — a Linux or macOS machine: the shell runner's one-line
      install, and the config it will write
    * `windows` — a Windows machine: the PowerShell runner's one-line install
    * `loop` — Claude Code on your own machine, in a `/loop`
    * `cloud` — a Claude Desktop scheduled task, or a cloud routine

  One generator behind the web wizard, the API and `slipdock runner new`, so
  the three can't tell people different things. It writes text and nothing
  else; `connect/4` is what makes the runner and the rule.

  The two runner scenarios need a runner token in what they print; the two
  Claude ones don't — a Claude session takes jobs with the sign-in it
  already has (see `Slipdock.Runners.session_runner/4`).
  """

  alias Slipdock.{Automations, Runners}
  alias Slipdock.Automations.Spec
  alias Slipdock.Boards.Board
  alias Slipdock.Runners.Runner

  @scenarios ~w(server windows loop cloud)
  @agents ~w(claude codex custom)
  @permission_modes ~w(default acceptEdits plan bypassPermissions)
  @services ~w(auto systemd launchd none)
  @wheres ~w(desktop cloud)

  @defaults %{
    "scenario" => "server",
    "agent" => "claude",
    "kind" => "",
    "command" => "",
    "cwd" => "",
    "permission_mode" => "acceptEdits",
    "timeout" => 3600,
    "pool" => "default",
    "service" => "auto",
    "where" => "desktop",
    "repo" => ""
  }

  # Shown in place of a token that was only ever shown once.
  @token_placeholder "sdr_YOUR_RUNNER_TOKEN"

  def scenarios, do: @scenarios
  def agents, do: @agents
  def permission_modes, do: @permission_modes
  def services, do: @services
  def defaults, do: @defaults
  def token_placeholder, do: @token_placeholder

  @doc "What each scenario is called in the wizard."
  def label("server"), do: "Linux / macOS machine"
  def label("windows"), do: "Windows machine"
  def label("loop"), do: "Claude Code on my machine"
  def label("cloud"), do: "Claude, scheduled"

  @doc "Whether a scenario's runner takes jobs with a runner token of its own."
  def needs_token?(scenario), do: scenario in ~w(server windows)

  @doc """
  The answers, checked and filled in from the defaults: `{:ok, answers}` or
  `{:error, message}`. Keys and values are strings, as a form sends them.
  """
  def normalise(answers) do
    answers =
      Map.merge(
        @defaults,
        for({k, v} <- answers || %{}, Map.has_key?(@defaults, to_string(k)), into: %{}) do
          {to_string(k), if(is_binary(v), do: String.trim(v), else: v)}
        end
      )

    answers =
      answers
      |> Map.update!("pool", &(&1 |> to_string() |> String.downcase()))
      |> Map.update!("kind", &(&1 |> to_string() |> String.downcase()))

    format = Runner.name_format()

    cond do
      answers["scenario"] not in @scenarios ->
        {:error, "scenario must be one of #{Enum.join(@scenarios, ", ")}"}

      answers["agent"] not in @agents ->
        {:error, "agent must be claude, codex or custom"}

      not Regex.match?(format, answers["pool"]) ->
        {:error, "pool must be lower case letters, digits, - or _"}

      answers["kind"] != "" and not Regex.match?(format, answers["kind"]) ->
        {:error, "kind must be lower case letters, digits, - or _"}

      answers["agent"] == "custom" and answers["command"] == "" and
          needs_token?(answers["scenario"]) ->
        {:error, "a custom agent needs the command to run"}

      answers["permission_mode"] not in @permission_modes ->
        {:error, "permission mode must be one of #{Enum.join(@permission_modes, ", ")}"}

      answers["service"] not in @services ->
        {:error, "service must be one of #{Enum.join(@services, ", ")}"}

      answers["where"] not in @wheres ->
        {:error, "where must be desktop or cloud"}

      not match?({:ok, _}, timeout(answers["timeout"])) ->
        {:error, "the timeout must be a whole number of seconds, at least 60"}

      true ->
        {:ok, timeout} = timeout(answers["timeout"])
        {:ok, %{answers | "timeout" => timeout}}
    end
  end

  defp timeout(n) when is_integer(n) and n >= 60, do: {:ok, n}

  defp timeout(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 60 -> {:ok, n}
      _ -> :error
    end
  end

  defp timeout(_), do: :error

  @doc "The job kind the answers queue and run: the one named, else the agent's."
  def kind(%{"kind" => kind}) when kind not in [nil, ""], do: kind
  def kind(%{"agent" => agent}), do: agent

  ## Doing it -----------------------------------------------------------------

  @doc """
  The whole wizard: checks the answers, puts the rule in place (a new
  *send to runner* rule on `answers["column"]`, an existing one named by
  `answers["rule_id"]`, or none), makes the runner when the scenario needs a
  token, and generates the text. Answers `{:ok, %{setup, runner, token,
  rule}}` or `{:error, message}`.
  """
  def connect(%Board{} = board, params, user, base_url) do
    with {:ok, answers} <- normalise(params),
         {:ok, rule} <- rule(board, params, answers, user),
         {:ok, runner, token} <- runner(board, params, answers, user) do
      setup = generate(answers, %{base_url: base_url, board: board, token: token, rule: rule})
      {:ok, %{setup: setup, runner: runner, token: token, rule: rule}}
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
          params = %{"column" => list.name, "pool" => answers["pool"], "kind" => kind(answers)}

          case Automations.create_rule_from_preset(board, "send_to_runner", params,
                 created_by: user
               ) do
            {:ok, rule} -> {:ok, rule}
            {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_message(changeset)}
            {:error, message} -> {:error, message}
          end
        end

      true ->
        {:ok, nil}
    end
  end

  defp find_list(board, name) do
    case Slipdock.Boards.find_column(board, name) do
      {:ok, column} -> {:ok, column}
      _ -> {:error, "there's no list called “#{name}” on this board"}
    end
  end

  defp runner(board, params, answers, user) do
    if needs_token?(answers["scenario"]) do
      name = blank(params["name"]) || "#{answers["pool"]} runner"
      attrs = %{"name" => name, "pool" => answers["pool"], "settings" => answers}

      case Runners.create_runner(board, attrs, user) do
        {:ok, runner, token} -> {:ok, runner, token}
        {:error, changeset} -> {:error, changeset_message(changeset)}
      end
    else
      {:ok, nil, nil}
    end
  end

  @doc """
  The text again for a runner made earlier, from the answers saved on it. Its
  token was shown once and is not kept, so the text has a placeholder where
  it goes — unless a fresh `token` (see `Slipdock.Runners.rotate_token/1`) is
  given.
  """
  def regenerate(%Runner{} = runner, %Board{} = board, base_url, token \\ nil) do
    {:ok, answers} = normalise(Map.put(runner.settings || %{}, "pool", runner.pool))
    generate(answers, %{base_url: base_url, board: board, token: token, rule: nil})
  end

  @doc """
  The steps for `answers` (already normalised): a map with the scenario,
  its `title`, an `intro`, the `steps` (each `%{text, code, lang}`, code
  optional), `warnings` and a `cost` note.
  """
  def generate(answers, ctx) do
    scenario = answers["scenario"]
    ctx = Map.merge(%{token: nil, rule: nil}, ctx)

    %{
      scenario: scenario,
      title: label(scenario),
      intro: intro(scenario, answers),
      steps: steps(scenario, answers, ctx),
      warnings: warnings(scenario, answers, ctx),
      cost: cost(scenario)
    }
  end

  defp intro("server", a),
    do:
      "Run this on the machine that should do the work. It installs a small shell script " <>
        "(sh and curl, nothing else) that takes #{a["pool"]} jobs from this board and runs " <>
        "#{agent_name(a)} on each, and keeps it running as a #{service_name(a)}."

  defp intro("windows", a),
    do:
      "Run this in PowerShell on the Windows machine. It installs the PowerShell runner " <>
        "(nothing else needed) for your user, with a Task Scheduler entry that starts it at " <>
        "logon — no admin rights. It takes #{a["pool"]} jobs and runs #{agent_name(a)} on each."

  defp intro("loop", a),
    do:
      "Claude Code itself takes #{a["pool"]} jobs, in a /loop in a terminal you leave open. " <>
        "Nothing is installed but the skills; it signs in through your browser."

  defp intro("cloud", %{"where" => "cloud"} = a),
    do:
      "A Claude Code routine takes #{a["pool"]} jobs on a schedule, in Anthropic's cloud, " <>
        "even while your computer is off."

  defp intro("cloud", a),
    do:
      "A Claude Desktop scheduled task takes #{a["pool"]} jobs on a schedule, on this " <>
        "computer, while the Desktop app is open."

  defp cost(scenario) when scenario in ~w(server windows),
    do:
      "A runner costs nothing while it waits: it asks the server for work and only " <>
        "starts the agent when there is a job. The right choice for anything left running."

  defp cost(_),
    do:
      "Nothing to install, but every check for work is a Claude turn and uses your Claude " <>
        "usage, even when nothing is queued. Fine for a while; for a queue watched all day, " <>
        "a runner costs nothing while idle."

  defp warnings("cloud", %{"where" => "cloud"}, ctx),
    do: [
      "The routine works on a fresh clone of a GitHub repository each run, so the code " <>
        "must be on GitHub.",
      "Claude reaches Slipdock from Anthropic's servers, so #{ctx.base_url} must be " <>
        "reachable from the internet over https. The hosted service is; a self-hosted " <>
        "server behind a firewall or only on your tailnet is not — use another scenario.",
      "Routines run at most once an hour."
    ]

  defp warnings("windows", _a, _ctx),
    do: []

  defp warnings(scenario, _a, %{token: nil}) when scenario in ~w(server windows),
    do: [
      "The runner's token was shown once, when it was made, and isn't kept. Put it in " <>
        "place of #{@token_placeholder}, or make a new token."
    ]

  defp warnings(_, _, _), do: []

  ## Steps --------------------------------------------------------------------

  defp steps("server", a, ctx) do
    [
      %{
        text: "On the machine, run:",
        lang: "sh",
        code: server_one_liner(a, ctx)
      },
      %{
        text:
          "Or check it first: the installer is the same file for everybody, and these are " <>
            "its checksums (compare with sha256sum install.sh).",
        lang: "sh",
        code:
          "curl -fsSL #{ctx.base_url}/runner/install.sh -o install.sh\n" <>
            "curl -fsSL #{ctx.base_url}/runner/SHA256SUMS"
      },
      %{
        text:
          "It writes this config to ~/.config/slipdock-runner/config (mode 600). It is yours " <>
            "to edit: each job_<kind> function is a kind of job this machine will run, and " <>
            "nothing else ever runs.",
        lang: "sh",
        code: config_preview(a, ctx)
      }
    ] ++ rule_step(a, ctx)
  end

  defp steps("windows", a, ctx) do
    [
      %{
        text: "In PowerShell on the machine, run:",
        lang: "powershell",
        code: windows_one_liner(a, ctx)
      },
      %{
        text:
          "It writes its config to %LOCALAPPDATA%\\slipdock-runner\\config.ps1, readable by " <>
            "your user alone, with a Job-#{pascal(kind(a))} function for this kind of job. Logs " <>
            "are in %LOCALAPPDATA%\\slipdock-runner\\runner.log."
      }
    ] ++ rule_step(a, ctx)
  end

  defp steps("loop", a, ctx) do
    [
      %{
        text:
          "Connect Claude Code to Slipdock (it signs in through your browser the first time):",
        lang: "sh",
        code: "claude mcp add --transport http slipdock #{ctx.base_url}/mcp"
      },
      %{
        text: "Install the Slipdock skills, which /slipdock-loop is one of:",
        lang: "sh",
        code: "curl -fsSL #{ctx.base_url}/install.sh | sh"
      },
      %{
        text: "Start Claude Code where the work is:",
        lang: "sh",
        code: "cd #{sh_q(cwd(a))} && claude --permission-mode #{a["permission_mode"]}"
      },
      %{
        text:
          "And in it, run this. With no interval, /loop paces itself: soon while there is " <>
            "work, rarely while the queue is empty.",
        lang: "text",
        code: "/loop " <> loop_prompt(a, ctx)
      }
    ] ++ rule_step(a, ctx)
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
        text: "Connect Claude Code to Slipdock, and install the skills:",
        lang: "sh",
        code:
          "claude mcp add --transport http slipdock #{ctx.base_url}/mcp\n" <>
            "curl -fsSL #{ctx.base_url}/install.sh | sh"
      },
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

  defp rule_step(_a, %{rule: %{} = rule}),
    do: [%{text: "On the board, the rule “#{rule.name}” sends cards: #{Spec.summary(rule.spec)}"}]

  defp rule_step(a, _ctx),
    do: [
      %{
        text:
          "Nothing is sent until a rule sends it: add one under Automations — the " <>
            "\"Send cards to a coding agent\" preset, with pool #{a["pool"]} and kind " <>
            "#{kind(a)} — or put a runner action in a rule you have."
      }
    ]

  ## The text itself ----------------------------------------------------------

  @doc false
  def server_one_liner(a, ctx) do
    flags =
      [
        "--url #{sh_q(ctx.base_url)}",
        "--token #{sh_q(ctx.token || @token_placeholder)}",
        "--pool #{a["pool"]}",
        "--agent #{a["agent"]}"
      ] ++
        if(a["kind"] != "", do: ["--kind #{a["kind"]}"], else: []) ++
        if(a["agent"] == "custom", do: ["--command #{sh_q(a["command"])}"], else: []) ++
        if(a["cwd"] != "", do: ["--cwd #{sh_q(a["cwd"])}"], else: []) ++
        if(a["agent"] == "claude", do: ["--permission-mode #{a["permission_mode"]}"], else: []) ++
        ["--timeout #{a["timeout"]}"] ++
        if(a["service"] != "auto", do: ["--service #{a["service"]}"], else: [])

    "curl -fsSL #{ctx.base_url}/runner/install.sh | sh -s -- \\\n  " <>
      Enum.join(flags, " \\\n  ")
  end

  @doc false
  def windows_one_liner(a, ctx) do
    params =
      [
        "-Url #{ps_q(ctx.base_url)}",
        "-Token #{ps_q(ctx.token || @token_placeholder)}",
        "-Pool #{a["pool"]}",
        "-Agent #{a["agent"]}"
      ] ++
        if(a["kind"] != "", do: ["-Kind #{a["kind"]}"], else: []) ++
        if(a["agent"] == "custom", do: ["-Command #{ps_q(a["command"])}"], else: []) ++
        if(a["cwd"] != "", do: ["-Cwd #{ps_q(a["cwd"])}"], else: []) ++
        if(a["agent"] == "claude", do: ["-PermissionMode #{a["permission_mode"]}"], else: []) ++
        ["-Timeout #{a["timeout"]}"]

    "& ([scriptblock]::Create((irm #{ps_q(ctx.base_url <> "/runner/install.ps1")}))) `\n  " <>
      Enum.join(params, " `\n  ")
  end

  @doc """
  The config the shell installer writes for these answers, line for line,
  except for the two things only the machine knows at install time — where
  the agent's program is, and the PATH — which are shown as notes.
  """
  def config_preview(a, ctx) do
    fn_name = "job_" <> String.replace(kind(a), "-", "_")

    """
    # slipdock-runner config — written by install.sh, yours to edit. It is sourced
    # by sh, so it is shell. It holds the runner's token: keep it mode 600.
    #
    # A job of kind K runs the function job_K below (a - in K is an _ here). The
    # server never says what to run: a kind with no function here is refused.
    # Each job gets SLIPDOCK_PROMPT, SLIPDOCK_JOB_ID, SLIPDOCK_JOB_KIND,
    # SLIPDOCK_CARD and SLIPDOCK_CARD_URL in its environment; pass the prompt on
    # only ever as "$SLIPDOCK_PROMPT", in double quotes.

    SLIPDOCK_URL=#{sh_q(ctx.base_url)}
    SLIPDOCK_RUNNER_TOKEN=#{sh_q(ctx.token || @token_placeholder)}
    POOL=#{sh_q(a["pool"])}
    WORKDIR=#{sh_q(if(a["cwd"] == "", do: "(your home)", else: a["cwd"]))}
    JOB_TIMEOUT=#{a["timeout"]}
    PERMISSION_MODE=#{sh_q(a["permission_mode"])}
    AGENT_BIN=#{sh_q(agent_bin_note(a))}
    CUSTOM_COMMAND=#{sh_q(if(a["agent"] == "custom", do: a["command"], else: ""))}
    PATH='(your PATH when you install)'
    export PATH CUSTOM_COMMAND

    #{fn_name}() {
      cd "$WORKDIR" || exit 1
    #{agent_line(a)}
    }

    # A kind to try the pipeline with: queue a job of kind echo and its output is
    # the prompt it was sent.
    job_echo() {
      printf '%s\\n' "$SLIPDOCK_PROMPT"
    }
    """
  end

  defp agent_bin_note(%{"agent" => "custom"}), do: ""
  defp agent_bin_note(%{"agent" => agent}), do: "(where #{agent} is on your PATH)"

  defp agent_line(%{"agent" => "claude"}),
    do: ~S|  "$AGENT_BIN" -p "$SLIPDOCK_PROMPT" --permission-mode "$PERMISSION_MODE"|

  defp agent_line(%{"agent" => "codex"}), do: ~S|  "$AGENT_BIN" exec "$SLIPDOCK_PROMPT"|
  defp agent_line(%{"agent" => "custom"}), do: ~S|  sh -c "$CUSTOM_COMMAND"|

  @doc "What a /loop or a Desktop task is told: take a job from the pool, and nothing else."
  def loop_prompt(a, ctx) do
    board = ctx.board

    "/slipdock-loop against #{ctx.base_url}/boards/#{board.id} (board code: #{board.code}), " <>
      "taking a job from the #{a["pool"]} pool's queue. Do exactly one card per pass, close it " <>
      "out on the board — commit and push with the card id — finish the job, then stop."
  end

  @doc """
  What a cloud routine is told. Self-contained: the routine has the Slipdock
  connector's tools but not the skills, which live on your machine.
  """
  def cloud_prompt(a, ctx) do
    """
    Take one job from the Slipdock job queue and do it.

    1. Call the Slipdock tool claim_job with board "#{ctx.board.code}" and pool "#{a["pool"]}". If it answers "nothing queued", stop: there is nothing to do this run.
    2. Otherwise the job names a card. Read it with get_card, move it to the board's doing list, and comment that you have picked it up and what you plan.
    3. Do the work in this repository. Call job_progress with the job id and a short note at each step — at least every 15 minutes. If it answers "cancel", stop, say so on the card, and call finish_job with outcome "cancelled".
    4. Run the tests, commit with the card number in the message, and push.
    5. Comment on the card what was done (files, tests, the commit), complete it with complete_card, and call finish_job with outcome "done" and a one-line summary. If you could not finish, flag the card, say why, and finish the job "failed".
    """
    |> String.trim_trailing()
  end

  ## Helpers ------------------------------------------------------------------

  defp agent_name(%{"agent" => "claude"}), do: "Claude Code"
  defp agent_name(%{"agent" => "codex"}), do: "Codex"
  defp agent_name(%{"agent" => "custom"}), do: "your command"

  defp service_name(%{"service" => "systemd"}), do: "systemd user service"
  defp service_name(%{"service" => "launchd"}), do: "launchd agent"
  defp service_name(%{"service" => "none"}), do: "process you start yourself"
  defp service_name(_), do: "service (systemd on Linux, launchd on macOS)"

  defp cwd(%{"cwd" => ""}), do: "~"
  defp cwd(%{"cwd" => cwd}), do: cwd

  defp repo(%{"repo" => ""}), do: "your project's GitHub repository"
  defp repo(%{"repo" => repo}), do: repo

  defp pascal(kind),
    do: kind |> String.split(["-", "_"], trim: true) |> Enum.map_join(&String.capitalize/1)

  @doc false
  # Single quotes, with any quote inside closed, escaped and reopened.
  def sh_q(value), do: "'" <> String.replace(to_string(value), "'", ~S('\'')) <> "'"

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

  defp changeset_message(other), do: to_string(other)
end

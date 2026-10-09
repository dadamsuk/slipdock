defmodule Slipdock.Runners.SetupTest do
  # The wizard's generator: answers in, steps out, for each scenario — and
  # `connect/4`, which makes the runner and the rule behind them.
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Automations, Runners}
  alias Slipdock.Runners.Setup

  @base "https://slipdock.example"

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Agents"}, owner: owner)
    %{owner: owner, board: board}
  end

  defp answers(extra \\ %{}) do
    {:ok, a} = Setup.normalise(extra)
    a
  end

  defp gen(board, extra, token \\ "sdr_tok"),
    do: Setup.generate(answers(extra), %{base_url: @base, board: board, token: token})

  defp codes(setup), do: setup.steps |> Enum.map(& &1[:code]) |> Enum.reject(&is_nil/1)

  describe "normalise/1" do
    test "fills in the defaults and folds case" do
      a = answers(%{"pool" => " Dev-Box ", "timeout" => "900"})
      assert a["scenario"] == "server"
      assert a["agent"] == "claude"
      assert a["pool"] == "dev-box"
      assert a["timeout"] == 900
      assert a["permission_mode"] == "acceptEdits"
    end

    test "drops what it doesn't know" do
      refute Map.has_key?(answers(%{"token" => "sdr_leak", "evil" => "x"}), "token")
    end

    test "refuses what it can't use" do
      for {params, message} <- [
            {%{"scenario" => "mainframe"}, "scenario"},
            {%{"agent" => "vim"}, "agent"},
            {%{"pool" => "my pool"}, "pool"},
            {%{"kind" => "$(id)"}, "kind"},
            {%{"agent" => "custom"}, "custom agent needs the command"},
            {%{"permission_mode" => "yolo"}, "permission mode"},
            {%{"service" => "cron"}, "service"},
            {%{"where" => "moon"}, "where"},
            {%{"timeout" => "5"}, "timeout"},
            {%{"timeout" => "soon"}, "timeout"}
          ] do
        assert {:error, got} = Setup.normalise(params)
        assert got =~ message, "#{inspect(params)} → #{got}"
      end
    end

    test "a custom agent in a Claude scenario needs no command" do
      assert {:ok, _} = Setup.normalise(%{"scenario" => "loop", "agent" => "custom"})
    end
  end

  describe "the server scenario" do
    test "one line to paste, with every option as a flag and values quoted", %{board: board} do
      setup =
        gen(board, %{
          "pool" => "dev",
          "agent" => "claude",
          "cwd" => "/srv/it's here",
          "timeout" => "600",
          "service" => "systemd"
        })

      [line | _] = codes(setup)
      assert line =~ "curl -fsSL #{@base}/runner/install.sh | sh -s -- \\\n"
      assert line =~ "--url '#{@base}'"
      assert line =~ "--token 'sdr_tok'"
      assert line =~ "--pool dev"
      assert line =~ "--agent claude"
      assert line =~ ~S(--cwd '/srv/it'\''s here')
      assert line =~ "--permission-mode acceptEdits"
      assert line =~ "--timeout 600"
      assert line =~ "--service systemd"
      assert setup.cost =~ "costs nothing while it waits"
      assert setup.warnings == []
    end

    test "a custom command and kind, but no permission mode it wouldn't use", %{board: board} do
      [line | _] =
        board
        |> gen(%{
          "agent" => "custom",
          "kind" => "make",
          "command" => "make agent P=\"$SLIPDOCK_PROMPT\""
        })
        |> codes()

      assert line =~ "--agent custom"
      assert line =~ "--kind make"
      assert line =~ ~S(--command 'make agent P="$SLIPDOCK_PROMPT"')
      refute line =~ "--permission-mode"
    end

    test "without the token, a placeholder and a warning saying why", %{board: board} do
      setup = gen(board, %{"cwd" => "/srv/w"}, nil)
      assert hd(codes(setup)) =~ "--token '#{Setup.token_placeholder()}'"
      assert [warning] = setup.warnings
      assert warning =~ "shown once"
    end

    test "shows the config it will write and how to check the installer", %{board: board} do
      [_, sums, config] = board |> gen(%{"pool" => "dev", "agent" => "codex"}) |> codes()
      assert sums =~ "#{@base}/runner/SHA256SUMS"
      assert config =~ "SLIPDOCK_RUNNER_TOKEN='sdr_tok'"
      assert config =~ "POOL='dev'"
      assert config =~ "job_codex() {"
      assert config =~ ~S("$AGENT_BIN" exec "$SLIPDOCK_PROMPT")
    end

    test "says no rule sends it anything yet, or which one does", %{board: board} do
      assert List.last(gen(board, %{}).steps).text =~ "Nothing is sent until a rule sends it"

      rule =
        rule_fixture(board, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "runner", "pool" => "default"}]
        })

      setup = Setup.generate(answers(), %{base_url: @base, board: board, token: "t", rule: rule})
      assert List.last(setup.steps).text =~ "the rule “#{rule.name}” sends cards"
    end
  end

  test "the windows scenario: a PowerShell line with literal strings", %{board: board} do
    setup = gen(board, %{"scenario" => "windows", "cwd" => "C:\\src\\it's", "pool" => "win"})
    [line, sums] = codes(setup)
    assert sums =~ "irm '#{@base}/runner/install.ps1' -OutFile install.ps1"
    assert sums =~ "irm '#{@base}/runner/SHA256SUMS'"
    assert Enum.map(setup.steps, & &1[:id]) == [:command, :checksums, :config, :rule]
    assert line =~ "& ([scriptblock]::Create((irm '#{@base}/runner/install.ps1'))) `\n"
    assert line =~ "-Token 'sdr_tok'"
    assert line =~ "-Cwd 'C:\\src\\it''s'"
    assert line =~ "-Pool win"
    assert setup.cost =~ "costs nothing"
  end

  test "the loop scenario: connect, the skills, and the exact /loop line", %{board: board} do
    setup = gen(board, %{"scenario" => "loop", "pool" => "loop", "cwd" => "~/src/app"}, nil)
    [mcp, skills, start, loop] = codes(setup)

    assert mcp == "claude mcp add --transport http slipdock #{@base}/mcp"
    assert skills == "curl -fsSL #{@base}/install.sh | sh"
    assert start == ~S(cd "$HOME"/'src/app' && claude --permission-mode acceptEdits)

    assert loop =~
             "/loop /slipdock-loop against #{@base}/boards/#{board.id} (board code: #{board.code})"

    assert loop =~ "taking a job from the loop pool's queue"
    # A session takes jobs with its own sign-in: no runner token anywhere.
    refute Enum.any?(codes(setup), &(&1 =~ "sdr_"))
    assert setup.warnings == []
    assert setup.cost =~ "uses your Claude usage"
  end

  describe "the scheduled scenario" do
    test "in the cloud: a connector, a self-contained prompt, and the warnings", %{board: board} do
      setup = gen(board, %{"scenario" => "cloud", "where" => "cloud", "repo" => "me/app"}, nil)
      [connector, prompt] = codes(setup)

      assert connector == "#{@base}/mcp"
      assert Enum.at(setup.steps, 1).text =~ "Choose me/app as the repository"
      assert prompt =~ ~s(claim_job with board "#{board.code}" and pool "default")
      assert prompt =~ "job_progress"
      assert prompt =~ "finish_job"
      refute prompt =~ "/slipdock-loop"

      assert Enum.any?(setup.warnings, &(&1 =~ "GitHub"))
      assert Enum.any?(setup.warnings, &(&1 =~ "#{@base} must be reachable from the internet"))
      assert Enum.any?(setup.warnings, &(&1 =~ "at most once an hour"))
    end

    test "on this computer: a local Desktop routine running the loop skill", %{board: board} do
      setup = gen(board, %{"scenario" => "cloud", "where" => "desktop", "cwd" => "~/app"}, nil)
      assert Enum.at(setup.steps, 2).text =~ "Routines → New routine → Local"
      assert Enum.at(setup.steps, 2).text =~ "Folder: ~/app"
      assert Enum.at(codes(setup), 2) =~ "/slipdock-loop against"
      assert setup.warnings == []
    end
  end

  describe "the ChatGPT scenario (#522)" do
    test "a connector, a self-contained prompt for one job, and the warnings", %{board: board} do
      setup = gen(board, %{"scenario" => "chatgpt", "pool" => "writing"}, nil)
      [connector, prompt] = codes(setup)

      assert setup.title == "ChatGPT"
      assert connector == "#{@base}/mcp"
      assert hd(setup.steps).text =~ "Settings → Apps & Connectors"
      assert prompt =~ ~s(claim_job with board "#{board.code}" and pool "writing")
      assert prompt =~ "get_card"
      assert prompt =~ "job_progress"
      assert prompt =~ ~s(finish_job with outcome "done")
      assert prompt =~ "You have no repository, shell or tests"
      # Nothing it can't do: no skill, no CLI, no commit.
      refute prompt =~ "/slipdock-loop"
      refute prompt =~ "commit with the card id"
      assert prompt =~ "Don't move the card to the doing list"
      refute Enum.any?(codes(setup), &(&1 =~ "sdr_"))

      assert Enum.any?(setup.warnings, &(&1 =~ "#{@base} must be reachable from the internet"))
      assert Enum.any?(setup.warnings, &(&1 =~ "can't commit, push or run your tests"))
      # No working directory to warn about, though the agent defaults to claude.
      refute Enum.any?(setup.warnings, &(&1 =~ "working directory"))
      assert setup.cost =~ "uses your ChatGPT usage"
      assert setup.intro =~ "ChatGPT takes writing jobs"
    end

    test "its jobs are of kind chatgpt unless another is named" do
      assert Setup.kind(answers(%{"scenario" => "chatgpt"})) == "chatgpt"
      assert Setup.kind(answers(%{"scenario" => "chatgpt", "kind" => "Docs"})) == "docs"
      assert Setup.kind(answers(%{"scenario" => "loop"})) == "claude"
    end

    test "committing is refused: it has no repository" do
      assert {:error, "ChatGPT has no repository to commit to" <> _} =
               Setup.normalise(%{"scenario" => "chatgpt", "commit" => "true"})

      assert {:error, "ChatGPT has no repository to commit to" <> _} =
               Setup.normalise(%{"scenario" => "chatgpt", "commit" => true, "push" => true})

      refute Setup.commits?(answers(%{"scenario" => "chatgpt"}))
      assert Setup.commits?(answers(%{"scenario" => "loop", "commit" => true}))
    end

    test "the other toggles and the verbosity reach its prompt", %{board: board} do
      setup =
        gen(
          board,
          %{
            "scenario" => "chatgpt",
            "in_progress" => true,
            "assign" => true,
            "move_done" => true,
            "complete" => true,
            "percent_100" => true,
            "verbosity" => "normal"
          },
          nil
        )

      prompt = List.last(codes(setup))
      assert prompt =~ "Move the card to the doing list when you start."
      assert prompt =~ "Assign the card to yourself when you start."
      assert prompt =~ "Move the card to the done list when you finish."
      assert prompt =~ "Mark the card complete when you finish."
      assert prompt =~ "Set the card's % complete to 100 when you finish."
      assert prompt =~ "Comment on the card what was done, with the result itself"
      assert prompt =~ "comment on the card what it needs and why you stopped"
      assert prompt =~ "Standing instructions for every job:\nComment on the card when you start"
    end

    test "saying nothing on the card: no comments asked for, only finish_job's summary",
         %{board: board} do
      prompt = List.last(codes(gen(board, %{"scenario" => "chatgpt"}, nil)))
      refute prompt =~ "Comment on the card what was done"
      refute prompt =~ "comment on the card what it needs"
      assert prompt =~ "Don't comment on the card at all"
      assert prompt =~ "say what it needs in finish_job's summary"
      assert prompt =~ "job_progress with the job id and no note"
    end

    test "hooks are left out, saying why; instructions stay", %{board: board} do
      setup =
        gen(
          board,
          %{
            "scenario" => "chatgpt",
            "instructions" => "Use British spelling.",
            "before_job" => "git pull"
          },
          nil
        )

      prompt = List.last(codes(setup))
      assert prompt =~ "Use British spelling."
      refute prompt =~ "git pull"
      assert Enum.any?(setup.warnings, &(&1 =~ "Hooks can't run in ChatGPT: it runs on OpenAI's"))
      refute Setup.hooks?(answers(%{"scenario" => "chatgpt"}))
    end

    test "connect makes no runner and no token, and a rule sending chatgpt jobs", ctx do
      [_, doing | _] = ctx.board.columns

      {:ok, result} =
        Setup.connect(
          ctx.board,
          %{"scenario" => "chatgpt", "pool" => "writing", "column" => doing.name},
          ctx.owner,
          @base
        )

      assert result.runner == nil
      assert result.token == nil
      assert Runners.list_runners(ctx.board) == []

      assert [%{"type" => "runner", "pool" => "writing", "kind" => "chatgpt"}] =
               result.rule.spec["actions"]
    end
  end

  describe "what a pass does to the card: seven toggles, all off (#514)" do
    defp loop(board, extra),
      do: Setup.loop_prompt(answers(extra), %{base_url: @base, board: board})

    defp cloud(board, extra),
      do: Setup.cloud_prompt(answers(Map.put(extra, "scenario", "cloud")), %{board: board})

    @all_on Map.new(Setup.toggles(), &{&1, "true"})

    # The sentence each toggle gives, on and off.
    @said %{
      "in_progress" =>
        {"Move the card to the doing list when you start.",
         "Don't move the card to the doing list: leave it where it is."},
      "assign" =>
        {"Assign the card to yourself when you start.", "Don't assign the card to anyone."},
      "move_done" =>
        {"Move the card to the done list when you finish.",
         "Don't move the card to the done list."},
      "complete" => {"Mark the card complete when you finish.", "Don't mark the card complete."},
      "percent_100" =>
        {"Set the card's % complete to 100 when you finish.",
         "Don't set the card's % complete at all."}
    }

    test "all off by default, and off is said, not left unsaid" do
      a = answers()
      assert Enum.all?(Setup.toggles(), &(a[&1] == false))
      assert length(Setup.toggles()) == 7

      text = Setup.card_text(a)
      for {_key, {on, off}} <- @said, do: assert(text =~ off) && refute(text =~ on)
      assert text =~ "Don't commit or push anything."
      refute text =~ "git repository"
    end

    test "each toggle on its own turns only its own sentence on", %{board: board} do
      for {key, {on, off}} <- @said do
        prompt = loop(board, %{"scenario" => "loop", key => "true"})
        assert prompt =~ on, key
        refute prompt =~ off, key

        for {other, {other_on, other_off}} <- @said, other != key do
          assert prompt =~ other_off, "#{key} on: #{other}"
          refute prompt =~ other_on, "#{key} on: #{other}"
        end
      end
    end

    test "commit, commit and push, or neither — committing only in a git repository",
         %{board: board} do
      commit = loop(board, %{"scenario" => "loop", "commit" => "on"})

      assert commit =~
               "If the working directory is a git repository, commit with the card id in the " <>
                 "message, but don't push; if it isn't one, skip the commit."

      both = loop(board, %{"scenario" => "loop", "commit" => true, "push" => true})

      assert both =~
               "If the working directory is a git repository, commit with the card id in the " <>
                 "message and push; if it isn't one, skip the commit."

      refute both =~ "don't push"
      assert loop(board, %{"scenario" => "loop"}) =~ "Don't commit or push anything."
    end

    test "push needs commit" do
      assert Setup.normalise(%{"push" => "true"}) ==
               {:error, "push needs commit: a pass can only push a commit it made"}

      assert Setup.normalise(%{"push" => "true", "commit" => "false"}) ==
               {:error, "push needs commit: a pass can only push a commit it made"}

      assert {:ok, %{"push" => true, "commit" => true}} =
               Setup.normalise(%{"push" => "on", "commit" => "on"})
    end

    test "a toggle is a checkbox: anything else is refused, #511's values included" do
      assert Setup.normalise(%{"commit" => "push"}) == {:error, "commit must be true or false"}
      assert Setup.normalise(%{"complete" => "yes"}) == {:error, "complete must be true or false"}
      assert {:ok, %{"assign" => false}} = Setup.normalise(%{"assign" => ""})
      assert {:ok, %{"assign" => false}} = Setup.normalise(%{"assign" => "off"})
      # #511's close is no longer an answer, and is dropped like any unknown key.
      refute Map.has_key?(answers(%{"close" => "done"}), "close")
    end

    test "all on, the loop prompt says each one on", %{board: board} do
      prompt = loop(board, Map.put(@all_on, "scenario", "loop"))
      for {_key, {on, off}} <- @said, do: assert(prompt =~ on) && refute(prompt =~ off)
      assert prompt =~ "commit with the card id in the message and push"
      assert prompt =~ "Then finish the job and stop."
    end

    test "a cloud routine's steps 2, 4 and 5 follow them", %{board: board} do
      off = cloud(board, %{"where" => "cloud"})

      assert off =~
               "2. Otherwise the job names a card. Read it with get_card. Don't move the card " <>
                 "to the doing list: leave it where it is. Don't assign the card to anyone.\n"

      assert off =~ "4. Run the tests if there are any. Don't commit or push anything."

      assert off =~
               "5. Don't move the card to the done list. Don't mark the card complete. Don't " <>
                 "set the card's % complete at all. Then call finish_job"

      refute off =~ "complete_card"

      on = cloud(board, Map.merge(@all_on, %{"where" => "cloud", "verbosity" => "normal"}))

      assert on =~
               "Read it with get_card. Move the card to the doing list when you start. Assign " <>
                 "the card to yourself when you start. Comment that you have picked it up"

      assert on =~ "4. Run the tests if there are any. If the working directory is a git"
      assert on =~ "and push; if it isn't one"

      assert on =~
               "5. Comment on the card what was done (files, tests, any commit). Move the card " <>
                 "to the done list when you finish. Mark the card complete when you finish. Set " <>
                 "the card's % complete to 100 when you finish. Then call finish_job"
    end

    test "a runner of its own is told in its standing instructions", %{board: board} do
      for scenario <- ~w(server windows) do
        text = Setup.instructions(answers(%{"scenario" => scenario}))
        assert text =~ "What to do to the card: Don't move the card to the doing list"
        assert text =~ "Don't commit or push anything."

        on = Setup.instructions(answers(Map.put(@all_on, "scenario", scenario)))
        assert on =~ "What to do to the card: Move the card to the doing list when you start."
        assert on =~ "Set the card's % complete to 100 when you finish."
      end

      [line | _] = board |> gen(%{"commit" => "true"}) |> codes()
      assert line =~ "--instructions 'What to do to the card:"
      assert line =~ "commit with the card id in the message, but don'\\''t push"

      # A Claude session hears it in its prompt, so not twice.
      refute Setup.instructions(answers(%{"scenario" => "loop"})) =~ "What to do to the card"
    end

    test "saved with the runner and changed later like any answer", ctx do
      {:ok, %{runner: runner}} =
        Setup.connect(
          ctx.board,
          %{"pool" => "dev", "commit" => "true", "assign" => "true"},
          ctx.owner,
          @base
        )

      assert %{"commit" => true, "assign" => true, "push" => false} = runner.settings

      {:ok, %{runner: runner}} = Setup.update(runner, ctx.board, %{"push" => "true"}, @base)
      assert %{"commit" => true, "assign" => true, "push" => true} = runner.settings

      assert {:error, "push needs commit" <> _} =
               Setup.update(runner, ctx.board, %{"commit" => "false"}, @base)
    end

    test "answers saved under #511 carry over", ctx do
      {:ok, %{runner: runner}} = Setup.connect(ctx.board, %{"pool" => "dev"}, ctx.owner, @base)

      for {old, want} <- [
            {%{"commit" => "push", "close" => "done"},
             %{"commit" => true, "push" => true, "move_done" => true, "complete" => true}},
            {%{"commit" => "commit", "close" => "open"},
             %{"commit" => true, "push" => false, "move_done" => false, "complete" => false}},
            {%{"commit" => "none", "close" => "done"},
             %{"commit" => false, "push" => false, "move_done" => true, "complete" => true}}
          ] do
        {:ok, runner} =
          Runners.update_runner(runner, %{"settings" => Map.merge(runner.settings, old)})

        saved = Setup.saved(runner)
        assert Map.take(saved, Map.keys(want)) == want, inspect(old)

        assert {saved["in_progress"], saved["assign"], saved["percent_100"]} ==
                 {false, false, false}

        refute Map.has_key?(saved, "close")
      end

      # And changing one answer saves the carried-over ones as toggles.
      {:ok, runner} =
        Runners.update_runner(runner, %{
          "settings" => Map.merge(runner.settings, %{"commit" => "none", "close" => "done"})
        })

      {:ok, %{runner: runner}} = Setup.update(runner, ctx.board, %{"assign" => "true"}, @base)
      assert %{"commit" => false, "move_done" => true, "assign" => true} = runner.settings
      refute Map.has_key?(runner.settings, "close")
    end
  end

  describe "how much to write on the card: Nothing, the default (#514)" do
    test "is the default, and says not to comment at all" do
      assert answers()["verbosity"] == "nothing"
      text = Setup.instructions(answers(%{"scenario" => "loop"}))
      assert text =~ "Don't comment on the card at all"
      assert text =~ "job_progress (or slipdock job-progress) without a note"
    end

    test "whatever the skill says is still a choice, and adds nothing" do
      assert Setup.instructions(answers(%{"scenario" => "loop", "verbosity" => ""})) == ""
    end

    test "reaches the loop prompt and a runner's standing instructions", %{board: board} do
      assert loop(board, %{"scenario" => "loop"}) =~
               "Standing instructions for every job:\nDon't comment on the card at all"

      [line | _] = board |> gen(%{}) |> codes()
      assert line =~ "Don'\\''t comment on the card at all"
    end

    test "a cloud routine is told no notes and no comments, and says why only in the job",
         %{board: board} do
      prompt = cloud(board, %{"where" => "cloud"})
      assert prompt =~ "Call job_progress with the job id and no note"
      refute prompt =~ "Comment that you have picked it up"
      refute prompt =~ "Comment on the card what was done"
      refute prompt =~ "say so on the card"
      assert prompt =~ "say why in finish_job's summary"

      chatty = cloud(board, %{"where" => "cloud", "verbosity" => "quiet"})
      assert chatty =~ "Call job_progress with the job id and a short note"
      assert chatty =~ "say so on the card"
      refute chatty =~ "in finish_job's summary"
    end

    test "an unknown verbosity names Nothing among the choices" do
      assert Setup.normalise(%{"verbosity" => "shouty"}) ==
               {:error, "verbosity must be nothing, quiet, normal or verbose"}
    end
  end

  describe "a session without the job tools (#511)" do
    test "is told to stop and say so, not to work the lists", %{board: board} do
      prompt =
        Setup.loop_prompt(answers(%{"scenario" => "loop"}), %{base_url: @base, board: board})

      assert prompt =~ Setup.no_job_tools()
      assert Setup.no_job_tools() =~ "don't work the board's lists directly"
      assert Setup.no_job_tools() =~ "Slipdock connector needs reconnecting"

      cloud =
        Setup.cloud_prompt(answers(%{"scenario" => "cloud", "where" => "cloud"}), %{board: board})

      assert cloud =~ "If there is no claim_job tool, stop and say the Slipdock connector needs"
    end
  end

  describe "a Windows working directory (#511)" do
    test "is told apart by its drive letter, ~\\ or a share" do
      for path <- [~S"C:\Users\da\GMinds", "d:/work", ~S"~\GMinds", ~S"\\nas\share"],
          do: assert(Setup.windows_path?(path), path)

      for path <- ["/tmp", "~/app", "", "~", "relative\\dir", nil],
          do: refute(Setup.windows_path?(path), inspect(path))
    end

    test "a Desktop routine installs the skills with PowerShell, into the Windows home",
         %{board: board} do
      setup =
        gen(
          board,
          %{"scenario" => "cloud", "where" => "desktop", "cwd" => ~S"C:\Users\da\GMinds"},
          nil
        )

      skills = Enum.at(setup.steps, 1)
      assert skills.lang == "powershell"
      assert skills.code == "irm '#{@base}/install.ps1' | iex"
      assert skills.text =~ ~S"%USERPROFILE%\.claude\skills"
      refute Enum.any?(codes(setup), &(&1 =~ "install.sh"))
      assert Enum.at(setup.steps, 2).text =~ ~S"Folder: C:\Users\da\GMinds"
    end

    test "a /loop gets PowerShell to start Claude Code there too", %{board: board} do
      setup = gen(board, %{"scenario" => "loop", "cwd" => ~S"C:\Users\da\it's"}, nil)
      [_mcp, skills, start, _loop] = codes(setup)

      assert skills =~ "/install.ps1' | iex"
      assert start == ~S"Set-Location 'C:\Users\da\it''s'; claude --permission-mode acceptEdits"
    end

    test "anywhere else keeps the shell steps, and names the PowerShell one", %{board: board} do
      setup = gen(board, %{"scenario" => "loop", "cwd" => "~/app"}, nil)
      [_mcp, skills, start, _loop] = codes(setup)

      assert skills == "curl -fsSL #{@base}/install.sh | sh"
      assert Enum.at(setup.steps, 1).text =~ "irm #{@base}/install.ps1 | iex"
      assert start =~ ~S(cd "$HOME"/'app' && claude)
    end
  end

  test "quoting: a quote inside is closed, escaped and reopened, or doubled" do
    assert Setup.sh_q("it's") == ~S('it'\''s')
    assert Setup.ps_q("it's") == "'it''s'"
  end

  describe "connect/4" do
    test "a runner scenario makes the runner, saves the answers and never the token", ctx do
      {:ok, result} =
        Setup.connect(
          ctx.board,
          %{"pool" => "dev", "name" => "laptop", "agent" => "codex"},
          ctx.owner,
          @base
        )

      assert result.runner.name == "laptop"
      assert result.runner.pool == "dev"
      assert "sdr_" <> _ = result.token
      assert Runners.authenticate(result.token).id == result.runner.id
      assert result.runner.settings["agent"] == "codex"
      refute inspect(result.runner.settings) =~ result.token
      assert hd(codes(result.setup)) =~ result.token
      assert result.rule == nil
    end

    test "a list adds a send-to-runner rule for it", ctx do
      [_, doing | _] = ctx.board.columns

      {:ok, %{rule: rule}} =
        Setup.connect(
          ctx.board,
          %{"pool" => "dev", "column" => String.upcase(doing.name)},
          ctx.owner,
          @base
        )

      assert rule.spec["trigger"] == %{"type" => "card_entered", "column" => doing.name}
      assert [%{"type" => "runner", "pool" => "dev", "kind" => "claude"}] = rule.spec["actions"]
      assert Automations.get_board_rule(ctx.board.id, rule.id)
    end

    test "or links a rule already there", ctx do
      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "runner", "pool" => "dev"}]
        })

      {:ok, %{rule: linked}} =
        Setup.connect(
          ctx.board,
          %{"pool" => "dev", "rule_id" => to_string(rule.id)},
          ctx.owner,
          @base
        )

      assert linked.id == rule.id
    end

    test "a list that isn't there, or another board's rule, makes nothing", ctx do
      assert {:error, "there's no list called “Nowhere”" <> _} =
               Setup.connect(ctx.board, %{"column" => "Nowhere"}, ctx.owner, @base)

      other = board_fixture()

      rule =
        rule_fixture(other, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "log", "message" => "x"}]
        })

      assert {:error, "no such rule on this board"} =
               Setup.connect(ctx.board, %{"rule_id" => to_string(rule.id)}, ctx.owner, @base)

      assert Runners.list_runners(ctx.board) == []
    end

    test "a Claude scenario makes no runner and no token", ctx do
      {:ok, result} = Setup.connect(ctx.board, %{"scenario" => "loop"}, ctx.owner, @base)
      assert result.runner == nil
      assert result.token == nil
      assert Runners.list_runners(ctx.board) == []
    end

    test "regenerate: the same steps from the saved answers, with the token left out", ctx do
      {:ok, %{runner: runner, setup: first}} =
        Setup.connect(
          ctx.board,
          %{"pool" => "dev", "agent" => "codex", "cwd" => "/w"},
          ctx.owner,
          @base
        )

      again = Setup.regenerate(runner, ctx.board, @base)
      [line | _] = codes(again)
      assert line =~ "--agent codex"
      assert line =~ "--cwd '/w'"
      # No token: run again on that machine, the installer keeps the one it has.
      refute line =~ "--token"
      assert hd(again.warnings) =~ "keeps the one in its config"
      assert length(again.steps) == length(first.steps)

      {:ok, runner, token} = Runners.rotate_token(runner)
      assert hd(codes(Setup.regenerate(runner, ctx.board, @base, token))) =~ token
    end
  end

  test "rotating a token ends the old one", %{board: board} do
    {:ok, runner, old} = Runners.create_runner(board, %{"name" => "r", "pool" => "dev"})
    {:ok, _, new} = Runners.rotate_token(runner)
    assert Runners.authenticate(old) == nil
    assert Runners.authenticate(new).id == runner.id
  end

  describe "instructions and hooks" do
    @tricky ~S"""
    Say "hi" and it's fine. $(touch PWNED) `touch PWNED` ${HOME}
    SLIPDOCK_EOF_deadbeef
    'quoted' — naïve café ✓
    """

    test "the verbosity paragraph, then the free text" do
      loop = &answers(Map.put(&1, "scenario", "loop"))
      assert Setup.instructions(loop.(%{"verbosity" => ""})) == ""
      assert Setup.instructions(loop.(%{"verbosity" => "quiet"})) =~ "one line when you start"

      both =
        Setup.instructions(
          loop.(%{"verbosity" => "verbose", "instructions" => "Never push to main."})
        )

      assert both =~ ~r/^Keep a detailed.*full summary\.\n\nNever push to main\.$/s
    end

    test "the server line carries them, quoted so nothing in them runs", %{board: board} do
      [line | _] =
        board
        |> gen(%{
          "instructions" => @tricky,
          "before_job" => "git pull",
          "after_job" => ~S(echo "$SLIPDOCK_STATUS")
        })
        |> codes()

      text = Setup.instructions(answers(%{"instructions" => @tricky}))
      assert text =~ ~r/\n\n#{Regex.escape(String.trim(@tricky))}$/
      assert line =~ "--instructions " <> Setup.sh_q(text)
      assert line =~ "--before-job 'git pull'"
      assert line =~ ~S(--after-job 'echo "$SLIPDOCK_STATUS"')
    end

    test "the config preview shows the heredoc and the hook functions", %{board: board} do
      [_, _, config] =
        board |> gen(%{"instructions" => "Be brief.", "before_job" => "git pull"}) |> codes()

      assert config =~
               "job_instructions() {\n  cat <<'SLIPDOCK_EOF_<random>'\nWhat to do to the card:"

      assert config =~ "\n\nBe brief.\nSLIPDOCK_EOF_<random>\n}"

      assert config =~ "JOB_INSTRUCTIONS=$(job_instructions)"
      assert config =~ "before_job() {\ngit pull\n}"
      refute config =~ "after_job()"
    end

    test "PowerShell gets them as literal strings", %{board: board} do
      [line, _sums] =
        board
        |> gen(%{
          "scenario" => "windows",
          "instructions" => "it's '@ here",
          "after_job" => "Write-Host 'x'"
        })
        |> codes()

      assert line =~ ~S(-Instructions 'What to do to the card: Don''t move)
      assert line =~ "\n\nit''s ''@ here' `"
      assert line =~ ~S(-AfterJob 'Write-Host ''x''')
    end

    test "a /loop is asked to run the hooks, in so many words", %{board: board} do
      setup =
        gen(
          board,
          %{
            "scenario" => "loop",
            "before_job" => "git pull",
            "after_job" => "make clean",
            "instructions" => "Be brief.",
            "verbosity" => ""
          },
          nil
        )

      loop = List.last(codes(setup))
      assert loop =~ "only go on if it succeeds: git pull"
      assert loop =~ "even if it failed or was cancelled — run this in the shell: make clean"
      assert loop =~ "Standing instructions for every job:\nBe brief."
      refute Enum.any?(codes(setup), &(&1 =~ "PostToolUse"))
    end

    test "or given Claude Code hooks it runs itself, on the MCP tools", %{board: board} do
      setup =
        gen(
          board,
          %{
            "scenario" => "loop",
            "hooks" => "hook",
            "before_job" => "git pull",
            "after_job" => "make clean"
          },
          nil
        )

      json = List.last(codes(setup))
      assert %{"hooks" => %{"PostToolUse" => [before, after_]}} = Jason.decode!(json)

      assert before == %{
               "matcher" => "mcp__slipdock__claim_job",
               "hooks" => [%{"type" => "command", "command" => "git pull"}]
             }

      assert after_["matcher"] == "mcp__slipdock__finish_job"
      loop = Enum.find(codes(setup), &(&1 =~ "/loop "))

      assert loop =~
               "with the Slipdock MCP tools claim_job, job_progress and finish_job (not the CLI)"

      refute loop =~ "run this in the shell"
    end

    test "a cloud routine takes the instructions and leaves the hooks out, saying why",
         %{board: board} do
      setup =
        gen(
          board,
          %{
            "scenario" => "cloud",
            "where" => "cloud",
            "instructions" => "Be brief.",
            "verbosity" => "",
            "after_job" => "make clean"
          },
          nil
        )

      prompt = List.last(codes(setup))
      assert prompt =~ "Standing instructions for every job:\nBe brief."
      refute prompt =~ "make clean"
      assert Enum.any?(setup.warnings, &(&1 =~ "Hooks can't run in a cloud routine"))
      refute Setup.hooks?(answers(%{"scenario" => "cloud", "where" => "cloud"}))
      assert Setup.hooks?(answers(%{"scenario" => "cloud", "where" => "desktop"}))
    end

    test "too much of either, or a choice it doesn't have, is refused" do
      assert {:error, "the instructions are over" <> _} =
               Setup.normalise(%{"instructions" => String.duplicate("x", 4001)})

      assert {:error, "a hook is over" <> _} =
               Setup.normalise(%{"after_job" => String.duplicate("x", 2001)})

      assert {:error, "verbosity" <> _} = Setup.normalise(%{"verbosity" => "shouty"})
      assert {:error, "hooks" <> _} = Setup.normalise(%{"hooks" => "magic"})
    end

    test "changing a runner's answers saves them and says what changes", ctx do
      {:ok, %{runner: runner}} = Setup.connect(ctx.board, %{"pool" => "dev"}, ctx.owner, @base)

      {:ok, %{runner: runner, diff: diff}} =
        Setup.update(
          runner,
          ctx.board,
          %{"instructions" => "Be brief.", "timeout" => "900", "pool" => "other"},
          @base
        )

      assert runner.settings["instructions"] == "Be brief."
      # The pool is what the token is for: it doesn't change here.
      assert runner.pool == "dev"
      assert Enum.any?(diff, &match?({:del, "  --timeout 3600" <> _}, &1))
      assert Enum.any?(diff, &match?({:ins, "Be brief.'"}, &1))
      assert Enum.any?(diff, &match?({:ins, "Be brief."}, &1))
      assert Enum.any?(diff, &match?({:eq, _}, &1))

      {:ok, %{diff: same}} = Setup.update(runner, ctx.board, Setup.saved(runner), @base)
      assert Enum.all?(same, &match?({:eq, _}, &1))

      assert {:error, "verbosity" <> _} =
               Setup.update(runner, ctx.board, %{"verbosity" => "x"}, @base)
    end
  end

  describe "the Slipdock tools, for a claude runner" do
    test "on by default: both servers in the flag, the config and the claude line",
         %{board: board} do
      a = answers()
      assert a["slipdock_tools"] == true
      assert a["mcp_servers"] == "claude_ai_Slipdock, slipdock"
      assert Setup.allowed_tools(a) == "mcp__claude_ai_Slipdock,mcp__slipdock"

      [line, _sums, config] = board |> gen(%{"cwd" => "/srv/w"}) |> codes()
      assert line =~ "--mcp-servers 'claude_ai_Slipdock,slipdock'"
      assert config =~ "ALLOWED_TOOLS='mcp__claude_ai_Slipdock,mcp__slipdock'"

      assert config =~
               ~S("$AGENT_BIN" -p "$SLIPDOCK_PROMPT" --permission-mode "$PERMISSION_MODE" --allowedTools "$ALLOWED_TOOLS")

      [ps | _] = board |> gen(%{"scenario" => "windows", "cwd" => "C:\\w"}) |> codes()
      assert ps =~ "-McpServers 'claude_ai_Slipdock,slipdock'"
    end

    test "one server named, given as the form or the API sends it", %{board: board} do
      for flag <- ["true", "on", true] do
        a = answers(%{"slipdock_tools" => flag, "mcp_servers" => " my-slipdock "})
        assert Setup.allowed_tools(a) == "mcp__my-slipdock"
      end

      [line | _] = board |> gen(%{"mcp_servers" => "slipdock"}) |> codes()
      assert line =~ "--mcp-servers 'slipdock'"
    end

    test "off: no --allowedTools anywhere, and the installers are told so", %{board: board} do
      for off <- ["false", false, "off", ""] do
        a = answers(%{"slipdock_tools" => off})
        assert a["slipdock_tools"] == false
        assert Setup.allowed_tools(a) == ""
      end

      [line, _sums, config] = board |> gen(%{"slipdock_tools" => "false"}) |> codes()
      assert line =~ "--mcp-servers ''"
      assert config =~ "ALLOWED_TOOLS=''"
      refute config =~ "--allowedTools"

      [ps | _] = board |> gen(%{"scenario" => "windows", "slipdock_tools" => false}) |> codes()
      assert ps =~ "-McpServers ''"
    end

    test "codex and custom agents aren't given it", %{board: board} do
      for agent <- ["codex", "custom"] do
        [line, _sums, config] =
          board |> gen(%{"agent" => agent, "command" => "true"}) |> codes()

        refute line =~ "--mcp-servers"
        assert config =~ "ALLOWED_TOOLS=''"
        refute config =~ "--allowedTools"
      end
    end

    test "a server name that isn't one, or none with the option on, is refused" do
      for names <- ["slip dock$", "mcp__x;rm", "a/b", "é"] do
        assert {:error, "an MCP server's name" <> _} =
                 Setup.normalise(%{"mcp_servers" => names}),
               names
      end

      assert {:error, "name the Slipdock MCP server" <> _} =
               Setup.normalise(%{"mcp_servers" => " , "})

      assert {:ok, _} = Setup.normalise(%{"mcp_servers" => "", "slipdock_tools" => "false"})

      assert {:error, "slipdock_tools must be true or false"} =
               Setup.normalise(%{"slipdock_tools" => "maybe"})
    end

    test "turning it off shows in what changes on the machine", ctx do
      {:ok, %{runner: runner}} = Setup.connect(ctx.board, %{"pool" => "dev"}, ctx.owner, @base)
      assert runner.settings["slipdock_tools"] == true

      {:ok, %{runner: runner, diff: diff}} =
        Setup.update(runner, ctx.board, %{"slipdock_tools" => "false"}, @base)

      assert runner.settings["slipdock_tools"] == false
      assert {:del, "  --mcp-servers 'claude_ai_Slipdock,slipdock' \\"} in diff
      assert {:ins, "  --mcp-servers '' \\"} in diff
      assert {:ins, "ALLOWED_TOOLS=''"} in diff
      assert Enum.any?(diff, &match?({:del, "  \"$AGENT_BIN\"" <> _}, &1))
    end
  end

  describe "a blank working directory" do
    @warning "No working directory: jobs start in your home directory"

    test "warns a claude runner, loop or Desktop task that project settings won't load",
         %{board: board} do
      for extra <- [
            %{},
            %{"scenario" => "windows"},
            %{"scenario" => "loop"},
            %{"scenario" => "cloud", "where" => "desktop"}
          ] do
        warnings = gen(board, Map.put(extra, "cwd", "")).warnings
        assert Enum.any?(warnings, &String.starts_with?(&1, @warning)), inspect(extra)
        assert Enum.any?(warnings, &(&1 =~ ".claude/settings.json"))
      end
    end

    test "but not with a directory set, for codex or a command, or a cloud routine",
         %{board: board} do
      for extra <- [
            %{"cwd" => "/srv/app"},
            %{"agent" => "codex"},
            %{"agent" => "custom", "command" => "true"},
            %{"scenario" => "cloud", "where" => "cloud"}
          ] do
        refute Enum.any?(gen(board, extra).warnings, &String.starts_with?(&1, @warning)),
               inspect(extra)
      end
    end
  end

  describe "a working directory under ~" do
    test "~ and ~/… are accepted, another user's ~ is refused" do
      for cwd <- ["~", "~/x", "~/", "~\\x", "/srv/app", "C:\\src"] do
        assert {:ok, %{"cwd" => ^cwd}} = Setup.normalise(%{"cwd" => cwd}), cwd
      end

      for cwd <- ["~bob/x", "~bob", "~root"] do
        assert {:error, "the working directory can't be another user's ~" <> rest} =
                 Setup.normalise(%{"cwd" => cwd}),
               cwd

        assert rest =~ "use a full path, or ~/"
      end
    end

    test "the config spells ~ as $HOME, outside the quotes", %{board: board} do
      config = fn cwd -> board |> gen(%{"cwd" => cwd}) |> codes() |> List.last() end

      assert config.("~/webs/it's here") =~ ~S(WORKDIR="$HOME"/'webs/it'\''s here') <> "\n"
      assert config.("~") =~ ~S(WORKDIR="$HOME") <> "\n"
      # Nothing changes for a path that is already whole.
      assert config.("/srv/app") =~ "WORKDIR='/srv/app'\n"
      assert config.("/srv/~x") =~ "WORKDIR='/srv/~x'\n"
    end

    test "the one-liners pass it as written, for the installer to expand", %{board: board} do
      [line | _] = board |> gen(%{"cwd" => "~/x"}) |> codes()
      assert line =~ "--cwd '~/x'"

      [ps | _] = board |> gen(%{"scenario" => "windows", "cwd" => "~\\x"}) |> codes()
      assert ps =~ "-Cwd '~\\x'"
    end

    test "a /loop starts where it says, home included", %{board: board} do
      cd = fn extra ->
        board |> gen(Map.put(extra, "scenario", "loop")) |> codes() |> Enum.at(2)
      end

      assert cd.(%{"cwd" => ""}) =~ ~S(cd "$HOME" && claude)
      assert cd.(%{"cwd" => "~/src/app"}) =~ ~S(cd "$HOME"/'src/app' && claude)
      assert cd.(%{"cwd" => "/srv/app"}) =~ "cd '/srv/app' && claude"
    end
  end

  describe "the wizard's defaults and wording (#493)" do
    test "a working directory not given is a scratch one; one given blank is still home" do
      assert answers()["cwd"] == "/tmp"
      assert answers(%{"scenario" => "loop"})["cwd"] == "/tmp"
      assert answers(%{"scenario" => "windows"})["cwd"] == ~S"~\AppData\Local\Temp"
      assert answers(%{"cwd" => ""})["cwd"] == ""
      assert answers(%{"cwd" => "/srv/app"})["cwd"] == "/srv/app"
    end

    test "the default goes into the one-liner and the config", %{board: board} do
      [line, _sums, config] = board |> gen(%{}) |> codes()
      assert line =~ "--cwd '/tmp'"
      assert config =~ "WORKDIR='/tmp'\n"

      [ps | _] = board |> gen(%{"scenario" => "windows"}) |> codes()
      assert ps =~ ~S"-Cwd '~\AppData\Local\Temp'"
    end

    test "the default directory warns like a blank one; a project folder doesn't", %{board: board} do
      for scenario <- ["server", "windows", "loop"] do
        warnings = gen(board, %{"scenario" => scenario}).warnings

        assert Enum.any?(warnings, &(&1 =~ "the default, so the project's own commands")),
               scenario
      end

      refute Enum.any?(gen(board, %{"cwd" => "/srv/app"}).warnings, &(&1 =~ "the default"))
    end

    test "the cost notes lose the sentences comparing the two", %{board: board} do
      runner = gen(board, %{}).cost
      claude = gen(board, %{"scenario" => "loop"}).cost

      assert runner =~ "costs nothing while it waits"
      refute runner =~ "The right choice for anything left running."
      assert claude =~ "uses your Claude usage, even when nothing is queued."
      refute claude =~ "Fine for a while"
      refute claude =~ "a runner costs nothing while idle"
    end

    test "with no rule, the last step names the Send cards to a runner preset", %{board: board} do
      rule = List.last(gen(board, %{"pool" => "dev"}).steps)
      assert rule.id == :rule

      assert rule.text ==
               "Nothing is sent until a rule sends it: add one under Automations with the " <>
                 "Send cards to a runner preset (pool dev, kind claude)."

      assert {rule.pool, rule.kind} == {"dev", "claude"}
      refute rule.text =~ "coding agent"
    end

    test "the runner scenarios name their steps for the wizard", %{board: board} do
      assert Enum.map(gen(board, %{}).steps, & &1[:id]) == [:command, :checksums, :config, :rule]
    end

    test "changing one answer keeps the others the runner has", ctx do
      {:ok, %{runner: runner}} =
        Setup.connect(
          ctx.board,
          %{"pool" => "dev", "cwd" => "", "instructions" => "Be brief."},
          ctx.owner,
          @base
        )

      {:ok, %{runner: runner}} = Setup.update(runner, ctx.board, %{"timeout" => "900"}, @base)
      assert runner.settings["timeout"] == 900
      # Not reset to the defaults: home stays home, the instructions stay.
      assert runner.settings["cwd"] == ""
      assert runner.settings["instructions"] == "Be brief."
    end
  end
end

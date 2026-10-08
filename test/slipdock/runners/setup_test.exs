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
      setup = gen(board, %{}, nil)
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
    [line] = codes(setup)
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
    assert start == "cd '~/src/app' && claude --permission-mode acceptEdits"

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
      assert Enum.at(setup.steps, 1).text =~ "Routines → New routine → Local"
      assert Enum.at(setup.steps, 1).text =~ "Folder: ~/app"
      assert Enum.at(codes(setup), 1) =~ "/slipdock-loop against"
      assert setup.warnings == []
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
      assert Setup.instructions(answers()) == ""
      assert Setup.instructions(answers(%{"verbosity" => "quiet"})) =~ "one line when you start"

      both =
        Setup.instructions(
          answers(%{"verbosity" => "verbose", "instructions" => "Never push to main."})
        )

      assert both =~ ~r/full summary\.\n\nNever push to main\.$/
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

      assert line =~ "--instructions " <> Setup.sh_q(String.trim(@tricky))
      assert line =~ "--before-job 'git pull'"
      assert line =~ ~S(--after-job 'echo "$SLIPDOCK_STATUS"')
    end

    test "the config preview shows the heredoc and the hook functions", %{board: board} do
      [_, _, config] =
        board |> gen(%{"instructions" => "Be brief.", "before_job" => "git pull"}) |> codes()

      assert config =~
               "job_instructions() {\n  cat <<'SLIPDOCK_EOF_<random>'\nBe brief.\nSLIPDOCK_EOF_<random>\n}"

      assert config =~ "JOB_INSTRUCTIONS=$(job_instructions)"
      assert config =~ "before_job() {\ngit pull\n}"
      refute config =~ "after_job()"
    end

    test "PowerShell gets them as literal strings", %{board: board} do
      [line] =
        board
        |> gen(%{
          "scenario" => "windows",
          "instructions" => "it's '@ here",
          "after_job" => "Write-Host 'x'"
        })
        |> codes()

      assert line =~ ~S(-Instructions 'it''s ''@ here')
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
            "instructions" => "Be brief."
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
      assert Enum.any?(diff, &match?({:ins, "  --instructions 'Be brief.'"}, &1))
      assert Enum.any?(diff, &match?({:ins, "Be brief."}, &1))
      assert Enum.any?(diff, &match?({:eq, _}, &1))

      {:ok, %{diff: same}} = Setup.update(runner, ctx.board, Setup.saved(runner), @base)
      assert Enum.all?(same, &match?({:eq, _}, &1))

      assert {:error, "verbosity" <> _} =
               Setup.update(runner, ctx.board, %{"verbosity" => "x"}, @base)
    end
  end
end

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

  defp gen(board, extra, _token \\ nil),
    do: Setup.generate(answers(extra), %{base_url: @base, board: board})

  defp codes(setup), do: setup.steps |> Enum.map(& &1[:code]) |> Enum.reject(&is_nil/1)

  describe "the daemon scenario (#2572)" do
    test "comes first; its steps install, enrol with a key, run the service, add the runner",
         %{board: board} do
      assert hd(Setup.scenarios()) == "daemon"
      assert Setup.label("daemon") == "A machine with the daemon"

      setup = gen(board, %{"scenario" => "daemon", "pool" => "build"}, nil)
      [build, init, service] = codes(setup)

      assert build =~ "go build"
      assert init == "slipdock-runner init --server #{@base} --key sde_YOUR_ENROLMENT_KEY"
      assert service == "slipdock-runner service install"
      assert List.last(setup.steps).text =~ "#{@base}/account/machines"
      assert List.last(setup.steps).text =~ "the build pool"
      assert setup.intro =~ "machine's page"
      # No key yet: the preview says one is made when the steps are shown.
      assert [warning] = setup.warnings
      assert warning =~ "sde_YOUR_ENROLMENT_KEY"
    end

    test "connect makes a one-time key for the board's tree, and no runner",
         %{board: board, owner: owner} do
      assert {:ok, result} =
               Setup.connect(board, %{"scenario" => "daemon", "pool" => "build"}, owner, @base)

      assert "sde_" <> _ = result.enrolment_key
      assert result.runner == nil
      assert result.token == nil
      assert Enum.any?(codes(result.setup), &(&1 =~ result.enrolment_key))
      assert result.setup.warnings == []
      assert [key] = Slipdock.Machines.list_enrolment_keys(owner)
      assert key.board_ids == [board.id]
      assert key.label == "build runner"
      assert Runners.list_runners(board) == []
    end

    test "a sub-board's wizard enrols the machine for its tree", %{board: board, owner: owner} do
      [_backlog, todo | _] = board.columns
      card = card_fixture(todo, %{"title" => "Epic"})
      {:ok, t} = Slipdock.Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card, t)

      assert {:ok, result} = Setup.connect(sub, %{"scenario" => "daemon"}, owner, @base)
      assert [%{board_ids: [id]}] = Slipdock.Machines.list_enrolment_keys(owner)
      assert id == board.id
      assert result.enrolment_key
    end

    test "other scenarios make no key", %{board: board, owner: owner} do
      {:ok, result} = Setup.connect(board, %{"scenario" => "loop"}, owner, @base)
      assert result.enrolment_key == nil
      assert Slipdock.Machines.list_enrolment_keys(owner) == []
    end
  end

  describe "normalise/1" do
    test "fills in the defaults and folds case" do
      a = answers(%{"pool" => " Dev-Box "})
      # The daemon is the default since the scripts went (#2582).
      assert a["scenario"] == "daemon"
      assert a["pool"] == "dev-box"
      assert a["permission_mode"] == "acceptEdits"
    end

    test "drops what it doesn't know" do
      refute Map.has_key?(answers(%{"token" => "sdr_leak", "evil" => "x"}), "token")
    end

    test "refuses what it can't use" do
      for {params, message} <- [
            {%{"scenario" => "mainframe"},
             "scenario must be one of daemon, loop, cloud, chatgpt"},
            {%{"pool" => "my pool"}, "pool"},
            {%{"kind" => "$(id)"}, "kind"},
            {%{"permission_mode" => "yolo"}, "permission mode"},
            {%{"where" => "moon"}, "where"}
          ] do
        assert {:error, got} = Setup.normalise(params)
        assert got =~ message, "#{inspect(params)} → #{got}"
      end
    end

    # The shell and PowerShell runners' scenarios were retired (#2582).
    test "server and windows are refused, pointing at the daemon" do
      for scenario <- ~w(server windows) do
        assert {:error, message} = Setup.normalise(%{"scenario" => scenario})
        assert message =~ "the shell and PowerShell runners were retired for the runner daemon"
        assert message =~ "use the daemon scenario"
        assert message =~ "Account › Machines"
      end

      refute "server" in Setup.scenarios()
      refute "windows" in Setup.scenarios()
      assert Setup.scenarios() == ~w(daemon loop cloud chatgpt)
    end

    test "the script runners' options are dropped, not kept" do
      a =
        answers(%{
          "scenario" => "loop",
          "self_update" => "true",
          "worktree" => "true",
          "service" => "systemd",
          "install_name" => "box",
          "mcp_servers" => "slipdock",
          "timeout" => "900",
          "agent" => "codex",
          "command" => "true"
        })

      for key <- ~w(self_update worktree service install_name mcp_servers timeout agent command),
          do: refute(Map.has_key?(a, key), key)

      assert Setup.kind(a) == "claude"
    end
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
      # Assigning is never asked of a job, ticked or not (#2027).
      refute prompt =~ "Assign the card to yourself"
      refute prompt =~ "--assignee me"
      assert prompt =~ "Don't assign the card to anyone: while this job holds it"
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

    test "a job never assigns the card, whatever a saved setup's assign says (#2027)",
         %{board: board} do
      for scenario <- Setup.scenarios(), assign <- [true, false] do
        a = answers(%{"scenario" => scenario, "assign" => assign})
        text = Setup.card_text(a)
        assert text =~ "Don't assign the card to anyone: while this job holds it", scenario
        assert text =~ "the card shows this runner as its loop beside the assignees"
        refute text =~ "Assign the card to yourself", scenario
      end

      prompt = loop(board, %{"scenario" => "loop", "assign" => "true"})
      refute prompt =~ "Assign the card to yourself"
      refute prompt =~ "--assignee me"
      # The off wording the slipdock-loop skill keys on is still said.
      assert prompt =~ Setup.off_wording()["assign"]
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
                 "to the doing list: leave it where it is. Don't assign the card to anyone: " <>
                 "while this job holds it, the card shows this runner as its loop beside the " <>
                 "assignees.\n"

      assert off =~ "4. Run the tests if there are any. Don't commit or push anything."

      assert off =~
               "5. Don't move the card to the done list. Don't mark the card complete. Don't " <>
                 "set the card's % complete at all. Then call finish_job"

      refute off =~ "complete_card"

      on = cloud(board, Map.merge(@all_on, %{"where" => "cloud", "verbosity" => "normal"}))

      assert on =~
               "Read it with get_card. Move the card to the doing list when you start. Don't " <>
                 "assign the card to anyone: while this job holds it, the card shows this " <>
                 "runner as its loop beside the assignees. Comment that you have picked it up"

      assert on =~ "4. Run the tests if there are any. If the working directory is a git"
      assert on =~ "and push; if it isn't one"

      assert on =~
               "5. Comment on the card what was done (files, tests, any commit). Move the card " <>
                 "to the done list when you finish. Mark the card complete when you finish. Set " <>
                 "the card's % complete to 100 when you finish. Then call finish_job"
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

    test "reaches the loop prompt", %{board: board} do
      assert loop(board, %{"scenario" => "loop"}) =~
               "Standing instructions for every job:\nDon't comment on the card at all"
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
      for path <- [~S"C:\Users\da\Notes", "d:/work", ~S"~\Notes", ~S"\\nas\share"],
          do: assert(Setup.windows_path?(path), path)

      for path <- ["/tmp", "~/app", "", "~", "relative\\dir", nil],
          do: refute(Setup.windows_path?(path), inspect(path))
    end

    test "a Desktop routine installs the skills with PowerShell, into the Windows home",
         %{board: board} do
      setup =
        gen(
          board,
          %{"scenario" => "cloud", "where" => "desktop", "cwd" => ~S"C:\Users\da\Notes"},
          nil
        )

      skills = Enum.at(setup.steps, 1)
      assert skills.lang == "powershell"
      assert skills.code == "irm '#{@base}/install.ps1' | iex"
      assert skills.text =~ ~S"%USERPROFILE%\.claude\skills"
      refute Enum.any?(codes(setup), &(&1 =~ "install.sh"))
      assert Enum.at(setup.steps, 2).text =~ ~S"Folder: C:\Users\da\Notes"
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
  end

  test "rotating a token ends the old one", %{board: board} do
    {:ok, runner, old} = Runners.create_runner(board, %{"name" => "r", "pool" => "dev"})
    {:ok, _, new} = Runners.rotate_token(runner)
    assert Runners.authenticate(old) == nil
    assert Runners.authenticate(new).id == runner.id
  end

  describe "instructions and hooks" do
    test "the verbosity paragraph, then the free text" do
      loop = &answers(Map.put(&1, "scenario", "loop"))
      assert Setup.instructions(loop.(%{"verbosity" => ""})) == ""
      assert Setup.instructions(loop.(%{"verbosity" => "quiet"})) =~ "one line when you start"
      # What to do to the card is the prompt's, never the standing instructions'.
      refute Setup.instructions(loop.(%{"commit" => "true"})) =~ "What to do to the card"

      both =
        Setup.instructions(
          loop.(%{"verbosity" => "verbose", "instructions" => "Never push to main."})
        )

      assert both =~ ~r/^Keep a detailed.*full summary\.\n\nNever push to main\.$/s
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
  end

  describe "a blank working directory" do
    @warning "No working directory: jobs start in your home directory"

    test "warns a claude runner, loop or Desktop task that project settings won't load",
         %{board: board} do
      for extra <- [
            %{"scenario" => "loop"},
            %{"scenario" => "cloud", "where" => "desktop"}
          ] do
        warnings = gen(board, Map.put(extra, "cwd", "")).warnings
        assert Enum.any?(warnings, &String.starts_with?(&1, @warning)), inspect(extra)
        assert Enum.any?(warnings, &(&1 =~ ".claude/settings.json"))
      end
    end

    test "but not with a directory set, for the daemon, ChatGPT or a cloud routine",
         %{board: board} do
      for extra <- [
            %{"scenario" => "loop", "cwd" => "/srv/app"},
            %{"scenario" => "daemon"},
            %{"scenario" => "chatgpt"},
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
      assert answers(%{"cwd" => ""})["cwd"] == ""
      assert answers(%{"cwd" => "/srv/app"})["cwd"] == "/srv/app"
    end

    test "the default directory warns like a blank one; a project folder doesn't", %{board: board} do
      for extra <- [%{"scenario" => "loop"}, %{"scenario" => "cloud", "where" => "desktop"}] do
        warnings = gen(board, extra).warnings

        assert Enum.any?(warnings, &(&1 =~ "the default, so the project's own commands")),
               inspect(extra)
      end

      refute Enum.any?(
               gen(board, %{"scenario" => "loop", "cwd" => "/srv/app"}).warnings,
               &(&1 =~ "the default")
             )
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
      rule = List.last(gen(board, %{"scenario" => "loop", "pool" => "dev"}).steps)
      assert rule.id == :rule

      assert rule.text ==
               "Nothing is sent until a rule sends it: add one under Automations with the " <>
                 "Send cards to a runner preset (pool dev, kind claude)."

      assert {rule.pool, rule.kind} == {"dev", "claude"}
      refute rule.text =~ "coding agent"
    end
  end

  describe "changeset_message/1 (#3052)" do
    test "fills each placeholder from the error's opts" do
      changeset =
        {%{}, %{name: :string, pool: :string}}
        |> Ecto.Changeset.cast(%{name: String.duplicate("n", 9), pool: ""}, [:name, :pool])
        |> Ecto.Changeset.validate_length(:name, max: 5)
        # An opt with no placeholder of its own (an enum of atoms) isn't
        # turned to text, which would raise.
        |> Ecto.Changeset.validate_inclusion(:name, [:a, :b])

      message = Setup.changeset_message(changeset)

      assert message == "name is invalid, should be at most 5 character(s)"
      refute message =~ "%{"
    end
  end
end

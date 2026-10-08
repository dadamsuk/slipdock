defmodule SlipdockWeb.RunnersLiveTest do
  # "Connect a runner" in the Automations panel: each scenario gives its own
  # steps, a runner's token is shown once, the rule it asks for appears, and
  # runners can be set up again, given a new token or revoked.
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Automations, Runners}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Launch"}, owner: user)
    %{board: board}
  end

  defp open(conn, board) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
    view |> element("#connect-runner") |> render_click()
    view
  end

  defp choose(view, params), do: view |> form("#runner-wizard", wizard: params) |> render_change()

  defp submit(view, params), do: view |> form("#runner-wizard", wizard: params) |> render_submit()

  test "the panel offers it, and lists no runners yet", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
    assert has_element?(view, "#board-runners", "Runners")
    assert has_element?(view, "#connect-runner")
    refute has_element?(view, "#runner-list")
  end

  test "a Linux machine: the runner is made and its token shown once", %{conn: conn, board: board} do
    view = open(conn, board)
    assert has_element?(view, "#runner-wizard", "costs nothing while it waits")

    html = submit(view, %{"scenario" => "server", "pool" => "dev", "name" => "laptop"})

    assert [runner] = Runners.list_runners(board)
    assert runner.name == "laptop"
    assert html =~ "shown this once"
    assert has_element?(view, "#runner-command", "/runner/install.sh")
    assert has_element?(view, "#runner-command", "--pool dev")
    assert has_element?(view, "#runner-command-copy")
    view |> element("#reveal-config") |> render_click()
    assert has_element?(view, "#runner-config", "job_claude()")
    assert has_element?(view, "#runner-#{runner.id}", "laptop")
    [token] = Regex.run(~r/sdr_[A-Za-z0-9_-]{20,}/, html)
    assert Runners.authenticate(token).id == runner.id

    # Set up again later: the same steps, the token left out, a new one on request.
    view |> element("#runner-#{runner.id} button", "Setup") |> render_click()
    refute render(view) =~ token
    refute has_element?(view, "#runner-command", "--token")
    assert has_element?(view, "#runner-setup", "keeps the one in its config")

    html = view |> element("#runner-setup button", "Make a new token") |> render_click()
    [new] = Regex.run(~r/sdr_[A-Za-z0-9_-]{20,}/, html)
    refute new == token
    assert Runners.authenticate(token) == nil
  end

  test "each scenario shows its own options and steps", %{conn: conn, board: board} do
    view = open(conn, board)

    choose(view, %{"scenario" => "windows"})
    assert has_element?(view, "#runner-wizard", "Longest a job may run")
    refute has_element?(view, "#runner-wizard select[name='wizard[service]']")

    choose(view, %{"scenario" => "loop"})
    refute has_element?(view, "#runner-wizard input[name='wizard[name]']")
    assert has_element?(view, "#runner-wizard", "uses your Claude usage")
    submit(view, %{"scenario" => "loop", "pool" => "loop"})
    assert has_element?(view, "#runner-setup", "/loop /slipdock-loop against")
    assert Runners.list_runners(board) == []

    view |> element("#connect-runner") |> render_click()
    choose(view, %{"scenario" => "cloud"})
    choose(view, %{"scenario" => "cloud", "where" => "cloud"})
    assert has_element?(view, "#runner-wizard", "must be reachable from the internet")
    assert has_element?(view, "#runner-wizard input[name='wizard[repo]']")
    submit(view, %{"scenario" => "cloud", "where" => "cloud", "repo" => "me/app"})
    assert has_element?(view, "#runner-setup", "claude.ai/code/routines")
    assert has_element?(view, "#runner-setup", "claim_job")
  end

  test "a custom agent shows a command field", %{conn: conn, board: board} do
    view = open(conn, board)
    refute has_element?(view, "input[name='wizard[command]']")
    choose(view, %{"scenario" => "server", "agent" => "custom"})
    assert has_element?(view, "input[name='wizard[command]']")
    assert has_element?(view, "#runner-wizard", "a custom agent needs the command")
  end

  test "picking a list adds the rule that sends it cards", %{conn: conn, board: board} do
    [_, doing | _] = board.columns
    view = open(conn, board)
    submit(view, %{"scenario" => "server", "pool" => "dev", "send" => "column:#{doing.name}"})

    assert [rule] = Automations.list_rules(board.id)
    assert rule.spec["trigger"]["column"] == doing.name
    assert has_element?(view, "#runner-setup", "the rule “#{rule.name}” sends cards")
    assert render(view) =~ rule.name
  end

  test "picking a list's top card adds a rule that sends one at a time", %{
    conn: conn,
    board: board
  } do
    [_, todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "First"})
    card_fixture(todo, %{"title" => "Second"})
    view = open(conn, board)
    assert has_element?(view, "option[value='top:#{todo.name}']", "the top card of #{todo.name}")
    submit(view, %{"scenario" => "server", "pool" => "dev", "send" => "top:#{todo.name}"})

    assert [rule] = Automations.list_rules(board.id)

    assert rule.spec["trigger"] == %{
             "type" => "list_top",
             "column" => todo.name,
             "unassigned" => true
           }

    assert [%Runners.Job{card_id: card_id}] = Runners.list_jobs(board, status: "open")
    assert card_id == card.id
    assert [%{"wait_while_doing" => true}] = rule.spec["actions"]
  end

  test "the top-card choice offers to wait while anything is in progress, ticked", %{
    conn: conn,
    board: board
  } do
    view = open(conn, board)
    refute has_element?(view, "input[type=checkbox][name='wizard[wait]']")
    choose(view, %{"scenario" => "server", "pool" => "dev", "send" => "top:To Do"})
    assert has_element?(view, "input[type=checkbox][name='wizard[wait]'][checked]")

    submit(view, %{"scenario" => "server", "pool" => "dev", "send" => "top:To Do", "wait" => "no"})

    assert [rule] = Automations.list_rules(board.id)
    refute Map.has_key?(hd(rule.spec["actions"]), "wait_while_doing")
  end

  test "the top-card rule asks how many times to put back a card left in progress", %{
    conn: conn,
    board: board
  } do
    view = open(conn, board)
    refute has_element?(view, "input[name='wizard[requeue]']")
    choose(view, %{"scenario" => "server", "pool" => "dev", "send" => "top:To Do"})
    assert has_element?(view, "input[type=number][name='wizard[requeue]'][value='1']")

    submit(view, %{
      "scenario" => "server",
      "pool" => "dev",
      "send" => "top:To Do",
      "requeue" => "2"
    })

    assert [rule] = Automations.list_rules(board.id)
    assert hd(rule.spec["actions"])["requeue_stuck"] == 2
  end

  test "offers, unticked, to tell you when a job times out or a card is given up", %{
    conn: conn,
    board: board
  } do
    view = open(conn, board)
    assert has_element?(view, "input[type=checkbox][name='wizard[alert]']")
    refute has_element?(view, "input[type=checkbox][name='wizard[alert]'][checked]")

    submit(view, %{"scenario" => "server", "pool" => "dev", "alert" => "yes"})

    assert [rule] = Automations.list_rules(board.id)

    assert rule.spec["trigger"] == %{
             "type" => "job_finished",
             "pool" => "dev",
             "outcome" => ["timeout", "requeued", "gave_up"]
           }
  end

  test "Advanced → Hooks has a prompt for Claude to write the hook, for the runner chosen", %{
    conn: conn,
    board: board
  } do
    view = open(conn, board)
    choose(view, %{"scenario" => "server", "pool" => "dev"})
    assert has_element?(view, "#wizard-hook-prompt summary", "Have Claude write this hook")
    assert has_element?(view, "#hook-prompt", "$SLIPDOCK_STATUS")
    assert has_element?(view, "#hook-prompt", "/runner/examples/after-job-hook.sh")
    assert has_element?(view, "#hook-prompt-copy")

    choose(view, %{"scenario" => "windows", "pool" => "dev"})
    assert has_element?(view, "#hook-prompt", "$env:SLIPDOCK_STATUS")

    choose(view, %{"scenario" => "loop", "pool" => "dev"})
    refute has_element?(view, "#wizard-hook-prompt")
  end

  test "an answer it can't use is said, and nothing is made", %{conn: conn, board: board} do
    view = open(conn, board)
    choose(view, %{"scenario" => "server", "pool" => "My Pool"})
    assert has_element?(view, "#runner-wizard", "pool must be lower case")
    assert has_element?(view, "#runner-wizard button[type=submit][disabled]")
    assert Runners.list_runners(board) == []
  end

  test "revoking a runner ends its token", %{conn: conn, board: board} do
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
    view |> element("#runner-#{runner.id} button[title=Revoke]") |> render_click()
    refute has_element?(view, "#runner-#{runner.id}")
    assert Runners.authenticate(token) == nil
  end

  test "somebody the board is shared with sees no runners and can't make one", %{board: board} do
    {:ok, _runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    other = user_fixture("w#{System.unique_integer([:positive])}@example.com")
    share_fixture(board, [other], "write")

    case live(log_in_user(build_conn(), other), ~p"/boards/#{board}/automations") do
      {:ok, view, _} ->
        refute has_element?(view, "#runner-list")
        refute has_element?(view, "#connect-runner")

        render_click(with_target(view, "#board-runners"), "open_wizard", %{})
        refute has_element?(view, "#runner-wizard")

      {:error, _redirect} ->
        :ok
    end
  end

  test "changing a runner's answers shows what changes on the machine", %{
    conn: conn,
    board: board
  } do
    view = open(conn, board)
    submit(view, %{"scenario" => "server", "pool" => "dev", "name" => "laptop"})
    [runner] = Runners.list_runners(board)

    view |> element("#runner-#{runner.id} button", "Setup") |> render_click()
    refute has_element?(view, "#runner-setup button", "Change the answers")
    view |> element("#runner-setup button", "Change Settings") |> render_click()
    assert has_element?(view, "#runner-wizard", "Changing “laptop”")
    refute has_element?(view, "#runner-wizard input[name='wizard[pool]']")

    view
    |> form("#runner-wizard",
      wizard: %{"instructions" => "Never push to main.", "before_job" => "git pull"}
    )
    |> render_submit()

    assert has_element?(
             view,
             "#runner-diff span.text-success",
             "--instructions 'Never push to main.'"
           )

    assert has_element?(view, "#runner-diff span.text-success", "git pull")

    assert Runners.list_runners(board) |> hd() |> Map.get(:settings) |> Map.get("before_job") ==
             "git pull"
  end

  test "hooks are greyed out for a cloud routine, with the reason", %{conn: conn, board: board} do
    view = open(conn, board)
    assert has_element?(view, "input[name='wizard[before_job]']")
    refute has_element?(view, "#hooks-off")

    choose(view, %{"scenario" => "cloud"})
    choose(view, %{"scenario" => "cloud", "where" => "cloud"})
    assert has_element?(view, "#hooks-off", "runs on Anthropic's machines")
    assert has_element?(view, "fieldset[disabled] input[name='wizard[before_job]']")

    choose(view, %{"scenario" => "loop"})
    assert has_element?(view, "select[name='wizard[hooks]']")
  end

  test "a claude runner may use the Slipdock tools unless it's unticked", %{
    conn: conn,
    board: board
  } do
    view = open(conn, board)

    assert has_element?(view, "#wizard-slipdock-tools", "Let it use the Slipdock tools")
    assert has_element?(view, "#wizard-slipdock-tools", "no access to the board")
    assert has_element?(view, "#wizard-slipdock-tools input[type=checkbox][checked]")

    assert has_element?(
             view,
             "input[name='wizard[mcp_servers]'][value='claude_ai_Slipdock, slipdock']"
           )

    # Unticked: the server's name goes, and nothing is allowed.
    choose(view, %{"slipdock_tools" => "false"})
    refute has_element?(view, "#wizard-slipdock-tools input[type=checkbox][checked]")
    refute has_element?(view, "input[name='wizard[mcp_servers]']")

    # Not offered for codex.
    choose(view, %{"agent" => "codex"})
    refute has_element?(view, "#wizard-slipdock-tools")

    choose(view, %{"agent" => "claude"})
    choose(view, %{"slipdock_tools" => "true"})
    submit(view, %{"pool" => "dev", "mcp_servers" => "slipdock", "cwd" => "/srv/app"})
    assert has_element?(view, "#runner-command", "--mcp-servers 'slipdock'")
    view |> element("#reveal-config") |> render_click()
    assert has_element?(view, "#runner-config", "ALLOWED_TOOLS='mcp__slipdock'")
    assert [runner] = Runners.list_runners(board)
    assert runner.settings["slipdock_tools"] == true
  end

  test "a bad server name is said, and nothing is made", %{conn: conn, board: board} do
    view = open(conn, board)
    choose(view, %{"mcp_servers" => "not a name!"})
    assert has_element?(view, "#runner-wizard", "an MCP server's name is letters")
  end

  test "a claude runner with no working directory is warned", %{conn: conn, board: board} do
    view = open(conn, board)
    choose(view, %{"cwd" => ""})
    assert has_element?(view, "#runner-wizard", "No working directory: jobs start in your home")

    choose(view, %{"cwd" => "/srv/app"})
    refute has_element?(view, "#runner-wizard", "No working directory")
  end

  describe "the wizard and its steps (#493)" do
    test "the Runners text, and Connect a runner opens a dialog of its own", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")

      assert has_element?(
               view,
               "#board-runners",
               "Send cards to a coding agent or LLM on your own machine, or to Claude on a schedule"
             )

      refute has_element?(view, "#runner-dialog")
      view |> element("#connect-runner") |> render_click()
      assert has_element?(view, "dialog#runner-dialog[phx-hook=ModalDialog] #runner-wizard")
      assert has_element?(view, "#runner-dialog[data-close-event=close_dialog]")
      # The panel underneath stays open.
      assert has_element?(view, "#automations-modal #rule-presets")

      # Escape or a click outside closes it, and nothing is made.
      view |> element("#runner-dialog") |> render_hook("close_dialog", %{})
      refute has_element?(view, "#runner-dialog")
      assert has_element?(view, "#automations-modal")
      assert Runners.list_runners(board) == []
    end

    test "name is optional, the directory /tmp, Hooks under Advanced", %{conn: conn, board: board} do
      view = open(conn, board)

      assert has_element?(view, "#runner-wizard label", "(optional)")
      assert has_element?(view, "input[name='wizard[cwd]'][value='/tmp']")
      assert has_element?(view, "details#wizard-advanced summary", "Advanced")

      assert has_element?(
               view,
               "details#wizard-advanced #wizard-hooks input[name='wizard[before_job]']"
             )

      refute has_element?(view, "details#wizard-advanced[open]")

      # Windows gets its own scratch directory; one typed in stays put.
      html = choose(view, %{"scenario" => "windows"})
      assert html =~ ~S(name="wizard[cwd]" value="~\AppData\Local\Temp")
      choose(view, %{"scenario" => "server"})
      assert has_element?(view, "input[name='wizard[cwd]'][value='/tmp']")
      choose(view, %{"cwd" => "/srv/app"})
      choose(view, %{"scenario" => "windows"})
      assert has_element?(view, "input[name='wizard[cwd]'][value='/srv/app']")
    end

    test "the hooks under Advanced still submit, and /tmp reaches the config", %{
      conn: conn,
      board: board
    } do
      view = open(conn, board)
      assert has_element?(view, "#runner-wizard", "the default, so the project's own commands")
      submit(view, %{"pool" => "dev", "before_job" => "git pull --ff-only"})

      assert [runner] = Runners.list_runners(board)
      assert runner.settings["before_job"] == "git pull --ff-only"
      assert runner.settings["cwd"] == "/tmp"
      assert has_element?(view, "#runner-command", "--cwd '/tmp'")
      assert has_element?(view, "#runner-command", "--before-job 'git pull --ff-only'")
    end

    test "the steps: no numbers, the script and config behind links, then Verify", %{
      conn: conn,
      board: board
    } do
      view = open(conn, board)
      html = submit(view, %{"pool" => "dev"})

      refute html =~ ~r/>\s*1\.\s*</
      refute has_element?(view, "#runner-setup ol")
      assert has_element?(view, "#runner-setup", "On the machine, run:")
      assert has_element?(view, "#runner-command-copy")
      assert has_element?(view, "#runner-installs", "That command will install")
      assert has_element?(view, "#reveal-script", "a runner script")
      assert has_element?(view, "#reveal-config", "a config file")
      refute has_element?(view, "#runner-setup", "Or check it first")
      # The token note sits above the command.
      assert html =~ ~r/shown this once.*id="runner-command"/s

      refute has_element?(view, "#runner-script")
      view |> element("#reveal-script") |> render_click()
      assert has_element?(view, "#runner-script", "SLIPDOCK_RUNNER_TOKEN")
      assert has_element?(view, "#runner-script-copy")

      refute has_element?(view, "#runner-config")
      view |> element("#reveal-config") |> render_click()
      assert has_element?(view, "#runner-config", "job_claude()")
      assert has_element?(view, "#runner-config-copy")
      assert has_element?(view, "#runner-setup", "~/.config/slipdock-runner/config")

      refute has_element?(view, "#runner-checksums")
      view |> element("#reveal-verify", "Verify the script") |> render_click()
      assert has_element?(view, "#runner-checksums", "/runner/SHA256SUMS")
      assert has_element?(view, "#runner-setup", "Or check it first")

      # Clicked again, a link hides what it showed.
      view |> element("#reveal-script") |> render_click()
      refute has_element?(view, "#runner-script")

      assert has_element?(
               view,
               "#runner-rule",
               "Nothing is sent until a rule sends it: add one under"
             )

      assert has_element?(view, "#runner-rule", "with the Send cards to a runner preset")
      view |> element("#runner-to-automations", "Automations") |> render_click()
      refute has_element?(view, "#runner-dialog")
      assert has_element?(view, "#rule-preset-send_to_runner", "Send cards to a runner")
    end

    test "a rule the wizard made is named instead", %{conn: conn, board: board} do
      view = open(conn, board)
      submit(view, %{"pool" => "dev", "send" => "column:To Do"})
      assert has_element?(view, "#runner-rule", "sends cards")
      refute has_element?(view, "#runner-to-automations")
    end

    test "on Windows, the script is the PowerShell runner and Verify its checksums", %{
      conn: conn,
      board: board
    } do
      view = open(conn, board)
      choose(view, %{"scenario" => "windows"})
      submit(view, %{"scenario" => "windows", "pool" => "win"})

      view |> element("#reveal-script") |> render_click()
      assert has_element?(view, "#runner-script", "$RunnerToken")
      view |> element("#reveal-config") |> render_click()
      assert has_element?(view, "#runner-setup", "config.ps1")
      view |> element("#reveal-verify") |> render_click()
      assert has_element?(view, "#runner-checksums", "-OutFile install.ps1")
    end

    test "a Claude scenario's steps are a plain list, unnumbered", %{conn: conn, board: board} do
      view = open(conn, board)
      choose(view, %{"scenario" => "loop"})
      html = submit(view, %{"scenario" => "loop", "pool" => "loop"})
      assert has_element?(view, "#runner-step-4", "/loop /slipdock-loop against")
      refute has_element?(view, "#runner-installs")
      refute html =~ ~r/>\s*1\.\s*</
    end

    test "the runner preset shows only once the board has a runner", %{
      conn: conn,
      board: board
    } do
      view = open(conn, board)
      refute has_element?(view, "#rule-preset-send_to_runner")
      refute render(view) =~ "coding agent\""

      submit(view, %{"pool" => "dev"})
      assert has_element?(view, "#rule-preset-send_to_runner", "Send cards to a runner")

      [runner] = Runners.list_runners(board)
      view |> element("#runner-#{runner.id} button[title=Revoke]") |> render_click()
      refute has_element?(view, "#rule-preset-send_to_runner")
    end
  end
end

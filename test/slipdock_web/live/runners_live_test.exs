defmodule SlipdockWeb.RunnersLiveTest do
  # "Connect a runner" in the Automations panel: each scenario gives its own
  # steps and the rule it asks for appears. The shell and Windows scenarios
  # were retired (#2582): a runner with a token of its own is one of theirs,
  # and its setup is the move onto a machine; it can still be given a new
  # token or revoked.
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Automations, Runners}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Launch"}, owner: user)
    %{board: board}
  end

  # The wizard opens on the daemon (#2572); these tests start from the
  # /loop scenario, which has every option the wizard still asks.
  defp open(conn, board) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
    view |> element("#connect-runner") |> render_click()
    choose(view, %{"scenario" => "loop"})
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

  # The scripts were retired (#2582): no shell or Windows scenario, and none
  # of the options only they had.
  test "the wizard offers no shell or Windows scenario", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
    html = view |> element("#connect-runner") |> render_click()

    radios =
      ~r/name="wizard\[scenario\]" value="([a-z]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()

    assert radios == ~w(daemon loop cloud chatgpt)
    refute html =~ "Linux / macOS machine"
    refute html =~ "Windows machine"

    for scenario <- ~w(daemon loop cloud chatgpt) do
      html = choose(view, %{"scenario" => scenario})

      for name <- ~w(name agent command timeout service worktree self_update slipdock_tools
                     mcp_servers),
          do: refute(html =~ ~s(name="wizard[#{name}]"), "#{scenario}: #{name}")

      refute has_element?(view, "#wizard-hook-prompt")
      refute html =~ "Keep the runner current"
      refute html =~ "/runner/"
      refute has_element?(view, "#runner-wizard button[type=submit]", "Make the runner")
    end
  end

  test "a runner with a token of its own shows the steps to move onto a machine", %{
    conn: conn,
    board: board
  } do
    {:ok, runner, token} =
      Runners.create_runner(board, %{
        "name" => "laptop",
        "pool" => "dev",
        "settings" => %{"scenario" => "server", "self_update" => true}
      })

    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
    refute has_element?(view, "#runner-#{runner.id} button", "Setup")
    refute has_element?(view, "#runner-#{runner.id}-script")
    view |> element("#runner-#{runner.id}-move", "Move to a machine") |> render_click()

    assert has_element?(view, "#runner-setup", "A retired shell runner — laptop")
    assert has_element?(view, "#runner-setup", "no longer serves")
    assert has_element?(view, "#runner-setup", "--scenario daemon --pool dev")
    assert has_element?(view, "#runner-setup", "systemctl --user disable --now slipdock-runner")
    refute has_element?(view, "#runner-setup", "/runner/install.sh")
    refute has_element?(view, "#runner-setup button", "Change Settings")

    # Its token can still be replaced, shown once, for its config by hand.
    html = view |> element("#runner-setup button", "Make a new token") |> render_click()
    [new] = Regex.run(~r/sdr_[A-Za-z0-9_-]{20,}/, html)
    refute new == token
    assert Runners.authenticate(token) == nil
    assert Runners.authenticate(new).id == runner.id
    assert has_element?(view, "#runner-setup", "shown this once")
  end

  test "each scenario shows its own options and steps", %{conn: conn, board: board} do
    view = open(conn, board)

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

  describe "ChatGPT (#522)" do
    test "its own options: no directory, permission mode or agent; the connector and prompt",
         %{conn: conn, board: board} do
      view = open(conn, board)
      choose(view, %{"scenario" => "chatgpt"})

      assert has_element?(view, "#runner-wizard label", "ChatGPT")
      refute has_element?(view, "#runner-wizard input[name='wizard[cwd]']")
      refute has_element?(view, "#runner-wizard select[name='wizard[permission_mode]']")
      refute has_element?(view, "#runner-wizard select[name='wizard[agent]']")
      refute has_element?(view, "#runner-wizard input[name='wizard[name]']")
      assert has_element?(view, "#runner-wizard", "uses your ChatGPT usage")
      assert has_element?(view, "#runner-wizard", "must be reachable from the internet")

      submit(view, %{"scenario" => "chatgpt", "pool" => "writing"})
      assert has_element?(view, "#runner-setup", "Settings → Apps & Connectors")
      assert has_element?(view, "#runner-setup", ~s(claim_job with board))
      assert has_element?(view, "#runner-setup", "You have no repository, shell or tests")
      assert Runners.list_runners(board) == []
    end

    test "commit and push are greyed out, and switching to it unticks them", %{
      conn: conn,
      board: board
    } do
      view = open(conn, board)
      choose(view, %{"scenario" => "loop", "commit" => "true"})
      choose(view, %{"scenario" => "loop", "commit" => "true", "push" => "true"})
      assert has_element?(view, "#wizard-commit[checked]")

      choose(view, %{"scenario" => "chatgpt", "commit" => "true", "push" => "true"})
      assert has_element?(view, "#wizard-commit[disabled]")
      assert has_element?(view, "#wizard-push[disabled]")
      refute has_element?(view, "#wizard-commit[checked]")
      refute has_element?(view, "#wizard-push[checked]")
      refute render(view) =~ "no repository to commit to"
      # The others stay free to tick.
      refute has_element?(view, "#wizard-complete[disabled]")
    end

    test "hooks are greyed out, saying ChatGPT isn't your machine", %{conn: conn, board: board} do
      view = open(conn, board)
      choose(view, %{"scenario" => "chatgpt"})
      assert has_element?(view, "#hooks-off", "ChatGPT runs on OpenAI's machines")
      assert has_element?(view, "fieldset[disabled] input[name='wizard[before_job]']")
    end
  end

  test "picking a list adds the rule that sends it cards", %{conn: conn, board: board} do
    [_, doing | _] = board.columns
    view = open(conn, board)
    submit(view, %{"scenario" => "loop", "pool" => "dev", "send" => "column:#{doing.name}"})

    assert [rule] = Automations.list_rules(board.id)
    assert rule.spec["trigger"]["column"] == doing.name
    assert has_element?(view, "#runner-setup", "the rule “#{rule.name}” sends cards")
    assert render(view) =~ rule.name
  end

  test "choosing no list again selects \"None yet\"", %{conn: conn, board: board} do
    [_, todo | _] = board.columns
    view = open(conn, board)
    choose(view, %{"scenario" => "loop", "pool" => "dev", "send" => "top:#{todo.name}"})
    assert has_element?(view, "option[value='top:#{todo.name}'][selected]")

    choose(view, %{"scenario" => "loop", "pool" => "dev", "send" => ""})

    assert has_element?(
             view,
             "select[name='wizard[send]'] option[value=''][selected]",
             "None yet"
           )

    refute has_element?(view, "option[value='top:#{todo.name}'][selected]")
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
    submit(view, %{"scenario" => "loop", "pool" => "dev", "send" => "top:#{todo.name}"})

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
    choose(view, %{"scenario" => "loop", "pool" => "dev", "send" => "top:To Do"})
    assert has_element?(view, "input[type=checkbox][name='wizard[wait]'][checked]")

    submit(view, %{"scenario" => "loop", "pool" => "dev", "send" => "top:To Do", "wait" => "no"})

    assert [rule] = Automations.list_rules(board.id)
    refute Map.has_key?(hd(rule.spec["actions"]), "wait_while_doing")
  end

  test "the top-card rule asks how many times to put back a card left in progress", %{
    conn: conn,
    board: board
  } do
    view = open(conn, board)
    refute has_element?(view, "input[name='wizard[requeue]']")
    choose(view, %{"scenario" => "loop", "pool" => "dev", "send" => "top:To Do"})
    assert has_element?(view, "input[type=number][name='wizard[requeue]'][value='1']")

    submit(view, %{
      "scenario" => "loop",
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

    submit(view, %{"scenario" => "loop", "pool" => "dev", "alert" => "yes"})

    assert [rule] = Automations.list_rules(board.id)

    assert rule.spec["trigger"] == %{
             "type" => "job_finished",
             "pool" => "dev",
             "outcome" => ["timeout", "requeued", "gave_up"]
           }
  end

  test "an answer it can't use is said, and nothing is made", %{conn: conn, board: board} do
    view = open(conn, board)
    choose(view, %{"scenario" => "loop", "pool" => "My Pool"})
    assert has_element?(view, "#runner-wizard", "pool must be lower case")
    assert has_element?(view, "#runner-wizard button[type=submit][disabled]")
    assert Runners.list_runners(board) == []
  end

  describe "clicking a runner shows what is known about it (#526)" do
    test "who made it, the job it holds, its job counts, latest jobs and rules", ctx do
      %{conn: conn, board: board, user: user} = ctx
      [todo | _] = board.columns

      {:ok, runner, _} =
        Runners.create_runner(
          board,
          %{
            "name" => "box",
            "pool" => "dev",
            "settings" => %{"scenario" => "loop", "cwd" => "~/src"}
          },
          user
        )

      done_card = card_fixture(todo, %{"title" => "Finished one"})
      busy_card = card_fixture(todo, %{"title" => "Busy one"})
      {:ok, done_job} = Runners.queue(done_card, %{pool: "dev", kind: "claude", prompt: "x"})
      Runners.claim(runner)
      {:ok, _} = Runners.finish(runner, done_job.id, %{exit: "0"})
      {:ok, busy_job} = Runners.queue(busy_card, %{pool: "dev", kind: "claude", prompt: "x"})
      Runners.claim(runner)

      rule_fixture(
        board,
        %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "runner", "pool" => "dev"}]
        },
        %{"name" => "Feeds dev"}
      )

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
      refute has_element?(view, "#runner-details-#{runner.id}")

      view |> element("#show-runner-#{runner.id}") |> render_click()
      details = "#runner-details-#{runner.id}"
      assert has_element?(view, details, "Runner with a token of its own")
      # Its saved scenario was retired (#2582), so it isn't named.
      assert has_element?(view, details, "a retired shell runner, to move onto a machine")
      refute has_element?(view, details, "Linux / macOS machine")
      assert has_element?(view, details, "~/src")
      assert has_element?(view, details, "by #{user.name || user.email}")
      assert has_element?(view, "#runner-now-#{runner.id}", "job ##{busy_job.id}")
      assert has_element?(view, "#runner-now-#{runner.id}", "Busy one")
      assert has_element?(view, "#runner-job-counts-#{runner.id}", "1 claimed, 1 done")
      assert has_element?(view, "#runner-jobs-#{runner.id}", "Finished one")

      assert has_element?(
               view,
               "#runner-jobs-#{runner.id} a[href='/boards/#{board.id}/cards/#{done_card.id}']"
             )

      assert has_element?(view, details, "Feeds dev")

      # Clicking again closes it.
      view |> element("#show-runner-#{runner.id}") |> render_click()
      refute has_element?(view, details)
    end

    test "an idle runner with no jobs or rules says so", %{conn: conn, board: board} do
      {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
      view |> element("#show-runner-#{runner.id}") |> render_click()

      assert has_element?(view, "#runner-now-#{runner.id}", "idle")
      assert has_element?(view, "#runner-details-#{runner.id}", "never")
      assert has_element?(view, "#runner-details-#{runner.id}", "no enabled rule sends cards")
      refute has_element?(view, "#runner-jobs-#{runner.id}")
    end

    test "a Claude session's runner names its API token", %{conn: conn, board: board, user: user} do
      {_token, api_token} = Slipdock.Accounts.create_api_token(user, "desktop")
      {:ok, runner} = Runners.session_runner(board, "loop", api_token, user)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
      view |> element("#show-runner-#{runner.id}") |> render_click()

      assert has_element?(view, "#runner-details-#{runner.id}", "Claude session")
      assert has_element?(view, "#runner-details-#{runner.id}", "desktop")
    end

    test "a runner revoked while open closes its details; a gone one is said", ctx do
      %{conn: conn, board: board} = ctx
      {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
      view |> element("#show-runner-#{runner.id}") |> render_click()
      view |> element("#runner-#{runner.id} button[title=Revoke]") |> render_click()
      refute has_element?(view, "#runner-details-#{runner.id}")

      render_click(with_target(view, "#board-runners"), "show_runner", %{"id" => runner.id})
      assert render(view) =~ "That runner is gone."
    end
  end

  test "revoking a runner ends its token", %{conn: conn, board: board} do
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
    view |> element("#runner-#{runner.id} button[title=Revoke]") |> render_click()
    refute has_element?(view, "#runner-#{runner.id}")
    assert Runners.authenticate(token) == nil
  end

  test "somebody the board is shared with sees no runners and can't make one", %{board: board} do
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    other = user_fixture("w#{System.unique_integer([:positive])}@example.com")
    share_fixture(board, [other], "write")

    case live(log_in_user(build_conn(), other), ~p"/boards/#{board}/automations") do
      {:ok, view, _} ->
        refute has_element?(view, "#runner-list")
        refute has_element?(view, "#connect-runner")

        render_click(with_target(view, "#board-runners"), "open_wizard", %{})
        refute has_element?(view, "#runner-wizard")

        render_click(with_target(view, "#board-runners"), "show_runner", %{"id" => runner.id})
        refute has_element?(view, "#runner-details-#{runner.id}")

      {:error, _redirect} ->
        :ok
    end
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
               "Send cards to a coding agent or LLM on your own machine, to Claude on a schedule, or to ChatGPT"
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

    test "the directory /tmp, Hooks under Advanced", %{conn: conn, board: board} do
      view = open(conn, board)

      assert has_element?(view, "input[name='wizard[cwd]'][value='/tmp']")
      assert has_element?(view, "details#wizard-advanced summary", "Advanced")

      assert has_element?(
               view,
               "details#wizard-advanced #wizard-hooks input[name='wizard[before_job]']"
             )

      refute has_element?(view, "details#wizard-advanced[open]")

      # One typed in stays put across scenarios.
      choose(view, %{"cwd" => "/srv/app"})
      choose(view, %{"scenario" => "cloud", "cwd" => "/srv/app"})
      assert has_element?(view, "input[name='wizard[cwd]'][value='/srv/app']")
    end

    test "a rule the wizard made is named instead", %{conn: conn, board: board} do
      view = open(conn, board)
      submit(view, %{"pool" => "dev", "send" => "column:To Do"})
      assert has_element?(view, "#runner-setup", "sends cards")
      refute has_element?(view, "#runner-to-automations")
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
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
      refute has_element?(view, "#rule-preset-send_to_runner")
      refute render(view) =~ "coding agent\""

      {:ok, runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
      assert has_element?(view, "#rule-preset-send_to_runner", "Send cards to a runner")

      view |> element("#runner-#{runner.id} button[title=Revoke]") |> render_click()
      refute has_element?(view, "#rule-preset-send_to_runner")
    end

    test "the runner preset takes a prompt in a text area, and the rule carries it (#1156)", %{
      conn: conn,
      board: board
    } do
      {:ok, _runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")

      view |> element("#rule-preset-send_to_runner") |> render_click()
      assert has_element?(view, "#rule-preset-form textarea[name='preset[prompt]']")

      view
      |> form("#rule-preset-form", %{
        "preset" => %{
          "column" => "To Do",
          "pool" => "dev",
          "prompt" => "Triage {{card.title}} and say what it needs."
        }
      })
      |> render_submit()

      rule =
        board.id |> Slipdock.Automations.list_rules() |> Enum.find(&(&1.name =~ "Send To Do"))

      assert [%{"type" => "runner", "prompt" => "Triage {{card.title}} and say what it needs."}] =
               rule.spec["actions"]
    end
  end

  describe "a Claude scenario's runner before its first job (#511)" do
    test "the pool shows as waiting until a session takes a job", ctx do
      %{conn: conn, board: board, user: user} = ctx
      view = open(conn, board)
      submit(view, %{"scenario" => "loop", "pool" => "loop", "send" => "column:To Do"})
      assert Runners.list_runners(board) == []

      assert has_element?(view, "#waiting-pool-loop", "Waiting for a runner")
      assert has_element?(view, "#waiting-pool-loop", "first time it takes one")

      {_token, api_token} = Slipdock.Accounts.create_api_token(user, "session")
      {:ok, runner} = Runners.session_runner(board, "loop", api_token, user)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
      assert has_element?(view, "#runner-#{runner.id}")
      refute has_element?(view, "#waiting-pool-loop")
    end

    test "a pool with a runner, or only a paused rule, isn't waiting", ctx do
      %{conn: conn, board: board} = ctx
      {:ok, _runner, _} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})

      [_dev, paused] =
        for pool <- ["dev", "paused"] do
          {:ok, rule} =
            Automations.create_rule_from_preset(board, "send_to_runner", %{
              "column" => "To Do",
              "pool" => pool
            })

          rule
        end

      {:ok, _} = Automations.toggle_rule(paused)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
      assert has_element?(view, "#runner-list")
      refute has_element?(view, "[id^=waiting-pool-]")
    end
  end

  describe "what a job does to the card, in the wizard (#514)" do
    @toggle_ids ~w(in_progress commit push move_done complete percent_100)

    test "six checkboxes, unticked, for every scenario, and Nothing written by default", ctx do
      view = open(ctx.conn, ctx.board)

      for scenario <- ~w(loop cloud chatgpt) do
        choose(view, %{"scenario" => scenario})

        for id <- @toggle_ids do
          assert has_element?(view, "#wizard-#{id}[type=checkbox]"), "#{scenario}: #{id}"
          refute has_element?(view, "#wizard-#{id}[checked]"), "#{scenario}: #{id}"
        end

        assert has_element?(
                 view,
                 "select[name='wizard[verbosity]'] option[value=nothing][selected]"
               )
      end

      assert has_element?(view, "#wizard-toggles", "Move to In Progress when running")
      # A job never assigns the card (#2027): no box for it.
      refute has_element?(view, "#wizard-assign")
      refute has_element?(view, "#wizard-toggles", "Assign the card")
      assert has_element?(view, "#wizard-toggles", "Mark as 100% when done")
      refute has_element?(view, "#wizard-commit option")
    end

    test "push is greyed out until commit is ticked, and unticked with it", ctx do
      view = open(ctx.conn, ctx.board)
      choose(view, %{"scenario" => "loop"})
      assert has_element?(view, "#wizard-push[disabled]")

      choose(view, %{"scenario" => "loop", "commit" => "true"})
      refute has_element?(view, "#wizard-push[disabled]")

      choose(view, %{"scenario" => "loop", "commit" => "true", "push" => "true"})
      assert has_element?(view, "#wizard-push[checked]")

      # Unticking commit unticks push too, rather than showing an error.
      choose(view, %{"scenario" => "loop", "commit" => "false", "push" => "true"})
      assert has_element?(view, "#wizard-push[disabled]")
      refute has_element?(view, "#wizard-push[checked]")
      refute render(view) =~ "push needs commit"
    end

    test "ticked boxes reach the steps; unticked ones are said off", ctx do
      view = open(ctx.conn, ctx.board)
      choose(view, %{"scenario" => "loop", "commit" => "true"})

      submit(view, %{
        "scenario" => "loop",
        "in_progress" => "true",
        "commit" => "true",
        "push" => "true",
        "complete" => "true"
      })

      assert has_element?(
               view,
               "#runner-setup",
               "Move the card to the doing list when you start."
             )

      assert has_element?(
               view,
               "#runner-setup",
               "commit with the card id in the message and push"
             )

      assert has_element?(view, "#runner-setup", "Mark the card complete when you finish.")
      assert has_element?(view, "#runner-setup", "Don't assign the card to anyone:")
      assert has_element?(view, "#runner-setup", "Don't move the card to the done list.")
      assert has_element?(view, "#runner-setup", "Don't comment on the card at all")
    end
  end
end

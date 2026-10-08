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
    assert has_element?(view, "#runner-step-1", "/runner/install.sh")
    assert has_element?(view, "#runner-step-1", "--pool dev")
    assert has_element?(view, "#runner-step-1-copy")
    assert has_element?(view, "#runner-step-3", "job_claude()")
    assert has_element?(view, "#runner-#{runner.id}", "laptop")
    [token] = Regex.run(~r/sdr_[A-Za-z0-9_-]{20,}/, html)
    assert Runners.authenticate(token).id == runner.id

    # Set up again later: the same steps, the token left out, a new one on request.
    view |> element("#runner-#{runner.id} button", "Setup") |> render_click()
    refute render(view) =~ token
    refute has_element?(view, "#runner-step-1", "--token")
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
    view |> element("#runner-setup button", "Change the answers") |> render_click()
    assert has_element?(view, "#runner-wizard", "Changing “laptop”")
    refute has_element?(view, "#runner-wizard input[name='wizard[pool]']")

    view
    |> form("#runner-wizard",
      wizard: %{"instructions" => "Never push to main.", "before_job" => "git pull"}
    )
    |> render_submit()

    assert has_element?(view, "#runner-diff span.text-success", "--instructions 'Never push to main.'")
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
end

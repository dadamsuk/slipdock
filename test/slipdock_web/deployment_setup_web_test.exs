defmodule SlipdockWeb.DeploymentSetupWebTest do
  @moduledoc """
  "Track deployments" (#1134) through the API and the settings wizard: the
  same generator's text, the token issued once, the owner only, the worked
  examples served, and the wizard turning green when the first deploy
  arrives.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments}
  alias Slipdock.Deployments.Setup

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "Wizard"}, owner: user)
    %{conn: conn, json: put_req_header(conn, "accept", "application/json"), board: board}
  end

  test "GET writes the text without issuing anything", %{json: conn, board: board} do
    body =
      conn
      |> get(~p"/api/boards/#{board.code}/deployments/setup?ci=gitlab&environments=prod")
      |> json_response(200)

    assert body["text"] =~ Setup.token_placeholder()
    assert body["snippet"] =~ "--env prod"
    assert body["prompt"] =~ "slipdock deploy run"
    assert body["delivery_metrics"] == false

    {:ok, a} = Setup.normalise(%{"ci" => "gitlab", "environments" => "prod"})
    expected = Setup.generate(a, %{board: board, base_url: "http://www.example.com", token: nil})
    assert body["text"] == expected.text
    refute Deployments.token?(Boards.get_board!(board.id))
  end

  test "POST turns the switch on and shows a new token once", %{json: conn, board: board} do
    body =
      conn
      |> post(~p"/api/boards/#{board.code}/deployments/setup", %{"ci" => "github"})
      |> json_response(200)

    assert body["delivery_metrics"] == true
    [token] = Regex.run(~r/sdd_[A-Za-z0-9_-]+/, body["text"])
    assert Deployments.authenticate(token).id == board.id
  end

  test "bad answers are a 422 and change nothing", %{json: conn, board: board} do
    body =
      conn
      |> post(~p"/api/boards/#{board.code}/deployments/setup", %{"ci" => "jenkins"})
      |> json_response(422)

    assert body["error"] =~ "ci must be one of"
    refute Boards.get_board!(board.id).delivery_metrics
  end

  test "only the owner", %{board: board, user: user} do
    other = user_fixture("setup-other@example.com")
    {:ok, _} = Slipdock.Access.grant(board, other, "write", user)

    assert conn_as(other)
           |> put_req_header("accept", "application/json")
           |> post(~p"/api/boards/#{board.code}/deployments/setup", %{})
           |> json_response(403)

    refute Boards.get_board!(board.id).delivery_metrics
  end

  test "every worked example is served, and nothing else", %{conn: conn} do
    for name <- Setup.example_files() do
      body = conn |> get("/deploy/examples/#{name}") |> response(200)
      assert body =~ "slipdock" or body =~ "SLIPDOCK"
    end

    assert conn |> get("/deploy/examples/github-actions.yml") |> response(200) =~
             "fetch-depth: 0"

    assert conn |> get("/deploy/examples/nope.sh") |> response(404)
    assert conn |> get("/deploy/examples/..%2Fmix.exs") |> response(404)
  end

  test "the wizard: set up, the token, waiting, then green", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")
    assert has_element?(view, "#deploy-setup")
    refute has_element?(view, "#deploy-setup-result")

    view
    |> form("#deploy-setup-form", deploy: %{ci: "github", environments: "production"})
    |> render_submit(%{"do" => "setup"})

    assert has_element?(view, "#deploy-setup-result", "sdd_")
    assert has_element?(view, "#deploy-waiting")
    assert Boards.get_board!(board.id).delivery_metrics

    {:ok, _} =
      Deployments.start(Boards.get_board!(board.id), %{
        environment: "production",
        sha: "abcdef1234"
      })

    # The board page forwards the deploy to the panel with send_update, a
    # second message to itself: let it handle both before looking.
    _ = :sys.get_state(view.pid)
    _ = :sys.get_state(view.pid)
    assert render(view) =~ "First deploy arrived: abcdef1 to production"
    refute has_element?(view, "#deploy-waiting")
  end

  test "the wizard's prompt changes nothing", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/settings")

    view
    |> form("#deploy-setup-form", deploy: %{ci: "gitlab", environments: "production"})
    |> render_submit(%{"do" => "prompt"})

    assert has_element?(view, "#deploy-prompt", "GitLab CI")
    refute has_element?(view, "#deploy-setup-result")
    refute Boards.get_board!(board.id).delivery_metrics
  end
end

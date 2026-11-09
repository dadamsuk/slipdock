defmodule SlipdockWeb.RunnerScriptsRetiredTest do
  @moduledoc """
  The shell and PowerShell runners retired for the runner daemon (#2582,
  W-2544 §10): nothing under `/runner/` is served any more (410 Gone, saying
  where to go), the script-state code is gone from the runner protocol and
  its JSON, and a runner with a token of its own is given the steps to move
  onto a machine rather than an installer.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Machines, Repo, Runners}
  alias Slipdock.Runners.{MachineRunners, Setup}

  @old_sha String.duplicate("a", 64)

  setup %{user: user} do
    board = board_fixture(%{"name" => "Retired", "code" => unique_code()}, owner: user)
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "laptop", "pool" => "dev"})
    %{board: board, runner: runner, token: token}
  end

  defp runner_conn(token),
    do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  # The column stays (OPS-6: migrations are additive), so read it raw.
  defp version_column(runner) do
    %{rows: [[version]]} =
      Repo.query!("SELECT version FROM runners WHERE id = $1", [runner.id])

    version
  end

  describe "the paths the scripts were served at" do
    @paths ~w(/runner/install.sh /runner/install.ps1 /runner/slipdock-runner
              /runner/slipdock-runner.ps1 /runner/SHA256SUMS /runner/examples/passlog.sh
              /runner/examples/after-job-hook.sh /runner/anything/else)

    test "answer 410 Gone, as plain text, for anybody" do
      for path <- @paths do
        conn = get(build_conn(), path)
        assert conn.status == 410, path
        assert [type] = get_resp_header(conn, "content-type")
        assert type =~ "text/plain", path
      end
    end

    test "say where to go instead, in comment lines only, so a pipe into sh runs nothing" do
      body = build_conn() |> get("/runner/install.sh") |> response(410)

      assert body =~ "the shell and PowerShell runners were retired for the runner daemon (#2582)"
      assert body =~ "/account/machines"
      assert body =~ "docs/manual/machines.md"

      for line <- String.split(body, "\n", trim: true),
          do: assert(String.starts_with?(line, "# "), line)

      # And sh agrees: running it does nothing and succeeds.
      dir = Path.join(System.tmp_dir!(), "slipdock-gone-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      File.write!(Path.join(dir, "gone.sh"), body)
      assert {"", 0} = System.cmd("sh", ["gone.sh"], cd: dir, stderr_to_stdout: true)
      assert File.ls!(dir) == ["gone.sh"]
    end

    test "the checksums are gone too: nothing names a script's SHA-256" do
      body = build_conn() |> get("/runner/SHA256SUMS") |> response(410)
      refute body =~ ~r/[0-9a-f]{64}/
    end
  end

  describe "the runner protocol, without the script state" do
    test "a claim saying a script version is answered without X-Runner-Latest, and not kept",
         ctx do
      conn =
        ctx.token
        |> runner_conn()
        |> put_req_header("x-runner-version", "sh " <> @old_sha)
        |> post("/api/runner/claim?wait=0")

      assert conn.status == 204
      assert get_resp_header(conn, "x-runner-latest") == []
      assert version_column(ctx.runner) == nil
    end

    test "a job's finish carries no X-Runner-Latest either", ctx do
      card = card_fixture(hd(ctx.board.columns), %{"title" => "Go"})
      {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})

      claim =
        ctx.token
        |> runner_conn()
        |> put_req_header("x-runner-kinds", "claude")
        |> put_req_header("x-runner-version", "ps1 " <> @old_sha)
        |> post("/api/runner/claim?wait=0")

      assert claim.status == 200
      assert get_resp_header(claim, "x-runner-latest") == []
      [id] = get_resp_header(claim, "x-job-id")

      finish =
        ctx.token
        |> runner_conn()
        |> put_req_header("content-type", "text/plain")
        |> post("/api/runner/jobs/#{id}/finish?exit=0", "done")

      assert finish.status == 200
      assert get_resp_header(finish, "x-runner-latest") == []
    end

    test "the runner's JSON has no version or script, and says whose machine it is", ctx do
      json = SlipdockWeb.API.JSON.runner(ctx.runner)
      refute Map.has_key?(json, :version)
      refute Map.has_key?(json, :script)
      assert Map.has_key?(json, :machine_id)
      assert json.machine_id == nil
    end

    test "missing_kinds still says what the board needs that a runner lacks", ctx do
      assert Runners.missing_kinds(ctx.runner) == []

      {:ok, _} =
        Boards.update_board(ctx.board, %{"verify_work" => true, "ship_via" => "pull_request"})

      assert Runners.missing_kinds(ctx.runner) == ["merge"]
      assert Runners.missing_kinds(Runners.report_kinds(ctx.runner, "claude,merge")) == []
    end
  end

  describe "which runners are retired" do
    setup %{user: user, board: board} do
      {:ok, key, _} = Machines.create_enrolment_key(user, [board.id])

      {:ok, {_machine_key, machine}} =
        Machines.enrol_with_key(key, %{"hostname" => "box", "os" => "linux", "arch" => "amd64"})

      {:ok, machine} =
        MachineRunners.record_ceiling(machine, %{
          "roots" => ["/srv/src"],
          "agents" => ["claude"],
          "max_permission_mode" => "acceptEdits",
          "max_timeout_minutes" => 60,
          "boards" => [board.id],
          "executors" => ["me"]
        })

      {:ok, machine_runner} =
        MachineRunners.add_runner(machine, board, %{
          "pool" => "build",
          "config" => %{"directory" => "/srv/src/app"}
        })

      {_token, api_token} = Slipdock.Accounts.create_api_token(user, "desktop")
      {:ok, session} = Runners.session_runner(board, "loop", api_token, user)

      %{machine_runner: machine_runner, session: session}
    end

    test "a token runner is; a machine's or a session's isn't", ctx do
      assert Setup.retired?(ctx.runner)
      refute Setup.retired?(ctx.machine_runner)
      refute Setup.retired?(ctx.session)
    end

    test "a machine's runner has no setup steps or token here: 422, pointing at its page",
         ctx do
      base = "/api/boards/#{ctx.board.id}/runners/#{ctx.machine_runner.id}"

      for conn <- [get(ctx.conn, base <> "/setup"), post(ctx.conn, base <> "/token")] do
        message = json_response(conn, 422)["error"]
        assert message =~ "is a machine's runner"
        assert message =~ "Account › Machines"
      end

      assert Repo.reload!(ctx.machine_runner).token_hash == ctx.machine_runner.token_hash
    end

    test "the Runners panel offers Move to a machine on the token runner alone", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")

      assert has_element?(view, "#runner-#{ctx.runner.id}-move", "Move to a machine")
      refute has_element?(view, "#runner-#{ctx.machine_runner.id}-move")
      refute has_element?(view, "#runner-#{ctx.session.id}-move")
      refute has_element?(view, "#runner-list button", "Setup")

      view |> element("#show-runner-#{ctx.machine_runner.id}") |> render_click()

      assert has_element?(
               view,
               "#runner-details-#{ctx.machine_runner.id}",
               "A machine's runner, set on the machine's page"
             )
    end
  end

  describe "the steps for a retired runner" do
    test "are the move onto a machine, for its pool, with no installer", ctx do
      setup = Setup.regenerate(ctx.runner, ctx.board, "https://slipdock.example")

      assert setup.scenario == "retired"
      assert setup.title == "A retired shell runner"
      assert setup.intro =~ "no longer serves"
      text = Enum.map_join(setup.steps, "\n", &"#{&1.text} #{&1[:code]}")
      assert text =~ "slipdock runner new #{ctx.board.code} --scenario daemon --pool dev"
      assert text =~ "https://slipdock.example/account/machines"
      assert text =~ "systemctl --user disable --now slipdock-runner.service"
      assert text =~ "launchctl bootout"
      assert text =~ "revoke this runner here"
      refute text =~ "/runner/"
      refute text =~ "sdr_"
    end

    test "a new token is shown in a step of its own, once", ctx do
      {:ok, runner, token} = Runners.rotate_token(ctx.runner)
      setup = Setup.regenerate(runner, ctx.board, "https://slipdock.example", token)

      assert %{code: ^token, text: text} = List.last(setup.steps)
      assert text =~ "shown this once"
      refute inspect(Setup.regenerate(runner, ctx.board, "https://slipdock.example")) =~ token
    end

    test "a saved answer from the shell runner's wizard changes nothing in them", ctx do
      saved =
        ctx.runner
        |> Ecto.Changeset.change(
          settings: %{"scenario" => "windows", "self_update" => true, "worktree" => true}
        )
        |> Repo.update!()

      assert Setup.regenerate(saved, ctx.board, "https://x") ==
               Setup.regenerate(ctx.runner, ctx.board, "https://x")

      assert Setup.retired?(saved)
    end
  end
end

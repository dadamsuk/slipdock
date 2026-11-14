defmodule SlipdockWeb.ReleaseNowTest do
  @moduledoc """
  *Release now* and the release command at every door (#2835): REST
  `GET`/`POST /api/boards/:board/release` (the owner's; a board that
  releases on merge refused), MCP `release_now` (and `check`), the board's
  release banner and the Agentic Building page's button, `release_command`
  through `PATCH /api/boards/:id`, `update_board`, the page and a portable
  export; and the release job as a runner claims it over HTTP.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Releases, Repo, Runners}
  alias Slipdock.Boards.Card
  alias Slipdock.Releases.Request
  alias Slipdock.Runners.Job

  setup %{user: user} do
    user = user |> Ecto.Changeset.change(name: "Dana") |> Repo.update!()
    board = board_fixture(%{"name" => "Rel now", "code" => unique_code()}, owner: user)

    {:ok, board} =
      Boards.update_board(board, %{
        "delivery_metrics" => true,
        "agentic_building" => true,
        "release_mode" => "batched"
      })

    {:ok, runner, runner_token} =
      Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})

    runner = Runners.report_kinds(runner, "merge,release")

    [_backlog, todo | _] = board.columns

    %{
      user: user,
      board: board,
      todo: todo,
      agent: with_token(user, "bot"),
      runner: runner,
      runner_token: runner_token
    }
  end

  defp with_token(user, label) do
    {token, _} = Accounts.create_api_token(user, label)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp mcp(conn, tool, args) do
    result =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: tool, arguments: args}
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")

    [%{"text" => text}] = result["content"]
    {result["isError"] == true, text}
  end

  # How many times `text` appears in the element `selector` renders.
  defp occurrences(view, selector, text) do
    view |> element(selector) |> render() |> String.split(text) |> length() |> Kernel.-(1)
  end

  # What the element `selector` says, as a person reads it: its text, with
  # each run of white space as one space.
  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # The hold as it is with a part taken out: no run named, or no fix card.
  defp hold_without!(board, keys) do
    hold = Map.drop(Releases.hold(board), keys)

    Repo.update_all(from(b in Slipdock.Boards.Board, where: b.id == ^board.id),
      set: [release_hold: hold]
    )

    hold
  end

  defp merged!(todo, title) do
    card = card_fixture(todo, %{"title" => title})

    Repo.update_all(
      from(c in Card, where: c.id == ^card.id),
      set: [
        completed: true,
        completed_at: ~U[2026-11-12 10:04:00Z],
        verify_state: "accepted",
        merge_sha: "abc1234def5678"
      ]
    )

    card
  end

  describe "REST" do
    test "GET says where releases stand; POST starts one, queues one, joins it", ctx do
      card = merged!(ctx.todo, "Feature")

      body = ctx.agent |> get(~p"/api/boards/#{ctx.board.code}/release") |> json_response(200)

      assert %{"mode" => "batched", "running" => nil, "queued" => nil, "last" => nil} =
               body["release"]

      assert [%{"id" => id, "title" => "Feature", "merged_at" => _}] = body["release"]["awaiting"]
      assert id == card.id

      body = ctx.agent |> post(~p"/api/boards/#{ctx.board.code}/release") |> json_response(201)
      assert body["how"] == "started"
      assert body["line"] =~ "Release started"
      assert body["request"]["status"] == "running"
      assert body["request"]["card_ids"] == [card.id]
      assert [%{"trigger" => "manual", "by" => by}] = body["request"]["triggers"]
      # An API token is named by its label.
      assert by =~ "bot"
      assert body["release"]["running"]["id"] == body["request"]["id"]
      assert Repo.get!(Job, body["request"]["job_id"]).kind == "release"

      assert %{"how" => "queued"} =
               ctx.agent |> post(~p"/api/boards/#{ctx.board.id}/release") |> json_response(201)

      body = ctx.agent |> post(~p"/api/boards/#{ctx.board.id}/release") |> json_response(201)
      assert body["how"] == "joined"
      assert length(body["request"]["triggers"]) == 2
      assert Repo.aggregate(Request, :count) == 2
    end

    test "a board that releases on merge answers 409 and starts nothing", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"release_mode" => "on_merge"})

      body = ctx.agent |> post(~p"/api/boards/#{ctx.board.id}/release") |> json_response(409)
      assert inspect(body) =~ "releases on merge"
      assert Repo.aggregate(Request, :count) == 0

      assert %{"release" => %{"mode" => "on_merge", "awaiting" => []}} =
               ctx.agent |> get(~p"/api/boards/#{ctx.board.id}/release") |> json_response(200)
    end

    test "someone the board is shared with can read but not release", ctx do
      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")
      conn = with_token(editor, "theirs")

      assert conn |> get(~p"/api/boards/#{ctx.board.id}/release") |> json_response(200)
      assert conn |> post(~p"/api/boards/#{ctx.board.id}/release") |> json_response(403)
      assert Repo.aggregate(Request, :count) == 0
    end

    test "release_command is set by PATCH, read back, and refused when it isn't one line", ctx do
      body =
        ctx.agent
        |> patch(~p"/api/boards/#{ctx.board.id}", %{"release_command" => "make release"})
        |> json_response(200)

      assert body["board"]["release_command"] == "make release"

      assert ctx.agent
             |> get(~p"/api/boards/#{ctx.board.id}")
             |> json_response(200)
             |> get_in(["board", "release_command"]) == "make release"

      body =
        ctx.agent
        |> patch(~p"/api/boards/#{ctx.board.id}", %{"release_command" => "a\nb"})
        |> json_response(422)

      assert inspect(body) =~ "must be one line"
    end
  end

  describe "MCP" do
    test "release_now asks, and check only reads", ctx do
      card = merged!(ctx.todo, "Feature")

      {false, text} = mcp(ctx.agent, "release_now", %{board: "#{ctx.board.id}", check: true})

      assert %{"release" => %{"running" => nil, "awaiting" => [%{"id" => id}]}} =
               Jason.decode!(text)

      assert id == card.id
      assert Repo.aggregate(Request, :count) == 0

      {false, text} = mcp(ctx.agent, "release_now", %{board: ctx.board.code})
      body = Jason.decode!(text)
      assert body["how"] == "started"
      assert body["request"]["card_ids"] == [card.id]
      assert body["release"]["running"]["id"] == body["request"]["id"]
      assert [%Request{status: "running"}] = Repo.all(Request)
    end

    test "release_now is refused on an on_merge board and for someone who isn't the owner", ctx do
      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")

      theirs = with_token(editor, "theirs")
      {true, _refusal} = mcp(theirs, "release_now", %{board: "#{ctx.board.id}"})
      assert Repo.aggregate(Request, :count) == 0

      # Reading where releases stand is any reader's.
      {false, text} = mcp(theirs, "release_now", %{board: "#{ctx.board.id}", check: true})
      assert Jason.decode!(text)["release"]["mode"] == "batched"
      assert Repo.aggregate(Request, :count) == 0

      {:ok, _} = Boards.update_board(ctx.board, %{"release_mode" => "on_merge"})
      {true, text} = mcp(ctx.agent, "release_now", %{board: "#{ctx.board.id}"})
      assert text =~ "releases on merge"
    end

    test "update_board sets the release command", ctx do
      {false, _} =
        mcp(ctx.agent, "update_board", %{
          board: "#{ctx.board.id}",
          release_command: "make release"
        })

      assert Boards.get_board!(ctx.board.id).release_command == "make release"

      {false, _} =
        mcp(ctx.agent, "update_board", %{board: "#{ctx.board.id}", release_command: nil})

      assert Boards.get_board!(ctx.board.id).release_command == nil
    end
  end

  @run "https://github.com/example/app/actions/runs/77"

  # The runner fires the release request's job, ending it with `output`.
  defp fire!(runner, request, output) do
    %Job{id: id} = Runners.claim(runner)
    assert id == request.job_id
    {:ok, _} = Runners.finish(runner, id, %{exit: "0", status: "done", output: output})
    :ok
  end

  describe "the board page" do
    test "a running release links its build once its job fires it, without a reload (#3005)",
         ctx do
      merged!(ctx.todo, "Feature")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      {:ok, :started, request} = Releases.release_now(ctx.board, "Dana")

      assert has_element?(view, "#release-banner-line", "A release is running")
      refute has_element?(view, "#release-running-run")

      fire!(ctx.runner, request, "release: run #{@run}\n")

      assert has_element?(
               view,
               ~s(#release-running-run[href="#{@run}"][target="_blank"][rel="noopener noreferrer"]),
               "follow the build"
             )

      assert has_element?(view, "#release-banner-line", "A release is running")
    end

    test "a fired release that named no run links nothing, and an ended one drops the link",
         ctx do
      merged!(ctx.todo, "Feature")
      {:ok, :started, request} = Releases.release_now(ctx.board, "Dana")
      fire!(ctx.runner, request, "ok, nothing to link\n")

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert has_element?(view, "#release-banner-line", "A release is running")
      refute has_element?(view, "#release-running-run")

      request =
        Repo.get!(Request, request.id) |> Ecto.Changeset.change(run_url: @run) |> Repo.update!()

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert has_element?(view, "#release-running-run")

      {:ok, _} = Releases.finish(request, "failed", "the deploy failed")
      refute has_element?(view, "#release-running-run")
    end

    test "someone it is shared with follows the build too, with no button", ctx do
      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")
      {:ok, :started, request} = Releases.release_now(ctx.board, "Dana")
      fire!(ctx.runner, request, "release: run #{@run}\n")

      {:ok, view, _} = live(log_in_user(build_conn(), editor), ~p"/boards/#{ctx.board}")
      assert has_element?(view, ~s(#release-running-run[href="#{@run}"]))
      refute has_element?(view, "#release-now")
    end

    test "a batched board with merged work shows the banner, and Release now starts one", ctx do
      merged!(ctx.todo, "Feature")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      assert has_element?(view, "#release-banner-line", "1 merged, awaiting release")

      view |> element("#release-now") |> render_click()

      assert [%Request{status: "running", triggers: [%{"by" => "Dana"}]}] = Repo.all(Request)
      assert has_element?(view, "#release-banner-line", "A release is running (1 cards)")
    end

    test "the awaiting count opens the list of the cards the release takes (#3038)", ctx do
      first = merged!(ctx.todo, "First feature")
      second = merged!(ctx.todo, "Second feature")
      open = card_fixture(ctx.todo, %{"title" => "Still open"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      assert has_element?(view, "#release-awaiting-toggle", "2 merged, awaiting release")

      for card <- [first, second] do
        assert has_element?(
                 view,
                 ~s(#release-awaiting-card-#{card.id} a[href="/boards/#{ctx.board.id}/cards/#{card.id}"]),
                 "##{card.id} #{card.title}"
               )
      end

      refute has_element?(view, "#release-awaiting-card-#{open.id}")
      refute has_element?(view, "#release-banner-line", "·")
      # The count is said once, as the toggle, not in the line as well.
      assert occurrences(view, "#release-banner-line", "2 merged, awaiting release") == 1

      # A release running takes them: no count, no list, no separator.
      {:ok, :started, _} = Releases.release_now(ctx.board, "Eli")
      assert has_element?(view, "#release-banner-line", "A release is running (2 cards)")
      refute has_element?(view, "#release-awaiting")
      refute has_element?(view, "#release-banner-line span", "·")
    end

    test "with no hold, a release running opens the line, with no separator before it (#2995)",
         ctx do
      merged!(ctx.todo, "First feature")
      merged!(ctx.todo, "Second feature")
      {:ok, :started, _} = Releases.release_now(ctx.board, "Eli")

      for {path, line} <- [
            {~p"/boards/#{ctx.board}", "#release-banner-line"},
            {~p"/boards/#{ctx.board}/agentic", "#board-release-line"}
          ] do
        {:ok, view, _} = live(ctx.conn, path)

        assert text(view, line) =~ ~r/^A release is running \(2 cards\)/
        refute text(view, line) =~ ~r/^·/
      end
    end

    test "no banner with nothing to say, or on a board that releases on merge", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, "#release-banner")

      merged!(ctx.todo, "Feature")
      {:ok, _} = Boards.update_board(ctx.board, %{"release_mode" => "on_merge"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, "#release-banner")
    end

    test "a board switched back to on merge shows none, even with a release still open", ctx do
      {:ok, :started, _} = Releases.release_now(ctx.board, "Dana")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert has_element?(view, "#release-banner")

      {:ok, _} = Boards.update_board(ctx.board, %{"release_mode" => "on_merge"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      refute has_element?(view, "#release-banner")
    end

    test "a release asked for elsewhere shows without a reload", ctx do
      merged!(ctx.todo, "Feature")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      {:ok, :started, _} = Releases.release_now(ctx.board, "Eli")
      assert has_element?(view, "#release-banner-line", "A release is running")
    end

    test "someone it is shared with sees the banner but no button", ctx do
      merged!(ctx.todo, "Feature")
      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")

      {:ok, view, _} = live(log_in_user(build_conn(), editor), ~p"/boards/#{ctx.board}")
      assert has_element?(view, "#release-banner")
      refute has_element?(view, "#release-now")
    end
  end

  describe "the Agentic Building page" do
    test "a running release links its build once its job fires it (#3005)", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")
      {:ok, :started, request} = Releases.release_now(ctx.board, "Dana")

      assert has_element?(view, "#board-release-line", "A release is running")
      refute has_element?(view, "#board-release-running-run")

      fire!(ctx.runner, request, "release: run #{@run}\n")

      assert has_element?(
               view,
               ~s(#board-release-running-run[href="#{@run}"][target="_blank"]),
               "follow the build"
             )
    end

    test "saves the release command and releases now", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")
      assert has_element?(view, "#board-release-line", "Nothing merged is awaiting release.")

      view
      |> form("#agentic-form", board: %{"release_command" => "make release"})
      |> render_submit()

      assert Boards.get_board!(ctx.board.id).release_command == "make release"

      view |> element("#board-release-now") |> render_click()

      assert [%Request{status: "running"} = request] = Repo.all(Request)
      assert Repo.get!(Job, request.job_id).prompt == "make release"
      assert has_element?(view, "#board-release-line", "A release is running")
    end

    test "the awaiting count there lists the cards too (#3038)", ctx do
      card = merged!(ctx.todo, "Feature")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")

      assert has_element?(view, "#board-release-awaiting-toggle", "1 merged, awaiting release")

      assert has_element?(
               view,
               ~s(#board-release-awaiting-card-#{card.id} a[href="/boards/#{ctx.board.id}/cards/#{card.id}"]),
               "##{card.id} Feature"
             )

      refute has_element?(view, "#board-release-line", "Nothing merged is awaiting release.")
      # Said once, as the toggle; with nothing else to say, no separator.
      assert occurrences(view, "#board-release-line", "1 merged, awaiting release") == 1
      refute has_element?(view, "#board-release-line", "·")

      # A release running lists nothing, and leaves no separator behind.
      {:ok, :started, _} = Releases.release_now(ctx.board, "Eli")
      assert has_element?(view, "#board-release-line", "A release is running")
      refute has_element?(view, "#board-release-awaiting")
      refute has_element?(view, "#board-release-line span", "·")
    end

    test "a release asked for elsewhere shows without a reload", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")
      assert has_element?(view, "#board-release-line", "Nothing merged is awaiting release.")

      {:ok, :started, _} = Releases.release_now(ctx.board, "Eli")
      assert has_element?(view, "#board-release-line", "A release is running")
    end

    test "someone it is shared with reads where releases stand, with no button", ctx do
      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")

      {:ok, view, _} = live(log_in_user(build_conn(), editor), ~p"/boards/#{ctx.board}/agentic")
      assert has_element?(view, "#board-release-line")
      refute has_element?(view, "#board-release-now")
    end

    test "no release block on a board that releases on merge", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"release_mode" => "on_merge"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")
      refute has_element?(view, "#board-release-status")
    end
  end

  describe "a red release's hold (#2838)" do
    setup ctx do
      {:ok, _} =
        Slipdock.Deployments.record_failure(ctx.board, %{
          environment: "production",
          sha: "feed0099",
          stage: "test",
          run_url: "https://github.com/example/app/actions/runs/88"
        })

      hold = Releases.hold(ctx.board)
      assert hold["fix_card_id"]
      %{hold: hold}
    end

    test "REST: GET shows it, POST is refused saying why, DELETE lifts it once", ctx do
      body = ctx.agent |> get(~p"/api/boards/#{ctx.board.id}/release") |> json_response(200)
      hold = body["release"]["hold"]
      assert hold["reason"] == "the release failed at test"
      assert hold["stage"] == "test"
      assert hold["run_url"] == "https://github.com/example/app/actions/runs/88"
      assert hold["fix_card_id"] == ctx.hold["fix_card_id"]
      assert hold["text"] =~ "fix card ##{ctx.hold["fix_card_id"]} releases when it merges"

      body = ctx.agent |> post(~p"/api/boards/#{ctx.board.id}/release") |> json_response(409)
      assert inspect(body) =~ "releases are held: the release failed at test"
      assert inspect(body) =~ "actions/runs/88"
      assert Repo.aggregate(Request, :count) == 0

      body =
        ctx.agent |> delete(~p"/api/boards/#{ctx.board.id}/release/hold") |> json_response(200)

      assert body["lifted"]["stage"] == "test"
      assert body["line"] == "Release hold lifted. Nothing was released."
      assert body["release"]["hold"] == nil
      assert Repo.aggregate(Request, :count) == 0

      body =
        ctx.agent |> delete(~p"/api/boards/#{ctx.board.id}/release/hold") |> json_response(409)

      assert inspect(body) =~ "aren't held"
    end

    test "REST: someone it is shared with can't lift it", ctx do
      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")
      conn = with_token(editor, "theirs")

      assert conn |> delete(~p"/api/boards/#{ctx.board.id}/release/hold") |> json_response(403)
      assert Releases.hold(ctx.board)
    end

    test "MCP: check shows it, release_now is refused, lift_hold lifts it", ctx do
      {false, text} = mcp(ctx.agent, "release_now", %{board: "#{ctx.board.id}", check: true})
      assert Jason.decode!(text)["release"]["hold"]["stage"] == "test"

      {true, text} = mcp(ctx.agent, "release_now", %{board: "#{ctx.board.id}"})
      assert text =~ "releases are held"

      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")

      {true, _} =
        mcp(with_token(editor, "theirs"), "release_now", %{
          board: "#{ctx.board.id}",
          check: true,
          lift_hold: true
        })

      assert Releases.hold(ctx.board)

      # check with lift_hold lifts: the owner's lift wins over the read.
      {false, text} =
        mcp(ctx.agent, "release_now", %{board: "#{ctx.board.id}", check: true, lift_hold: true})

      body = Jason.decode!(text)
      assert body["lifted"]["stage"] == "test"
      assert body["release"]["hold"] == nil
      assert Repo.aggregate(Request, :count) == 0

      {true, text} = mcp(ctx.agent, "release_now", %{board: "#{ctx.board.id}", lift_hold: true})
      assert text =~ "aren't held"
    end

    test "the board page's banner says it is held, links the run, and Lift hold lifts it", ctx do
      merged!(ctx.todo, "Waiting")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      assert has_element?(
               view,
               "#release-banner-line",
               "Releases held: the release failed at test"
             )

      assert has_element?(view, "#release-banner-line", "fix card ##{ctx.hold["fix_card_id"]}")
      # Held, the count still opens the list, after the hold (#3038).
      assert has_element?(view, "#release-banner-line span", "·")
      assert has_element?(view, "#release-awaiting-toggle", "1 merged, awaiting release")

      assert has_element?(
               view,
               ~s(#release-hold-run[href="https://github.com/example/app/actions/runs/88"]),
               "the failing run"
             )

      view |> element("#release-lift-hold") |> render_click()

      assert Releases.hold(ctx.board) == nil
      assert Repo.aggregate(Request, :count) == 0
      # The banner stays for the merged card, without Lift hold or the run.
      assert has_element?(view, "#release-banner-line", "merged, awaiting release")
      refute has_element?(view, "#release-lift-hold")
      refute has_element?(view, "#release-hold-run")
    end

    test "the failing run sits with the hold's reason, not after the cards awaiting (#2995)",
         ctx do
      merged!(ctx.todo, "Waiting")
      fix = "fix card ##{ctx.hold["fix_card_id"]}"

      for {path, line} <- [
            {~p"/boards/#{ctx.board}", "#release-banner-line"},
            {~p"/boards/#{ctx.board}/agentic", "#board-release-line"}
          ] do
        {:ok, view, _} = live(ctx.conn, path)

        assert text(view, line) =~
                 "Releases held: the release failed at test (the failing run) · #{fix} · 1 merged, awaiting release"

        # Nothing after the count but the list of the cards it opens.
        refute text(view, line) =~ ~r/awaiting release.*the failing run/
        assert occurrences(view, line, "the failing run") == 1
      end
    end

    test "a hold that names no run says the reason alone, with no brackets (#2995)", ctx do
      merged!(ctx.todo, "Waiting")
      hold_without!(ctx.board, ["run_url"])
      fix = "fix card ##{ctx.hold["fix_card_id"]}"

      for {path, line, run} <- [
            {~p"/boards/#{ctx.board}", "#release-banner-line", "#release-hold-run"},
            {~p"/boards/#{ctx.board}/agentic", "#board-release-line", "#board-release-hold-run"}
          ] do
        {:ok, view, _} = live(ctx.conn, path)

        assert text(view, line) =~
                 "Releases held: the release failed at test · #{fix} · 1 merged, awaiting release"

        refute has_element?(view, run)
        refute text(view, line) =~ "("
      end
    end

    test "a hold with no fix card and nothing awaiting ends at its run, with no separator (#2995)",
         ctx do
      hold_without!(ctx.board, ["fix_card_id"])

      for {path, line} <- [
            {~p"/boards/#{ctx.board}", "#release-banner-line"},
            {~p"/boards/#{ctx.board}/agentic", "#board-release-line"}
          ] do
        {:ok, view, _} = live(ctx.conn, path)
        assert text(view, line) == "Releases held: the release failed at test (the failing run)"
      end

      # With a card awaiting, the count follows the run, after one separator.
      # The component's own HTML: a view's rendered element has lost the
      # white space between two elements, which is all that parts these.
      merged!(ctx.todo, "Waiting")

      html =
        render_component(&SlipdockWeb.BoardLive.BoardView.release_line/1,
          release: Releases.status(ctx.board),
          id: "release"
        )

      assert html |> String.replace(~r/<[^>]+>/, "") |> String.replace(~r/\s+/, " ") =~
               "Releases held: the release failed at test (the failing run) · 1 merged, awaiting release"
    end

    test "someone it is shared with sees the hold but no Lift hold", ctx do
      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")

      {:ok, view, _} = live(log_in_user(build_conn(), editor), ~p"/boards/#{ctx.board}")
      assert has_element?(view, "#release-banner-line", "Releases held")
      refute has_element?(view, "#release-lift-hold")

      render_hook(view, "lift_release_hold", %{})
      assert Releases.hold(ctx.board)
    end

    test "the Agentic Building page shows it with the run and lifts it", ctx do
      merged!(ctx.todo, "Waiting")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")
      assert has_element?(view, "#board-release-line", "Releases held")
      # Held, the count still opens the list, after the hold (#3038).
      assert has_element?(view, "#board-release-line span", "·")
      assert has_element?(view, "#board-release-awaiting-toggle", "1 merged, awaiting release")

      assert has_element?(
               view,
               ~s(#board-release-hold-run[href="https://github.com/example/app/actions/runs/88"])
             )

      view |> element("#board-release-lift-hold") |> render_click()

      assert Releases.hold(ctx.board) == nil
      refute has_element?(view, "#board-release-lift-hold")
      assert render(view) =~ "Release hold lifted. Nothing was released."

      # Lifted already (elsewhere, or a second click): the refusal says so.
      render_hook(view, "lift_release_hold", %{})
      assert render(view) =~ "this board&#39;s releases aren&#39;t held"
    end

    test "on the Agentic Building page someone it is shared with sees it, with no Lift hold",
         ctx do
      editor = user_fixture("editor#{System.unique_integer([:positive])}@example.com")
      share_fixture(ctx.board, [editor], "write")

      {:ok, view, _} = live(log_in_user(build_conn(), editor), ~p"/boards/#{ctx.board}/agentic")
      assert has_element?(view, "#board-release-line", "Releases held")
      refute has_element?(view, "#board-release-lift-hold")

      render_hook(view, "lift_release_hold", %{})
      assert Releases.hold(ctx.board)
    end
  end

  describe "someone who reads a sub-board alone" do
    # A tree's releases name and count its root's cards: reading a
    # sub-board is not reading those.
    setup ctx do
      root_card = merged!(ctx.todo, "The root's secret")
      {:ok, template} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card_fixture(ctx.todo, %{"title" => "Epic"}), template)
      sub = Boards.get_board!(sub.id)

      reader = user_fixture("subreader#{System.unique_integer([:positive])}@example.com")
      share_fixture(sub, [reader], "read")

      %{sub: sub, reader: reader, theirs: with_token(reader, "theirs"), root_card: root_card}
    end

    test "REST: the sub-board's release status is refused, naming the root", ctx do
      assert ctx.theirs |> get(~p"/api/boards/#{ctx.sub.id}") |> json_response(200)

      body = ctx.theirs |> get(~p"/api/boards/#{ctx.sub.id}/release") |> json_response(403)
      assert Jason.encode!(body) =~ "releases are its tree's root board's, which you can't read"
      refute Jason.encode!(body) =~ "The root's secret"

      # The owner reads the tree's status through the sub-board.
      body = ctx.agent |> get(~p"/api/boards/#{ctx.sub.id}/release") |> json_response(200)
      assert [%{"id" => id}] = body["release"]["awaiting"]
      assert id == ctx.root_card.id
    end

    test "MCP: check is refused the same way, and the owner's reads the tree", ctx do
      {true, text} = mcp(ctx.theirs, "release_now", %{board: "#{ctx.sub.id}", check: true})
      assert text =~ "releases are its tree's root board's, which you can't read"
      refute text =~ "The root's secret"

      {false, text} = mcp(ctx.agent, "release_now", %{board: "#{ctx.sub.id}", check: true})
      assert [%{"title" => "The root's secret"}] = Jason.decode!(text)["release"]["awaiting"]
    end

    test "the board page shows them no banner; the owner sees it on the sub-board", ctx do
      {:ok, view, _} = live(log_in_user(build_conn(), ctx.reader), ~p"/boards/#{ctx.sub}")
      refute has_element?(view, "#release-banner")

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.sub}")
      assert has_element?(view, "#release-banner-line", "1 merged, awaiting release")
    end

    test "the Agentic Building page shows them no release status; the owner sees it", ctx do
      {:ok, view, _} =
        live(log_in_user(build_conn(), ctx.reader), ~p"/boards/#{ctx.sub}/agentic")

      refute has_element?(view, "#board-release-status")

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.sub}/agentic")
      assert has_element?(view, "#board-release-line", "1 merged, awaiting release")
    end

    test "a release asked for elsewhere doesn't bring the banner to them", ctx do
      {:ok, view, _} = live(log_in_user(build_conn(), ctx.reader), ~p"/boards/#{ctx.sub}")
      {:ok, :started, _} = Releases.release_now(ctx.board, "Eli")
      refute has_element?(view, "#release-banner")
    end
  end

  describe "the help" do
    test "the app's guide, the agents' doors table and the flow page name Release now", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/help/boards")
      assert html =~ "Release now"
      assert html =~ "one follow-up"
      assert html =~ "follow the build"

      {:ok, _view, html} = live(conn, ~p"/help/agents")
      assert html =~ "Release a batched board&#39;s merged work now"
      assert html =~ "slipdock release [--lift-hold], slipdock releases"
      assert html =~ "release_now (check: true to read, lift_hold: true)"
      assert html =~ "DELETE …/release/hold"

      {:ok, _view, html} = live(conn, ~p"/help/agents/flow")
      assert html =~ "A batched board releases on a trigger, not on a merge."
      assert html =~ "A red release holds the next one and files a"
    end
  end

  describe "a card released with no deploy recorded" do
    test "reads released, with no environment, in its JSON", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"delivery_metrics" => false})
      card = merged!(ctx.todo, "Feature")
      {:ok, :started, request} = Releases.release_now(board, "Dana")
      {:ok, _} = Releases.finish(request, "released", "the release command ran")

      body = ctx.agent |> get(~p"/api/cards/#{card.id}") |> json_response(200)

      assert %{"state" => "released", "environment" => nil, "text" => "Released · " <> _} =
               body["card"]["release"]
    end
  end

  describe "the runner protocol" do
    test "a runner that takes release claims the job: its kind, the command, no card", ctx do
      {:ok, :started, request} = Releases.release_now(ctx.board, "Dana")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.runner_token)
        |> put_req_header("x-runner-kinds", "merge,release")
        |> put_req_header("content-type", "text/plain")
        |> post("/api/runner/claim?wait=0")

      assert conn.status == 200
      assert conn.resp_body == "gh workflow run release.yml --ref {default_branch}"
      assert get_resp_header(conn, "x-job-kind") == ["release"]
      assert get_resp_header(conn, "x-job-id") == ["#{request.job_id}"]
      assert get_resp_header(conn, "x-card-id") == []

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.runner_token)
        |> put_req_header("content-type", "text/plain")
        |> post(
          "/api/runner/jobs/#{request.job_id}/finish?exit=0",
          "https://github.com/example/app/actions/runs/7"
        )

      assert conn.status in [200, 204]

      assert Repo.get!(Request, request.id).run_url ==
               "https://github.com/example/app/actions/runs/7"
    end

    test "a runner that doesn't say it takes release is handed nothing", ctx do
      {:ok, :started, _} = Releases.release_now(ctx.board, "Dana")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.runner_token)
        |> put_req_header("x-runner-kinds", "claude,merge")
        |> put_req_header("content-type", "text/plain")
        |> post("/api/runner/claim?wait=0")

      assert conn.status == 204
    end
  end

  test "the release command goes out with a portable export and comes back in", ctx do
    {:ok, board} = Boards.update_board(ctx.board, %{"release_command" => "make release"})

    document = Slipdock.Portable.export(ctx.user, boards: [board])
    [tree] = document.boards
    assert tree.root.release_command == "make release"

    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(document))
    assert Boards.get_board!(hd(report.boards).id).release_command == "make release"

    odd = update_in(document.boards, fn [t] -> [put_in(t.root.release_command, "a\nb")] end)
    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(odd))
    assert Boards.get_board!(hd(report.boards).id).release_command == nil

    long = String.duplicate("x", 501)
    odd = update_in(document.boards, fn [t] -> [put_in(t.root.release_command, long)] end)
    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(odd))
    assert Boards.get_board!(hd(report.boards).id).release_command == nil

    fits = String.duplicate("x", 500)
    odd = update_in(document.boards, fn [t] -> [put_in(t.root.release_command, fits)] end)
    {:ok, report} = Slipdock.Portable.import(ctx.user, Jason.encode!(odd))
    assert Boards.get_board!(hd(report.boards).id).release_command == fits
  end
end

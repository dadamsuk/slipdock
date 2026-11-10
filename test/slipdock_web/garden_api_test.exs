defmodule SlipdockWeb.GardenAPITest do
  @moduledoc """
  The board gardener over HTTP and MCP (W-1807): a run started and listed,
  suggestions applied, dismissed and undone, settings changed, and every
  write refused to a reader, a read-only token and a stranger.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Boards, Gardener, Repo}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    [_backlog, _todo, doing, done] = board.columns
    # complete outside Done: completed_not_done finds it
    stray = card_fixture(doing, %{"title" => "Stray", "completed" => true})
    reader = user_fixture("garden-reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", owner)
    stranger = user_fixture("garden-stranger@example.com")
    %{board: board, owner: owner, reader: reader, stranger: stranger, stray: stray, done: done}
  end

  defp as(user), do: user |> conn_as() |> put_req_header("accept", "application/json")

  defp with_token(user, opts) do
    {token, _} = Accounts.create_api_token(user, "limited", opts)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp open_one(board) do
    {:ok, _} = Gardener.run(board, only: ["completed_not_done"])
    [s] = Gardener.list_open(board)
    s
  end

  describe "GET and POST /api/boards/:board/garden" do
    test "a run, then the open suggestions with their subjects named", ctx do
      assert %{"suggestions" => [], "last_run" => nil, "checks" => checks} =
               as(ctx.owner) |> get("/api/boards/#{ctx.board.code}/garden") |> json_response(200)

      assert %{"key" => "abandoned_backlog", "enabled" => false, "settings" => %{"days" => 180}} =
               Enum.find(checks, &(&1["key"] == "abandoned_backlog"))

      assert %{"suggestions" => [s], "last_run" => run} =
               as(ctx.owner)
               |> post("/api/boards/#{ctx.board.code}/garden", %{})
               |> json_response(200)

      assert run["trigger"] == "manual"
      assert run["counts"]["completed_not_done"] == 1
      assert s["check"] == "completed_not_done"
      assert s["label"] == "Complete but not in Done"

      assert s["cards"] == [
               %{"id" => ctx.stray.id, "title" => "Stray", "board_id" => ctx.board.id}
             ]

      assert [%{"op" => "move", "column" => col}] = s["proposal"]
      assert col == ctx.done.id
      assert s["needs_keep"] == false

      # A reader can list what is there.
      assert %{"suggestions" => [_]} =
               as(ctx.reader) |> get("/api/boards/#{ctx.board.code}/garden") |> json_response(200)
    end

    test "check narrows the run and the list; an unknown one is refused", ctx do
      assert %{"suggestions" => []} =
               as(ctx.owner)
               |> post("/api/boards/#{ctx.board.code}/garden", %{"check" => "epic_done"})
               |> json_response(200)

      assert %{"error" => error} =
               as(ctx.owner)
               |> get("/api/boards/#{ctx.board.code}/garden?check=tidy")
               |> json_response(400)

      assert error =~ "unknown check \"tidy\": one of epic_done"
    end

    test "running needs write access", ctx do
      assert as(ctx.reader)
             |> post("/api/boards/#{ctx.board.code}/garden", %{})
             |> json_response(403)

      assert with_token(ctx.owner, scope: "read")
             |> post("/api/boards/#{ctx.board.code}/garden", %{})
             |> json_response(403)

      assert as(ctx.stranger) |> get("/api/boards/#{ctx.board.code}/garden") |> json_response(404)
    end
  end

  describe "deciding" do
    test "apply moves the card, undo puts it back", ctx do
      s = open_one(ctx.board)

      assert %{"suggestion" => %{"state" => "applied", "decided_by_id" => by}} =
               as(ctx.owner)
               |> post("/api/garden/suggestions/#{s.id}/apply", %{})
               |> json_response(200)

      assert by == ctx.owner.id
      assert Boards.get_card!(ctx.stray.id).column_id == ctx.done.id

      assert %{"suggestion" => %{"state" => "open"}} =
               as(ctx.owner)
               |> post("/api/garden/suggestions/#{s.id}/undo", %{})
               |> json_response(200)

      refute Boards.get_card!(ctx.stray.id).column_id == ctx.done.id
    end

    test "dismiss, then applying it is refused with the reason", ctx do
      s = open_one(ctx.board)

      assert %{"suggestion" => %{"state" => "dismissed"}} =
               as(ctx.owner)
               |> post("/api/garden/suggestions/#{s.id}/dismiss", %{})
               |> json_response(200)

      assert %{"error" => "that suggestion is dismissed, not open"} =
               as(ctx.owner)
               |> post("/api/garden/suggestions/#{s.id}/apply", %{})
               |> json_response(422)
    end

    test "an unknown field and an unknown suggestion are refused", ctx do
      s = open_one(ctx.board)

      assert %{"error" => "unknown field(s): survivor"} =
               as(ctx.owner)
               |> post("/api/garden/suggestions/#{s.id}/apply", %{"survivor" => 1})
               |> json_response(400)

      assert as(ctx.owner) |> post("/api/garden/suggestions/0/apply", %{}) |> json_response(404)
    end

    test "a reader, a read-only token and a stranger may not decide", ctx do
      s = open_one(ctx.board)

      for conn <- [as(ctx.reader), with_token(ctx.owner, scope: "read")],
          verb <- ~w(apply dismiss undo) do
        assert conn |> post("/api/garden/suggestions/#{s.id}/#{verb}", %{}) |> json_response(403)
      end

      assert as(ctx.stranger)
             |> post("/api/garden/suggestions/#{s.id}/apply", %{})
             |> response(404)

      assert Gardener.get_suggestion(s.id).state == "open"
    end
  end

  describe "PATCH /api/boards/:board/garden/settings" do
    test "changes one check's settings", ctx do
      assert %{"checks" => checks} =
               as(ctx.owner)
               |> patch("/api/boards/#{ctx.board.code}/garden/settings", %{
                 "check" => "stale_in_progress",
                 "days" => "21"
               })
               |> json_response(200)

      assert %{"settings" => %{"days" => 21}} =
               Enum.find(checks, &(&1["key"] == "stale_in_progress"))
    end

    test "a bad value, a missing check and a reader are refused", ctx do
      path = "/api/boards/#{ctx.board.code}/garden/settings"

      assert %{"error" => "days must be a whole number above 0"} =
               as(ctx.owner)
               |> patch(path, %{"check" => "long_overdue", "days" => "0"})
               |> json_response(422)

      assert %{"error" => "check is required" <> _} =
               as(ctx.owner) |> patch(path, %{}) |> json_response(400)

      assert as(ctx.reader)
             |> patch(path, %{"check" => "long_overdue", "days" => "9"})
             |> json_response(403)
    end
  end

  describe "proposals (#1788)" do
    setup ctx do
      body = "# Data model\n\n## Rules\n\n- **DATA-1** must · judgement · Never cast.\n"

      {:ok, page} =
        Slipdock.Wiki.create_page(ctx.board, %{"title" => "Data model", "body" => body})

      Map.put(ctx, :page, page)
    end

    defp proposal(page),
      do: %{
        "explanation" => "DATA-1 keeps breaking: name the fields",
        "steps" => [
          %{
            "op" => "edit_section",
            "page" => page.code,
            "section" => "Data model/Rules",
            "body" => "- **DATA-1** must · judgement · Never cast owner ids."
          }
        ],
        "findings" => [4]
      }

    defp agent(conn), do: put_req_header(conn, "x-slipdock-agent", "1")

    defp agent_token(user) do
      user |> with_token([]) |> put_req_header("x-slipdock-client", "cli") |> agent()
    end

    test "an agent files one (201), and again gets the same one (200)", ctx do
      path = "/api/boards/#{ctx.board.code}/garden/proposals"

      assert %{"created" => true, "suggestion" => s} =
               agent_token(ctx.owner) |> post(path, proposal(ctx.page)) |> json_response(201)

      assert s["check"] == "proposal"
      assert s["label"] == "Proposed edits"
      assert s["findings"] == [4]
      assert s["person_only"] == true
      assert [%{"op" => "edit_section", "page" => page_id, "base" => base} = step] = s["proposal"]
      assert page_id == ctx.page.id
      # The step names its page by code too, for a reader (#2592).
      assert step["page_code"] == ctx.page.code
      assert is_binary(base)
      assert [%{"id" => ^page_id, "code" => _}] = s["pages"]

      assert %{"created" => false, "suggestion" => %{"id" => id}} =
               agent_token(ctx.owner) |> post(path, proposal(ctx.page)) |> json_response(200)

      assert id == s["id"]

      # Listed, and narrowed by check=proposal.
      assert %{"suggestions" => [%{"id" => ^id, "proposal" => [listed]}]} =
               as(ctx.owner)
               |> get("/api/boards/#{ctx.board.code}/garden?check=proposal")
               |> json_response(200)

      assert listed["page_code"] == ctx.page.code
    end

    test "a step outside the list, an unknown field, a reader and a read-only token are refused",
         ctx do
      path = "/api/boards/#{ctx.board.code}/garden/proposals"
      bad = %{proposal(ctx.page) | "steps" => [%{"op" => "complete", "card" => ctx.stray.id}]}

      assert %{"error" => error} = as(ctx.owner) |> post(path, bad) |> json_response(422)
      assert error =~ "a proposal can't take a “complete” step"

      assert %{"error" => "unknown field(s): apply"} =
               as(ctx.owner)
               |> post(path, Map.put(proposal(ctx.page), "apply", true))
               |> json_response(400)

      assert as(ctx.reader) |> post(path, proposal(ctx.page)) |> json_response(403)

      assert with_token(ctx.owner, scope: "read")
             |> post(path, proposal(ctx.page))
             |> json_response(403)

      assert Gardener.list_open(ctx.board, check: "proposal") == []
    end

    # #2668: a person-only suggestion is decided on the Tidy-up page, never
    # over the API, whatever the token or its request says.
    test "no token decides one, whatever it sends; the refusal names the Tidy-up page", ctx do
      {:ok, s, :new} = Gardener.propose(ctx.board, ctx.owner, proposal(ctx.page))
      person = ctx.owner |> with_token([]) |> put_req_header("x-slipdock-client", "cli")
      job = agent_token(ctx.owner) |> put_req_header("x-slipdock-job", "77")
      script = ctx.owner |> with_token([]) |> put_req_header("x-slipdock-client", "curl")

      for conn <- [agent_token(ctx.owner), person, job, script],
          body <- [%{}, %{"confirm" => true}, %{"confirm" => "true"}],
          verb <- ~w(apply dismiss) do
        assert %{"error" => error} =
                 conn
                 |> post("/api/garden/suggestions/#{s.id}/#{verb}", body)
                 |> json_response(422)

        assert error =~ "only a person can #{verb} a proposed handbook edit"
        assert error =~ "Tidy-up page: " <> Gardener.tidy_url(s)
      end

      assert Gardener.get_suggestion(s.id).state == "open"
      assert Repo.get!(Slipdock.Wiki.Page, ctx.page.id).body == ctx.page.body
    end

    test "an applied one isn't undone over the API either", ctx do
      {:ok, s, :new} = Gardener.propose(ctx.board, ctx.owner, proposal(ctx.page))
      {:ok, applied} = Gardener.apply(s, ctx.owner, actor: Slipdock.Actor.web(ctx.owner))
      person = ctx.owner |> with_token([]) |> put_req_header("x-slipdock-client", "cli")

      for conn <- [person, agent_token(ctx.owner)] do
        assert %{"error" => error} =
                 conn
                 |> post("/api/garden/suggestions/#{applied.id}/undo", %{"confirm" => true})
                 |> json_response(422)

        assert error =~ "only a person can undo a proposed handbook edit"
      end

      assert Gardener.get_suggestion(s.id).state == "applied"
      assert Repo.get!(Slipdock.Wiki.Page, ctx.page.id).body =~ "Never cast owner ids."
    end

    test "an ordinary suggestion is still an agent's to apply", ctx do
      s = open_one(ctx.board)

      assert %{"suggestion" => %{"state" => "applied"}} =
               agent_token(ctx.owner)
               |> post("/api/garden/suggestions/#{s.id}/apply", %{})
               |> json_response(200)
    end

    test "MCP garden findings: true is the findings page's list, from the root (#2123)", ctx do
      {:ok, _} =
        Slipdock.Boards.add_comment(
          card_fixture(hd(ctx.board.columns), %{"title" => "Taught"}),
          "- Findings:\n  - gotcha: screens must not flash on load",
          by: ctx.owner
        )

      [f] = Slipdock.Repo.all(Slipdock.Findings.Finding)

      {:ok, drafted, :new} =
        Gardener.propose(ctx.board, ctx.owner, Map.put(proposal(ctx.page), "findings", [f.id]))

      # A rule proposed with no findings behind it is the Tidy-up page's alone.
      other =
        ctx.page
        |> proposal()
        |> Map.delete("findings")
        |> Map.put("steps", [
          %{
            "op" => "edit_section",
            "page" => ctx.page.code,
            "section" => "Data model/Rules",
            "body" => "- **DATA-2** should · judgement · Name every table."
          }
        ])

      {:ok, plain, :new} = Gardener.propose(ctx.board, ctx.owner, other)

      epic = card_fixture(hd(ctx.board.columns), %{"title" => "Epic"})
      {:ok, t} = Slipdock.Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      sub = Slipdock.Boards.get_board!(sub.id)

      ids = fn list -> Enum.map(list, & &1["id"]) end

      for ref <- [ctx.board.code, to_string(sub.id)] do
        assert %{"suggestions" => from_mcp} =
                 as(ctx.owner)
                 |> mcp_call("garden", %{board: ref, findings: true})
                 |> Map.fetch!("structuredContent")

        assert %{"awaiting" => from_rest} =
                 as(ctx.owner) |> get("/api/boards/#{ref}/findings") |> json_response(200)

        assert ids.(from_mcp) == [drafted.id]
        assert ids.(from_mcp) == ids.(from_rest)
        assert hd(from_mcp)["findings"] == [f.id] and hd(from_rest)["findings"] == [f.id]
      end

      # check: proposal alone is every open proposal on the board given.
      assert %{"suggestions" => all} =
               as(ctx.owner)
               |> mcp_call("garden", %{board: ctx.board.code, check: "proposal"})
               |> Map.fetch!("structuredContent")

      assert Enum.sort(ids.(all)) == Enum.sort([drafted.id, plain.id])

      assert %{"isError" => true} =
               as(ctx.owner) |> mcp_call("garden", %{board: ctx.board.code, findings: "x"})
    end

    test "MCP garden lists proposals; garden_decide can't apply, dismiss or undo one (#2668)",
         ctx do
      {:ok, s, :new} = Gardener.propose(ctx.board, ctx.owner, proposal(ctx.page))

      assert %{"suggestions" => [listed]} =
               as(ctx.owner)
               |> mcp_call("garden", %{board: ctx.board.code, check: "proposal"})
               |> Map.fetch!("structuredContent")

      assert listed["id"] == s.id
      assert listed["person_only"]

      for decision <- ~w(apply dismiss) do
        assert %{"isError" => true, "content" => [%{"text" => text}]} =
                 as(ctx.owner)
                 |> mcp_call("garden_decide", %{
                   suggestion: s.id,
                   decision: decision,
                   confirm: true
                 })

        assert text =~ "only a person can #{decision} a proposed handbook edit"
        assert text =~ Gardener.tidy_url(s)
      end

      assert Gardener.get_suggestion(s.id).state == "open"
      assert Repo.get!(Slipdock.Wiki.Page, ctx.page.id).body == ctx.page.body

      {:ok, _} = Gardener.apply(s, ctx.owner, actor: Slipdock.Actor.web(ctx.owner))

      assert %{"isError" => true} =
               as(ctx.owner)
               |> mcp_call("garden_decide", %{suggestion: s.id, decision: "undo", confirm: true})

      assert Gardener.get_suggestion(s.id).state == "applied"
    end
  end

  defp mcp_call(conn, tool, args) do
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
  end

  describe "MCP" do
    defp call(conn, tool, args) do
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
    end

    defp ok!(result) do
      assert result["isError"] == false, inspect(result["content"])
      result["structuredContent"]
    end

    defp error!(result) do
      assert result["isError"] == true
      [%{"text" => text}] = result["content"]
      text
    end

    test "garden lists without running, and runs with run: true", ctx do
      assert %{"suggestions" => [], "note" => "Nothing to tidy."} =
               as(ctx.owner) |> call("garden", %{board: ctx.board.code}) |> ok!()

      assert %{"suggestions" => [s], "last_run" => %{"trigger" => "mcp"}, "note" => note} =
               as(ctx.owner) |> call("garden", %{board: ctx.board.code, run: true}) |> ok!()

      assert s["check"] == "completed_not_done"
      assert note =~ "apply only what they approve"
    end

    test "a read-only token can list but not run", ctx do
      conn = with_token(ctx.owner, scope: "read")
      assert %{"suggestions" => []} = conn |> call("garden", %{board: ctx.board.code}) |> ok!()

      assert %{"suggestions" => []} =
               with_token(ctx.owner, scope: "read")
               |> call("garden", %{board: ctx.board.code, run: false})
               |> ok!()

      # run as a boolean or as the string the argument parser also takes
      for run <- [true, "true"] do
        text =
          with_token(ctx.owner, scope: "read")
          |> call("garden", %{board: ctx.board.code, run: run})
          |> error!()

        assert text =~ "read-only, so it can't garden"
      end

      assert Gardener.last_run(ctx.board) == nil
      assert Gardener.list_open(ctx.board) == []
    end

    test "a reader's run is refused and runs nothing", ctx do
      text = as(ctx.reader) |> call("garden", %{board: ctx.board.code, run: true}) |> error!()
      assert text =~ "edit this board"
      assert Gardener.last_run(ctx.board) == nil
    end

    # run: true records a run and files suggestions, so tools/list must not tell
    # a client garden is read-only: it would run it without asking (#1868).
    test "tools/list doesn't mark garden read-only", ctx do
      tools =
        as(ctx.owner)
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
        |> json_response(200)
        |> get_in(["result", "tools"])

      garden = Enum.find(tools, &(&1["name"] == "garden"))

      assert garden["annotations"]["readOnlyHint"] == false
      assert garden["annotations"]["destructiveHint"] == false
      assert garden["description"] =~ "run: true looks again first (a write)"
    end

    test "garden_decide without confirm is refused, and changes nothing", ctx do
      s = open_one(ctx.board)

      text =
        as(ctx.owner)
        |> call("garden_decide", %{suggestion: s.id, decision: "apply", confirm: false})
        |> error!()

      assert text =~ "needs confirm = true"
      assert Gardener.get_suggestion(s.id).state == "open"
    end

    test "garden_decide applies, undoes and dismisses", ctx do
      s = open_one(ctx.board)

      decide =
        &(as(ctx.owner)
          |> call("garden_decide", Map.merge(%{suggestion: s.id, confirm: true}, &1)))

      assert %{"suggestion" => %{"state" => "applied"}} = decide.(%{decision: "apply"}) |> ok!()
      assert %{"suggestion" => %{"state" => "open"}} = decide.(%{decision: "undo"}) |> ok!()

      assert %{"suggestion" => %{"state" => "dismissed"}} =
               decide.(%{decision: "dismiss"}) |> ok!()

      assert decide.(%{decision: "maybe"}) |> error!() =~
               "decision must be apply, dismiss or undo"
    end

    test "garden_decide is refused to a reader and a read-only token", ctx do
      s = open_one(ctx.board)
      args = %{suggestion: s.id, decision: "apply", confirm: true}

      assert as(ctx.reader) |> call("garden_decide", args) |> error!()

      assert with_token(ctx.owner, scope: "read") |> call("garden_decide", args) |> error!() =~
               "read-only"

      assert Gardener.get_suggestion(s.id).state == "open"
    end
  end
end

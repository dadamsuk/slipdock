defmodule SlipdockWeb.API.MachineControllerTest do
  @moduledoc """
  Machines over the API (#2570): a daemon enrolling by device code or by a
  one-time key, the machine key reaching `/api/machine` and nothing else,
  and the owner's list, show, enrolment key and revoke, which a board-scoped
  or read-only token is refused.
  """
  # Sync: rate limiting is one table for the node.
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Machines, Repo, Runners}
  alias Slipdock.Machines.{Enrolment, Machine}

  @about %{
    "hostname" => "build-box",
    "os" => "linux",
    "arch" => "amd64",
    "fingerprint" => "SHA256:abc"
  }

  setup %{user: user} do
    Slipdock.RateLimit.reset()
    %{board: board_fixture(%{"name" => "Served"}, owner: user)}
  end

  defp rate_limited do
    previous = Application.get_env(:slipdock, :rate_limit)
    Application.put_env(:slipdock, :rate_limit, enabled: true)
    Slipdock.RateLimit.reset()
    on_exit(fn -> Application.put_env(:slipdock, :rate_limit, previous) end)
  end

  defp anon, do: build_conn() |> put_req_header("accept", "application/json")
  defp machine_conn(key), do: anon() |> put_req_header("authorization", "Bearer " <> key)

  defp enrolled(ctx) do
    {:ok, key, _} = Machines.create_enrolment_key(ctx.user, [ctx.board.id])
    {:ok, {machine_key, machine}} = Machines.enrol_with_key(key, @about)
    {machine_key, machine}
  end

  describe "enrolling by device code" do
    test "start, approve, poll: the key comes once", ctx do
      started = anon() |> post(~p"/api/machines/enrol", @about) |> json_response(200)

      assert started["user_code"] =~ ~r/^[A-Z2-9]{4}-[A-Z2-9]{4}$/
      assert started["verification_uri"] =~ "/account/machines/approve"
      assert started["verification_uri_complete"] =~ "user_code="
      assert started["expires_in"] == 600
      assert started["interval"] == 5

      poll = fn ->
        anon() |> post(~p"/api/machines/enrol/token", %{device_code: started["device_code"]})
      end

      assert %{"error" => "authorization_pending"} = poll.() |> json_response(400)

      enrolment = Machines.enrolment_by_user_code(started["user_code"])
      {:ok, _} = Machines.approve_enrolment(enrolment, ctx.user, [ctx.board.id])

      assert %{"machine_key" => "sdm_" <> _, "machine" => machine} = poll.() |> json_response(200)
      assert machine["hostname"] == "build-box"
      assert machine["boards"] == [ctx.board.id]
      assert machine["state"] == "enrolled"
      assert machine["enrolled_via"] == "device_code"

      assert %{"error" => "expired_token"} = poll.() |> json_response(400)
    end

    test "refused: the poll says so", _ctx do
      started = anon() |> post(~p"/api/machines/enrol", @about) |> json_response(200)
      {:ok, _} = Machines.deny_enrolment(Machines.enrolment_by_user_code(started["user_code"]))

      assert %{"error" => "access_denied"} =
               anon()
               |> post(~p"/api/machines/enrol/token", %{device_code: started["device_code"]})
               |> json_response(400)
    end

    test "no hostname, no request; no code, no poll" do
      assert %{"error" => "invalid_request", "error_description" => "hostname is required" <> _} =
               anon() |> post(~p"/api/machines/enrol", %{"os" => "linux"}) |> json_response(400)

      assert Repo.aggregate(Enrolment, :count) == 0

      assert %{"error" => "invalid_request"} =
               anon() |> post(~p"/api/machines/enrol/token", %{}) |> json_response(400)

      assert %{"error" => "expired_token"} =
               anon()
               |> post(~p"/api/machines/enrol/token", %{device_code: "made-up"})
               |> json_response(400)
    end

    test "starting is rate limited per address" do
      rate_limited()
      for _ <- 1..20, do: anon() |> post(~p"/api/machines/enrol", @about) |> json_response(200)

      assert %{"error" => "slow_down"} =
               anon() |> post(~p"/api/machines/enrol", @about) |> json_response(429)
    end

    test "polling is rate limited per address" do
      rate_limited()

      for _ <- 1..30,
          do: anon() |> post(~p"/api/machines/enrol/token", %{device_code: "x"}) |> response(400)

      assert %{"error" => "slow_down"} =
               anon()
               |> post(~p"/api/machines/enrol/token", %{device_code: "x"})
               |> json_response(429)
    end
  end

  describe "enrolling by one-time key" do
    test "the key's label names the machine (#2666)", ctx do
      {:ok, key, _} = Machines.create_enrolment_key(ctx.user, [ctx.board.id], "Silverbox")
      body = Map.put(@about, "enrolment_key", key)

      assert %{"machine" => %{"name" => "Silverbox", "hostname" => "build-box"}} =
               anon() |> post(~p"/api/machines/enrol/token", body) |> json_response(200)
    end

    test "the key enrols once", ctx do
      {:ok, key, _} = Machines.create_enrolment_key(ctx.user, [ctx.board.id])
      body = Map.put(@about, "enrolment_key", key)

      assert %{"machine_key" => "sdm_" <> _, "machine" => %{"enrolled_via" => "enrolment_key"}} =
               anon() |> post(~p"/api/machines/enrol/token", body) |> json_response(200)

      assert %{"error" => "invalid_grant"} =
               anon() |> post(~p"/api/machines/enrol/token", body) |> json_response(400)
    end

    test "a machine described badly is told why, and the key survives", ctx do
      {:ok, key, _} = Machines.create_enrolment_key(ctx.user, [ctx.board.id])

      assert %{"error" => "invalid_request"} =
               anon()
               |> post(~p"/api/machines/enrol/token", %{"enrolment_key" => key})
               |> json_response(400)

      assert anon()
             |> post(~p"/api/machines/enrol/token", Map.put(@about, "enrolment_key", key))
             |> json_response(200)
    end
  end

  describe "the machine key" do
    test "GET /api/machine answers with the machine", ctx do
      {key, machine} = enrolled(ctx)

      assert %{"machine" => %{"id" => id, "boards" => boards}} =
               key |> machine_conn() |> get(~p"/api/machine") |> json_response(200)

      assert id == machine.id
      assert boards == [ctx.board.id]
      assert Repo.get!(Machine, machine.id).last_seen_at
    end

    test "a revoked machine's key is refused at once, through the API too", ctx do
      {key, machine} = enrolled(ctx)

      assert %{"machine" => %{"state" => "revoked", "revoked_at" => at}} =
               ctx.conn |> delete(~p"/api/machines/#{machine.id}") |> json_response(200)

      assert at

      assert %{"error" => "unauthorized: " <> _} =
               key |> machine_conn() |> get(~p"/api/machine") |> json_response(401)
    end

    test "is not an API token: the API refuses it, and the runner protocol wants a runner", ctx do
      {key, _} = enrolled(ctx)

      key |> machine_conn() |> get(~p"/api/me") |> json_response(401)
      key |> machine_conn() |> get(~p"/api/boards") |> json_response(401)
      key |> machine_conn() |> get(~p"/api/machines") |> json_response(401)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> key)
        |> post("/api/runner/claim?wait=0")

      # Since #2571 the runner protocol takes a machine key for one of the
      # machine's own runners, named in X-Runner-Id; it claims nothing without.
      assert conn.status == 400
      assert conn.resp_body =~ "X-Runner-Id"
    end

    test "an API token or runner token is not a machine key", ctx do
      {:ok, _, runner_token} = Runners.create_runner(ctx.board, %{"name" => "r", "pool" => "dev"})
      {api_token, _} = Accounts.create_api_token(ctx.user, "t")

      for token <- [api_token, runner_token] do
        token |> machine_conn() |> get(~p"/api/machine") |> json_response(401)
      end

      anon() |> get(~p"/api/machine") |> json_response(401)
    end
  end

  describe "deciding an enrolment by its code, as the page does" do
    defp pending_code do
      {:ok, {device_code, enrolment}} = Machines.request_enrolment(@about, "192.0.2.10")
      {device_code, enrolment.user_code}
    end

    test "look it up, then approve it for a board: the approver owns the machine", ctx do
      {device_code, code} = pending_code()

      assert %{"enrolment" => shown} =
               ctx.conn
               |> get(~p"/api/machines/enrolment?#{[user_code: code]}")
               |> json_response(200)

      assert shown["hostname"] == "build-box"
      assert shown["fingerprint"] == "SHA256:abc"
      assert shown["client_ip"] == "192.0.2.10"
      assert shown["state"] == "pending"

      assert %{"enrolment" => %{"state" => "approved"}} =
               ctx.conn
               |> post(~p"/api/machines/enrolment/approve", %{
                 user_code: code,
                 boards: [ctx.board.code]
               })
               |> json_response(200)

      assert {:ok, {_, machine}} = Machines.poll_enrolment(device_code)
      assert machine.user_id == ctx.user.id

      # Decided: the code is gone.
      ctx.conn
      |> get(~p"/api/machines/enrolment?#{[user_code: code]}")
      |> json_response(404)
    end

    test "approving with no board, or another's board, is refused and decides nothing", ctx do
      {device_code, code} = pending_code()
      theirs = board_fixture(%{}, owner: user_fixture("stranger@example.com"))

      for boards <- [nil, [], [theirs.id]] do
        body = if boards, do: %{user_code: code, boards: boards}, else: %{user_code: code}

        ctx.conn
        |> post(~p"/api/machines/enrolment/approve", body)
        |> json_response(422)
      end

      assert Machines.poll_enrolment(device_code) == {:error, :authorization_pending}
    end

    test "refusing tells the machine", ctx do
      {device_code, code} = pending_code()

      assert %{"enrolment" => %{"state" => "refused"}} =
               ctx.conn
               |> post(~p"/api/machines/enrolment/refuse", %{user_code: code})
               |> json_response(200)

      assert Machines.poll_enrolment(device_code) == {:error, :access_denied}
    end

    test "an unknown code is not found, and lookups are rate limited per person", ctx do
      assert %{"error" => "no pending machine with that code" <> _} =
               ctx.conn
               |> get(~p"/api/machines/enrolment?#{[user_code: "BBBB-CCCC"]}")
               |> json_response(404)

      ctx.conn |> post(~p"/api/machines/enrolment/refuse", %{}) |> json_response(404)

      rate_limited()

      for _ <- 1..30 do
        ctx.conn
        |> get(~p"/api/machines/enrolment?#{[user_code: "BBBB-CCCC"]}")
        |> json_response(404)
      end

      ctx.conn
      |> get(~p"/api/machines/enrolment?#{[user_code: "BBBB-CCCC"]}")
      |> json_response(429)
    end

    test "a board-scoped or read-only token can't approve", ctx do
      {device_code, code} = pending_code()
      {scoped, _} = Accounts.create_api_token(ctx.user, "s", scope_boards: [ctx.board.id])
      {read, _} = Accounts.create_api_token(ctx.user, "r", scope: "read")

      for token <- [scoped, read] do
        anon()
        |> put_req_header("authorization", "Bearer " <> token)
        |> post(~p"/api/machines/enrolment/approve", %{user_code: code, boards: [ctx.board.id]})
        |> json_response(403)
      end

      assert Machines.poll_enrolment(device_code) == {:error, :authorization_pending}
    end
  end

  describe "the owner's machines" do
    test "list and show their own; another's is not found", ctx do
      {_, machine} = enrolled(ctx)

      assert %{"machines" => [%{"id" => id, "fingerprint" => "SHA256:abc"}]} =
               ctx.conn |> get(~p"/api/machines") |> json_response(200)

      assert id == machine.id

      assert %{"machine" => %{"name" => "build-box"}} =
               ctx.conn |> get(~p"/api/machines/#{machine.id}") |> json_response(200)

      stranger = conn_as(user_fixture("stranger@example.com"))
      assert %{"machines" => []} = stranger |> get(~p"/api/machines") |> json_response(200)
      stranger |> get(~p"/api/machines/#{machine.id}") |> json_response(404)
      stranger |> delete(~p"/api/machines/#{machine.id}") |> json_response(404)
      refute Machine.revoked?(Repo.get!(Machine, machine.id))

      ctx.conn |> get(~p"/api/machines/not-an-id") |> json_response(404)
    end

    test "its owner renames it; a blank name, a member and a stranger are refused", ctx do
      {_, machine} = enrolled(ctx)

      assert %{"machine" => %{"name" => "Silverbox", "hostname" => "build-box"}} =
               ctx.conn
               |> patch(~p"/api/machines/#{machine.id}", %{name: " Silverbox "})
               |> json_response(200)

      assert Repo.get!(Machine, machine.id).name == "Silverbox"

      assert %{"error" => "give the machine a name"} =
               ctx.conn
               |> patch(~p"/api/machines/#{machine.id}", %{name: "  "})
               |> json_response(422)

      assert %{"error" => "give the machine a name"} =
               ctx.conn |> patch(~p"/api/machines/#{machine.id}", %{}) |> json_response(422)

      member = user_fixture("member@example.com")
      {:ok, _} = Slipdock.Access.grant(ctx.board, member, "write", ctx.user)

      assert %{"error" => "only the machine's owner changes it" <> _} =
               member
               |> conn_as()
               |> patch(~p"/api/machines/#{machine.id}", %{name: "mine now"})
               |> json_response(403)

      conn_as(user_fixture("stranger@example.com"))
      |> patch(~p"/api/machines/#{machine.id}", %{name: "mine now"})
      |> json_response(404)

      assert Repo.get!(Machine, machine.id).name == "Silverbox"
    end

    test "an enrolment key is shown once, for boards the caller can reach", ctx do
      assert %{"enrolment_key" => "sde_" <> _, "boards" => [b], "valid_hours" => 24} =
               ctx.conn
               |> post(~p"/api/machines/enrolment-keys", %{
                 boards: [ctx.board.code],
                 label: "ci"
               })
               |> json_response(201)

      assert b == ctx.board.id

      theirs = board_fixture(%{}, owner: user_fixture("stranger@example.com"))

      assert %{"error" => "not a top-level board you're a member of" <> _} =
               ctx.conn
               |> post(~p"/api/machines/enrolment-keys", %{boards: [theirs.id]})
               |> json_response(422)

      assert %{"error" => "choose at least one board" <> _} =
               ctx.conn |> post(~p"/api/machines/enrolment-keys", %{}) |> json_response(422)
    end

    test "a board-scoped token is refused, and says why", ctx do
      {_, machine} = enrolled(ctx)
      {token, _} = Accounts.create_api_token(ctx.user, "scoped", scope_boards: [ctx.board.id])
      conn = anon() |> put_req_header("authorization", "Bearer " <> token)

      for request <- [
            &get(&1, ~p"/api/machines"),
            &get(&1, ~p"/api/machines/#{machine.id}"),
            &post(&1, ~p"/api/machines/enrolment-keys", %{boards: [ctx.board.id]}),
            &patch(&1, ~p"/api/machines/#{machine.id}", %{name: "x"}),
            &delete(&1, ~p"/api/machines/#{machine.id}")
          ] do
        assert %{"error" => "this API token is limited to some boards" <> _} =
                 conn |> request.() |> json_response(403)
      end

      refute Machine.revoked?(Repo.get!(Machine, machine.id))
      assert Repo.get!(Machine, machine.id).name == "build-box"
    end

    test "a read-only token may list but not revoke or make keys", ctx do
      {_, machine} = enrolled(ctx)
      {token, _} = Accounts.create_api_token(ctx.user, "ro", scope: "read")
      conn = anon() |> put_req_header("authorization", "Bearer " <> token)

      conn |> get(~p"/api/machines") |> json_response(200)
      conn |> delete(~p"/api/machines/#{machine.id}") |> json_response(403)
      conn |> patch(~p"/api/machines/#{machine.id}", %{name: "x"}) |> json_response(403)

      conn
      |> post(~p"/api/machines/enrolment-keys", %{boards: [ctx.board.id]})
      |> json_response(403)

      refute Machine.revoked?(Repo.get!(Machine, machine.id))
      assert Repo.get!(Machine, machine.id).name == "build-box"
    end
  end

  describe "Set up this machine with Claude (#2579)" do
    test "the machine key fetches the prompt for its own boards; a revoked one is refused", ctx do
      {key, machine} = enrolled(ctx)

      assert %{"prompt" => prompt} =
               key |> machine_conn() |> get(~p"/api/machine/setup-prompt") |> json_response(200)

      assert prompt =~ ~s|enrolled as "build-box" (machine ##{machine.id})|
      assert prompt =~ "Served"
      assert prompt =~ "4. **Write back.**"

      anon() |> get(~p"/api/machine/setup-prompt") |> json_response(401)
      {api_token, _} = Accounts.create_api_token(ctx.user, "t")
      api_token |> machine_conn() |> get(~p"/api/machine/setup-prompt") |> json_response(401)

      ctx.conn |> delete(~p"/api/machines/#{machine.id}") |> json_response(200)
      key |> machine_conn() |> get(~p"/api/machine/setup-prompt") |> json_response(401)
    end

    test "its owner gets the same prompt; a member is refused and a stranger finds nothing",
         ctx do
      {key, machine} = enrolled(ctx)

      assert %{"prompt" => prompt} =
               ctx.conn |> get(~p"/api/machines/#{machine.id}/setup-prompt") |> json_response(200)

      assert %{"prompt" => ^prompt} =
               key |> machine_conn() |> get(~p"/api/machine/setup-prompt") |> json_response(200)

      member = user_fixture("setup-member@example.com")
      {:ok, _} = Slipdock.Access.grant(ctx.board, member, "read", ctx.user)

      assert %{"error" => "only the machine's owner changes it" <> _} =
               conn_as(member)
               |> get(~p"/api/machines/#{machine.id}/setup-prompt")
               |> json_response(403)

      conn_as(user_fixture("setup-stranger@example.com"))
      |> get(~p"/api/machines/#{machine.id}/setup-prompt")
      |> json_response(404)
    end
  end
end

defmodule SlipdockWeb.API.DeviceFlowTest do
  @moduledoc """
  The device authorization grant end to end, and the things it exists to
  prevent: approving without being signed in, approving by following a link,
  reusing a code, and learning which codes exist by polling.
  """
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.Accounts
  alias Slipdock.Accounts.DeviceAuthorization
  alias Slipdock.Repo

  setup do
    Slipdock.RateLimit.reset()
    :ok
  end

  defp start(conn, params \\ %{}) do
    conn
    |> Plug.Conn.delete_req_header("authorization")
    |> post(~p"/api/auth/device", params)
    |> json_response(200)
  end

  defp poll(conn, device_code) do
    conn
    |> Plug.Conn.delete_req_header("authorization")
    |> post(~p"/api/auth/device/token", %{device_code: device_code})
  end

  describe "the happy path" do
    test "start, approve in a browser, poll, get a token", ctx do
      started = start(ctx.conn, %{label: "Claude on laptop", scope: "read"})

      assert started["user_code"] =~ ~r/^[A-Z2-9]{4}-[A-Z2-9]{4}$/
      assert started["interval"] == 5
      assert started["expires_in"] == 600
      assert started["verification_uri"] =~ "/activate"

      # Pending until somebody decides.
      assert %{"error" => "authorization_pending"} =
               ctx.conn |> poll(started["device_code"]) |> json_response(400)

      # The person approves, in a browser where they are signed in.
      ctx.conn
      |> post(~p"/activate", %{user_code: started["user_code"], decision: "approve"})
      |> response(302)

      assert %{"token" => token, "token_type" => "bearer"} =
               ctx.conn |> poll(started["device_code"]) |> json_response(200)

      # And the token works, with the scope that was asked for. (ConnCase
      # already minted one for the request itself, so find ours by label.)
      minted = Enum.find(Accounts.list_api_tokens(ctx.user), &(&1.label == "Claude on laptop"))
      assert minted
      assert minted.scope == "read"
      assert minted.expires_at
      assert %Accounts.User{} = Accounts.get_user_by_api_token(token)
    end

    test "refusing tells the client rather than leaving it polling", ctx do
      started = start(ctx.conn)

      ctx.conn
      |> post(~p"/activate", %{user_code: started["user_code"], decision: "deny"})
      |> response(302)

      assert %{"error" => "access_denied"} =
               ctx.conn |> poll(started["device_code"]) |> json_response(400)

      refute Enum.any?(Accounts.list_api_tokens(ctx.user), &(&1.label == "Device"))
    end
  end

  describe "what it refuses" do
    @tag :anonymous
    test "a signed-out visitor cannot approve anything", %{conn: conn} do
      started = start(conn)

      conn
      |> post(~p"/activate", %{user_code: started["user_code"], decision: "approve"})
      |> response(302)

      # Sent to sign in, and nothing was approved.
      assert Repo.get_by!(DeviceAuthorization, user_code: strip(started["user_code"])).approved_at ==
               nil
    end

    test "a GET to /activate never approves — only a POST decides", ctx do
      started = start(ctx.conn)

      # This is what following verification_uri_complete does.
      ctx.conn |> get(~p"/activate?user_code=#{started["user_code"]}") |> html_response(200)

      assert %{"error" => "authorization_pending"} =
               ctx.conn |> poll(started["device_code"]) |> json_response(400)
    end

    test "a code is good once: the second poll gets nothing", ctx do
      started = start(ctx.conn)

      ctx.conn
      |> post(~p"/activate", %{user_code: started["user_code"], decision: "approve"})
      |> response(302)

      assert %{"token" => _} = ctx.conn |> poll(started["device_code"]) |> json_response(200)

      assert %{"error" => "expired_token"} =
               ctx.conn |> poll(started["device_code"]) |> json_response(400)

      assert Enum.count(Accounts.list_api_tokens(ctx.user), &(&1.label == "Device")) == 1
    end

    test "an approved code cannot be approved again by someone else", ctx do
      started = start(ctx.conn)
      code = started["user_code"]

      ctx.conn |> post(~p"/activate", %{user_code: code, decision: "approve"}) |> response(302)

      # The code no longer resolves to a pending request at all.
      refute Accounts.device_authorization_by_user_code(code)
    end

    test "an unknown device code is answered exactly as an expired one", ctx do
      started = start(ctx.conn)
      real = ctx.conn |> poll(started["device_code"]) |> json_response(400)
      fake = ctx.conn |> poll("ZmFrZS1kZXZpY2UtY29kZQ") |> json_response(400)

      # Pending vs expired is a real difference; "exists" vs "does not" must
      # not be, or polling becomes a way to enumerate codes.
      assert real["error"] == "authorization_pending"
      assert fake["error"] == "expired_token"
    end

    test "an expired request cannot be approved", ctx do
      started = start(ctx.conn)
      code = strip(started["user_code"])

      Repo.get_by!(DeviceAuthorization, user_code: code)
      |> Ecto.Changeset.change(expires_at: DateTime.utc_now(:second) |> DateTime.add(-1, :minute))
      |> Repo.update!()

      refute Accounts.device_authorization_by_user_code(code)

      assert %{"error" => "expired_token"} =
               ctx.conn |> poll(started["device_code"]) |> json_response(400)
    end

    test "the admin scope cannot be asked for through the device flow", ctx do
      # Otherwise anybody could start one labelled "Slipdock CLI" and send the
      # code to an admin, whose approval would hand them an admin token.
      assert %{"error" => "invalid_scope"} =
               ctx.conn
               |> Plug.Conn.delete_req_header("authorization")
               |> post(~p"/api/auth/device", %{label: "Slipdock CLI", scope: "admin"})
               |> json_response(400)

      assert Repo.aggregate(DeviceAuthorization, :count) == 0
    end

    test "a second approval is a no-op and cannot take the request over", ctx do
      started = start(ctx.conn)
      request = Accounts.device_authorization_by_user_code(started["user_code"])
      other = user_fixture("someone-else@example.com")

      # Both held the request before either decided — the race a stale struct
      # used to lose, with the later approval overwriting whose token it was.
      assert {:ok, _} = Accounts.approve_device_authorization(request, ctx.user)
      assert {:error, :expired} = Accounts.approve_device_authorization(request, other)
      assert {:error, :expired} = Accounts.deny_device_authorization(request)

      decided = Repo.get!(DeviceAuthorization, request.id)
      assert decided.user_id == ctx.user.id
      assert decided.denied_at == nil
    end

    test "an approval the page sends twice says so rather than crashing", ctx do
      started = start(ctx.conn)
      code = started["user_code"]

      ctx.conn |> post(~p"/activate", %{user_code: code, decision: "approve"}) |> response(302)

      conn = post(ctx.conn, ~p"/activate", %{user_code: code, decision: "deny"})
      assert redirected_to(conn) == ~p"/activate"
      assert %{"token" => _} = ctx.conn |> poll(started["device_code"]) |> json_response(200)
    end

    test "a very long User-Agent is clipped, not a 500", ctx do
      started =
        ctx.conn
        |> Plug.Conn.delete_req_header("authorization")
        |> Plug.Conn.put_req_header("user-agent", String.duplicate("x", 2000))
        |> start()

      request = Repo.get_by!(DeviceAuthorization, user_code: strip(started["user_code"]))
      assert String.length(request.client_agent) == 255
    end

    test "polling without a device code is a plain bad request", ctx do
      assert %{"error" => "invalid_request"} =
               ctx.conn
               |> Plug.Conn.delete_req_header("authorization")
               |> post(~p"/api/auth/device/token", %{})
               |> json_response(400)
    end
  end

  describe "the codes themselves" do
    test "a user code avoids vowels and look-alike characters" do
      codes =
        for _ <- 1..200,
            do: Accounts.request_device_authorization() |> elem(1) |> Map.get(:user_code)

      for code <- codes do
        assert String.length(code) == 8
        refute code =~ ~r/[AEIOU01ILU]/
      end

      # And they are not all the same one.
      assert length(Enum.uniq(codes)) > 190

      # Every character of the alphabet turns up: the rejection sampling
      # throws bytes away, it does not narrow what comes out.
      assert codes |> Enum.join() |> String.graphemes() |> Enum.uniq() |> length() == 27
    end

    test "a code is forgiving about how it is typed", ctx do
      started = start(ctx.conn)
      shown = started["user_code"]

      for typed <- [shown, String.downcase(shown), String.replace(shown, "-", ""), " #{shown} "] do
        assert Accounts.device_authorization_by_user_code(typed)
      end
    end
  end

  describe "the address it was asked from" do
    test "a forwarded header from a stranger is not believed", ctx do
      conn =
        %{ctx.conn | remote_ip: {203, 0, 113, 9}}
        |> put_req_header("x-forwarded-for", "192.0.2.77")

      started = start(conn)

      assert Repo.get_by!(DeviceAuthorization, user_code: strip(started["user_code"])).client_ip ==
               "203.0.113.9"
    end

    test "one from our own proxy is", ctx do
      conn =
        %{ctx.conn | remote_ip: {127, 0, 0, 1}}
        |> put_req_header("x-forwarded-for", "198.51.100.7")

      started = start(conn)

      assert Repo.get_by!(DeviceAuthorization, user_code: strip(started["user_code"])).client_ip ==
               "198.51.100.7"
    end

    test "spoofing the header does not dodge the limit", ctx do
      previous = Application.get_env(:slipdock, :rate_limit)
      Application.put_env(:slipdock, :rate_limit, enabled: true)
      Slipdock.RateLimit.reset()
      on_exit(fn -> Application.put_env(:slipdock, :rate_limit, previous) end)

      statuses =
        for n <- 1..40 do
          %{ctx.conn | remote_ip: {203, 0, 113, 9}}
          |> put_req_header("x-forwarded-for", "192.0.2.#{n}")
          |> Plug.Conn.delete_req_header("authorization")
          |> post(~p"/api/auth/device", %{})
          |> Map.get(:status)
        end

      assert 429 in statuses
    end
  end

  describe "grinding and housekeeping" do
    test "looking up codes is rate limited", ctx do
      # Rate limiting is off in test by default, so turn it on for this one.
      previous = Application.get_env(:slipdock, :rate_limit)
      Application.put_env(:slipdock, :rate_limit, enabled: true)
      Slipdock.RateLimit.reset()
      on_exit(fn -> Application.put_env(:slipdock, :rate_limit, previous) end)

      # Approving somebody else's request only ever mints a token for your
      # own account, so grinding wins nothing — but it should still be shut.
      for _ <- 1..30, do: get(ctx.conn, ~p"/activate?user_code=ZZZZ-ZZZZ")

      assert ctx.conn
             |> get(~p"/activate?user_code=ZZZZ-ZZZZ")
             |> html_response(200) =~ "Too many codes tried"
    end

    test "deciding is rate limited too", ctx do
      previous = Application.get_env(:slipdock, :rate_limit)
      Application.put_env(:slipdock, :rate_limit, enabled: true)
      Slipdock.RateLimit.reset()
      on_exit(fn -> Application.put_env(:slipdock, :rate_limit, previous) end)

      for _ <- 1..30,
          do: post(ctx.conn, ~p"/activate", %{user_code: "ZZZZ-ZZZZ", decision: "approve"})

      started = start(ctx.conn)

      ctx.conn
      |> post(~p"/activate", %{user_code: started["user_code"], decision: "approve"})
      |> response(302)

      assert %{"error" => "authorization_pending"} =
               ctx.conn |> poll(started["device_code"]) |> json_response(400)
    end

    test "expired requests are swept when a new one is made", ctx do
      started = start(ctx.conn)

      Repo.get_by!(DeviceAuthorization, user_code: strip(started["user_code"]))
      |> Ecto.Changeset.change(expires_at: DateTime.utc_now(:second) |> DateTime.add(-1, :hour))
      |> Repo.update!()

      start(ctx.conn)

      refute Repo.get_by(DeviceAuthorization, user_code: strip(started["user_code"]))
    end
  end

  defp strip(code), do: String.replace(code, "-", "")
end

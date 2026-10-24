defmodule SlipdockWeb.API.InboundControllerTest do
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Repo, TestConfig}
  alias Slipdock.Inbound.Email
  alias SlipdockWeb.API.InboundController

  @secret "test-inbound-secret"
  @domain "in.example.com"

  # Stands in for the epics that fill the dispatcher in: accepts card mail,
  # refuses everything else the way the real one does.
  defmodule AcceptCards do
    def dispatch(%{kind: "card"}), do: {:ok, %{}}
    def dispatch(request), do: Slipdock.Inbound.Dispatcher.dispatch(request)
  end

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: [@secret])
    :ok
  end

  defp raw(opts \\ []) do
    id =
      Keyword.get(opts, :message_id, "<#{System.unique_integer([:positive])}@example.com>")

    from = Keyword.get(opts, :from, "Sender <sender@example.com>")

    "From: #{from}\r\nTo: card-abc@#{@domain}\r\nSubject: Hello\r\n" <>
      "Message-ID: #{id}\r\n\r\nBody text\r\n"
  end

  defp post_mail(conn, body, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, Integer.to_string(System.system_time(:second)))
    secret = Keyword.get(opts, :secret, @secret)
    to = Keyword.get(opts, :to, "card-abc@#{@domain}")

    signature =
      Keyword.get_lazy(opts, :signature, fn -> InboundController.sign(secret, timestamp, body) end)

    conn
    |> put_req_header("content-type", "message/rfc822")
    |> then(&if timestamp, do: put_req_header(&1, "x-slipdock-timestamp", timestamp), else: &1)
    |> then(&if signature, do: put_req_header(&1, "x-slipdock-signature", signature), else: &1)
    |> then(&if to, do: put_req_header(&1, "x-envelope-to", to), else: &1)
    |> put_req_header("x-envelope-from", "bounce@example.com")
    |> post("/api/inbound/email", body)
  end

  defp rows(recipient \\ "card-abc@#{@domain}"),
    do: Repo.all(from e in Email, where: e.recipient == ^recipient)

  describe "switched off" do
    test "404 without a domain or a secret, and nothing recorded", %{conn: conn} do
      TestConfig.put(:inbound, domain: nil, secrets: [@secret])
      body = raw()
      assert conn |> post_mail(body) |> json_response(404)

      TestConfig.put(:inbound, domain: @domain, secrets: [])
      assert build_conn() |> post_mail(body) |> json_response(404)
      assert rows() == []
    end
  end

  describe "the signature" do
    # The same pair is pinned in cloudflare/inbound-email/worker.test.js, so
    # the Worker and the app can't drift apart.
    test "a known message signs to the value the Worker computes" do
      raw = "From: a@example.com\r\nSubject: Hi\r\n\r\nBody é\r\n"

      assert InboundController.sign("s3cret", "1700000000", raw) ==
               "715b15c9a88842253a77c748601654d98800b068ee04ca81d1be4dd7499e14e0"
    end

    test "a missing signature is 401, never a bounce", %{conn: conn} do
      assert %{"error" => "missing signature"} =
               conn |> post_mail(raw(), signature: nil) |> json_response(401)
    end

    test "a wrong secret is 401", %{conn: conn} do
      assert %{"error" => "bad signature"} =
               conn |> post_mail(raw(), secret: "other") |> json_response(401)
    end

    test "a body changed after signing is 401", %{conn: conn} do
      timestamp = Integer.to_string(System.system_time(:second))
      signature = InboundController.sign(@secret, timestamp, raw())

      assert conn
             |> post_mail(raw() <> "tampered", timestamp: timestamp, signature: signature)
             |> json_response(401)
    end

    test "a timestamp over five minutes old, or in the future, is 401", %{conn: conn} do
      old = Integer.to_string(System.system_time(:second) - 301)
      ahead = Integer.to_string(System.system_time(:second) + 301)

      assert %{"error" => "stale timestamp"} =
               conn |> post_mail(raw(), timestamp: old) |> json_response(401)

      assert build_conn() |> post_mail(raw(), timestamp: ahead) |> json_response(401)
    end

    test "a missing or malformed timestamp is 401", %{conn: conn} do
      assert conn |> post_mail(raw(), timestamp: nil, signature: "x") |> json_response(401)
      assert build_conn() |> post_mail(raw(), timestamp: "soon") |> json_response(401)
    end

    test "the previous secret still works while it is rotated", %{conn: conn} do
      TestConfig.put(:inbound, domain: @domain, secrets: ["new", @secret])
      assert conn |> post_mail(raw(), secret: @secret) |> json_response(422)
    end

    test "an upper-case hex signature is accepted", %{conn: conn} do
      timestamp = Integer.to_string(System.system_time(:second))
      body = raw()
      signature = InboundController.sign(@secret, timestamp, body) |> String.upcase()

      assert conn
             |> post_mail(body, timestamp: timestamp, signature: signature)
             |> json_response(422)
    end
  end

  describe "the size cap" do
    test "a body over 26 MiB is 413 with a reason, and not recorded", %{conn: conn} do
      body = raw() <> :binary.copy("x", 26 * 1024 * 1024 + 1)

      assert %{"reject" => "The message is too large" <> _} =
               conn |> post_mail(body) |> json_response(413)

      assert rows() == []
    end
  end

  describe "a signed message" do
    test "with no recipient header is 400 with a reason", %{conn: conn} do
      assert %{"reject" => _} = conn |> post_mail(raw(), to: nil) |> json_response(400)
    end

    test "is refused for now, recorded with its reason", %{conn: conn} do
      user = user_fixture("sender@example.com")

      assert %{"reject" => "Mail to this address isn't set up on this server yet."} =
               conn |> post_mail(raw(from: "Sender <#{user.email}>")) |> json_response(422)

      assert [email] = rows()
      assert email.outcome == "rejected"
      assert email.kind == "card"
      assert email.sender == user.email
      assert email.subject == "Hello"
      assert email.reason =~ "isn't set up"
      assert email.size > 0
      # The sender claims to be this account, so it shows in their log.
      assert email.user_id == user.id
    end

    test "to an address outside the pattern is refused as no such address", %{conn: conn} do
      to = "hello@#{@domain}"

      assert %{"reject" => "No such address here."} =
               conn |> post_mail(raw(), to: to) |> json_response(422)

      assert [%{kind: "unknown", outcome: "rejected"}] = rows(to)
    end

    test "to another domain is refused, however the local part looks", %{conn: conn} do
      to = "card-abc@example.org"

      assert %{"reject" => "No such address here."} =
               conn |> post_mail(raw(), to: to) |> json_response(422)
    end

    test "accepted is 202, and a repeat is 200 with no second row", %{conn: conn} do
      TestConfig.put(:inbound_dispatcher, AcceptCards)
      body = raw(message_id: "<once@example.com>")

      assert %{"ok" => true, "id" => id} = conn |> post_mail(body) |> json_response(202)

      assert %{"ok" => true, "id" => ^id, "duplicate" => true} =
               build_conn() |> post_mail(body) |> json_response(200)

      assert [%{id: ^id, outcome: "accepted"}] = rows()
    end

    test "a repeat of a refused message is refused again, without a second row", %{conn: conn} do
      body = raw(message_id: "<refused@example.com>")

      assert %{"reject" => reason} = conn |> post_mail(body) |> json_response(422)
      assert %{"reject" => ^reason} = build_conn() |> post_mail(body) |> json_response(422)
      assert [_] = rows()
    end

    test "the same message to two addresses is two rows", %{conn: conn} do
      TestConfig.put(:inbound_dispatcher, AcceptCards)
      body = raw(message_id: "<twice@example.com>")

      assert conn |> post_mail(body) |> json_response(202)
      assert build_conn() |> post_mail(body, to: "card-xyz@#{@domain}") |> json_response(202)
      assert [_] = rows()
      assert [_] = rows("card-xyz@#{@domain}")
    end

    test "without a Message-ID, a repeat is still recognised", %{conn: conn} do
      TestConfig.put(:inbound_dispatcher, AcceptCards)
      body = "From: sender@example.com\r\nSubject: No id\r\n\r\nBody\r\n"

      assert conn |> post_mail(body) |> json_response(202)
      assert build_conn() |> post_mail(body) |> json_response(200)
      assert [%{message_id: "<" <> _}] = rows()
    end

    test "that can't be parsed is refused as unreadable, under the envelope sender",
         %{conn: conn} do
      assert %{"reject" => "The message couldn't be read."} =
               conn |> post_mail("just some bytes") |> json_response(422)

      assert [%{sender: "bounce@example.com", subject: nil, outcome: "rejected"}] = rows()
      # And a repeat is refused the same way, without a second row.
      assert build_conn() |> post_mail("just some bytes") |> json_response(422)
      assert [_] = rows()
    end
  end

  describe "automatic mail" do
    test "is 202 with the reason it was dropped, so the Worker never bounces it", %{conn: conn} do
      body = "Auto-Submitted: auto-replied\r\n" <> raw()

      assert %{"ok" => true, "dropped" => "Automatic mail" <> _} =
               conn |> post_mail(body) |> json_response(202)

      assert [%{outcome: "dropped"}] = rows()
      assert %{"duplicate" => true} = build_conn() |> post_mail(body) |> json_response(200)
    end
  end

  describe "rate limits" do
    setup do
      TestConfig.put(:rate_limit, enabled: true)
      :ok
    end

    test "too much mail to one address is 429 with a reason, and not recorded", %{conn: conn} do
      token = "rl#{System.unique_integer([:positive])}"
      to = "card-#{token}@#{@domain}"
      for _ <- 1..30, do: Slipdock.RateLimit.hit("inbound:token:#{token}", 30, :timer.hours(1))

      assert %{"reject" => "Too much mail" <> _} =
               conn |> post_mail(raw(), to: to) |> json_response(429)

      assert rows(to) == []
    end

    test "too much mail from one sender is 429", %{conn: conn} do
      sender = "flood#{System.unique_integer([:positive])}@example.com"
      for _ <- 1..60, do: Slipdock.RateLimit.hit("inbound:sender:#{sender}", 60, :timer.hours(1))

      assert conn |> post_mail(raw(from: sender)) |> json_response(429)
    end
  end
end

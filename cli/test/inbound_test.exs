defmodule SlipdockCLI.InboundTest do
  @moduledoc "`slipdock inbound log`: your inbound mail and what came of it (#1242)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Inbound}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-inbound-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  @two ~s({"domain":"example.com","inbound":[) <>
         ~s({"id":2,"at":"2026-10-24T19:00:00Z","kind":"card","subject":"New card","outcome":"accepted","reason":null,"link":"/boards/3/cards/9"},) <>
         ~s({"id":1,"at":"2026-10-24T18:00:00Z","kind":"reply","subject":null,"outcome":"rejected","reason":"You can no longer add to this board.","link":null}]})

  test "lists each message: when, kind, outcome, subject, and why or what it made" do
    serve([{200, @two}])
    out = capture_io(fn -> Inbound.run("inbound", ["log"], []) end)

    assert_received {:request, "GET", "/api/inbound/log", _}
    assert out =~ "OUTCOME"
    assert out =~ ~r/2026-10-24 19:00\s+card\s+accepted\s+New card\s+\/boards\/3\/cards\/9/
    assert out =~ ~r/2026-10-24 18:00\s+reply\s+bounced\s+\(no subject\)\s+You can no longer add/
  end

  test "none says where mail would show" do
    serve([{200, ~s({"domain":"example.com","inbound":[]})}])

    assert capture_io(fn -> Inbound.run("inbound", ["log"], []) end) =~
             "No inbound mail yet. Mail you send to an address at example.com shows here."
  end

  test "--json passes the answer through" do
    serve([{200, @two}])
    json = capture_io(fn -> Inbound.run("inbound", ["log"], json: true) end)
    assert %{"inbound" => [%{"id" => 2}, %{"id" => 1}]} = JSON.decode!(json)
  end

  @board ~s({"domain":"example.com","board":{"id":3,"code":"slipdock","name":"Slipdock"},) <>
           ~s("addresses":{"card":"card-aaaa@example.com"}})

  test "inbound <board> shows your card address for it" do
    serve([{200, @board}])
    out = capture_io(fn -> Inbound.run("inbound", ["slipdock"], []) end)

    assert_received {:request, "GET", "/api/boards/slipdock/inbound", _}
    assert out =~ "new card on slipdock:  card-aaaa@example.com"
    refute out =~ "New address made"
  end

  test "inbound <board> --rotate posts, and says the old address is gone" do
    serve([{200, @board}])
    out = capture_io(fn -> Inbound.run("inbound", ["slipdock"], rotate: true) end)

    assert_received {:request, "POST", "/api/boards/slipdock/inbound/rotate", _}
    assert out =~ "New address made. Mail to the old one bounces from now on."
    assert out =~ "card-aaaa@example.com"
  end

  test "a board ref with odd characters is escaped in the path" do
    serve([{200, @board}])
    capture_io(fn -> Inbound.run("inbound", ["My Board"], []) end)
    assert_received {:request, "GET", "/api/boards/My%20Board/inbound", _}
  end

  test "inbound me, and inbound me --rotate, for the personal address" do
    me =
      ~s({"domain":"example.com","board":null,"addresses":{"add":"add-bbbb@example.com"}})

    serve([{200, me}, {200, me}])

    assert capture_io(fn -> Inbound.run("inbound", ["me"], []) end) =~
             "quick add, any board:  add-bbbb@example.com"

    assert_received {:request, "GET", "/api/me/inbound", _}

    capture_io(fn -> Inbound.run("inbound", ["me"], rotate: true) end)
    assert_received {:request, "POST", "/api/me/inbound/rotate", _}
  end

  test "inbound me --ack on|off sets the acknowledgement, and it is shown" do
    on =
      ~s({"domain":"example.com","board":null,"ack":true,"addresses":{"add":"add-bbbb@example.com"}})

    serve([{200, on}])

    out = capture_io(fn -> Inbound.run("inbound", ["me"], ack: "on") end)
    assert_received {:request, "POST", "/api/me/inbound", body}
    assert body =~ ~s("ack":true)
    assert out =~ "acknowledgements: on"

    off = String.replace(on, ~s("ack":true), ~s("ack":false))
    serve([{200, off}])

    assert capture_io(fn -> Inbound.run("inbound", ["me"], ack: "off") end) =~
             "acknowledgements: off"

    assert_received {:request, "POST", "/api/me/inbound", body}
    assert body =~ ~s("ack":false)
  end

  test "--json passes the addresses through" do
    serve([{200, @board}])
    json = capture_io(fn -> Inbound.run("inbound", ["slipdock"], json: true) end)
    assert %{"addresses" => %{"card" => "card-aaaa@example.com"}} = JSON.decode!(json)
  end

  # A refusal (inbound mail off: 404) and a usage error end in
  # `System.halt/1`, so, as elsewhere in this suite, they are not run here.

  test "the CLI routes inbound here and lists it in the help" do
    serve([{200, ~s({"domain":"example.com","inbound":[]})}])
    assert capture_io(fn -> SlipdockCLI.main(["inbound", "log"]) end) =~ "No inbound mail yet"
    assert_received {:request, "GET", "/api/inbound/log", _}

    help = capture_io(fn -> SlipdockCLI.main(["--help"]) end)
    assert help =~ "inbound log"
    assert help =~ "inbound <board> [--rotate]"
    assert help =~ "inbound me [--rotate]"
    assert help =~ "--ack on|off"
  end
end

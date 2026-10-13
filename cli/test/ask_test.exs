defmodule SlipdockCLI.AskTest do
  @moduledoc "`slipdock ask`: what it sends the server, `--board` included, and what it prints."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    saved = Map.new(~w(SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    System.delete_env("KANBAN_TOKEN")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  @answer ~s({"question":"q","answer":"Finance are waiting.","searches":["refunds"],"sources":[{"kind":"card","id":57,"title":"Refund rounding","board":"Delivery","found_by":"refunds","url":"/boards/1/cards/57"}]})

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  test "the words are the question, and no board is sent unless asked for" do
    serve([{200, @answer}])

    out = capture_io(fn -> Boards.run("ask", ["what", "about", "refunds"], []) end)

    assert_received {:request, "POST", "/api/ask", body}
    assert JSON.decode!(body) == %{"q" => "what about refunds"}
    assert out =~ "Finance are waiting."
    assert out =~ "#57"
    assert out =~ "Refund rounding"
  end

  test "--board keeps the question to that board" do
    serve([{200, @answer}])

    capture_io(fn -> Boards.run("ask", ["what", "now"], board: "delivery") end)

    assert_received {:request, "POST", "/api/ask", body}
    assert JSON.decode!(body) == %{"q" => "what now", "board" => "delivery"}
  end
end

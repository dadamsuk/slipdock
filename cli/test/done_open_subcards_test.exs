defmodule SlipdockCLI.DoneOpenSubcardsTest do
  @moduledoc """
  Orchestration fixes 5 (#1758) on the CLI: `slipdock done` on a card whose
  sub-board has open cards gets the server's 422, which names them. A
  refusal ends in `System.halt/1`, so it is covered as the value `done`
  halts on (what `Util.out/3` prints, with its HTTP status); the server's
  side is in `SlipdockWeb.API.OpenSubcardsTest`.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, HTTP}

  @refusal %{
    "error" => "validation failed",
    "details" => %{
      "completed" => [
        "is refused: card #12 has open subcards: #13 Foo, #14 Bar are still open. " <>
          "Finish or archive them first, then complete it"
      ]
    }
  }

  @card ~s({"card":{"id":12,"title":"Epic","column":"Done","board_id":3,"priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0,"items":[]}}})

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-subcards-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    System.delete_env("KANBAN_TOKEN")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  test "the completion done sends is refused with a 422 that names the open subcards" do
    serve([{422, JSON.encode!(@refusal)}])

    assert {:error, 422, %{"error" => "validation failed", "details" => details}} =
             HTTP.patch("/cards/12", %{"completed" => true})

    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert JSON.decode!(body) == %{"completed" => true}
    assert [message] = details["completed"]
    assert message =~ "#13 Foo, #14 Bar are still open"
  end

  test "once they are done, done completes it as before" do
    serve([{200, @card}])
    out = capture_io(fn -> Boards.run("done", ["12"], []) end)
    assert out =~ "completed"
    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert JSON.decode!(body) == %{"completed" => true}
  end
end

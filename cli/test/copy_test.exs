defmodule SlipdockCLI.CopyTest do
  @moduledoc """
  `slipdock copy`: what it sends, and what it says. Refusals end in
  `System.halt/1` through the shared `out/3`; the server's side of them is in
  the app's copy_card_api_test.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-copy-#{System.unique_integer([:positive])}")
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

    :ok
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  @copied ~s({"card":{"id":12,"title":"Weekly review","column":"To Do","completed":false,"priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":2,"items":[]}},"copied_from":7})

  test "with no options it sends nothing but the card, and says what it made" do
    serve([{201, @copied}])
    out = capture_io(fn -> Boards.run("copy", ["7"], []) end)
    assert_received {:request, "POST", "/api/cards/7/copy", body}
    assert JSON.decode!(body) == %{}
    assert out =~ "copied #7 to"
    assert out =~ "#12"
    assert out =~ "Weekly review"
  end

  test "--board, --column, --title and --top go through" do
    serve([{201, @copied}])

    capture_io(fn ->
      Boards.run("copy", ["7"], board: "ops", column: "To Do", title: "Again", top: true)
    end)

    assert_received {:request, "POST", "/api/cards/7/copy", body}

    assert JSON.decode!(body) == %{
             "board" => "ops",
             "column" => "To Do",
             "title" => "Again",
             "at" => "top"
           }
  end

  test "--bottom" do
    serve([{201, @copied}])
    capture_io(fn -> Boards.run("copy", ["7"], bottom: true) end)
    assert_received {:request, "POST", "/api/cards/7/copy", body}
    assert JSON.decode!(body) == %{"at" => "bottom"}
  end
end

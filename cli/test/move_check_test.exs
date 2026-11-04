defmodule SlipdockCLI.MoveCheckTest do
  @moduledoc "`slipdock move-check` (#1752): what it sends, and the order it prints back."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home =
      Path.join(System.tmp_dir!(), "slipdock-movecheck-#{System.unique_integer([:positive])}")

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

  @items %{
    "items" => [
      %{"id" => 13, "text" => "ship it", "done" => false, "position" => 0},
      %{"id" => 11, "text" => "write it", "done" => true, "position" => 1}
    ]
  }

  test "--before sends the item to go in front of, and prints the new order" do
    serve([{200, JSON.encode!(@items)}])

    out = capture_io(fn -> Boards.run("move-check", ["13"], before: "11") end)

    assert_received {:request, "POST", "/api/checklist/13/move", sent}
    assert JSON.decode!(sent) == %{"before" => "11"}
    assert out =~ "moved item #13"
    assert out =~ ~r/\[ \] #13 ship it\n\s+\[x\] #11 write it/
  end

  test "without --before it sends no before, which puts the item last" do
    serve([{200, JSON.encode!(@items)}])
    capture_io(fn -> Boards.run("move-check", ["11"], []) end)
    assert_received {:request, "POST", "/api/checklist/11/move", sent}
    assert JSON.decode!(sent) == %{}
  end

  test "--json prints the server's answer as it is" do
    serve([{200, JSON.encode!(@items)}])
    out = capture_io(fn -> Boards.run("move-check", ["13"], json: true) end)
    assert JSON.decode!(out) == @items
  end
end

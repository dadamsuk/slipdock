defmodule SlipdockCLI.PageSwitchTest do
  @moduledoc "`slipdock page switch`: the quick switcher from a shell (W-103 R11.4)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-switch-#{System.unique_integer([:positive])}")
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

  defp run(args, opts, response) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, response}]))
    out = capture_io(fn -> Wiki.run("page", args, opts) end)
    assert_received {:request, "GET", path, _}
    {path, out}
  end

  test "sends the letters and prints each match with its path and how it matched" do
    {path, out} =
      run(
        ["switch", "brain", "acme", "call"],
        [limit: 5],
        ~s({"matches":[{"code":"W-7","title":"Call","path":"Journal/Acme/Call","board":"Journal Desk","matched":"path"},
          {"code":"W-9","title":"Rust","path":"Rust","board":"KB","matched":"alias:Borrow checker"}]})
      )

    assert path =~ "/boards/brain/pages/switch"
    assert path =~ "q=acme+call"
    assert path =~ "limit=5"
    assert out =~ "W-7"
    assert out =~ "Journal/Acme/Call · Journal Desk"
    assert out =~ "(alias Borrow checker)"
  end

  test "no match says so" do
    {_path, out} = run(["switch", "brain", "zz"], [], ~s({"matches":[]}))
    assert out =~ "no note's title, alias or path matches"
  end
end

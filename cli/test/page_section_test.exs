defmodule SlipdockCLI.PageSectionTest do
  @moduledoc """
  `slipdock page section … --replace|--append` (#1756): the server says what
  a section write did to the section, and the command shows it.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  setup do
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    home = Path.join(System.tmp_dir!(), "slipdock-section-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
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

  defp run(args, opts, response) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, response}]))
    out = capture_io(fn -> Wiki.run("page", args, opts) end)
    assert_receive {:request, method, path, body}, 2_000
    {{method, path, :json.decode(body)}, out}
  end

  defp saved(note) do
    %{"page" => %{"code" => "W-9", "title" => "Keys", "url" => "/w/9"}}
    |> then(&if(note, do: Map.put(&1, "note", note), else: &1))
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  test "a replace sends the body as given and shows that the heading was kept" do
    {{method, path, sent}, out} =
      run(["section", "W-9", "Keyboard"], [body: "New keys."], saved("heading kept"))

    assert {method, path} == {"PUT", "/api/pages/W-9/section/Keyboard"}
    assert sent["body"] == "New keys."
    assert out =~ "replaced Keyboard of W-9 Keys (heading kept)"
  end

  test "an append into a table shows that the table was extended" do
    {{method, path, sent}, out} =
      run(["section", "W-9", "Table"], [append: "| b | 2 |"], saved("table extended"))

    assert {method, path} == {"POST", "/api/pages/W-9/section/Table"}
    assert sent["body"] == "| b | 2 |"
    assert out =~ "appended to Table of W-9 Keys (table extended)"
  end

  test "a server that sends no note prints the plain line" do
    {_request, out} = run(["section", "W-9", "Log"], [append: "- x"], saved(nil))
    assert out =~ "appended to Log of W-9 Keys"
    refute out =~ "("
  end

  describe "--append - (#1966)" do
    test "reads the text from stdin rather than appending a literal -" do
      System.put_env("SLIPDOCK_URL", FakeServer.start([{200, saved(nil)}]))
      text = "- one\n- two\n"

      out =
        capture_io([input: text], fn ->
          Wiki.run("page", ["section", "W-9", "Log"], append: "-", message: "#1966 log")
        end)

      assert_receive {:request, "POST", "/api/pages/W-9/section/Log", body}, 2_000
      assert :json.decode(body) == %{"body" => text, "message" => "#1966 log"}
      assert out =~ "appended to Log of W-9 Keys"
    end

    test "--body - still reads the replacement from stdin" do
      System.put_env("SLIPDOCK_URL", FakeServer.start([{200, saved(nil)}]))

      capture_io([input: "Piped keys."], fn ->
        Wiki.run("page", ["section", "W-9", "Keyboard"], body: "-")
      end)

      assert_receive {:request, "PUT", "/api/pages/W-9/section/Keyboard", body}, 2_000
      assert :json.decode(body)["body"] == "Piped keys."
    end
  end
end

defmodule SlipdockCLI.ToolsTest do
  @moduledoc "`slipdock tools`: publishing a folder as a package, and reading Tools back."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Tools}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-tools-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    Enum.each(~w(SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  defp tool_dir(home) do
    dir = Path.join(home, "demo")
    File.mkdir_p!(Path.join(dir, "skills/demo"))
    File.write!(Path.join(dir, "tool.json"), ~s({"name":"demo","version":"1.0.0","summary":"s"}))
    File.write!(Path.join(dir, "README.md"), "# Demo")
    File.write!(Path.join(dir, "skills/demo/SKILL.md"), "---\nname: demo\n---\n")
    File.write!(Path.join(dir, ".DS_Store"), "junk")
    dir
  end

  test "pack keeps every file at its path in the folder and leaves dotfiles out", %{home: home} do
    bytes = Tools.pack(tool_dir(home))
    {:ok, entries} = :erl_tar.extract({:binary, bytes}, [:compressed, :memory])

    assert entries |> Enum.map(&to_string(elem(&1, 0))) |> Enum.sort() ==
             ["README.md", "skills/demo/SKILL.md", "tool.json"]
  end

  test "publish sends the packed folder as the multipart field package", %{home: home} do
    dir = tool_dir(home)
    reply = ~s({"tool":{"name":"demo","version":"1.0.0","sha":"abc"}})
    System.put_env("SLIPDOCK_URL", FakeServer.start([{201, reply}]))

    out = capture_io(fn -> Tools.run("tools", ["publish", dir], []) end)

    assert_received {:request, "POST", "/api/tools", body}
    assert body =~ ~s(name="package"; filename="demo.tar.gz")
    assert body =~ "content-type: application/gzip"
    assert out =~ "published demo 1.0.0"
  end

  test "show prints the board, the skills and the files", %{home: _home} do
    tool =
      ~s({"tool":{"name":"demo","title":"Demo","version":"1.1.0","sha":"abc","summary":"Does it",) <>
        ~s("board":{"lists":[{"name":"Found"},{"name":"Closed"}],"folders":["Config"],"tags":[{"name":"hot"}],) <>
        ~s("pages":[{"title":"Config"}],"automations":[{"preset":"feed_runner"}]},) <>
        ~s("skills":[{"name":"demo","sha":"s1","files":["SKILL.md"]}],) <>
        ~s("files":[{"path":"a.sh","install":"local","skill":"demo"}],"versions":["1.1.0","1.0.0"]}})

    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, tool}]))
    out = capture_io(fn -> Tools.run("tools", ["show", "demo"], version: "1.1.0") end)

    assert_received {:request, "GET", "/api/tools/demo?version=1.1.0", _}
    assert out =~ "board: Found → Closed"
    assert out =~ "folders: Config"
    assert out =~ "tags: hot"
    assert out =~ "automations: feed_runner"
    assert out =~ "skill: demo"
    assert out =~ "file: a.sh (beside demo)"
    assert out =~ "versions: 1.1.0, 1.0.0"
  end

  test "install-board asks the server to build the board and says which it is" do
    reply =
      ~s({"install":{"board":"demo","board_name":"Demo","created":true,"installed_version":"1.0.0",) <>
        ~s("url":"http://x/boards/9","added":{"lists":["Found","Closed"],"pages":[]}}})

    System.put_env("SLIPDOCK_URL", FakeServer.start([{201, reply}]))

    out =
      capture_io(fn ->
        Tools.run("tools", ["install-board", "demo"], name: "Demo", version: "1.0.0")
      end)

    assert_received {:request, "POST", "/api/tools/demo/install", body}
    assert :json.decode(body) == %{"name" => "Demo", "version" => "1.0.0"}
    assert out =~ "made board demo (Demo), demo 1.0.0"
    assert out =~ "added lists: Found, Closed"
    refute out =~ "added pages"
  end

  test "install-board on a board already made says so" do
    reply =
      ~s({"install":{"board":"demo","board_name":"Demo","created":false,"installed_version":"1.0.0",) <>
        ~s("url":"http://x/boards/9","added":null}})

    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, reply}]))
    out = capture_io(fn -> Tools.run("tools", ["install-board", "demo"], []) end)

    assert_received {:request, "POST", "/api/tools/demo/install", "{}"}
    assert out =~ "already have board demo"
  end
end

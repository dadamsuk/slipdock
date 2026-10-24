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

  test "install-board handbook --board puts the handbook on that board" do
    reply =
      ~s({"install":{"board":"proj","board_name":"Project","created":true,"installed_version":"1.0.0",) <>
        ~s("url":"http://x/boards/9","added":{"folders":["Handbook"],"pages":["Index"]}}})

    System.put_env("SLIPDOCK_URL", FakeServer.start([{201, reply}]))

    out =
      capture_io(fn -> Tools.run("tools", ["install-board", "handbook"], board: "proj") end)

    assert_received {:request, "POST", "/api/tools/handbook/install", body}
    assert :json.decode(body) == %{"board" => "proj"}
    assert out =~ "installed handbook on board proj (Project)"
    assert out =~ "added pages: Index"
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

  defp sha(files) do
    files
    |> Enum.reduce(:crypto.hash_init(:sha256), fn {f, t}, acc ->
      :crypto.hash_update(acc, f <> "\0" <> t)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp skills_tar(entries) do
    path = Path.join(System.tmp_dir!(), "t-#{System.unique_integer([:positive])}.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end),
        [:compressed, :write]
      )

    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  defp tool_json(sha) do
    ~s({"tool":{"name":"demo","title":"Demo","version":"1.0.0","board":{"lists":[]},"installed":null,) <>
      ~s("skills":[{"name":"demo","sha":"#{sha}","files":["SKILL.md","run.sh"]}]}})
  end

  test "install unpacks the skills into --dir and points at the board", %{home: home} do
    files = [{"SKILL.md", "skill"}, {"run.sh", "echo"}]
    tar = skills_tar([{"demo/SKILL.md", "skill"}, {"demo/run.sh", "echo"}])
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, tool_json(sha(files))}, {200, tar}]))
    dir = Path.join(home, "skills")

    out = capture_io(fn -> Tools.run("tools", ["install", "demo"], dir: dir) end)

    assert_received {:request, "GET", "/api/tools/demo", _}
    assert_received {:request, "GET", "/api/tools/demo/skills.tar.gz?version=1.0.0", _}
    assert File.read!(Path.join(dir, "demo/SKILL.md")) == "skill"
    assert File.read!(Path.join(dir, "demo/run.sh")) == "echo"
    assert out =~ "installed demo 1.0.0: 1 skill(s), 2 file(s)"
    assert out =~ "ask your agent to set up Demo"
  end

  test "check says current, then behind once a file changes", %{home: home} do
    dir = Path.join(home, "skills")
    File.mkdir_p!(Path.join(dir, "demo"))
    File.write!(Path.join(dir, "demo/SKILL.md"), "skill")
    File.write!(Path.join(dir, "demo/run.sh"), "echo")
    good = sha([{"SKILL.md", "skill"}, {"run.sh", "echo"}])

    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, tool_json(good)}]))
    out = capture_io(fn -> Tools.run("tools", ["check", "demo"], dir: dir) end)
    assert out =~ "current"

    File.write!(Path.join(dir, "demo/run.sh"), "echo changed")
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, tool_json(good)}]))
    out = capture_io(fn -> Tools.run("tools", ["check", "demo"], dir: dir) end)
    assert out =~ "behind"

    File.rm_rf!(Path.join(dir, "demo"))
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, tool_json(good)}]))
    out = capture_io(fn -> Tools.run("tools", ["check", "demo"], dir: dir) end)
    assert out =~ "not installed"
  end

  test "the list shows each Tool's kind and the board its install made" do
    reply =
      ~s({"tools":[{"name":"a","version":"1.0.0","kind":"listed","summary":"S","installed":{"board":"abc"}},) <>
        ~s({"name":"b","version":"2.0.0","kind":"mine","summary":"T","installed":null}]})

    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, reply}]))
    out = capture_io(fn -> Tools.run("tools", [], []) end)

    assert out =~ ~r/a\s+1\.0\.0\s+listed\s+abc/
    assert out =~ ~r/b\s+2\.0\.0\s+mine\s+-/
  end

  test "request-listing asks for the version and says an admin decides" do
    reply =
      ~s({"tool":{"name":"demo","version":"1.2.0","listing":{"this_version":"waiting for an admin"}}})

    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, reply}]))

    out = capture_io(fn -> Tools.run("tools", ["request-listing", "demo"], version: "1.2.0") end)

    assert_received {:request, "POST", "/api/tools/demo/listing", body}
    assert :json.decode(body) == %{"version" => "1.2.0"}
    assert out =~ "an admin approves it before it shows (waiting for an admin)"
  end

  test "install-board on an upgrade says what was added and what was left alone" do
    reply =
      ~s({"install":{"board":"demo","board_name":"Demo","created":false,"upgraded":true,) <>
        ~s("installed_version":"2.0.0","url":"http://x/boards/9",) <>
        ~s("added":{"tags":["cold"]},"skipped":{"pages":["Config"],"lists":[]}}})

    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, reply}]))
    out = capture_io(fn -> Tools.run("tools", ["install-board", "demo"], []) end)

    assert out =~ "upgraded board demo (Demo), demo 2.0.0"
    assert out =~ "added tags: cold"
    assert out =~ "left alone pages: Config"
    refute out =~ "left alone lists"
  end
end

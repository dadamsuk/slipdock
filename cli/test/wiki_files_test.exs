defmodule SlipdockCLI.WikiFilesTest do
  @moduledoc """
  `slipdock wiki files` and `wiki get` (#1156): the wiki's files that are
  not pages, listed and fetched by path; and `slipdock tools file`, one file
  of a Tool's package by its path.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Tools, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-wf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    Enum.each(~w(SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &System.delete_env/1)
    here = File.cwd!()
    File.cd!(home)

    on_exit(fn ->
      File.cd!(here)

      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  describe "wiki files" do
    test "lists each file by path, size and the start of its sha" do
      serve([
        {200,
         ~s({"board":"jobs","files":[{"path":"Tool/build.py","size":12,"sha256":"abcdef0123456789ff"}]})}
      ])

      out = capture_io(fn -> Wiki.run("wiki", ["files", "jobs"], []) end)

      assert_received {:request, "GET", "/api/boards/jobs/files", _}
      assert out =~ ~r/Tool\/build\.py\s+12\s+abcdef012345\b/
      refute out =~ "6789ff"
    end

    test "--folder asks for one folder" do
      serve([{200, ~s({"board":"jobs","files":[]})}])

      out = capture_io(fn -> Wiki.run("wiki", ["files", "jobs"], folder: "Tool/templates") end)

      assert_received {:request, "GET", path, _}
      assert path == "/api/boards/jobs/files?folder=Tool%2Ftemplates"
      assert out =~ "no files"
    end
  end

  describe "wiki get" do
    test "with no --out, saves it under its own name here", %{home: home} do
      serve([{200, "print('hi')\n"}])

      out = capture_io(fn -> Wiki.run("wiki", ["get", "jobs", "Tool/build.py"], []) end)

      assert_received {:request, "GET", "/api/boards/jobs/files/Tool/build.py", _}
      assert File.read!(Path.join(home, "build.py")) == "print('hi')\n"
      refute File.exists?(Path.join(home, "build.py.part"))
      assert out =~ "saved build.py (12 bytes)"
    end

    test "each segment of the path is encoded, the slashes kept" do
      serve([{200, "x"}])

      capture_io(fn ->
        Wiki.run("wiki", ["get", "jobs", "Tool/templates/cv template.docx"], out: "cv.docx")
      end)

      assert_received {:request, "GET",
                       "/api/boards/jobs/files/Tool/templates/cv%20template.docx", _}
    end

    test "--out - writes the bytes to stdout and nothing else" do
      serve([{200, <<0, 1, 2, 255>>}])

      out = capture_io(fn -> Wiki.run("wiki", ["get", "jobs", "Tool/a.bin"], out: "-") end)

      assert out == <<0, 1, 2, 255>>
    end

    test "the name it saves under is the last segment, and a file already here is kept", %{
      home: home
    } do
      assert Wiki.wiki_file_dest("Tool/../../etc/passwd", []) == {:ok, "passwd"}
      assert {:error, msg} = Wiki.wiki_file_dest("Tool/..", [])
      assert msg =~ "--out"
      assert {:error, _} = Wiki.wiki_file_dest("", [])

      File.write!(Path.join(home, "build.py"), "mine")

      assert {:error, "build.py is already here: --force" <> _} =
               Wiki.wiki_file_dest("Tool/build.py", [])

      assert Wiki.wiki_file_dest("Tool/build.py", force: true) == {:ok, "build.py"}
    end
  end

  describe "tools file" do
    test "prints the file to stdout, from the latest version" do
      serve([{200, "---\nname: demo\n---\n\nRun it."}])

      out = capture_io(fn -> Tools.run("tools", ["file", "demo", "skills/demo/SKILL.md"], []) end)

      assert_received {:request, "GET", "/api/tools/demo/files/skills/demo/SKILL.md", _}
      assert out == "---\nname: demo\n---\n\nRun it."
    end

    test "--version asks for that version, and --out saves it", %{home: home} do
      serve([{200, "print(1)"}])
      dest = Path.join(home, "build.py")

      out =
        capture_io(fn ->
          Tools.run("tools", ["file", "demo", "files/build.py"], version: "1.2.0", out: dest)
        end)

      assert_received {:request, "GET", "/api/tools/demo/files/files/build.py?version=1.2.0", _}
      assert File.read!(dest) == "print(1)"
      assert out =~ "saved #{dest} (8 bytes)"
    end
  end

  describe "tools download" do
    test "asks which version is latest and saves the package as <name>-<version>.tar.gz" do
      serve([{200, ~s({"tool":{"name":"demo","version":"1.3.0"}})}, {200, "PKG"}])

      out = capture_io(fn -> Tools.run("tools", ["download", "demo"], []) end)

      assert_received {:request, "GET", "/api/tools/demo", _}
      assert_received {:request, "GET", "/api/tools/demo/package.tar.gz?version=1.3.0", _}
      assert File.read!("demo-1.3.0.tar.gz") == "PKG"
      assert out =~ "saved demo-1.3.0.tar.gz (3 bytes)"
    end

    test "--version goes straight to that version, and --out saves it there", %{home: home} do
      serve([{200, "OLD"}])
      dest = Path.join(home, "mine.tgz")

      capture_io(fn ->
        Tools.run("tools", ["download", "demo"], version: "1.0.0", out: dest)
      end)

      assert_received {:request, "GET", "/api/tools/demo/package.tar.gz?version=1.0.0", _}
      refute_received {:request, "GET", "/api/tools/demo", _}
      assert File.read!(dest) == "OLD"
    end

    test "--out - writes the bytes to stdout" do
      serve([{200, "RAW"}])

      out =
        capture_io(fn -> Tools.run("tools", ["download", "demo"], version: "1.0.0", out: "-") end)

      assert out == "RAW"
      refute File.exists?("demo-1.0.0.tar.gz")
    end

    test "a file already there is refused unless --force; stdout never is" do
      assert Tools.package_dest("demo", "1.0.0", []) == {:ok, "demo-1.0.0.tar.gz"}

      File.write!("demo-1.0.0.tar.gz", "mine")

      assert {:error, "demo-1.0.0.tar.gz is already here: --force" <> _} =
               Tools.package_dest("demo", "1.0.0", [])

      assert Tools.package_dest("demo", "1.0.0", force: true) == {:ok, "demo-1.0.0.tar.gz"}
      assert Tools.package_dest("demo", "1.0.0", out: "-") == {:ok, "-"}
      assert Tools.package_dest("demo", "1.0.0", out: "elsewhere.tgz") == {:ok, "elsewhere.tgz"}
    end
  end
end

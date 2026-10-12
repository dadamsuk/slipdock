defmodule SlipdockCLI.SyncWatchTest do
  @moduledoc """
  What keeps a mirror in sync on its own (W-103 R2.1, R2.6, R2.7): the
  watcher's timing (a pass once the folder has been still for 2 s, the
  change feed asked between), `.slipdockignore`, and the service each
  system runs it as.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeVault, Sync}
  alias SlipdockCLI.Sync.{Engine, Scan, Service, State, Watch}

  setup do
    root = Path.join(System.tmp_dir!(), "slipdock-watch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  describe ".slipdockignore" do
    test "globs by name anywhere, by path from the root, and whole folders" do
      patterns =
        Scan.parse_ignores("""
        # private things
        *.pdf
        Private/
        drafts/*.md
        **/scratch.md
        !keep.pdf
        """)

      assert Scan.ignored?("a.pdf", patterns)
      assert Scan.ignored?("deep/in/b.pdf", patterns)
      assert Scan.ignored?("Private/x.md", patterns)
      assert Scan.ignored?("Notes/Private/x.md", patterns)
      assert Scan.ignored?("drafts/one.md", patterns)
      refute Scan.ignored?("drafts/sub/one.md", patterns)
      refute Scan.ignored?("notes/drafts/one.md", patterns)
      assert Scan.ignored?("a/b/scratch.md", patterns)
      assert Scan.ignored?("scratch.md", patterns)
      # `!` is not supported, so the line is skipped rather than misread.
      assert Scan.ignored?("keep.pdf", patterns)
      refute Scan.ignored?("Notes/Plan.md", patterns)
      refute Scan.ignored?("Privateer.md", patterns)
    end

    test "an ignored file is neither sent nor fetched, and what the state knew there stays",
         %{root: root} do
      vault = FakeVault.start()
      FakeVault.put(vault, "Private/Server.md", "s")
      kept = FakeVault.put(vault, "Old.md", "o")
      write(root, ".slipdockignore", "Private/\nOld.md\n")
      write(root, "Private/Local.md", "l")
      write(root, "Old.md", "o")
      write(root, "Open.md", "open")

      state = %{
        State.new("http://test", %{"id" => 1, "name" => "B"}, "h")
        | "entries" => %{"Old.md" => %{"id" => kept + 100, "kind" => "page", "hash" => "x"}}
      }

      {:ok, state, report} = Engine.run(root, state, {FakeVault, vault}, host: "h")

      assert [%{path: "Open.md"}] = report.sent
      assert report.received == []
      refute File.exists?(Path.join(root, "Private/Server.md"))
      refute FakeVault.by_path(vault, "Private/Local.md")
      assert state["entries"]["Old.md"]["hash"] == "x"
    end
  end

  describe "the watcher's timing" do
    test "a change waits until the folder has been still for the settle time" do
      w = Watch.new(%{"a.md" => {1, 1}}, 0)
      changed = %{"a.md" => {2, 2}}

      assert {:idle, w} = Watch.tick(w, changed, 1_000)
      assert {:idle, w} = Watch.tick(w, changed, 2_500)
      assert {:pass, w} = Watch.tick(w, changed, 3_000)

      w = Watch.passed(w, changed, 3_000)
      assert {:idle, _} = Watch.tick(w, changed, 4_000)
    end

    test "a file still being written keeps pushing the pass back" do
      w = Watch.new(%{}, 0)

      w =
        Enum.reduce(1..5, w, fn n, w ->
          {:idle, w} = Watch.tick(w, %{"big.md" => {n, n}}, n * 1_000)
          w
        end)

      assert {:idle, w} = Watch.tick(w, %{"big.md" => {5, 5}}, 6_000)
      assert {:pass, _} = Watch.tick(w, %{"big.md" => {5, 5}}, 7_000)
    end

    test "with nothing changed here, the feed is asked every interval" do
      w = Watch.new(%{}, 0)
      assert {:idle, w} = Watch.tick(w, %{}, 5_000, interval_ms: 10_000)
      assert {:poll, w} = Watch.tick(w, %{}, 10_000, interval_ms: 10_000)
      assert {:idle, _} = Watch.tick(w, %{}, 15_000, interval_ms: 10_000)
    end

    test "the feed means a pass when it has changes or says resync" do
      assert Watch.changed?({:ok, %{"changes" => [%{"cursor" => 4}]}})
      assert Watch.changed?({:ok, %{"changes" => [], "resync" => true}})
      refute Watch.changed?({:ok, %{"changes" => [], "resync" => false}})
      refute Watch.changed?({:error, "could not reach the server"})
    end

    test "the loop passes after a local edit settles, and when the feed has news", %{root: root} do
      parent = self()
      {:ok, clock} = Agent.start_link(fn -> 0 end)

      sleep = fn ms ->
        Agent.update(clock, &(&1 + ms))
        t = Agent.get(clock, & &1)
        # A note written a second in; the server has news at twelve.
        if t == 1_000, do: write(root, "Note.md", "hello")
      end

      poll = fn cursor ->
        send(parent, {:polled, cursor})

        if Agent.get(clock, & &1) >= 12_000,
          do: {:ok, %{"changes" => [%{}], "cursor" => 9}},
          else: {:ok, %{"changes" => []}}
      end

      pass = fn ->
        send(parent, {:pass, Agent.get(clock, & &1)})
        7
      end

      Watch.loop(root, 5, pass, poll,
        sleep: sleep,
        clock: fn -> Agent.get(clock, & &1) end,
        ticks: 16,
        interval_ms: 10_000
      )

      # Changed at 1 s, still since, passed at 3 s; the feed asked at 13 s.
      assert_received {:pass, 3_000}
      assert_received {:polled, 7}
      assert_received {:pass, t} when t >= 12_000
    end
  end

  describe "the service" do
    test "Linux: a systemd user unit running sync --watch on the folder" do
      plan =
        Service.plan(
          {:unix, :linux},
          "/u/me/My Notes",
          ["/usr/bin/slipdock"],
          "/u/me",
          "/usr/bin:/bin"
        )

      assert plan.name =~ ~r/^slipdock-sync-my-notes-[0-9a-f]{6}\.service$/
      assert plan.file == "/u/me/.config/systemd/user/#{plan.name}"
      assert plan.content =~ ~s(ExecStart=/usr/bin/slipdock sync --watch "/u/me/My Notes")
      assert plan.content =~ "Environment=PATH=/usr/bin:/bin\n"
      assert plan.content =~ "Restart=always"
      assert ["systemctl", "--user", "enable", "--now", plan.name] in plan.install
      assert ["systemctl", "--user", "disable", "--now", plan.name] in plan.uninstall
    end

    test "macOS: a launchd agent, kept alive, logging to ~/Library/Logs" do
      plan =
        Service.plan(
          {:unix, :darwin},
          "/Users/me/Notes & Co",
          ["/opt/slipdock"],
          "/Users/me",
          "/usr/bin"
        )

      assert plan.file =~
               ~r"^/Users/me/Library/LaunchAgents/us\.slipdock\.sync\.notes-co-[0-9a-f]{6}\.plist$"

      assert plan.content =~
               "<string>/opt/slipdock</string><string>sync</string><string>--watch</string>"

      assert plan.content =~ "<string>/Users/me/Notes &amp; Co</string>"
      assert plan.content =~ "<key>KeepAlive</key><true/>"
      assert ["launchctl", "load", "-w", plan.file] in plan.install
    end

    test "Windows: a scheduled task at logon, run through escript" do
      plan =
        Service.plan(
          {:win32, :nt},
          "C:/Users/me/Notes",
          ["escript.exe", "C:/bin/slipdock"],
          "C:/Users/me",
          ""
        )

      assert plan.file == nil
      [create, run] = plan.install
      assert ["schtasks", "/Create", "/F", "/SC", "ONLOGON", "/TN", task, "/TR", tr] = create
      assert task =~ "Slipdock sync notes-"
      assert tr == ~s("escript.exe" "C:/bin/slipdock" "sync" "--watch" "C:/Users/me/Notes")
      assert run == ["schtasks", "/Run", "/TN", task]
    end

    test "two folders with one name get two services" do
      refute Service.name("/a/Notes") == Service.name("/b/Notes")
      assert Service.name("/a/...") =~ ~r/^vault-/
    end

    test "print shows the file and the commands, and installs nothing", %{root: root} do
      State.save(root, State.new("http://x", %{"id" => 1, "name" => "B"}, "h"))
      out = capture_io(fn -> Sync.run("sync", ["service", "print", root], []) end)

      assert out =~ "sync --watch"
      assert out =~ "then:"
    end
  end
end

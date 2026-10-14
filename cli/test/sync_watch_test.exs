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
    defp decode(encoded) do
      encoded |> Base.decode64!() |> :unicode.characters_to_binary({:utf16, :little}, :utf8)
    end

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

    test "Windows: a per-user logon task, registered through PowerShell, not schtasks" do
      plan =
        Service.plan(
          {:win32, :nt},
          "C:/Users/O'Brien/My Notes",
          ["escript.exe", "C:/bin/slipdock"],
          "C:/Users/O'Brien",
          ""
        )

      assert plan.file == nil
      assert plan.name =~ "Slipdock sync my-notes-"
      # One step, so nothing can fail unseen before it.
      assert [["powershell" | args]] = plan.install
      assert decode(List.last(args)) == plan.content
      refute plan.content =~ "schtasks"

      # For this user alone (schtasks /SC ONLOGON wants an elevated prompt),
      # never stopped (schtasks stops a task after 72 hours), restarted, and
      # replacing a task installed before.
      assert plan.content =~ "New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME"
      assert plan.content =~ "-ExecutionTimeLimit ([TimeSpan]::Zero)"
      assert plan.content =~ "-RestartCount 999"
      assert plan.content =~ "-TaskName '#{plan.name}'"
      assert plan.content =~ " -Force "
      assert plan.content =~ "Start-ScheduledTask -TaskName '#{plan.name}'"
      assert plan.content =~ "$ErrorActionPreference = 'Stop'"
      # A quote in the path is doubled inside a PowerShell literal.
      assert plan.content =~ "'Slipdock sync of C:/Users/O''Brien/My Notes'"

      [["powershell" | un]] = plan.uninstall

      assert decode(List.last(un)) =~
               "Unregister-ScheduledTask -TaskName '#{plan.name}' -Confirm:$false"
    end

    test "Windows: the task runs the sync hidden, and exits with its status" do
      args =
        Service.win_task_args([
          "C:/Program Files/escript.exe",
          "C:/bin/slipdock",
          "sync",
          "--watch",
          "C:/it's here"
        ])

      assert "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand " <>
               encoded = args

      assert decode(encoded) ==
               "& 'C:/Program Files/escript.exe' 'C:/bin/slipdock' 'sync' '--watch' 'C:/it''s here'\n" <>
                 "exit $LASTEXITCODE\n"
    end

    # Real PowerShell, where there is one: SLIPDOCK_PWSH, or pwsh on the PATH.
    # Linux has no Task Scheduler, so this runs what the task would run and
    # parses what install would register.
    @pwsh System.get_env("SLIPDOCK_PWSH") || System.find_executable("pwsh")

    @tag skip: if(@pwsh, do: false, else: "pwsh is not installed here")
    test "Windows: PowerShell runs the task's command with every argument intact" do
      dir = Path.join(System.tmp_dir!(), "svc-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      # Stands in for escript.exe: writes down what it was given, then fails.
      fake = Path.join(dir, "fake escript")

      File.write!(
        fake,
        ~s(#!/bin/sh\nfor a in "$@"; do echo "[$a]"; done > "#{dir}/argv"\nexit 3\n)
      )

      File.chmod!(fake, 0o755)

      root = Path.join(dir, "it's my vault")
      args = Service.win_task_args([fake, "/bin/slipdock", "sync", "--watch", root])

      {_, code} = System.cmd(@pwsh, String.split(args, " ") -- ["-WindowStyle", "Hidden"])

      # The sync's own status, so Task Scheduler sees it fail and restarts it.
      assert code == 3

      assert File.read!(Path.join(dir, "argv")) ==
               "[/bin/slipdock]\n[sync]\n[--watch]\n[#{root}]\n"
    end

    @tag skip: if(@pwsh, do: false, else: "pwsh is not installed here")
    test "Windows: what install and uninstall run is valid PowerShell" do
      plan = Service.plan({:win32, :nt}, "C:/a'b/N", ["escript.exe", "C:/s"], "C:/a'b", "")

      for [_ | args] <- plan.install ++ plan.uninstall do
        script = decode(List.last(args))

        check =
          "$e = $null; [System.Management.Automation.Language.Parser]::ParseInput(" <>
            "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('#{Base.encode64(script)}')), " <>
            "[ref]$null, [ref]$e) | Out-Null; $e.Count"

        assert {"0\n", 0} = System.cmd(@pwsh, ["-NoProfile", "-Command", check])
      end
    end

    test "install stops at the first step that fails, and says what it printed" do
      dir = Path.join(System.tmp_dir!(), "svc-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      later = Path.join(dir, "later")

      plan = %{
        install: [
          ["sh", "-c", "echo 'ERROR: Access is denied.'; exit 1"],
          ["sh", "-c", "touch '#{later}'"]
        ]
      }

      assert {:error, msg} = Service.install(plan)
      assert msg == "sh failed (1): ERROR: Access is denied."
      refute File.exists?(later)
    end

    test "install lets a prepare step fail, and runs every install step" do
      dir = Path.join(System.tmp_dir!(), "svc-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      plan = %{
        prepare: [["sh", "-c", "exit 3"]],
        install: [
          ["sh", "-c", "touch '#{dir}/one'"],
          ["sh", "-c", "touch '#{dir}/two'"]
        ]
      }

      assert Service.install(plan) == :ok
      assert File.exists?(Path.join(dir, "one"))
      assert File.exists?(Path.join(dir, "two"))
    end

    test "a step whose command is missing is an error, not a pass" do
      assert {:error, "no-such-command-here is not on this machine"} =
               Service.install(%{install: [["no-such-command-here"]]})
    end

    test "macOS: unloading an agent not loaded yet may fail; loading it may not" do
      plan = Service.plan({:unix, :darwin}, "/Users/me/N", ["/opt/slipdock"], "/Users/me", "")
      assert plan.prepare == [["launchctl", "unload", plan.file]]
      assert plan.install == [["launchctl", "load", "-w", plan.file]]
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

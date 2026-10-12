defmodule SlipdockCLI.Sync.Service do
  @moduledoc false

  # `slipdock sync service install|uninstall|print [DIR]` (W-103 R2.1): keeps
  # `slipdock sync --watch DIR` running in the background, with what each
  # system already has —
  #
  #   * Linux: a systemd user unit, restarted when it stops;
  #   * macOS: a launchd agent, run at login and kept alive;
  #   * Windows: a scheduled task run at logon, restarted when it fails.
  #
  # One per folder, named for it, so two mirrors run side by side. The plan
  # (what file is written where, and what is run) is worked out apart from
  # carrying it out, so `print` shows it and the tests read it.

  @doc """
  What installing means on `os` (`:os.type/0`'s answer): `%{name:, file:,
  content:, install: [[cmd | args]], uninstall: [[cmd | args]], logs:}`.
  `command` is the argv that runs this CLI; `env` the PATH to give it.
  """
  def plan(os, root, command, home, path_env) do
    name = name(root)
    argv = command ++ ["sync", "--watch", root]

    case os do
      {:unix, :darwin} ->
        label = "us.slipdock.sync.#{name}"
        file = Path.join([home, "Library", "LaunchAgents", label <> ".plist"])
        logs = Path.join([home, "Library", "Logs", "slipdock-sync-#{name}.log"])

        %{
          name: label,
          file: file,
          content: plist(label, argv, logs, path_env),
          install: [["launchctl", "unload", file], ["launchctl", "load", "-w", file]],
          uninstall: [["launchctl", "unload", "-w", file]],
          logs: logs
        }

      {:win32, _} ->
        task = "Slipdock sync #{name}"

        %{
          name: task,
          file: nil,
          content: nil,
          install: [
            [
              "schtasks",
              "/Create",
              "/F",
              "/SC",
              "ONLOGON",
              "/TN",
              task,
              "/TR",
              win_command(argv)
            ],
            ["schtasks", "/Run", "/TN", task]
          ],
          uninstall: [
            ["schtasks", "/End", "/TN", task],
            ["schtasks", "/Delete", "/F", "/TN", task]
          ],
          logs: "Task Scheduler, under #{task}"
        }

      _ ->
        unit = "slipdock-sync-#{name}.service"
        dir = System.get_env("XDG_CONFIG_HOME") || Path.join(home, ".config")
        file = Path.join([dir, "systemd", "user", unit])

        %{
          name: unit,
          file: file,
          content: unit(root, argv, path_env),
          install: [
            ["systemctl", "--user", "daemon-reload"],
            ["systemctl", "--user", "enable", "--now", unit]
          ],
          uninstall: [
            ["systemctl", "--user", "disable", "--now", unit],
            ["systemctl", "--user", "daemon-reload"]
          ],
          logs: "journalctl --user -u #{unit} -f"
        }
    end
  end

  @doc """
  A name for a folder's service: its own name, made safe, and a few hex
  digits of its full path, so two folders called `Notes` don't collide.
  """
  def name(root) do
    base =
      root
      |> Path.basename()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> then(&if(&1 == "", do: "vault", else: &1))

    digest = :crypto.hash(:sha256, root) |> Base.encode16(case: :lower) |> binary_part(0, 6)
    "#{base}-#{digest}"
  end

  defp unit(root, argv, path_env) do
    """
    [Unit]
    Description=Slipdock sync of #{root}
    After=network-online.target
    Wants=network-online.target

    [Service]
    ExecStart=#{Enum.map_join(argv, " ", &systemd_quote/1)}
    Environment=#{systemd_quote("PATH=" <> path_env)}
    Restart=always
    RestartSec=10

    [Install]
    WantedBy=default.target
    """
  end

  # systemd splits ExecStart on spaces unless the word is double-quoted.
  defp systemd_quote(word) do
    if String.match?(word, ~r/[\s"\\]/),
      do: "\"" <> (word |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\"",
      else: word
  end

  defp plist(label, argv, logs, path_env) do
    args = Enum.map_join(argv, "", &"<string>#{xml(&1)}</string>")

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>#{xml(label)}</string>
      <key>ProgramArguments</key><array>#{args}</array>
      <key>EnvironmentVariables</key><dict><key>PATH</key><string>#{xml(path_env)}</string></dict>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>StandardOutPath</key><string>#{xml(logs)}</string>
      <key>StandardErrorPath</key><string>#{xml(logs)}</string>
    </dict>
    </plist>
    """
  end

  defp xml(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp win_command(argv), do: Enum.map_join(argv, " ", &"\"#{&1}\"")

  @doc """
  The argv that runs this CLI as a service would: the escript itself where
  it can run on its own (a `#!` line), `escript.exe` in front on Windows.
  """
  def command(os \\ :os.type()) do
    script =
      try do
        :escript.script_name() |> to_string() |> Path.expand()
      rescue
        # Not running as an escript (a test, `mix run`): the name it installs as.
        _ -> System.find_executable("slipdock") || "slipdock"
      end

    case os do
      {:win32, _} -> [System.find_executable("escript") || "escript.exe", script]
      _ -> [script]
    end
  end
end

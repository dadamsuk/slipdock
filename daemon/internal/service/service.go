// Package service installs the daemon as a service of the account that runs
// it: a systemd user unit on Linux, a launchd agent on macOS, a Task
// Scheduler task on Windows. Each runs `slipdock-runner run --home <dir>`,
// starts at boot or log-on, and comes back if it stops.
//
// The names (slipdock-machine.service, us.slipdock.machine, "Slipdock
// machine") are not the shell runner's (slipdock-runner*.service,
// us.slipdock.runner*, "Slipdock runner*"), so both can run while a machine
// moves over.
package service

import (
	"bytes"
	"encoding/binary"
	"encoding/xml"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"unicode/utf16"
)

// Kinds of service manager.
const (
	Systemd = "systemd"
	Launchd = "launchd"
	Windows = "windows"
)

// The service's names.
const (
	SystemdUnit  = "slipdock-machine.service"
	LaunchdLabel = "us.slipdock.machine"
	WindowsTask  = "Slipdock machine"
)

// Spec is what the service runs.
type Spec struct {
	Kind string
	// Exe is the daemon's absolute path.
	Exe string
	// Home is the daemon's directory (machine.Dir).
	Home string
	// UserHome is the account's home directory.
	UserHome string
	// ConfigHome is the user's config directory ($XDG_CONFIG_HOME, or
	// ~/.config), where systemd looks for user units.
	ConfigHome string
	// User is the account's name, which a Windows task runs as.
	User string
}

// Plan is a service ready to install: one file to write, and the commands
// that load and start it.
type Plan struct {
	Kind    string
	Path    string
	Content []byte
	Start   [][]string
	Stop    [][]string
	// Logs says where its output goes.
	Logs string
	// Note is said after it starts.
	Note string
}

// Detect picks the service manager for goos. On Linux it needs systemctl.
func Detect(goos string, haveSystemctl bool) (string, error) {
	switch goos {
	case "darwin":
		return Launchd, nil
	case "windows":
		return Windows, nil
	case "linux":
		if haveSystemctl {
			return Systemd, nil
		}
		return "", errors.New("no systemd here to run the daemon as a service. On WSL, turn it on " +
			"(`[boot] systemd=true` in /etc/wsl.conf, then `wsl --shutdown`); elsewhere, run " +
			"`slipdock-runner run` under your own supervisor")
	default:
		return "", fmt.Errorf("no service manager known for %s: run `slipdock-runner run` under your own supervisor", goos)
	}
}

// Build makes the plan for s.
func Build(s Spec) (Plan, error) {
	if !filepath.IsAbs(s.Exe) || s.Home == "" {
		return Plan{}, errors.New("the service needs the daemon's absolute path and its directory")
	}
	switch s.Kind {
	case Systemd:
		return systemd(s), nil
	case Launchd:
		return launchd(s), nil
	case Windows:
		return windows(s)
	default:
		return Plan{}, fmt.Errorf("unknown service kind %q", s.Kind)
	}
}

// systemdQuote quotes one ExecStart word: double quotes, with backslash and
// quote escaped, and % doubled since systemd expands specifiers.
func systemdQuote(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	s = strings.ReplaceAll(s, "%", "%%")
	return `"` + s + `"`
}

func systemd(s Spec) Plan {
	exec := strings.Join([]string{systemdQuote(s.Exe), "run", "--home", systemdQuote(s.Home)}, " ")
	unit := fmt.Sprintf(`[Unit]
Description=Slipdock runner daemon (this machine's runners)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=%s
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
`, exec)
	return Plan{
		Kind:    Systemd,
		Path:    filepath.Join(s.ConfigHome, "systemd", "user", SystemdUnit),
		Content: []byte(unit),
		Start: [][]string{
			{"systemctl", "--user", "daemon-reload"},
			{"systemctl", "--user", "enable", SystemdUnit},
			// Restarted, not just started: installing again changes what it runs.
			{"systemctl", "--user", "restart", SystemdUnit},
		},
		Stop: [][]string{
			{"systemctl", "--user", "disable", "--now", SystemdUnit},
		},
		Logs: "journalctl --user -u slipdock-machine -f",
		Note: "to keep it running while you are logged out: loginctl enable-linger",
	}
}

func xmlEscape(s string) string {
	var b bytes.Buffer
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}

func launchd(s Spec) Plan {
	log := filepath.Join(s.UserHome, "Library", "Logs", "slipdock-machine.log")
	path := filepath.Join(s.UserHome, "Library", "LaunchAgents", LaunchdLabel+".plist")
	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>run</string>
    <string>--home</string>
    <string>%s</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
`, LaunchdLabel, xmlEscape(s.Exe), xmlEscape(s.Home), xmlEscape(log), xmlEscape(log))
	return Plan{
		Kind:    Launchd,
		Path:    path,
		Content: []byte(plist),
		Start: [][]string{
			// Unloaded first, so installing again picks up the new plist;
			// an unload of one that isn't loaded fails harmlessly.
			{"-launchctl", "unload", path},
			{"launchctl", "load", "-w", path},
		},
		Stop: [][]string{
			{"launchctl", "unload", "-w", path},
		},
		Logs: log,
	}
}

// windows is a Task Scheduler task as the account, at log-on and every five
// minutes after (IgnoreNew makes the repeat a no-op while it runs), with no
// time limit: the shell runner's PowerShell twin found the task's own
// restart-on-failure doesn't bring back one that started and then exited.
func windows(s Spec) (Plan, error) {
	if s.User == "" {
		return Plan{}, errors.New("a Windows task needs the account it runs as")
	}
	log := filepath.Join(s.Home, "daemon.log")
	args := fmt.Sprintf(`run --home "%s" --log "%s"`, s.Home, log)
	task := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Slipdock runner daemon (this machine's runners)</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>%[1]s</UserId>
    </LogonTrigger>
    <TimeTrigger>
      <Enabled>true</Enabled>
      <StartBoundary>2000-01-01T00:00:00</StartBoundary>
      <Repetition>
        <Interval>PT5M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>%[1]s</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
    <Hidden>true</Hidden>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>%[2]s</Command>
      <Arguments>%[3]s</Arguments>
    </Exec>
  </Actions>
</Task>
`, xmlEscape(s.User), xmlEscape(s.Exe), xmlEscape(args))
	path := filepath.Join(s.Home, "slipdock-machine-task.xml")
	return Plan{
		Kind:    Windows,
		Path:    path,
		Content: utf16LE(task),
		Start: [][]string{
			{"schtasks", "/Create", "/TN", WindowsTask, "/XML", path, "/F"},
			{"schtasks", "/Run", "/TN", WindowsTask},
		},
		Stop: [][]string{
			{"-schtasks", "/End", "/TN", WindowsTask},
			{"schtasks", "/Delete", "/TN", WindowsTask, "/F"},
		},
		Logs: log,
	}, nil
}

// utf16LE is s as UTF-16 little-endian with a byte-order mark, which is
// what schtasks /XML reads reliably.
func utf16LE(s string) []byte {
	s = strings.ReplaceAll(s, "\n", "\r\n")
	units := utf16.Encode([]rune(s))
	out := make([]byte, 2+2*len(units))
	out[0], out[1] = 0xFF, 0xFE
	for i, u := range units {
		binary.LittleEndian.PutUint16(out[2+2*i:], u)
	}
	return out
}

// Runner runs one command, as `name args...`.
type Runner func(name string, args ...string) error

// Writer writes a file, making its directory.
type Writer func(path string, data []byte) error

// Install writes the plan's file and runs its start commands in turn. A
// command written with a leading "-" may fail without stopping the rest.
func Install(p Plan, write Writer, run Runner) error {
	if err := write(p.Path, p.Content); err != nil {
		return fmt.Errorf("writing %s: %w", p.Path, err)
	}
	return runAll(p.Start, run)
}

// Uninstall runs the plan's stop commands. The file is left for the caller.
func Uninstall(p Plan, run Runner) error {
	return runAll(p.Stop, run)
}

func runAll(cmds [][]string, run Runner) error {
	for _, c := range cmds {
		name, mayFail := strings.CutPrefix(c[0], "-")
		if err := run(name, c[1:]...); err != nil && !mayFail {
			return fmt.Errorf("%s: %w", strings.Join(append([]string{name}, c[1:]...), " "), err)
		}
	}
	return nil
}

package service

import (
	"encoding/binary"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf16"
)

// abs is an absolute path on this OS: from / here, from C:\ on Windows.
func abs(parts ...string) string {
	root := string(filepath.Separator)
	if filepath.Separator == '\\' {
		root = `C:\`
	}
	return filepath.Join(append([]string{root}, parts...)...)
}

func spec(kind string) Spec {
	return Spec{
		Kind:       kind,
		Exe:        abs("opt", "slipdock", "slipdock-runner"),
		Home:       abs("cfg", "slipdock-runner", "machine"),
		UserHome:   abs("u"),
		ConfigHome: abs("u", ".config"),
		User:       "builder",
	}
}

func TestDetect(t *testing.T) {
	for goos, want := range map[string]string{"darwin": Launchd, "windows": Windows} {
		if got, err := Detect(goos, false); err != nil || got != want {
			t.Errorf("%s: %s, %v", goos, got, err)
		}
	}
	if got, err := Detect("linux", true); err != nil || got != Systemd {
		t.Errorf("linux with systemctl: %s, %v", got, err)
	}
	if _, err := Detect("linux", false); err == nil || !strings.Contains(err.Error(), "wsl.conf") {
		t.Errorf("linux without systemd says how to turn it on: %v", err)
	}
	if _, err := Detect("plan9", true); err == nil {
		t.Error("an unknown OS has no service manager")
	}
}

func TestSystemdUnit(t *testing.T) {
	s := spec(Systemd)
	s.Home = abs("cfg", `100% "odd"`)
	p, err := Build(s)
	if err != nil {
		t.Fatal(err)
	}
	if p.Path != filepath.Join(s.ConfigHome, "systemd", "user", "slipdock-machine.service") {
		t.Fatalf("path %s", p.Path)
	}
	unit := string(p.Content)
	wantExec := `ExecStart="/opt/slipdock/slipdock-runner" run --home "/cfg/100%% \"odd\""`
	if filepath.Separator == '/' && !strings.Contains(unit, wantExec) {
		t.Fatalf("ExecStart quotes its words, escapes quotes and doubles %%:\n%s\nwant %s", unit, wantExec)
	}
	for _, want := range []string{"Restart=always", "WantedBy=default.target", "After=network-online.target"} {
		if !strings.Contains(unit, want) {
			t.Errorf("missing %q", want)
		}
	}
	if p.Start[2][2] != "restart" || p.Stop[0][2] != "disable" {
		t.Fatalf("commands %v / %v", p.Start, p.Stop)
	}
}

func TestLaunchdPlist(t *testing.T) {
	s := spec(Launchd)
	s.Home = abs("cfg", "a&b")
	p, err := Build(s)
	if err != nil {
		t.Fatal(err)
	}
	if p.Path != filepath.Join(s.UserHome, "Library", "LaunchAgents", "us.slipdock.machine.plist") {
		t.Fatalf("path %s", p.Path)
	}
	plist := string(p.Content)
	for _, want := range []string{
		"<key>Label</key><string>us.slipdock.machine</string>",
		"<string>" + s.Exe + "</string>\n    <string>run</string>\n    <string>--home</string>",
		"a&amp;b",
		"<key>KeepAlive</key><true/>",
		"<key>RunAtLoad</key><true/>",
	} {
		if !strings.Contains(plist, want) {
			t.Errorf("missing %q in\n%s", want, plist)
		}
	}
	if strings.Contains(plist, "a&b") {
		t.Error("paths are XML-escaped")
	}
	if p.Start[0][0] != "-launchctl" {
		t.Error("unloading one that isn't loaded may fail")
	}
}

func decodeUTF16(t *testing.T, b []byte) string {
	t.Helper()
	if b[0] != 0xFF || b[1] != 0xFE {
		t.Fatal("no UTF-16 little-endian byte-order mark")
	}
	units := make([]uint16, (len(b)-2)/2)
	for i := range units {
		units[i] = binary.LittleEndian.Uint16(b[2+2*i:])
	}
	return string(utf16.Decode(units))
}

func TestWindowsTask(t *testing.T) {
	s := spec(Windows)
	s.User = `HOST\a<b`
	p, err := Build(s)
	if err != nil {
		t.Fatal(err)
	}
	task := decodeUTF16(t, p.Content)
	for _, want := range []string{
		"<LogonTrigger>",
		"<Interval>PT5M</Interval>",
		"<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>",
		"<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>",
		"<RunLevel>LeastPrivilege</RunLevel>",
		`HOST\a&lt;b`,
		"<Command>" + s.Exe + "</Command>",
		"run --home &#34;" + s.Home + "&#34; --log",
		"\r\n",
	} {
		if !strings.Contains(task, want) {
			t.Errorf("missing %q in\n%s", want, task)
		}
	}
	if p.Start[0][0] != "schtasks" || p.Start[0][5] != p.Path {
		t.Fatalf("start %v", p.Start)
	}
	s.User = ""
	if _, err := Build(s); err == nil {
		t.Error("a task needs its account")
	}
}

func TestBuildRefuses(t *testing.T) {
	s := spec(Systemd)
	s.Exe = "relative/slipdock-runner"
	if _, err := Build(s); err == nil {
		t.Error("a relative executable is refused")
	}
	s = spec("upstart")
	if _, err := Build(s); err == nil {
		t.Error("an unknown kind is refused")
	}
}

func TestInstallWritesThenRunsInOrder(t *testing.T) {
	p, _ := Build(spec(Launchd))
	var wrote string
	var ran []string
	err := Install(p, func(path string, data []byte) error { wrote = path; return nil },
		func(name string, args ...string) error {
			ran = append(ran, name+" "+strings.Join(args, " "))
			if name == "launchctl" && args[0] == "unload" {
				return errors.New("not loaded")
			}
			return nil
		})
	if err != nil {
		t.Fatal(err)
	}
	if wrote != p.Path {
		t.Fatalf("wrote %s", wrote)
	}
	if len(ran) != 2 || !strings.HasPrefix(ran[0], "launchctl unload") || !strings.HasPrefix(ran[1], "launchctl load -w") {
		t.Fatalf("ran %v", ran)
	}
}

func TestInstallStopsAtAFailure(t *testing.T) {
	p, _ := Build(spec(Systemd))
	var ran int
	err := Install(p, func(string, []byte) error { return nil }, func(name string, args ...string) error {
		ran++
		if args[1] == "enable" {
			return errors.New("boom")
		}
		return nil
	})
	if err == nil || !strings.Contains(err.Error(), "systemctl --user enable") || ran != 2 {
		t.Fatalf("err %v after %d commands", err, ran)
	}
	if err := Install(p, func(string, []byte) error { return errors.New("read-only") }, nil); err == nil {
		t.Fatal("a failed write fails the install")
	}
}

func TestUninstall(t *testing.T) {
	p, _ := Build(spec(Windows))
	var ran []string
	err := Uninstall(p, func(name string, args ...string) error {
		ran = append(ran, args[0])
		if args[0] == "/End" {
			return errors.New("not running")
		}
		return nil
	})
	if err != nil || len(ran) != 2 || ran[1] != "/Delete" {
		t.Fatalf("%v, ran %v", err, ran)
	}
}

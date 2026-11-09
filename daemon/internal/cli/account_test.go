package cli

import (
	"errors"
	"runtime"
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// sudoWorld is a world whose sudo runs the set-up script (recorded) and
// says the account's home is /srv/slipdock.
func sudoWorld(t *testing.T, stdin string) (*world, *[]string) {
	w := newWorld(t)
	w.env.Stdin = strings.NewReader(stdin)
	var scripts []string
	w.env.Output = func(name string, args ...string) (string, error) {
		if name == "sudo" {
			scripts = append(scripts, strings.Join(args, " "))
			return "Creating home directory\n/srv/" + accountIn(args) + "\n", w.outputErr["sudo"]
		}
		return w.outputs[name], w.outputErr[name]
	}
	return w, &scripts
}

func accountIn(args []string) string {
	s := strings.Join(args, " ")
	i := strings.Index(s, "id -u ")
	return strings.Fields(s[i+len("id -u "):])[0]
}

// unixOnly skips a test of the dedicated account, whose paths are Unix's,
// on Windows, where the account isn't offered.
func unixOnly(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the dedicated account is Linux's and macOS's")
	}
}

func TestInitOffersADedicatedAccountAndRunsAsIt(t *testing.T) {
	unixOnly(t)
	f := &fake{}
	ts := f.start(t)
	w, scripts := sudoWorld(t, "\ny\n")
	w.env.HomeOpen = func(string) bool { return true }
	if code := w.main("init", "--server", ts.URL, "--key", "sdk_good"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	out := w.out.String()
	for _, want := range []string{
		"Who should jobs run as?",
		"1) A dedicated account, slipdock. Recommended for an always-on machine",
		"It can't read your home",
		"2) You, builder. For a laptop that is only yours.",
		"Nothing stops an agent reading or changing what you can.",
		"is open to other accounts, so a job as slipdock could read it",
		"Jobs run as slipdock:",
		"a shell as slipdock opens",
		"clone your repositories under /srv/slipdock/src",
		"executors:                  user",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("init doesn't say %q:\n%s", want, out)
		}
	}
	if len(*scripts) != 1 || !strings.HasPrefix((*scripts)[0], "sh -c set -eu") ||
		!strings.Contains((*scripts)[0], "'builder ALL=(slipdock) NOPASSWD: ALL'") ||
		!strings.Contains((*scripts)[0], "chmod o-rwx '"+w.home+"'") {
		t.Fatalf("one sudo, running the set-up script that closes the home: %q", *scripts)
	}
	l, err := machine.LoadLocal(w.dir)
	if err != nil || l.User == nil || l.User.Name != "slipdock" || l.User.Home != "/srv/slipdock" {
		t.Fatalf("the local file names the account: %+v %v", l.User, err)
	}
	c, _ := machine.LoadCeiling(w.dir)
	if strings.Join(c.Executors, ",") != "user" || c.Roots[0] != "/srv/slipdock/src" {
		t.Fatalf("a dedicated-account machine offers user only, in the account's home: %+v", c)
	}
	if len(w.interactive) != 1 || strings.Join(w.interactive[0], " ") != "sudo -u slipdock -i" || len(w.ran) != 0 {
		t.Fatalf("set-up opens a shell as the account, attached to the terminal: %q %v", w.interactive, w.ran)
	}
}

func TestInitAsMe(t *testing.T) {
	f := &fake{}
	ts := f.start(t)
	for _, how := range [][]string{{"--as-me"}, {}} {
		w, scripts := sudoWorld(t, "2\n")
		args := append([]string{"init", "--server", ts.URL, "--key", "sdk_good"}, how...)
		if code := w.main(args...); code != 0 {
			t.Fatalf("%v: exit %d: %s", how, code, w.errOut)
		}
		if len(*scripts) != 0 || len(w.ran) != 0 || len(w.interactive) != 0 {
			t.Fatalf("%v: as me needs no sudo and opens no shell: %v %v %q", how, *scripts, w.ran, w.interactive)
		}
		c, _ := machine.LoadCeiling(w.dir)
		if strings.Join(c.Executors, ",") != "me,confined" {
			t.Fatalf("%v: as me, on Linux: %v", how, c.Executors)
		}
		if l, _ := machine.LoadLocal(w.dir); l.User != nil {
			t.Fatalf("%v: no account: %+v", how, l.User)
		}
		if !strings.Contains(w.out.String(), "Jobs run as you:") {
			t.Fatal(w.out.String())
		}
	}
}

func TestInitWithANamedAccountAndNoSetUp(t *testing.T) {
	unixOnly(t)
	f := &fake{}
	ts := f.start(t)
	w, scripts := sudoWorld(t, "")
	if code := w.main("init", "--server", ts.URL, "--key", "sdk_good", "--user", "jobs", "--no-setup"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if len(*scripts) != 1 || !strings.Contains((*scripts)[0], "'builder ALL=(jobs) NOPASSWD: ALL'") || strings.Contains((*scripts)[0], "o-rwx") {
		t.Fatalf("the named account, the home left alone (it isn't open): %q", *scripts)
	}
	if len(w.ran) != 0 || len(w.interactive) != 0 {
		t.Fatalf("--no-setup opens no shell: %v %q", w.ran, w.interactive)
	}
	if l, _ := machine.LoadLocal(w.dir); l.User == nil || l.User.Name != "jobs" || l.User.Home != "/srv/jobs" {
		t.Fatalf("%+v", l.User)
	}

	// Enrolling again as me takes the account out of the local file and
	// changes the ceiling's executors, keeping the rest of it.
	c, _ := machine.LoadCeiling(w.dir)
	c.MaxTimeoutMinutes = 15
	_ = machine.SaveCeiling(w.dir, c)
	if code := w.main("init", "--server", ts.URL, "--key", "sdk_good", "--replace", "--as-me"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	c, _ = machine.LoadCeiling(w.dir)
	if strings.Join(c.Executors, ",") != "me,confined" || c.MaxTimeoutMinutes != 15 {
		t.Fatalf("%+v", c)
	}
	if l, _ := machine.LoadLocal(w.dir); l.User != nil {
		t.Fatalf("%+v", l.User)
	}
}

func TestInitOnWindowsOffersTheCurrentAccountOnly(t *testing.T) {
	f := &fake{}
	ts := f.start(t)
	w, scripts := sudoWorld(t, "")
	w.env.GOOS = "windows"
	if code := w.main("init", "--server", ts.URL, "--key", "sdk_good"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if !strings.Contains(w.out.String(), "On Windows jobs run as you (builder), the current account: a dedicated account isn't offered there yet.") ||
		strings.Contains(w.out.String(), "Who should jobs run as?") {
		t.Fatal(w.out.String())
	}
	if c, _ := machine.LoadCeiling(w.dir); strings.Join(c.Executors, ",") != "me" || len(*scripts) != 0 {
		t.Fatalf("%+v %v", c, *scripts)
	}
	if code := w.main("init", "--server", ts.URL, "--key", "sdk_good", "--replace", "--user", "slipdock"); code != 1 ||
		!strings.Contains(w.errOut.String(), "current account only") {
		t.Fatalf("--user on Windows: %d %s", code, w.errOut)
	}
}

func TestInitRefusals(t *testing.T) {
	f := &fake{}
	ts := f.start(t)
	cases := []struct {
		name  string
		stdin string
		args  []string
		setup func(w *world)
		code  int
		want  string
	}{
		{"both", "", []string{"--as-me", "--user", "x"}, nil, 2, "give one"},
		{"not a choice", "3\n", nil, nil, 1, `"3" is not 1 or 2`},
		{"home left open", "1\nn\n", nil, func(w *world) { w.env.HomeOpen = func(string) bool { return true } }, 1, "needs your home closed"},
		{"sudo fails", "1\n", nil, func(w *world) { w.outputErr["sudo"] = errors.New("exit status 1") }, 1, "setting up the account slipdock failed"},
		{"a bad name", "", []string{"--user", "Bad.Name"}, nil, 1, "can't be the account's name"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w, _ := sudoWorld(t, c.stdin)
			if c.setup != nil {
				c.setup(w)
			}
			before := f.enrols
			args := append([]string{"init", "--server", ts.URL, "--key", "sdk_good"}, c.args...)
			if code := w.main(args...); code != c.code || !strings.Contains(w.errOut.String(), c.want) {
				t.Fatalf("exit %d, want %d with %q: %s", code, c.code, c.want, w.errOut)
			}
			if f.enrols != before || machine.Enrolled(w.dir) {
				t.Fatal("a refusal leaves nothing enrolled")
			}
		})
	}
}

func TestSetUpWithoutAHomeOnTheEnd(t *testing.T) {
	w, _ := sudoWorld(t, "")
	w.env.Output = func(string, ...string) (string, error) { return "something else\n", nil }
	if _, err := setUpAccount(runAs{account: "slipdock"}, w.env); err == nil || !strings.Contains(err.Error(), "didn't say where its home is") {
		t.Fatalf("%v", err)
	}
}

func TestTheSetUpShellFailingIsSaid(t *testing.T) {
	w, _ := sudoWorld(t, "")
	w.interactiveErr["sudo -u slipdock -i"] = errors.New("exit status 1")
	startSetUp(runAs{account: "slipdock", home: "/srv/slipdock"}, "/srv/slipdock/src", w.env)
	if !strings.Contains(w.out.String(), "Open it again with `sudo -u slipdock -i`") {
		t.Fatal(w.out.String())
	}
}

func TestReadLineLeavesTheRest(t *testing.T) {
	r := strings.NewReader("one\r\ntwo\nthree")
	if a, b, c, d := readLine(r), readLine(r), readLine(r), readLine(r); a != "one" || b != "two" || c != "three" || d != "" {
		t.Fatalf("%q %q %q %q", a, b, c, d)
	}
}

func TestConfineIsACommand(t *testing.T) {
	w := newWorld(t)
	if code := w.main("confine"); code != 2 || !strings.Contains(w.errOut.String(), "usage: slipdock-runner confine") {
		t.Fatalf("%d %s", code, w.errOut)
	}
}

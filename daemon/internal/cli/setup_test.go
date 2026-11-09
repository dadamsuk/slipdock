package cli

import (
	"encoding/base64"
	"errors"
	"strings"
	"testing"
)

// A prompt with what a careless launch would mangle: lines, quotes, a $,
// backticks, a backslash.
const prompt = "Read the board's machine-setup page.\nInstall what's missing, then run \"mix test\" as $USER `id` \\ done."

// initAsMe enrols a new machine by key, jobs run as the person, its stdin
// answering input.
func initAsMe(t *testing.T, input string, extra ...string) (*world, *fake, int) {
	f := &fake{setupPrompt: prompt}
	ts := f.start(t)
	w := newWorld(t)
	w.env.Stdin = strings.NewReader(input)
	code := w.main(append([]string{"init", "--as-me", "--server", ts.URL, "--key", "sdk_good"}, extra...)...)
	return w, f, code
}

// initAsAccount enrols a new machine whose jobs run as the dedicated
// account slipdock, its stdin answering input.
func initAsAccount(t *testing.T, f *fake, input string, extra ...string) (*world, int) {
	unixOnly(t)
	ts := f.start(t)
	w, _ := sudoWorld(t, input)
	code := w.main(append([]string{"init", "--user", "slipdock", "--server", ts.URL, "--key", "sdk_good"}, extra...)...)
	return w, code
}

// claudeAsAccount says whether call is claude started as account by sudo
// in a login shell, and decodes the prompt it was given.
func claudeAsAccount(t *testing.T, call []string, account string) string {
	t.Helper()
	if len(call) != 7 || strings.Join(call[:6], " ") != "sudo -u "+account+" -i sh -c" {
		t.Fatalf("not claude as %s in a login shell: %q", account, call)
	}
	script := call[6]
	if strings.Contains(script, "$") || !strings.HasPrefix(script, "exec claude \"`echo ") || !strings.HasSuffix(script, " | base64 -d`\"") {
		t.Fatalf("the script sudo -i would mangle or that doesn't run claude: %q", script)
	}
	b64 := strings.TrimSuffix(strings.TrimPrefix(script, "exec claude \"`echo "), " | base64 -d`\"")
	got, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		t.Fatalf("%q: %v", b64, err)
	}
	return string(got)
}

func TestInitSetsUpWithClaudeOnYes(t *testing.T) {
	for _, answer := range []string{"y\n", "Yes\n", " YES "} {
		w, _, code := initAsMe(t, answer)
		if code != 0 {
			t.Fatalf("%q: exit %d: %s", answer, code, w.errOut)
		}
		if !strings.Contains(w.out.String(), "\n"+setupQuestion) || !strings.Contains(w.out.String(), setupLater) {
			t.Fatalf("%q: asks, and says how to do it again:\n%s", answer, w.out)
		}
		if len(w.interactive) != 1 || len(w.interactive[0]) != 2 || w.interactive[0][0] != "claude" || w.interactive[0][1] != prompt {
			t.Fatalf("%q: launches claude with exactly the prompt: %q", answer, w.interactive)
		}
		if len(w.ran) != 0 {
			t.Fatalf("claude runs attached to the terminal, not by Run: %v", w.ran)
		}
	}
}

func TestInitSetupQuestionWording(t *testing.T) {
	want := "Set up this machine with Claude now? It reads the board's machine-setup page, installs what's missing and proves it by running the suite. [y/N] "
	if setupQuestion != want {
		t.Fatalf("the question is %q", setupQuestion)
	}
}

func TestInitDeclinesSetupByDefault(t *testing.T) {
	for _, answer := range []string{"", "\n", "n\n", "no\n", "sure\n", "yy\n"} {
		w, _, code := initAsMe(t, answer)
		if code != 0 {
			t.Fatalf("%q: exit %d: %s", answer, code, w.errOut)
		}
		out := w.out.String()
		if !strings.Contains(out, setupQuestion) || !strings.Contains(out, setupLater) || !strings.Contains(out, "Jobs run as you:") {
			t.Fatalf("%q: asks, then says what set-up is as you and how to do it later:\n%s", answer, out)
		}
		if len(w.interactive) != 0 {
			t.Fatalf("%q: launched %q", answer, w.interactive)
		}
		if i, j, k := strings.Index(out, "ceiling, in"), strings.Index(out, setupQuestion), strings.Index(out, "Next: add its runners"); i < 0 || j < i || k < j {
			t.Fatalf("%q: asked after the ceiling, before the Next lines:\n%s", answer, out)
		}
	}
}

func TestInitNoSetupDoesNotAsk(t *testing.T) {
	f := &fake{setupPrompt: prompt}
	ts := f.start(t)
	w := newWorld(t)
	in := strings.NewReader("y\n")
	w.env.Stdin = in
	if code := w.main("init", "--as-me", "--server", ts.URL, "--key", "sdk_good", "--no-setup"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if strings.Contains(w.out.String(), "Set up this machine with Claude") || strings.Contains(w.out.String(), "slipdock-runner setup") {
		t.Fatalf("--no-setup asks nothing:\n%s", w.out)
	}
	if in.Len() != 2 {
		t.Fatalf("--no-setup reads no stdin: %d bytes left", in.Len())
	}
	if len(w.interactive) != 0 {
		t.Fatalf("launched %q", w.interactive)
	}
}

func TestInitSetupWithoutClaude(t *testing.T) {
	f := &fake{setupPrompt: prompt}
	ts := f.start(t)
	w := newWorld(t)
	w.paths["claude"] = false
	w.env.Stdin = strings.NewReader("y\n")
	if code := w.main("init", "--as-me", "--server", ts.URL, "--key", "sdk_good"); code != 0 {
		t.Fatalf("init still succeeds: exit %d: %s", code, w.errOut)
	}
	out := w.out.String()
	if !strings.Contains(out, "`claude`) isn't on the PATH") || !strings.Contains(out, setupLater) {
		t.Fatalf("says claude is missing and how to do it later:\n%s", out)
	}
	if len(w.interactive) != 0 {
		t.Fatalf("launched %q", w.interactive)
	}
}

func TestInitSetupFromAnOlderServer(t *testing.T) {
	f := &fake{noSetup: true}
	ts := f.start(t)
	w := newWorld(t)
	w.env.Stdin = strings.NewReader("y\n")
	if code := w.main("init", "--as-me", "--server", ts.URL, "--key", "sdk_good"); code != 0 {
		t.Fatalf("init still succeeds: exit %d: %s", code, w.errOut)
	}
	if out := w.out.String(); !strings.Contains(out, "doesn't offer a setup prompt yet") || !strings.Contains(out, setupLater) {
		t.Fatalf("says the server has no prompt:\n%s", out)
	}
	if len(w.interactive) != 0 {
		t.Fatalf("launched %q", w.interactive)
	}
}

func TestInitSetupClaudeFails(t *testing.T) {
	f := &fake{setupPrompt: prompt}
	ts := f.start(t)
	w := newWorld(t)
	w.interactiveErr["claude "+prompt] = errors.New("exit status 3")
	w.env.Stdin = strings.NewReader("y\n")
	if code := w.main("init", "--as-me", "--server", ts.URL, "--key", "sdk_good"); code != 0 {
		t.Fatalf("a failing claude doesn't fail init: exit %d: %s", code, w.errOut)
	}
	if !strings.Contains(w.out.String(), "claude stopped with an error: exit status 3") {
		t.Fatalf("reports it:\n%s", w.out)
	}
}

func TestInitAsksServerThenSetup(t *testing.T) {
	f := &fake{setupPrompt: prompt}
	ts := f.start(t)
	w := newWorld(t)
	w.env.Stdin = strings.NewReader(ts.URL + "\ny\n")
	if code := w.main("init", "--as-me", "--key", "sdk_good"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if len(w.interactive) != 1 || w.interactive[0][1] != prompt {
		t.Fatalf("the second line answers the second question: %q", w.interactive)
	}
}

func TestInitAsAnAccountSetsUpWithClaudeAsIt(t *testing.T) {
	w, code := initAsAccount(t, &fake{setupPrompt: prompt}, "y\n")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if len(w.interactive) != 1 {
		t.Fatalf("claude as the account, in place of the shell: %q", w.interactive)
	}
	if got := claudeAsAccount(t, w.interactive[0], "slipdock"); got != prompt {
		t.Fatalf("claude as slipdock gets exactly the prompt:\n%q\nnot\n%q", got, prompt)
	}
	if strings.Contains(w.out.String(), "a shell as slipdock opens") || !strings.Contains(w.out.String(), setupLater) {
		t.Fatalf("no shell is offered, and how to do it again is:\n%s", w.out)
	}
}

func TestInitAsAnAccountNeedsNoClaudeOnYourPath(t *testing.T) {
	f := &fake{setupPrompt: prompt}
	unixOnly(t)
	ts := f.start(t)
	w, _ := sudoWorld(t, "y\n")
	w.paths["claude"] = false
	if code := w.main("init", "--user", "slipdock", "--server", ts.URL, "--key", "sdk_good"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if len(w.interactive) != 1 || w.interactive[0][0] != "sudo" {
		t.Fatalf("the account's PATH is its own: claude is launched as it all the same: %q", w.interactive)
	}
}

func TestInitAsAnAccountDeclinedOpensTheShell(t *testing.T) {
	for _, tc := range []struct {
		name, input string
		f           *fake
	}{
		{"no", "n\n", &fake{setupPrompt: prompt}},
		{"nothing typed", "", &fake{setupPrompt: prompt}},
		{"an older server", "y\n", &fake{noSetup: true}},
	} {
		w, code := initAsAccount(t, tc.f, tc.input)
		if code != 0 {
			t.Fatalf("%s: exit %d: %s", tc.name, code, w.errOut)
		}
		if len(w.interactive) != 1 || strings.Join(w.interactive[0], " ") != "sudo -u slipdock -i" {
			t.Fatalf("%s: falls back to the shell as the account: %q", tc.name, w.interactive)
		}
		if out := w.out.String(); !strings.Contains(out, "a shell as slipdock opens") || !strings.Contains(out, setupLater) {
			t.Fatalf("%s:\n%s", tc.name, out)
		}
	}
}

func TestInitAsAnAccountClaudeFailing(t *testing.T) {
	unixOnly(t)
	f := &fake{setupPrompt: prompt}
	ts := f.start(t)
	w, _ := sudoWorld(t, "y\n")
	w.interactiveErr["sudo "+strings.Join(claudeAs("slipdock", prompt), " ")] = errors.New("exit status 127")
	if code := w.main("init", "--user", "slipdock", "--server", ts.URL, "--key", "sdk_good"); code != 0 {
		t.Fatalf("a failing claude doesn't fail init: exit %d: %s", code, w.errOut)
	}
	out := w.out.String()
	for _, want := range []string{"claude as slipdock stopped with an error: exit status 127", "`sudo -u slipdock -i`, then `claude`", setupLater} {
		if !strings.Contains(out, want) {
			t.Errorf("doesn't say %q:\n%s", want, out)
		}
	}
	if len(w.interactive) != 1 {
		t.Fatalf("claude ran, so no shell follows: %q", w.interactive)
	}
}

func TestInitAsAnAccountNoSetup(t *testing.T) {
	w, code := initAsAccount(t, &fake{setupPrompt: prompt}, "y\n", "--no-setup")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if len(w.interactive) != 0 || strings.Contains(w.out.String(), setupQuestion) || strings.Contains(w.out.String(), "a shell as slipdock opens") {
		t.Fatalf("--no-setup: neither the question nor the shell: %q\n%s", w.interactive, w.out)
	}
}

func TestClaudeAsSurvivesSudo(t *testing.T) {
	if got := claudeAsAccount(t, append([]string{"sudo"}, claudeAs("jobs", prompt)...), "jobs"); got != prompt {
		t.Fatalf("%q", got)
	}
}

func TestSetupPrintsThePrompt(t *testing.T) {
	w, f := enrolled(t)
	f.setupPrompt = prompt
	if code := w.main("setup", "--print"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if w.out.String() != prompt+"\n" {
		t.Fatalf("prints the prompt alone: %q", w.out)
	}
	if len(w.interactive) != 0 {
		t.Fatalf("--print launches nothing: %q", w.interactive)
	}
}

func TestSetupLaunchesClaude(t *testing.T) {
	w, f := enrolled(t)
	f.setupPrompt = prompt
	if code := w.main("setup"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if len(w.interactive) != 1 || len(w.interactive[0]) != 2 || w.interactive[0][0] != "claude" || w.interactive[0][1] != prompt {
		t.Fatalf("launches claude with exactly the prompt: %q", w.interactive)
	}
	if strings.Contains(w.out.String(), setupQuestion) {
		t.Fatal("setup doesn't ask: it was asked for")
	}
}

func TestSetupLaunchesClaudeAsTheSavedAccount(t *testing.T) {
	unixOnly(t)
	w, f := enrolled(t)
	f.setupPrompt = prompt
	if err := saveRunAs(w.dir, runAs{account: "slipdock", home: "/srv/slipdock"}); err != nil {
		t.Fatal(err)
	}
	w.paths["claude"] = false
	if code := w.main("setup"); code != 0 {
		t.Fatalf("exit %d: %s", code, w.errOut)
	}
	if len(w.interactive) != 1 || claudeAsAccount(t, w.interactive[0], "slipdock") != prompt {
		t.Fatalf("claude as the saved account, with exactly the prompt: %q", w.interactive)
	}
	if code := w.main("setup", "--print"); code != 0 || w.out.String() != prompt+"\n" {
		t.Fatalf("--print is the same for an account: %d %q", code, w.out)
	}
}

func TestSetupFailures(t *testing.T) {
	empty := newWorld(t)
	if code := empty.main("setup"); code != 1 || !strings.Contains(empty.errOut.String(), "not enrolled") {
		t.Fatalf("unenrolled: %d %s", code, empty.errOut)
	}
	if code := empty.main("setup", "--print"); code != 1 || !strings.Contains(empty.errOut.String(), "not enrolled") {
		t.Fatalf("unenrolled --print: %d %s", code, empty.errOut)
	}

	w, f := enrolled(t)
	f.setupPrompt = prompt
	w.paths["claude"] = false
	if code := w.main("setup"); code != 1 || !strings.Contains(w.errOut.String(), "isn't on the PATH") {
		t.Fatalf("no claude: %d %s", code, w.errOut)
	}
	if code := w.main("setup", "--print"); code != 0 || w.out.String() != prompt+"\n" {
		t.Fatalf("--print needs no claude: %d %s", code, w.errOut)
	}
	w.paths["claude"] = true

	w.interactiveErr["claude "+prompt] = errors.New("exit status 1")
	if code := w.main("setup"); code != 1 || !strings.Contains(w.errOut.String(), "claude stopped with an error") {
		t.Fatalf("claude fails: %d %s", code, w.errOut)
	}
	delete(w.interactiveErr, "claude "+prompt)

	f.revoked = true
	if code := w.main("setup", "--print"); code != 1 || !strings.Contains(w.errOut.String(), "revoked") {
		t.Fatalf("revoked: %d %s", code, w.errOut)
	}
	f.revoked, f.noSetup = false, true
	if code := w.main("setup"); code != 1 || !strings.Contains(w.errOut.String(), "doesn't offer a setup prompt yet") {
		t.Fatalf("an older server: %d %s", code, w.errOut)
	}
	if len(w.interactive) != 1 {
		t.Fatalf("only the run that got a prompt launched claude: %q", w.interactive)
	}
	if code := w.main("setup", "extra"); code != 2 {
		t.Fatalf("a stray argument is a usage error: %d", code)
	}
}

func TestUsageNamesSetup(t *testing.T) {
	w := newWorld(t)
	w.main("help")
	if !strings.Contains(w.out.String(), "slipdock-runner setup [--print]") || !strings.Contains(w.out.String(), "--no-setup") {
		t.Fatal(w.out.String())
	}
}

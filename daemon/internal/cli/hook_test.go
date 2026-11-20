package cli

import (
	"bytes"
	"strings"
	"testing"
)

// `slipdock-runner hook pretooluse` (#3520): hidden, run by a job's agent.
func TestTheHookCommand(t *testing.T) {
	var out, errOut bytes.Buffer
	env := Env{Stdin: strings.NewReader(`{"tool_name":"Bash"}`), Stdout: &out, Stderr: &errOut,
		Getenv: func(string) string { return "" }}
	if code := Main([]string{"hook", "pretooluse"}, env); code != 0 || !strings.Contains(out.String(), `"permissionDecision":"deny"`) {
		t.Fatalf("exit %d, out %q: a shell call with nothing to ask is refused", code, out.String())
	}
	out.Reset()
	env.Stdin = strings.NewReader(`{"tool_name":"Read"}`)
	if code := Main([]string{"hook", "pretooluse"}, env); code != 0 || out.Len() != 0 {
		t.Fatalf("exit %d, out %q: Read goes through", code, out.String())
	}
	if code := Main([]string{"hook"}, env); code != 2 {
		t.Fatalf("no hook named: exit %d", code)
	}
	var usage bytes.Buffer
	Main([]string{"help"}, Env{Stdout: &usage})
	if strings.Contains(usage.String(), "hook") {
		t.Error("the hook is in the usage; it is not for people")
	}
}

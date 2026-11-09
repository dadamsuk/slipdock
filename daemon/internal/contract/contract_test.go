package contract

import (
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

func TestRenderFillsInTheMachine(t *testing.T) {
	var b strings.Builder
	err := Render(&b, Facts{
		Server: "https://slipdock.example.com", Name: "box", MachineID: 7, Fingerprint: "ab12:cd34",
		Version: "v1.0.0", Account: "builder", CeilingPath: "/etc/x/ceiling.json", KeyPath: "/etc/x/machine-key",
		Ceiling: machine.Ceiling{
			Roots: []string{"/srv/a", "/srv/b"}, Agents: []string{"claude", "codex"},
			MaxPermissionMode: "acceptEdits", MaxTimeoutMinutes: 45, Boards: []int64{3, 9},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	out := b.String()
	for _, want := range []string{
		"Server:        https://slipdock.example.com",
		"Machine:       box (#7)",
		"Fingerprint:   ab12:cd34",
		"slipdock-runner v1.0.0",
		"Jobs run as:   builder",
		"Its ceiling (/etc/x/ceiling.json)",
		"Working directories inside: /srv/a, /srv/b",
		"Agents:                     claude, codex",
		"Highest permission mode:    acceptEdits",
		"Longest job:                45 minutes",
		"Boards served:              #3, #9",
		"/etc/x/machine-key",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
}

// The contract's promises, as W-2544 part 9 lists them: losing one of
// these lines is losing a promise.
func TestTheTextSaysWhatTheServerCanAndCannotDo(t *testing.T) {
	for _, want := range []string{
		"What the server can do",
		"Queue jobs for the pools this machine's runners joined",
		"only inside the ceiling",
		"Name a newer version",
		"What the server cannot do",
		"Run a command on this machine",
		"Change a hook or a command",
		"outside the roots",
		"Read files on this machine",
		"isn't signed",
		"What nothing here bounds",
		"First-install trust",
		"its operator is also the one who signs releases",
		"Network access",
		"Prompts are instructions from the board's members",
		"it is not an API",
	} {
		if !strings.Contains(Text, want) {
			t.Errorf("the contract no longer says %q", want)
		}
	}
}

func TestNoBoardsReadsAsNone(t *testing.T) {
	var b strings.Builder
	if err := Render(&b, Facts{}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(b.String(), "Boards served:              none") {
		t.Fatal(b.String())
	}
}

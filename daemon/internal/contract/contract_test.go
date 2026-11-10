package contract

import (
	"strings"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

func TestRenderFillsInTheMachine(t *testing.T) {
	var b strings.Builder
	err := Render(&b, Facts{
		Server: "https://slipdock.example.com", Name: "box", MachineID: 7, Fingerprint: "ab12:cd34",
		Version: "v1.0.0", CeilingPath: "/etc/x/ceiling.json", KeyPath: "/etc/x/machine-key",
		Ceiling: machine.Ceiling{
			Roots: []string{"/srv/a", "/srv/b"}, Agents: []string{"claude", "codex"},
			MaxPermissionMode: "acceptEdits", MaxTimeoutMinutes: 45, Boards: []int64{3, 9},
			Executors: []string{"me", "confined"},
		},
		RunsAs: []string{"me:  builder", "confined:  builder, walled in"},
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
		"Machine key:   /etc/x/machine-key",
		"Its ceiling (/etc/x/ceiling.json)",
		"Working directories inside: /srv/a, /srv/b",
		"Agents:                     claude, codex",
		"Highest permission mode:    acceptEdits",
		"Longest job:                45 minutes",
		"Boards served:              #3, #9",
		"Executors allowed:          me, confined",
		"Jobs run as\n  me:  builder\n  confined:  builder, walled in\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	// The whole shared text follows, as the terminal shows it.
	if !strings.HasSuffix(out, Plain(Text)) {
		t.Errorf("the contract isn't printed whole after the machine:\n%s", out)
	}
	if strings.Contains(out, "####") {
		t.Error("a Markdown heading mark reached the terminal")
	}
}

// The contract's promises, as W-2544 part 9 lists them: losing one of
// these lines is losing a promise.
func TestTheTextSaysWhatTheServerCanAndCannotDo(t *testing.T) {
	text := strings.Join(strings.Fields(Text), " ")
	for _, want := range []string{
		"#### What the server can do",
		"Queue jobs for the pools this machine's runners joined",
		"they apply only inside the machine's ceiling",
		"Name a newer version of the daemon",
		"#### What the server cannot do",
		"Run a command on this machine",
		"Change a hook or a command",
		"Change the ceiling",
		"outside the ceiling's roots",
		"Read files on this machine",
		"isn't signed with the project's release key",
		"It is not an API token",
		"#### What nothing here bounds",
		"First-install trust",
		"the operator who runs the server is also the one who signs the releases",
		"Network access",
		"unless its runner uses the `container` executor with the network off",
		"Prompts are the board members' instructions",
		"within the runner's permission mode",
		"Give the agent a `slipdock` CLI the project didn't sign",
		"only when its signature verifies against the same release key",
		"The slipdock skills, and a CLI taken on the server's word",
		"With `cli_checksum_only` set in `local.json`",
		"#### What each executor stops",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("the contract no longer says %q", want)
		}
	}
}

// Each executor the daemon knows has its paragraph, saying what it stops
// and what it doesn't.
func TestEveryExecutorSaysWhatItStopsAndDoesnt(t *testing.T) {
	_, section, ok := strings.Cut(Text, "#### What each executor stops")
	if !ok {
		t.Fatal("no executor section")
	}
	items := strings.Split(section, "\n- ")
	for _, name := range []string{executor.Me, executor.User, executor.Confined, executor.Container} {
		var item string
		for _, it := range items {
			if strings.HasPrefix(it, "`"+name+"`:") {
				item = strings.Join(strings.Fields(it), " ")
			}
		}
		if item == "" {
			t.Errorf("no paragraph for %s", name)
			continue
		}
		if !strings.Contains(item, "stop") {
			t.Errorf("%s doesn't say what it stops: %s", name, item)
		}
		if name != executor.Me && !strings.Contains(item, "doesn't stop") {
			t.Errorf("%s doesn't say what it doesn't stop: %s", name, item)
		}
	}
}

func TestPlainUnderlinesHeadingsAndKeepsTheRest(t *testing.T) {
	got := Plain("Intro.\n\n#### What it can do\n\n- a `thing`\n#### Ünïcode\nend")
	want := "Intro.\n\nWhat it can do\n--------------\n\n- a `thing`\nÜnïcode\n-------\nend"
	if got != want {
		t.Fatalf("got\n%q\nwant\n%q", got, want)
	}
	// Only a level-four heading is the contract's; anything else is text.
	if got := Plain("### not one\n####nor this\n"); got != "### not one\n####nor this\n" {
		t.Fatalf("changed: %q", got)
	}
}

func TestNoBoardsReadsAsNoneAndAnOldCeilingAsMe(t *testing.T) {
	var b strings.Builder
	if err := Render(&b, Facts{}); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Boards served:              none", "Executors allowed:          me"} {
		if !strings.Contains(b.String(), want) {
			t.Errorf("missing %q in:\n%s", want, b.String())
		}
	}
}

// A Windows checkout writes the embedded files with CRLF; the contract reads
// the same either way.
func TestLineEndsAreLF(t *testing.T) {
	if got := lf("a\r\nb\r\n\r\nc\n"); got != "a\nb\n\nc\n" {
		t.Fatalf("%q", got)
	}
	if strings.Contains(Text, "\r") || strings.Contains(machineText, "\r") {
		t.Fatal("a carriage return in the embedded text")
	}
}

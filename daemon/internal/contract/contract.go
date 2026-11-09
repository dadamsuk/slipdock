// Package contract is the trust contract (W-2544 part 9): one text,
// contract.md, embedded in the daemon and published by the server (which
// reads the same file at compile time, Slipdock.Machines.TrustContract),
// saying what a Slipdock server can and cannot make this machine do. Render
// prints it for `slipdock-runner show`, after machine.txt filled with this
// machine's limits.
package contract

import (
	_ "embed"
	"fmt"
	"io"
	"strings"
	"text/template"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// Text is the contract as the server publishes it, in Markdown.
//
//go:embed contract.md
var Text string

//go:embed machine.txt
var machineText string

// Facts are what Render fills in.
type Facts struct {
	Server      string
	Name        string
	MachineID   int64
	Fingerprint string
	Version     string
	CeilingPath string
	KeyPath     string
	Ceiling     machine.Ceiling
	// RunsAs says, one line per executor the ceiling allows, who a job
	// under it runs as on this machine.
	RunsAs []string
}

var tmpl = template.Must(template.New("contract").Option("missingkey=error").Funcs(template.FuncMap{
	"join": strings.Join,
	"boards": func(ids []int64) string {
		if len(ids) == 0 {
			return "none"
		}
		parts := make([]string, len(ids))
		for i, id := range ids {
			parts[i] = fmt.Sprintf("#%d", id)
		}
		return strings.Join(parts, ", ")
	},
}).Parse(machineText))

// Render writes this machine's limits, then the contract.
func Render(w io.Writer, f Facts) error {
	if err := tmpl.Execute(w, f); err != nil {
		return err
	}
	_, err := io.WriteString(w, Plain(Text))
	return err
}

// Plain is the contract's Markdown as a terminal shows it: each heading
// underlined instead of marked with #. The rest of the text is written to
// read as it is.
func Plain(md string) string {
	var b strings.Builder
	for _, line := range strings.SplitAfter(md, "\n") {
		body := strings.TrimRight(line, "\n")
		if title, ok := strings.CutPrefix(body, "#### "); ok {
			fmt.Fprintf(&b, "%s\n%s\n", title, strings.Repeat("-", len([]rune(title))))
			continue
		}
		b.WriteString(line)
	}
	return b.String()
}

// Package contract is the trust contract (W-2544 part 9): one text, embedded
// in the daemon and published by the server, saying what a Slipdock server
// can and cannot make this machine do. Render fills it with one machine's
// limits, for `slipdock-runner show`.
package contract

import (
	_ "embed"
	"fmt"
	"io"
	"strings"
	"text/template"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

//go:embed contract.txt
var Text string

// Facts are what Render fills in.
type Facts struct {
	Server      string
	Name        string
	MachineID   int64
	Fingerprint string
	Version     string
	Account     string
	CeilingPath string
	KeyPath     string
	Ceiling     machine.Ceiling
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
}).Parse(Text))

// Render writes the contract filled with f.
func Render(w io.Writer, f Facts) error {
	return tmpl.Execute(w, f)
}

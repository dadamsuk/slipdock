package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
	"github.com/dadamsuk/slipdock/daemon/internal/machineconfig"
	"github.com/dadamsuk/slipdock/daemon/internal/runner"
)

// cmdConfig prints the machine's settings from its own files (#2652): the
// ceiling, local.json and each runner's accepted config, and for a runner
// the ceiling refused, what and why. --effective resolves the names; --json
// dumps the three files as one object. show stays the trust contract.
func cmdConfig(args []string, env Env) error {
	fs, home := newFlags("config", env)
	effective := fs.Bool("effective", false, "resolve names: the program each agent and hook runs, each runner's executor and root")
	asJSON := fs.Bool("json", false, "the three files as one JSON object")
	if err := parse(fs, args); err != nil {
		return err
	}
	if *effective && *asJSON {
		fmt.Fprintln(env.Stderr, "slipdock-runner config: --json dumps the files as they are, so not with --effective")
		return errUsage
	}
	d, err := dir(*home, env)
	if err != nil {
		return err
	}
	if *asJSON {
		return dumpConfig(d, env.Stdout)
	}
	ceil, ceilErr := machine.LoadCeiling(d)
	local, err := machine.LoadLocal(d)
	if err != nil {
		return fmt.Errorf("the local file: %w", err)
	}
	cache, err := machineconfig.ReadCache(d)
	if err != nil {
		return err
	}
	out := env.Stdout
	printCeilingFile(out, d, ceil, ceilErr)
	printLocal(out, d)
	printRunners(out, d, cache, *effective, ceil, ceilErr == nil, local, env)
	return nil
}

// dumpConfig writes {"ceiling":…, "local":…, "config_cache":…}, each the
// file as it is (null when there is none).
func dumpConfig(d string, out io.Writer) error {
	obj := map[string]json.RawMessage{}
	for key, name := range map[string]string{"ceiling": machine.CeilingFile, "local": machine.LocalFile, "config_cache": machineconfig.CacheFile} {
		data, err := os.ReadFile(filepath.Join(d, name))
		switch {
		case errors.Is(err, os.ErrNotExist):
			obj[key] = json.RawMessage("null")
			continue
		case err != nil:
			return err
		case !json.Valid(data):
			return fmt.Errorf("%s is not valid JSON", filepath.Join(d, name))
		}
		obj[key] = json.RawMessage(bytes.TrimSpace(data))
	}
	data, err := json.MarshalIndent(obj, "", "  ")
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "%s\n", data)
	return nil
}

func printCeilingFile(out io.Writer, d string, c machine.Ceiling, err error) {
	fmt.Fprintf(out, "Ceiling (%s)\n", filepath.Join(d, machine.CeilingFile))
	if err != nil {
		fmt.Fprintf(out, "  can't be read: %v\n\n", err)
		return
	}
	boards := make([]string, len(c.Boards))
	for i, b := range c.Boards {
		boards[i] = fmt.Sprintf("#%d", b)
	}
	rows := [][2]string{
		{"roots", list0(c.Roots)},
		{"agents", list0(c.Agents)},
		{"max permission mode", c.MaxPermissionMode},
		{"max timeout", fmt.Sprintf("%d minutes", c.MaxTimeoutMinutes)},
		{"boards", list0(boards)},
		{"executors", list0(c.Offered())},
	}
	if len(c.ContainerImages) > 0 {
		rows = append(rows, [2]string{"container images", list0(c.ContainerImages)})
	}
	printRows(out, rows)
	fmt.Fprintln(out)
}

func printLocal(out io.Writer, d string) {
	path := filepath.Join(d, machine.LocalFile)
	fmt.Fprintf(out, "Local (%s)\n", path)
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		fmt.Fprintln(out, "  none: claude and codex are found on the PATH, and no hook or other agent is defined")
		fmt.Fprintln(out)
		return
	}
	var buf bytes.Buffer
	if err != nil || json.Indent(&buf, bytes.TrimSpace(data), "  ", "  ") != nil {
		fmt.Fprintf(out, "  can't be read: %v\n\n", err)
		return
	}
	fmt.Fprintf(out, "  %s\n\n", buf.String())
}

// printRunners prints each runner the cache knows: its accepted config at
// its version, and what the ceiling refused and why.
func printRunners(out io.Writer, d string, c *machineconfig.Cache, effective bool, ceil machine.Ceiling, hasCeiling bool, local machine.Local, env Env) {
	if c == nil {
		fmt.Fprintf(out, "Runners: none accepted yet (no %s)\n", machineconfig.CacheFile)
		return
	}
	fmt.Fprintf(out, "Runners (config version %d)\n", c.Version)
	ids := map[int64]bool{}
	for _, l := range c.Runners {
		ids[l.ID] = true
	}
	for id, rep := range c.Reported {
		if rep.Outcome == "rejected" {
			ids[id] = true
		}
	}
	sorted := make([]int64, 0, len(ids))
	for id := range ids {
		sorted = append(sorted, id)
	}
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	for _, id := range sorted {
		l, accepted := listedName(c, id)
		rep, reported := c.Reported[id]
		refused := reported && rep.Outcome == "rejected"
		name := l.Name
		if !accepted {
			name = refusedName(d, id)
		}
		fmt.Fprintf(out, "\n  %s (#%d)", name, id)
		if accepted {
			fmt.Fprintf(out, " v%d accepted", l.ConfigVersion)
			if l.Paused {
				fmt.Fprint(out, ", paused")
			}
		}
		fmt.Fprintln(out)
		if refused {
			kept := "it doesn't run"
			if accepted {
				kept = fmt.Sprintf("it keeps v%d", l.ConfigVersion)
			}
			fmt.Fprintf(out, "    REFUSED v%d, %s: %s\n", rep.Version, kept, rep.Reason)
			if ch := lastChange(d, id); ch.text != "" {
				fmt.Fprintf(out, "    changes.log %s: %s\n", ch.at, ch.text)
			}
		}
		if !accepted {
			continue
		}
		rows := [][2]string{{"board", fmt.Sprintf("#%d", l.BoardID)}, {"pool", l.Pool}}
		rows = append(rows, configRows(l.Config)...)
		printRowsIndent(out, "    ", rows)
		if effective {
			printEffective(out, l.Runner, ceil, hasCeiling, local, env)
		}
	}
}

// configRows are a config's fields that are set, by their JSON names.
func configRows(c runner.Config) [][2]string {
	var rows [][2]string
	v := reflect.ValueOf(c)
	t := v.Type()
	for i := 0; i < t.NumField(); i++ {
		name := strings.Split(t.Field(i).Tag.Get("json"), ",")[0]
		val := fmt.Sprint(v.Field(i).Interface())
		if val == "" || val == "0" {
			continue
		}
		if first, _, more := strings.Cut(val, "\n"); more {
			val = first + " …"
		}
		rows = append(rows, [2]string{name, clip(val, 100)})
	}
	return rows
}

// printEffective resolves a runner's names on this machine: the program
// its agent and each hook runs, who its jobs run as, and the root its
// directory is inside.
func printEffective(out io.Writer, r runner.Runner, ceil machine.Ceiling, hasCeiling bool, local machine.Local, env Env) {
	c := r.Config
	resolve := func(cmd machine.Command) string {
		line := cmd.Path
		if len(cmd.Args) > 0 {
			line += " " + strings.Join(cmd.Args, " ")
		}
		switch {
		case c.Executor == executor.Container:
			return line + " (inside the container's image)"
		case c.Executor == executor.User:
			who := "the dedicated account's"
			if local.User != nil {
				who = local.User.Name + "'s"
			}
			if filepath.IsAbs(cmd.Path) {
				return line
			}
			return line + " (looked up on " + who + " PATH when a job runs)"
		case filepath.IsAbs(cmd.Path):
			return line
		}
		if env.LookPath == nil {
			return line
		}
		p, err := env.LookPath(cmd.Path)
		if err != nil {
			return line + " (NOT on the PATH: no job can run)"
		}
		return p + strings.TrimPrefix(line, cmd.Path)
	}
	rows := [][2]string{}
	if agent, ok := local.Agent(c.Agent); ok {
		rows = append(rows, [2]string{"agent " + c.Agent, resolve(agent)})
	} else {
		rows = append(rows, [2]string{"agent " + c.Agent, "NOT DEFINED in local.json's agents: no job can run"})
	}
	for _, h := range []struct{ which, name string }{{"before_hook", c.BeforeHook}, {"after_hook", c.AfterHook}, {"probe_hook", c.ProbeHook}} {
		if h.name == "" {
			continue
		}
		label := h.which + " " + h.name
		if hook, ok := local.Hook(h.name); ok {
			rows = append(rows, [2]string{label, resolve(hook)})
		} else {
			rows = append(rows, [2]string{label, "NOT DEFINED in local.json's hooks: every job fails before it starts"})
		}
	}
	if vars := local.RunnerEnv(r.Name); len(vars) > 0 {
		rows = append(rows, [2]string{"env", strings.Join(vars, " ")})
	}
	account := "this account"
	if env.Account != nil {
		account = env.Account()
	}
	rows = append(rows, [2]string{"runs as", c.Executor + ": " + whoRunsAs(c.Executor, local, account)})
	switch {
	case !hasCeiling:
		rows = append(rows, [2]string{"root", "unknown: the ceiling can't be read"})
	default:
		if root := runner.RootOf(c.Directory, ceil.Roots); root != "" {
			rows = append(rows, [2]string{"root", c.Directory + " is inside " + root})
		} else {
			rows = append(rows, [2]string{"root", c.Directory + " is OUTSIDE every root (" + strings.Join(ceil.Roots, ", ") + ")"})
		}
	}
	fmt.Fprintln(out, "    effective:")
	printRowsIndent(out, "      ", rows)
}

func list0(l []string) string {
	if len(l) == 0 {
		return "(none)"
	}
	return strings.Join(l, ", ")
}

func printRows(out io.Writer, rows [][2]string) { printRowsIndent(out, "  ", rows) }

func printRowsIndent(out io.Writer, indent string, rows [][2]string) {
	w := 0
	for _, r := range rows {
		w = max(w, len(r[0]))
	}
	for _, r := range rows {
		fmt.Fprintf(out, "%s%-*s  %s\n", indent, w+1, r[0]+":", orDash(r[1]))
	}
}

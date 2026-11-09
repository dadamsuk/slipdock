// Package runner runs a machine's runners: one worker per runner, each
// taking jobs from the server's runner protocol with the machine key and
// running them as the shell runner does (W-2544 part 5), in one supervised
// process where one worker crashing leaves the others running.
//
// What a job runs comes only from the machine's own files: the agent's
// program, a custom command and the hooks are defined in machine.LocalFile,
// and the server's config only names them. A name the file doesn't define
// fails the job before anything starts.
package runner

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// Config is a runner's typed config, as the server sends it
// (Slipdock.Runners.Config): data, never a command.
type Config struct {
	Agent          string `json:"agent"`
	Directory      string `json:"directory"`
	PermissionMode string `json:"permission_mode"`
	TimeoutMinutes int    `json:"timeout_minutes"`
	Model          string `json:"model"`
	Worktree       string `json:"worktree"`
	Verbosity      string `json:"verbosity"`
	Instructions   string `json:"instructions"`
	Executor       string `json:"executor"`
	BeforeHook     string `json:"before_hook"`
	AfterHook      string `json:"after_hook"`
	ProbeHook      string `json:"probe_hook"`
}

// Runner is one of the machine's runners, as GET /api/machine/config lists it.
type Runner struct {
	ID            int64  `json:"id"`
	Name          string `json:"name"`
	BoardID       int64  `json:"board_id"`
	Pool          string `json:"pool"`
	Config        Config `json:"config"`
	ConfigVersion int64  `json:"config_version"`
}

// MachineConfig is the machine's config: its runners, at a version.
type MachineConfig struct {
	Version int64    `json:"version"`
	Runners []Runner `json:"runners"`
}

// executors this daemon can run a job under yet. The others (W-2543) come
// with their own cards; a runner set to one is refused, never run as the
// daemon's own account in its place.
var executors = []string{"me"}

// Check says why c falls outside the ceiling, or nil when it is inside it.
func (r Runner) Check(ceil machine.Ceiling) error {
	c := r.Config
	var problems []string
	if !contains(ceil.Agents, c.Agent) {
		problems = append(problems, fmt.Sprintf("agent %q is not one this machine allows (%s)", c.Agent, strings.Join(ceil.Agents, ", ")))
	}
	if !insideRoots(c.Directory, ceil.Roots) {
		problems = append(problems, fmt.Sprintf("directory %q is not inside %s", c.Directory, strings.Join(ceil.Roots, ", ")))
	}
	if rank := machine.ModeRank(c.PermissionMode); rank < 0 || rank > machine.ModeRank(ceil.MaxPermissionMode) {
		problems = append(problems, fmt.Sprintf("permission mode %q is above %s", c.PermissionMode, ceil.MaxPermissionMode))
	}
	if c.TimeoutMinutes < 1 || c.TimeoutMinutes > ceil.MaxTimeoutMinutes {
		problems = append(problems, fmt.Sprintf("timeout %d minutes is over %d", c.TimeoutMinutes, ceil.MaxTimeoutMinutes))
	}
	if !containsID(ceil.Boards, r.BoardID) {
		problems = append(problems, fmt.Sprintf("board #%d is not one this machine serves", r.BoardID))
	}
	if !contains(executors, c.Executor) {
		problems = append(problems, fmt.Sprintf("executor %q is not available on this daemon yet (only %s)", c.Executor, strings.Join(executors, ", ")))
	}
	if len(problems) > 0 {
		return fmt.Errorf("%s", strings.Join(problems, "; "))
	}
	return nil
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

func containsID(list []int64, id int64) bool {
	for _, v := range list {
		if v == id {
			return true
		}
	}
	return false
}

// insideRoots: dir is an absolute path at or below one of roots.
func insideRoots(dir string, roots []string) bool {
	if dir == "" || !filepath.IsAbs(dir) {
		return false
	}
	dir = filepath.Clean(dir)
	for _, root := range roots {
		rel, err := filepath.Rel(filepath.Clean(root), dir)
		if err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel) {
			return true
		}
	}
	return false
}

// Kinds are the job kinds a runner takes, said on every claim: its agent's,
// verify (the same agent checks another's work), the built-in merge and
// the built-in probe (#2580), which the server sends only to the runner it
// names.
func (r Runner) Kinds(local machine.Local) []string {
	kinds := []string{r.Config.Agent}
	if r.Config.Agent != "verify" {
		kinds = append(kinds, "verify")
	}
	if !local.NoMerge && r.Config.Agent != "merge" {
		kinds = append(kinds, "merge")
	}
	if r.Config.Agent != ProbeKind {
		kinds = append(kinds, ProbeKind)
	}
	return kinds
}

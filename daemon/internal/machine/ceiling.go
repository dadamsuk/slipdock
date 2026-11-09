package machine

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Ceiling is the machine's own limits on what the server may configure
// (W-2541, W-2544 part 2). Written by init, changed only by a person at
// the machine, never read or written by the server.
type Ceiling struct {
	// Roots are the directories a runner's working directory must be inside.
	Roots []string `json:"roots"`
	// Agents a runner may run: claude, codex, or the name of a custom
	// command defined in this machine's local file.
	Agents []string `json:"agents"`
	// MaxPermissionMode is the highest permission mode a runner may use.
	MaxPermissionMode string `json:"max_permission_mode"`
	// MaxTimeoutMinutes is the longest a job may run.
	MaxTimeoutMinutes int `json:"max_timeout_minutes"`
	// Boards the machine serves.
	Boards []int64 `json:"boards"`
	// Executors a runner may name (W-2543): me, user, confined. A ceiling
	// written before there were any reads as me only.
	Executors []string `json:"executors,omitempty"`
}

// ExecutorNames are the executors a ceiling may list.
var ExecutorNames = []string{"me", "user", "confined", "container"}

// PermissionModes from least to most permissive: a runner's mode must not
// rank above the ceiling's.
var PermissionModes = []string{"plan", "default", "acceptEdits", "bypassPermissions"}

// ModeRank is a mode's place in PermissionModes, or -1 if it isn't one.
func ModeRank(mode string) int {
	for i, m := range PermissionModes {
		if m == mode {
			return i
		}
	}
	return -1
}

var agentName = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,39}$`)

// Validate says what, if anything, is wrong with the ceiling.
func (c Ceiling) Validate() error {
	var problems []string
	if len(c.Roots) == 0 {
		problems = append(problems, "roots: name at least one directory runners may work in")
	}
	for _, r := range c.Roots {
		if !filepath.IsAbs(r) {
			problems = append(problems, fmt.Sprintf("roots: %q is not an absolute path", r))
		}
	}
	if len(c.Agents) == 0 {
		problems = append(problems, "agents: name at least one (claude, codex, or a custom command)")
	}
	for _, a := range c.Agents {
		if !agentName.MatchString(a) {
			problems = append(problems, fmt.Sprintf("agents: %q is not a name (lower case, digits, - and _)", a))
		}
	}
	if ModeRank(c.MaxPermissionMode) < 0 {
		problems = append(problems, fmt.Sprintf("max_permission_mode: %q is not one of %s",
			c.MaxPermissionMode, strings.Join(PermissionModes, ", ")))
	}
	if c.MaxTimeoutMinutes < 1 || c.MaxTimeoutMinutes > 24*60 {
		problems = append(problems, "max_timeout_minutes: between 1 and 1440")
	}
	if len(c.Boards) == 0 {
		problems = append(problems, "boards: the machine serves at least one board")
	}
	for _, e := range c.Executors {
		if !oneOf(ExecutorNames, e) {
			problems = append(problems, fmt.Sprintf("executors: %q is not one of %s", e, strings.Join(ExecutorNames, ", ")))
		}
	}
	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

// sourceFolders are the home's usual source folders, in the order init
// proposes them.
var sourceFolders = []string{"src", "dev", "code", "projects", "repos"}

// ProposeCeiling is what init offers: the home's source folder (the first of
// ~/src, ~/dev, ~/code, ~/projects, ~/repos that exists, else ~/src),
// claude, acceptEdits and one hour, for the boards the enrolment chose.
func ProposeCeiling(home string, boards []int64) Ceiling {
	root := filepath.Join(home, sourceFolders[0])
	for _, name := range sourceFolders {
		p := filepath.Join(home, name)
		if fi, err := os.Stat(p); err == nil && fi.IsDir() {
			root = p
			break
		}
	}
	b := append([]int64(nil), boards...)
	sort.Slice(b, func(i, j int) bool { return b[i] < b[j] })
	return Ceiling{
		Roots:             []string{root},
		Agents:            []string{"claude"},
		MaxPermissionMode: "acceptEdits",
		MaxTimeoutMinutes: 60,
		Boards:            b,
		Executors:         []string{"me"},
	}
}

func oneOf(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// SaveCeiling writes the ceiling, after checking it.
func SaveCeiling(dir string, c Ceiling) error {
	if err := c.Validate(); err != nil {
		return fmt.Errorf("the ceiling isn't valid: %w", err)
	}
	if err := ensureDir(dir); err != nil {
		return err
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return writeFile(filepath.Join(dir, CeilingFile), append(data, '\n'), 0o644)
}

// LoadCeiling reads and checks the ceiling.
func LoadCeiling(dir string) (Ceiling, error) {
	var c Ceiling
	path := filepath.Join(dir, CeilingFile)
	data, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return c, fmt.Errorf("%s: %w", path, err)
	}
	if err := c.Validate(); err != nil {
		return c, fmt.Errorf("%s: %w", path, err)
	}
	if len(c.Executors) == 0 {
		c.Executors = []string{"me"}
	}
	return c, nil
}

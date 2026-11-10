package machine

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// LocalFile is the machine's own definitions of what can run: the agents'
// programs, custom commands and hooks (W-2541). The server names an agent
// or a hook; only this file says what the name runs. Like the ceiling, a
// person at the machine writes it and the server never reads or writes it.
const LocalFile = "local.json"

// Command is a program and its first arguments.
type Command struct {
	// Path is the program: an absolute path, or a name looked up on the
	// PATH of the account jobs run as.
	Path string   `json:"path"`
	Args []string `json:"args,omitempty"`
	// AllowedTools, for claude: the tools a job may use without asking
	// (in -p nobody is there to approve one), such as mcp__slipdock.
	AllowedTools []string `json:"allowed_tools,omitempty"`
}

// Local is what LocalFile holds. Every field is optional: with no file at
// all, claude and codex are found on the PATH and nothing else is defined.
type Local struct {
	// Agents by name. claude and codex need no entry unless their program
	// isn't on the PATH or claude has tools to allow; any other agent a
	// runner names must be defined here, and gets the prompt as
	// $SLIPDOCK_PROMPT, never on its command line.
	Agents map[string]Command `json:"agents,omitempty"`
	// Hooks by name: a runner's before, after and probe hooks name these.
	Hooks map[string]Command `json:"hooks,omitempty"`
	// Models picks a model by the card's profile (docs, fix, feature,
	// schema, security, spike), over the runner's own model.
	Models map[string]string `json:"models,omitempty"`
	// Transcripts is where Claude Code keeps its transcripts (default
	// ~/.claude/projects, or $CLAUDE_CONFIG_DIR/projects).
	Transcripts string `json:"transcripts,omitempty"`
	// SkillsDir is where the slipdock skills are installed (default
	// ~/.claude/skills), and CLI the slipdock CLI (default: the one on
	// the PATH): their checksums go with each claim, so the board shows
	// drift.
	SkillsDir string `json:"skills_dir,omitempty"`
	CLI       string `json:"cli,omitempty"`
	// NoMerge turns off the built-in merge kind.
	NoMerge bool `json:"no_merge,omitempty"`
	// NoSkillsUpdate keeps the skills in SkillsDir as they are: by
	// default each slipdock skill there is replaced with the server's
	// before every agent job (#2614).
	NoSkillsUpdate bool `json:"no_skills_update,omitempty"`
	// NoCLIUpdate keeps the slipdock CLI as it is: by default, before
	// every agent job, the server's is put in the daemon's own bin (or at
	// CLI, when that is set) if the claim's CLI differs from it (#2631).
	NoCLIUpdate bool `json:"no_cli_update,omitempty"`
	// CLIChecksumOnly lets that update install a CLI the server serves
	// unsigned, checked only against the server's own SHA256SUMS: by
	// default only a CLI signed with the project's release key is
	// installed (#2669, W-2542).
	CLIChecksumOnly bool `json:"cli_checksum_only,omitempty"`
	// User is the dedicated account jobs run as under the user executor
	// (W-2543): init writes it when it sets the account up.
	User *Account `json:"user,omitempty"`
	// ConfinedWritable are what a confined job may write besides its own
	// directory: the agent's own state (default ~/.claude, for claude).
	ConfinedWritable []string `json:"confined_writable,omitempty"`
	// LogLevel is the least a line must matter to reach the daemon's log:
	// debug, info (the default), warn or error (#2652). run's --log-level
	// overrides it.
	LogLevel string `json:"log_level,omitempty"`
	// Container is how the container executor runs a job here (#2577).
	// Which images it may run is the ceiling's (container_images).
	Container *ContainerSettings `json:"container,omitempty"`
	// Runners are this machine's own settings for a runner, by the name
	// the board gives it (#2667). Runners that share a name share its
	// entry, and a name no runner has does nothing.
	Runners map[string]RunnerSettings `json:"runners,omitempty"`
}

// RunnerSettings are the machine's own for one runner.
type RunnerSettings struct {
	// Env are variables its jobs get, the agent and the hooks alike:
	// MIX_TEST_PARTITION, say, so two runners' test suites never share a
	// database. SLIPDOCK_* and the executor's own (HOME, PATH) are
	// refused.
	Env map[string]string `json:"env,omitempty"`
}

// ContainerSettings are the machine's own for the container executor.
type ContainerSettings struct {
	// Runtime is docker, podman or a path to either (default: docker on
	// the PATH, else podman).
	Runtime string `json:"runtime,omitempty"`
	// Pull is never (the default: the image must be on the machine),
	// missing or always.
	Pull string `json:"pull,omitempty"`
	// Login are mounted read-only at the same paths, each inside the home
	// (default: the agent's login, and the slipdock CLI's).
	Login []string `json:"login,omitempty"`
	// Env are the daemon's variables a job gets (default: the agent's key
	// or token). SLIPDOCK_* never pass.
	Env []string `json:"env,omitempty"`
}

// Account is a dedicated account: its name, its home, and the PATH its
// jobs get (default: its ~/.local/bin and ~/bin, then the system's).
type Account struct {
	Name string `json:"name"`
	Home string `json:"home"`
	Path string `json:"path,omitempty"`
}

// LogLevels are what log_level may be.
var LogLevels = []string{"debug", "info", "warn", "error"}

// BuiltinAgents need no entry in the local file.
var BuiltinAgents = []string{"claude", "codex"}

// Validate says what, if anything, is wrong with the file.
func (l Local) Validate() error {
	var problems []string
	check := func(kind, name string, c Command) {
		if !agentName.MatchString(name) {
			problems = append(problems, fmt.Sprintf("%s: %q is not a name (lower case, digits, - and _)", kind, name))
		}
		if strings.TrimSpace(c.Path) == "" {
			problems = append(problems, fmt.Sprintf("%s.%s: path is empty", kind, name))
		}
	}
	for _, name := range sortedNames(l.Agents) {
		check("agents", name, l.Agents[name])
	}
	for _, name := range sortedNames(l.Hooks) {
		check("hooks", name, l.Hooks[name])
	}
	if u := l.User; u != nil {
		if strings.TrimSpace(u.Name) == "" {
			problems = append(problems, "user.name: the account's name is empty")
		}
		if !filepath.IsAbs(u.Home) {
			problems = append(problems, fmt.Sprintf("user.home: %q is not an absolute path", u.Home))
		}
	}
	for _, w := range l.ConfinedWritable {
		if !filepath.IsAbs(w) {
			problems = append(problems, fmt.Sprintf("confined_writable: %q is not an absolute path", w))
		}
	}
	if !oneOf(LogLevels, l.LogLevel) && l.LogLevel != "" {
		problems = append(problems, fmt.Sprintf("log_level: %q is not one of %s", l.LogLevel, strings.Join(LogLevels, ", ")))
	}
	if ct := l.Container; ct != nil {
		if ct.Pull != "" && !oneOf(executor.Pulls, ct.Pull) {
			problems = append(problems, fmt.Sprintf("container.pull: %q is not one of %s", ct.Pull, strings.Join(executor.Pulls, ", ")))
		}
		if ct.Runtime != "" && strings.TrimSpace(ct.Runtime) != ct.Runtime {
			problems = append(problems, fmt.Sprintf("container.runtime: %q has spaces around it", ct.Runtime))
		}
		for _, p := range ct.Login {
			if !filepath.IsAbs(p) {
				problems = append(problems, fmt.Sprintf("container.login: %q is not an absolute path", p))
			}
		}
		for _, name := range ct.Env {
			if err := executor.ValidPassEnv(name); err != nil {
				problems = append(problems, "container.env: "+err.Error())
			}
		}
	}
	problems = append(problems, l.runnerProblems()...)
	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

// runnerProblems says what is wrong with the runners block.
func (l Local) runnerProblems() []string {
	var problems []string
	for _, runner := range sortedNames(l.Runners) {
		if strings.TrimSpace(runner) == "" {
			problems = append(problems, "runners: a runner's name is empty")
		}
		env := l.Runners[runner].Env
		for _, name := range sortedNames(env) {
			if err := executor.ValidJobEnv(name); err != nil {
				problems = append(problems, fmt.Sprintf("runners.%s.env: %v", runner, err))
			}
			if strings.ContainsRune(env[name], 0) {
				problems = append(problems, fmt.Sprintf("runners.%s.env: %s has a NUL in its value", runner, name))
			}
		}
	}
	return problems
}

// RunnerEnv is what the file sets for the jobs of the runner called
// name, as NAME=value in the names' order.
func (l Local) RunnerEnv(name string) []string {
	env := l.Runners[name].Env
	out := make([]string, 0, len(env))
	for _, k := range sortedNames(env) {
		out = append(out, k+"="+env[k])
	}
	return out
}

func sortedNames[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// SaveLocal writes the local file, after checking it.
func SaveLocal(dir string, l Local) error {
	if err := l.Validate(); err != nil {
		return fmt.Errorf("the local file isn't valid: %w", err)
	}
	if err := ensureDir(dir); err != nil {
		return err
	}
	data, err := json.MarshalIndent(l, "", "  ")
	if err != nil {
		return err
	}
	return writeFile(filepath.Join(dir, LocalFile), append(data, '\n'), 0o644)
}

// LoadLocal reads and checks the local file. A missing file is an empty one.
func LoadLocal(dir string) (Local, error) {
	var l Local
	path := filepath.Join(dir, LocalFile)
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return l, nil
	} else if err != nil {
		return l, err
	}
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&l); err != nil {
		return l, fmt.Errorf("%s: %w", path, err)
	}
	if err := l.Validate(); err != nil {
		return l, fmt.Errorf("%s: %w", path, err)
	}
	return l, nil
}

// Agent is the command for agent name: the local file's entry, else a
// built-in agent's program on the PATH. ok is false for a name the file
// doesn't define and that isn't built in.
func (l Local) Agent(name string) (Command, bool) {
	if c, found := l.Agents[name]; found {
		return c, true
	}
	for _, b := range BuiltinAgents {
		if b == name {
			return Command{Path: name}, true
		}
	}
	return Command{}, false
}

// Hook is the command for hook name, if the local file defines it.
func (l Local) Hook(name string) (Command, bool) {
	c, found := l.Hooks[name]
	return c, found
}

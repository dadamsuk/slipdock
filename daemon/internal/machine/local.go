package machine

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
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
}

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
	for _, name := range sortedKeys(l.Agents) {
		check("agents", name, l.Agents[name])
	}
	for _, name := range sortedKeys(l.Hooks) {
		check("hooks", name, l.Hooks[name])
	}
	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

func sortedKeys(m map[string]Command) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
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

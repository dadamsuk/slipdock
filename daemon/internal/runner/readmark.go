package runner

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// A Claude Code job's PreToolUse hook (#3520). When the agent reads text
// less trusted than its job's tier, the server marks the job; the hook,
// `slipdock-runner hook pretooluse` (internal/hook), asks the server
// whether the job is marked before each shell, network or MCP tool call,
// and refuses it from then on. The machine installs it, in the agent's
// command line, and the server only answers the question.

// hookMatcher is the tools Claude Code runs the hook for; the hook itself
// decides (hook.Guarded), so a wider match costs a call, never a hole.
const hookMatcher = "Bash|PowerShell|Monitor|WebFetch|WebSearch|mcp__.*"

// hooked is whether job's agent gets the hook: a Claude Code agent, a
// server that gave the job a hook key, and an executor the daemon's own
// binary runs under (not the container, whose image hasn't it).
func (w *Worker) hooked(job *Job) bool {
	if job == nil || job.HookKey == "" || w.Runner.Config.Agent != "claude" || w.Launcher == "" {
		return false
	}
	return w.Executor == nil || w.Executor.Name() != executor.Container
}

// markURL is where the hook asks whether job is marked.
func (w *Worker) markURL(job *Job) string {
	server := ""
	if w.Client != nil {
		server = strings.TrimRight(w.Client.Server, "/")
	}
	return fmt.Sprintf("%s/api/runner/jobs/%d/mark", server, job.ID)
}

// hookSettings is the --settings JSON that gives the agent the hook, or
// "" when it gets none. The key and the URL go in the environment.
func (w *Worker) hookSettings(job *Job) string {
	if !w.hooked(job) {
		return ""
	}
	settings := map[string]any{
		"hooks": map[string]any{
			"PreToolUse": []any{map[string]any{
				"matcher": hookMatcher,
				"hooks": []any{map[string]any{
					"type":    "command",
					"command": shellQuote(w.Launcher, w.GOOS) + " hook pretooluse",
					"timeout": 30,
				}},
			}},
		},
	}
	data, err := json.Marshal(settings)
	if err != nil {
		return ""
	}
	return string(data)
}

// shellQuote quotes path for the shell Claude Code runs a hook's command
// in: single quotes on Unix, double on Windows.
func shellQuote(path, goos string) string {
	if goos == "windows" {
		return `"` + strings.ReplaceAll(path, `"`, `\"`) + `"`
	}
	return "'" + strings.ReplaceAll(path, "'", `'\''`) + "'"
}

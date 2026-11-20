// Package hook is `slipdock-runner hook pretooluse` (#3520), the Claude
// Code PreToolUse hook the daemon gives a job's agent. Before a shell,
// network or MCP tool call it asks the server whether a read of
// less-trusted text has marked the job, and refuses the call when it has,
// or when it can't find out. Every other tool is let through unasked.
package hook

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Env is what the hook runs with.
type Env struct {
	Stdin          io.Reader
	Stdout, Stderr io.Writer
	Getenv         func(string) string
	HTTP           *http.Client
	// Sleep waits between tries (time.Sleep).
	Sleep func(time.Duration)
}

// Tries is how many times the server is asked before the hook gives up
// and refuses the call; Pause is the wait between tries.
var (
	Tries = 3
	Pause = time.Second
)

// Main runs the hook named by args and answers its exit status.
func Main(args []string, env Env) int {
	if len(args) != 1 || args[0] != "pretooluse" {
		fmt.Fprintln(env.Stderr, "usage: slipdock-runner hook pretooluse (run by Claude Code, not by people)")
		return 2
	}
	return PreToolUse(env)
}

// Guarded is whether a call to tool waits on the job's mark: the shell,
// the network and every MCP server but Slipdock's own. Pushing goes
// through the shell or an MCP server, so it is among them.
func Guarded(tool string) bool {
	switch tool {
	case "Bash", "PowerShell", "Monitor", "WebFetch", "WebSearch":
		return true
	}
	if rest, ok := strings.CutPrefix(tool, "mcp__"); ok {
		server, _, _ := strings.Cut(rest, "__")
		return !strings.Contains(strings.ToLower(server), "slipdock")
	}
	return false
}

type input struct {
	ToolName string `json:"tool_name"`
}

// PreToolUse reads Claude Code's hook input from stdin and, for a guarded
// tool, asks the server. A refusal is the JSON decision on stdout with
// exit 0; anything let through is exit 0 and nothing printed.
func PreToolUse(env Env) int {
	data, err := io.ReadAll(io.LimitReader(env.Stdin, 4<<20))
	var in input
	if err == nil {
		err = json.Unmarshal(data, &in)
	}
	if err != nil {
		// Not knowing the tool is not knowing it is safe.
		return deny(env, "slipdock-runner couldn't read the tool call ("+err.Error()+"), so it is refused")
	}
	if !Guarded(in.ToolName) {
		return 0
	}
	marked, reason, err := ask(env)
	switch {
	case err != nil:
		return deny(env, "slipdock-runner couldn't check this job's mark with the server ("+err.Error()+
			"), so "+in.ToolName+" is refused; try again shortly")
	case marked:
		return deny(env, "this job read text less trusted than its own ("+reason+
			"), so the machine refuses the shell, the network and pushing for the rest of the run. "+
			"Carry on with the other tools, or finish and say what is left")
	}
	return 0
}

// ask asks the server, a few times, whether the job is marked.
func ask(env Env) (marked bool, reason string, err error) {
	url, key := env.Getenv("SLIPDOCK_HOOK_URL"), env.Getenv("SLIPDOCK_HOOK_KEY")
	if !strings.HasPrefix(url, "https://") && !strings.HasPrefix(url, "http://") || key == "" {
		return false, "", fmt.Errorf("no SLIPDOCK_HOOK_URL or SLIPDOCK_HOOK_KEY")
	}
	client := env.HTTP
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second}
	}
	sleep := env.Sleep
	if sleep == nil {
		sleep = time.Sleep
	}
	for try := 1; ; try++ {
		marked, reason, err = askOnce(client, url, key)
		if err == nil || try >= Tries {
			return marked, reason, err
		}
		sleep(Pause)
	}
}

func askOnce(client *http.Client, url, key string) (bool, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, "", err
	}
	req.Header.Set("Authorization", "Bearer "+key)
	resp, err := client.Do(req)
	if err != nil {
		return false, "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	text := strings.TrimSpace(string(body))
	if resp.StatusCode != http.StatusOK {
		return false, "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	switch {
	case text == "clear":
		return false, "", nil
	case text == "marked" || strings.HasPrefix(text, "marked "):
		return true, strings.TrimSpace(strings.TrimPrefix(text, "marked")), nil
	}
	return false, "", fmt.Errorf("an answer it doesn't know: %q", firstLine(text))
}

func deny(env Env, reason string) int {
	out := map[string]any{
		"hookSpecificOutput": map[string]any{
			"hookEventName":            "PreToolUse",
			"permissionDecision":       "deny",
			"permissionDecisionReason": reason,
		},
	}
	if err := json.NewEncoder(env.Stdout).Encode(out); err != nil {
		// Exit 2 blocks the call too, with stderr as the reason.
		fmt.Fprintln(env.Stderr, reason)
		return 2
	}
	return 0
}

func firstLine(s string) string {
	s, _, _ = strings.Cut(s, "\n")
	if len(s) > 100 {
		s = s[:100]
	}
	return s
}

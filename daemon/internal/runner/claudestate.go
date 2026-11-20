package runner

import (
	"os"
	"path/filepath"
)

// What a confined claude job may write of Claude Code's own directory
// (~/.claude, or $CLAUDE_CONFIG_DIR), when the local file's
// confined_writable doesn't say (#3485): the state a session keeps there,
// never what a later session loads and runs (its settings and hooks,
// CLAUDE.md, skills, plugins, commands, agents, output styles, and the
// rest the list leaves out).
//
// The card asked for a config directory of the job's own "or equivalent";
// this is the equivalent. A per-job CLAUDE_CONFIG_DIR would cost the
// macOS sign-in, which Claude Code keeps in the keychain under an entry
// named for its config directory, and would mean copying the skills and
// MCP config in; with the list, the job reads them where they are.
//
// Left out, besides the config: what a later or a concurrent session
// reads back and acts on (shell-snapshots, session-env, sessions, ide,
// state, backups, statsig, cache), and downloads. A job runs without
// them: its shell commands go without a snapshot of the login shell.
var claudeStateDirs = []string{
	"projects",     // transcripts (the daemon reads them) and project memory
	"todos",        // per session
	"tasks",        // per session
	"plans",        // per session
	"file-history", // per session: the edits it can rewind
	"debug",        // per session logs
	"logs",
	"telemetry",
	"paste-cache",
	"image-cache",
}

// claudeStateFiles are files Claude Code updates in place, writable only
// when they are there (Landlock and the macOS profile grant that file
// alone, not its directory, so a rewrite through a file beside it is still
// refused). .credentials.json is where Claude Code keeps its sign-in on
// Linux and refreshes the token: a job that couldn't save a refreshed
// token would leave the next one signed in with a token already spent,
// and the job can read the file anyway. history.jsonl is the prompt
// history a session appends to.
var claudeStateFiles = []string{".credentials.json", "history.jsonl"}

// claudeDir is Claude Code's own directory for the daemon's account.
func (w *Worker) claudeDir() string {
	if w.Getenv != nil {
		if d := w.Getenv("CLAUDE_CONFIG_DIR"); filepath.IsAbs(d) {
			return d
		}
	}
	if w.Home == "" {
		return ""
	}
	return filepath.Join(w.Home, ".claude")
}

// confinedWritable is what a confined job may write besides its directory:
// the local file's confined_writable, else, for claude, its session state.
func (w *Worker) confinedWritable() []string {
	if len(w.Local.ConfinedWritable) > 0 || w.Runner.Config.Agent != "claude" {
		return w.Local.ConfinedWritable
	}
	dir := w.claudeDir()
	if dir == "" {
		return nil
	}
	var out []string
	for _, name := range append(append([]string(nil), claudeStateDirs...), claudeStateFiles...) {
		out = append(out, filepath.Join(dir, name))
	}
	return out
}

// makeClaudeState makes the state directories that aren't there yet, which
// a confined job can't make itself: the sandbox grants only what exists.
func (w *Worker) makeClaudeState() {
	if len(w.Local.ConfinedWritable) > 0 || w.Runner.Config.Agent != "claude" {
		return
	}
	dir := w.claudeDir()
	if dir == "" {
		return
	}
	for _, name := range claudeStateDirs {
		if err := os.MkdirAll(filepath.Join(dir, name), 0o700); err != nil {
			w.say("warn: can't make %s for a confined job: %v", filepath.Join(dir, name), err)
		}
	}
}

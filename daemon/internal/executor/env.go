package executor

import "strings"

// JobVars are what the daemon sets for a job and its hooks. The daemon's
// own environment never passes one on.
var JobVars = []string{"SLIPDOCK_JOB_ID", "SLIPDOCK_JOB_KIND", "SLIPDOCK_CARD", "SLIPDOCK_CARD_URL",
	"SLIPDOCK_PROMPT", "SLIPDOCK_PROFILE", "SLIPDOCK_MODEL", "SLIPDOCK_RUNNER_ID", "SLIPDOCK_WORKTREE",
	"SLIPDOCK_EXIT", "SLIPDOCK_STATUS", "SLIPDOCK_MERGE_PR", "SLIPDOCK_MERGE_COMMIT", "SLIPDOCK_MERGED_FILE",
	"CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS", "PWD"}

func withoutJobVars(env []string) []string {
	var out []string
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		if !isJobVar(name) {
			out = append(out, kv)
		}
	}
	return out
}

func isJobVar(name string) bool {
	for _, v := range JobVars {
		if strings.EqualFold(v, name) {
			return true
		}
	}
	return false
}

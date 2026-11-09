package runner

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// claimHeaders are what every claim says, as the shell runner's do: the
// kinds the runner takes, which daemon this is, and the SHA-256 of each
// installed slipdock skill and of the slipdock CLI (#1795), so the board
// shows drift (sums, from drift).
func claimHeaders(kinds []string, version string, sums driftSums) http.Header {
	return http.Header{
		"X-Runner-Kinds":   {strings.Join(kinds, ",")},
		"X-Runner-Version": {"daemon " + version},
		"X-Runner-Skills":  {sums.skills},
		"X-Runner-Cli":     {sums.cli},
	}
}

// driftSums are the installed skills' and the CLI's sums a claim reports,
// and when they were read.
type driftSums struct {
	skills, cli string
	at          time.Time
}

// driftEvery is how long the user executor's sums are kept (#2617).
const driftEvery = 5 * time.Minute

// drift is the skills' and the CLI's sums, read as the account jobs run as
// (driftFiles), since its skills and CLI are what its jobs use. Read again
// before each claim, so a skill edited while the runner waits is reported
// on the next one; except under the user executor, where each read is a
// sudo in the auth log, so they are kept for DriftEvery and read again
// after each job (Run forgets them), which is when the daemon updates the
// skills (#2614) and a job may have changed them.
func (w *Worker) drift() driftSums {
	keep := w.Executor != nil && w.Executor.Name() == executor.User
	now := w.Now()
	if keep && !w.sums.at.IsZero() && now.Sub(w.sums.at) < w.DriftEvery {
		return w.sums
	}
	files := w.driftFiles()
	sums := driftSums{skills: installedSkills(files, w.skillsDir()), cli: fileSHA(files, w.cliPath()), at: now}
	if keep {
		w.sums = sums
	}
	return sums
}

// installedSkills is name=sha256 of each slipdock*/SKILL.md under dir, its
// carriage returns taken out first, or "none".
func installedSkills(fs executor.Files, dir string) string {
	var list []string
	for _, f := range fs.Glob(dir, filepath.Join("slipdock*", "SKILL.md")) {
		data, err := fs.ReadFile(f)
		if err != nil {
			continue
		}
		sum := sha256.Sum256([]byte(strings.ReplaceAll(string(data), "\r", "")))
		list = append(list, filepath.Base(filepath.Dir(f))+"="+hex.EncodeToString(sum[:]))
	}
	if len(list) == 0 {
		return "none"
	}
	return strings.Join(list, ",")
}

// fileSHA is the file's SHA-256, or "none".
func fileSHA(fs executor.Files, path string) string {
	if path == "" {
		return "none"
	}
	data, err := fs.ReadFile(path)
	if err != nil {
		return "none"
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

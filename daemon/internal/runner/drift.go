package runner

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"path/filepath"
	"sort"
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

// installedSkills is name=sha256 of each slipdock* skill under dir, or
// "none": one sum for every file of the skill (sumSkill, #3006), so a
// reference file that is changed, missing or extra shows as drift, not
// only its SKILL.md. The files are the ones at the skill's top level and
// in its references folder, which is all the server serves (SKILL.md and
// references/*); a name that starts with a dot is left out. A folder with
// no SKILL.md that reads is no skill.
func installedSkills(fs executor.Files, dir string) string {
	sums := map[string]map[string]string{}
	for _, pattern := range []string{filepath.Join("slipdock*", "*"), filepath.Join("slipdock*", "references", "*")} {
		for _, f := range fs.Glob(dir, pattern) {
			rel, err := filepath.Rel(dir, f)
			if err != nil || strings.HasPrefix(filepath.Base(f), ".") {
				continue
			}
			skill, file, ok := strings.Cut(filepath.ToSlash(rel), "/")
			if !ok {
				continue
			}
			// A folder (references itself) doesn't read, and isn't a file.
			data, err := fs.ReadFile(f)
			if err != nil {
				continue
			}
			if sums[skill] == nil {
				sums[skill] = map[string]string{}
			}
			sums[skill][file] = textSHA(data)
		}
	}
	names := make([]string, 0, len(sums))
	for skill, files := range sums {
		if _, ok := files["SKILL.md"]; ok {
			names = append(names, skill)
		}
	}
	if len(names) == 0 {
		return "none"
	}
	sort.Strings(names)
	list := make([]string, len(names))
	for i, skill := range names {
		list[i] = skill + "=" + sumSkill(sums[skill])
	}
	return strings.Join(list, ",")
}

// textSHA is data's SHA-256 with its carriage returns taken out first, so
// a copy checked out with CRLF line endings reads as the same text.
func textSHA(data []byte) string {
	sum := sha256.Sum256([]byte(strings.ReplaceAll(string(data), "\r", "")))
	return hex.EncodeToString(sum[:])
}

// sumSkill is one skill's sum, from each file's path inside the skill
// (with forward slashes) and its textSHA: the SHA-256 of a line for each
// file in path order, "<path>\x00<sha256>\n". The server computes the same
// over what it serves (Slipdock.Runners.Drift.served_skills/0), so the
// two differ when any file's text does, or when either side has a file
// the other lacks.
func sumSkill(files map[string]string) string {
	paths := make([]string, 0, len(files))
	for p := range files {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	h := sha256.New()
	for _, p := range paths {
		h.Write([]byte(p + "\x00" + files[p] + "\n"))
	}
	return hex.EncodeToString(h.Sum(nil))
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

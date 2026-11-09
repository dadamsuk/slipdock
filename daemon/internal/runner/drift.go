package runner

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// claimHeaders are what every claim says, as the shell runner's do: the
// kinds the runner takes, which daemon this is, and the SHA-256 of each
// installed slipdock skill and of the slipdock CLI (#1795), so the board
// shows drift. Made again before each claim: a skill edited while the
// runner waits is reported on the next one.
func claimHeaders(kinds []string, version, skillsDir, cli string) http.Header {
	return http.Header{
		"X-Runner-Kinds":   {strings.Join(kinds, ",")},
		"X-Runner-Version": {"daemon " + version},
		"X-Runner-Skills":  {installedSkills(skillsDir)},
		"X-Runner-Cli":     {fileSHA(cli)},
	}
}

// installedSkills is name=sha256 of each slipdock*/SKILL.md under dir, its
// carriage returns taken out first, or "none".
func installedSkills(dir string) string {
	files, _ := filepath.Glob(filepath.Join(dir, "slipdock*", "SKILL.md"))
	var list []string
	for _, f := range files {
		data, err := os.ReadFile(f)
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
func fileSHA(path string) string {
	if path == "" {
		return "none"
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "none"
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

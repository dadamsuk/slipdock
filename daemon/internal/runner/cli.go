package runner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// The server's slipdock CLI, before each agent job (#2631), as the skills
// are (#2614): when the server's /cli/SHA256SUMS differs from the CLI the
// claim reports, the daemon fetches /cli/slipdock.escript, checks its
// SHA-256 against the sums, and puts it in place, so the runner reports a
// current CLI at its next claim without a person's step.
//
// Where it goes:
//   - the file local.json's cli names, replaced in place: the person said
//     that is the one;
//   - else the daemon's own bin (<machine dir>/bin/slipdock), which goes
//     first on the job's PATH and is the CLI the claim reports. A copy the
//     person installed elsewhere (on the PATH) is never written.
//
// A failed fetch, a sum that doesn't match or a write that fails keeps the
// CLI there was, and the job runs. A cli that is a symlink (a checkout of
// the person's own) is left alone. local.json's no_cli_update turns it
// off, and the daemon's own copy is then neither used nor reported. Under
// the user executor the jobs' CLI is another account's, which the daemon
// doesn't write; under the container executor, and on Windows (where the
// escript needs the .cmd that /cli/install.ps1 writes), only a cli that
// local.json names is replaced.

// cliPathOnServer and cliSumsPath are where the server serves the CLI and
// its SHA-256. Neither needs a key, so none is sent.
const (
	cliPathOnServer = "/cli/slipdock.escript"
	cliSumsPath     = "/cli/SHA256SUMS"
)

// cliMax bounds the escript.
const cliMax = 64 << 20

// cliSumLine is the escript's line in SHA256SUMS.
var cliSumLine = regexp.MustCompile(`(?m)^([0-9a-f]{64})[ \t]+\*?slipdock\.escript[ \t]*\r?$`)

// fetch gets a file the server serves to anybody, up to max bytes.
func (c *Client) fetch(ctx context.Context, path string, max int) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 120*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.Server+path, nil)
	if err != nil {
		return nil, err
	}
	if c.UserAgent != "" {
		req.Header.Set("User-Agent", c.UserAgent)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, int64(max)+1))
	if err != nil {
		return nil, err
	}
	if len(data) > max {
		return nil, fmt.Errorf("over %d bytes", max)
	}
	return data, nil
}

// serverCLISum is the SHA-256 the server publishes for its escript.
func (c *Client) serverCLISum(ctx context.Context) (string, error) {
	sums, err := c.fetch(ctx, cliSumsPath, 4096)
	if err != nil {
		return "", err
	}
	m := cliSumLine.FindSubmatch(sums)
	if m == nil {
		return "", errors.New("it has no checksum for slipdock.escript")
	}
	return string(m[1]), nil
}

// daemonCLI is the daemon's own copy of the CLI: <machine dir>/bin/slipdock.
func (w *Worker) daemonCLI() string {
	md := w.MachineDir
	if md == "" && w.JobsDir != "" {
		md = filepath.Dir(w.JobsDir)
	}
	if md == "" {
		return ""
	}
	return filepath.Join(md, "bin", "slipdock")
}

// cliTarget is the file the CLI update writes, or "" and why it writes
// none.
func (w *Worker) cliTarget() (string, string) {
	if w.Executor != nil && w.Executor.Name() == executor.User {
		return "", "the jobs run as another account, whose CLI the daemon doesn't write"
	}
	if w.Local.CLI != "" {
		return w.Local.CLI, ""
	}
	if w.Executor != nil && w.Executor.Name() == executor.Container {
		return "", "the container mounts the machine's CLI from the PATH, which the daemon doesn't write (name it as cli in local.json)"
	}
	if w.GOOS == "windows" {
		return "", "on Windows the CLI is the one /cli/install.ps1 installs (name its slipdock.escript as cli in local.json)"
	}
	return w.daemonCLI(), ""
}

// usesDaemonCLI: the daemon's own copy is there and is the jobs' CLI.
func (w *Worker) usesDaemonCLI() bool {
	if w.Local.NoCLIUpdate || w.Local.CLI != "" {
		return false
	}
	target, _ := w.cliTarget()
	if target == "" || target != w.daemonCLI() {
		return false
	}
	fi, err := os.Stat(target)
	return err == nil && fi.Mode().IsRegular()
}

// cliEnv puts the daemon's own copy of the CLI first on the job's PATH,
// when it is the jobs' CLI.
func (w *Worker) cliEnv() []string {
	if !w.usesDaemonCLI() {
		return nil
	}
	bin := filepath.Dir(w.daemonCLI())
	if p := w.Getenv("PATH"); p != "" {
		return []string{"PATH=" + bin + string(os.PathListSeparator) + p}
	}
	return []string{"PATH=" + bin}
}

// keepCLI puts the server's CLI in place for the job about to run, when
// the one the claim reports differs from it. A failure is said in the
// daemon's log and the job's, and the job runs.
func (w *Worker) keepCLI(ctx context.Context, j *jobRun) {
	say := func(format string, a ...any) {
		line := "cli: " + fmt.Sprintf(format, a...)
		w.say("job #%d: %s", j.job.ID, line)
		j.note("slipdock-runner: " + line)
	}
	if w.Local.NoCLIUpdate {
		return
	}
	target, why := w.cliTarget()
	if target == "" {
		say("%s; keeping it", why)
		return
	}
	if fi, err := os.Lstat(target); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		say("%s is a symlink; left alone", target)
		return
	}
	want, err := w.Client.serverCLISum(ctx)
	if err != nil {
		say("could not read the server's %s (%v); keeping the CLI there is", cliSumsPath, err)
		return
	}
	if fileSHA(executor.LocalFiles, w.cliPath()) == want {
		return
	}
	data, err := w.Client.fetch(ctx, cliPathOnServer, cliMax)
	if err != nil {
		say("could not fetch the server's CLI (%v); keeping the CLI there is", err)
		return
	}
	sum := sha256.Sum256(data)
	if got := hex.EncodeToString(sum[:]); got != want {
		say("the server's CLI has SHA-256 %s, not the %s its %s gives; keeping the CLI there is", got, want, cliSumsPath)
		return
	}
	if err := putCLI(target, data); err != nil {
		say("could not put the server's CLI at %s (%v); keeping the CLI there is", target, err)
		return
	}
	say("installed the server's CLI (%s) at %s", want[:12], target)
}

// putCLI writes data whole to <target>.new, then swaps it in.
func putCLI(target string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	staged := target + ".new"
	_ = os.Remove(staged)
	f, err := os.OpenFile(staged, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		_ = os.Remove(staged)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(staged)
		return err
	}
	if err := os.Rename(staged, target); err != nil {
		_ = os.Remove(staged)
		return err
	}
	return nil
}

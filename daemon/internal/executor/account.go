package executor

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// account is the user executor: jobs run as a dedicated account through
// `sudo -n -u <account>`, which init's sudoers rule lets the daemon's
// account do without a password. The job's environment is built afresh:
// nothing of the daemon's (its tokens, its ssh agent, its HOME) passes.
type account struct {
	s    Settings
	sudo string
	// Run is how a command is run and its output read (tests replace it).
	output func(cmd *exec.Cmd) ([]byte, error)
}

func newAccount(s Settings) *account {
	if s.AccountPath == "" {
		s.AccountPath = DefaultPath(s.AccountHome, s.GOOS)
	}
	return &account{s: s, sudo: "sudo", output: func(cmd *exec.Cmd) ([]byte, error) { return cmd.Output() }}
}

// DefaultPath is the PATH a dedicated account's jobs get unless the local
// file sets one: its own bin folders first, where per-user toolchains go.
func DefaultPath(home, goos string) string {
	// The account is Linux's or macOS's: its paths are slash-separated
	// wherever the daemon was built.
	dirs := []string{path.Join(home, ".local", "bin"), path.Join(home, "bin")}
	if goos == "darwin" {
		dirs = append(dirs, "/opt/homebrew/bin")
	}
	return strings.Join(append(dirs, "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"), ":")
}

func (a *account) Name() string { return User }
func (a *account) Home() string { return a.s.AccountHome }

// Ready: sudo runs commands as the account without a password, and the
// daemon's own home is closed to it.
func (a *account) Ready() error {
	ctx, cancel := context.WithTimeout(context.Background(), checkTimeout)
	defer cancel()
	if out, err := run(ctx, a.as(ctx, "/bin/sh", "-c", "exit 0")); err != nil {
		return fmt.Errorf("sudo can't run commands as %s without a password (%s): run `slipdock-runner init --replace` to set the account up again",
			a.s.Account, firstLine(out, err))
	}
	return homeClosed(a.s.Home, a.s.Account, a.groups)
}

// as is a command run as the account, with nothing of the daemon's
// environment.
func (a *account) as(ctx context.Context, name string, args ...string) *exec.Cmd {
	full := append([]string{"-n", "-u", a.s.Account, "--", name}, args...)
	cmd := exec.CommandContext(ctx, a.sudo, full...)
	cmd.Dir = "/"
	cmd.Env = []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin"}
	return cmd
}

// baseEnv is the account's environment: its home, its name and its PATH,
// and the daemon's locale.
func (a *account) baseEnv() []string {
	env := []string{"HOME=" + a.s.AccountHome, "USER=" + a.s.Account, "LOGNAME=" + a.s.Account,
		"PATH=" + a.s.AccountPath, "SHELL=/bin/sh"}
	if a.s.Getenv != nil {
		for _, k := range []string{"LANG", "LC_ALL", "TZ"} {
			if v := a.s.Getenv(k); v != "" {
				env = append(env, k+"="+v)
			}
		}
	}
	return env
}

// inDir runs prog in dir as the account, with env and nothing else.
const inDir = `cd -- "$1" && shift && exec "$@"`

func (a *account) wrap(ctx context.Context, dir string, env []string, prog string, args ...string) *exec.Cmd {
	full := append([]string{"-i"}, env...)
	full = append(full, "/bin/sh", "-c", inDir, "sh", dir, prog)
	return a.as(ctx, "/usr/bin/env", append(full, args...)...)
}

func (a *account) Command(p Proc, prog string, args ...string) (*exec.Cmd, error) {
	env := append(a.baseEnv(), p.Env...)
	env = append(env, "PWD="+p.Dir)
	cmd := a.wrap(context.Background(), p.Dir, env, prog, args...)
	inGroup(cmd)
	return cmd, nil
}

func (a *account) Exec(ctx context.Context, dir, name string, args ...string) (string, error) {
	return run(ctx, a.wrap(ctx, dir, append(a.baseEnv(), "PWD="+dir), name, args...))
}

// Stop signals the account's processes the job started. sudo is root's
// and the daemon can't signal them itself, so the signal is sent as the
// account: to every process descended from sudo, and every other process
// of the account in one of their process groups (a child that outlived
// its parent).
func (a *account) Stop(cmd *exec.Cmd, force bool) {
	if cmd.Process == nil {
		return
	}
	sig := "TERM"
	if force {
		sig = "KILL"
	}
	uid, err := a.uid()
	if err != nil {
		return
	}
	out, err := exec.Command("ps", "-A", "-o", "pid=,ppid=,pgid=,uid=").Output()
	if err != nil {
		return
	}
	targets := jobProcesses(string(out), cmd.Process.Pid, uid)
	if len(targets) == 0 {
		return
	}
	args := []string{"-s", sig, "--"}
	for _, pid := range targets {
		args = append(args, strconv.Itoa(pid))
	}
	ctx, cancel := context.WithTimeout(context.Background(), checkTimeout)
	defer cancel()
	_, _ = run(ctx, a.as(ctx, "/bin/kill", args...))
}

// jobProcesses reads `ps -o pid=,ppid=,pgid=,uid=`: the processes owned
// by uid that descend from root, or share a process group with one that
// does.
func jobProcesses(ps string, root, uid int) []int {
	type proc struct{ pid, ppid, pgid, uid int }
	var procs []proc
	for _, line := range strings.Split(ps, "\n") {
		f := strings.Fields(line)
		if len(f) != 4 {
			continue
		}
		var p proc
		var errs [4]error
		p.pid, errs[0] = strconv.Atoi(f[0])
		p.ppid, errs[1] = strconv.Atoi(f[1])
		p.pgid, errs[2] = strconv.Atoi(f[2])
		p.uid, errs[3] = strconv.Atoi(f[3])
		if errors.Join(errs[:]...) == nil {
			procs = append(procs, p)
		}
	}
	children := map[int][]proc{}
	for _, p := range procs {
		children[p.ppid] = append(children[p.ppid], p)
	}
	in := map[int]bool{}
	groups := map[int]bool{}
	queue := []int{root}
	for len(queue) > 0 {
		pid := queue[0]
		queue = queue[1:]
		for _, c := range children[pid] {
			if in[c.pid] {
				continue
			}
			in[c.pid] = true
			queue = append(queue, c.pid)
			if c.uid == uid {
				groups[c.pgid] = true
			}
		}
	}
	var out []int
	for _, p := range procs {
		if p.uid == uid && (in[p.pid] || groups[p.pgid]) {
			out = append(out, p.pid)
		}
	}
	sort.Ints(out)
	return out
}

func (a *account) uid() (int, error) {
	out, err := exec.Command("id", "-u", a.s.Account).Output()
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(string(out)))
}

// groups are the ids of the account's groups.
func (a *account) groups() ([]int, error) {
	out, err := exec.Command("id", "-G", a.s.Account).Output()
	if err != nil {
		return nil, fmt.Errorf("can't list %s's groups: %v", a.s.Account, err)
	}
	var ids []int
	for _, f := range strings.Fields(string(out)) {
		if id, err := strconv.Atoi(f); err == nil {
			ids = append(ids, id)
		}
	}
	return ids, nil
}

func (a *account) Resolve(prog string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), checkTimeout)
	defer cancel()
	if filepath.IsAbs(prog) {
		if _, err := run(ctx, a.as(ctx, "/bin/sh", "-c", `test -x "$1"`, "sh", prog)); err != nil {
			return prog, fmt.Errorf("%s can't run %s", a.s.Account, prog)
		}
		return prog, nil
	}
	cmd := a.as(ctx, "/usr/bin/env", "-i", "PATH="+a.s.AccountPath, "HOME="+a.s.AccountHome,
		"/bin/sh", "-c", `command -v -- "$1"`, "sh", prog)
	out, err := a.output(cmd)
	path := strings.TrimSpace(string(out))
	if err != nil || !filepath.IsAbs(path) {
		return prog, fmt.Errorf("%s is not on %s's PATH", prog, a.s.Account)
	}
	return path, nil
}

func (a *account) IsDir(path string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), checkTimeout)
	defer cancel()
	_, err := run(ctx, a.as(ctx, "/bin/sh", "-c", `test -d "$1"`, "sh", path))
	return err == nil
}

func (a *account) Files() Files { return accountFiles{a} }

// accountFiles read as the account: its transcripts are its own, 0600.
type accountFiles struct{ a *account }

func (f accountFiles) ReadFile(path string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), checkTimeout)
	defer cancel()
	return f.a.output(f.a.as(ctx, "/bin/cat", "--", path))
}

const globScript = `cd -- "$1" 2>/dev/null || exit 0
for f in $2; do [ -e "$f" ] && printf '%s\n' "$f"; done
exit 0`

func (f accountFiles) Glob(root, pattern string) []string {
	ctx, cancel := context.WithTimeout(context.Background(), checkTimeout)
	defer cancel()
	out, err := f.a.output(f.a.as(ctx, "/bin/sh", "-c", globScript, "sh", root, pattern))
	if err != nil {
		return nil
	}
	return lines(string(out), func(l string) string { return filepath.Join(root, l) })
}

func (f accountFiles) Recent(paths []string, since time.Time) []string {
	if len(paths) == 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), checkTimeout)
	defer cancel()
	minutes := int(math.Ceil(time.Since(since).Minutes())) + 1
	args := append([]string{"-c", `m=$1; shift; find "$@" -prune -type f -mmin -"$m" -exec ls -t {} +`, "sh", strconv.Itoa(minutes)}, paths...)
	out, err := f.a.output(f.a.as(ctx, "/bin/sh", args...))
	if err != nil && len(out) == 0 {
		return nil
	}
	return lines(string(out), func(l string) string { return l })
}

func lines(s string, f func(string) string) []string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimRight(l, "\r"); l != "" {
			out = append(out, f(l))
		}
	}
	return out
}

func firstLine(out string, err error) string {
	if l := strings.TrimSpace(strings.SplitN(strings.TrimSpace(out), "\n", 2)[0]); l != "" {
		return l
	}
	return err.Error()
}

// AccountName is what a dedicated account's name, and the daemon's own,
// may be: they go into a sudoers rule and a shell script.
var accountName = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)
var ownerName = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$`)

// SudoersFile is where init's rule goes: a name with no dot, which sudo
// would skip.
func SudoersFile(acct string) string { return "/etc/sudoers.d/slipdock-runner-" + acct }

// AccountSetupScript is what init runs with one sudo to set the user
// executor up on goos: the account (made only if it isn't there), its home
// closed to others, and a sudoers rule that lets owner run commands as it
// without a password (checked with visudo before it is put in place).
// closeHome also closes ownerHome to other accounts, which the user
// executor needs.
func AccountSetupScript(goos, acct, owner, ownerHome string, closeHome bool) (string, error) {
	if !accountName.MatchString(acct) {
		return "", fmt.Errorf("%q can't be the account's name: lower case letters, digits, - and _, up to 32", acct)
	}
	if !ownerName.MatchString(owner) || owner == "root" {
		return "", fmt.Errorf("can't write a sudoers rule for the account %q", owner)
	}
	if acct == owner {
		return "", fmt.Errorf("the dedicated account must not be you (%s)", owner)
	}
	var b strings.Builder
	b.WriteString("set -eu\n")
	switch goos {
	case "linux":
		fmt.Fprintf(&b, "if ! id -u %[1]s >/dev/null 2>&1; then useradd --create-home --shell /bin/bash --comment 'Slipdock jobs' %[1]s; fi\n", acct)
		fmt.Fprintf(&b, "home=$(getent passwd %s | cut -d: -f6)\n", acct)
	case "darwin":
		fmt.Fprintf(&b, "if ! id -u %[1]s >/dev/null 2>&1; then\n"+
			"  sysadminctl -addUser %[1]s -fullName 'Slipdock jobs' -shell /bin/zsh -home /Users/%[1]s -password \"$(head -c 24 /dev/urandom | base64)\"\n"+
			"  createhomedir -c -u %[1]s >/dev/null\nfi\n", acct)
		fmt.Fprintf(&b, "home=/Users/%s\n", acct)
	default:
		return "", Supported(User, goos)
	}
	b.WriteString("chmod 0750 \"$home\"\n")
	rule := SudoersFile(acct)
	fmt.Fprintf(&b, "printf '%%s\\n' '# slipdock-runner: %[2]s runs jobs as %[1]s (W-2543)' '%[2]s ALL=(%[1]s) NOPASSWD: ALL' > %[3]s.tmp\n", acct, owner, rule)
	fmt.Fprintf(&b, "chmod 0440 %[1]s.tmp\nvisudo -cf %[1]s.tmp >/dev/null\nmv %[1]s.tmp %[1]s\n", rule)
	if closeHome {
		mode := "o-rwx"
		if goos == "darwin" {
			mode = "go-rwx" // every macOS account is in staff, the home's group
		}
		fmt.Fprintf(&b, "chmod %s %s\n", mode, shellQuote(ownerHome))
	}
	b.WriteString("printf '%s\\n' \"$home\"\n")
	return b.String(), nil
}

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

package runner

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/executor"
)

// The server's skills, before each agent job (#2614), as the shell
// runner's keep_skills did (#2048): the server's packaged skills
// (priv/skills, served as /api/skills.tar.gz) are the one source, so each
// slipdock skill under the skills directory is replaced with the server's,
// and the agent reads the skills of the server it talks to.
//
// The guards are the shell runner's:
//   - an archive with any entry outside a slipdock* folder, a ".." in a
//     path, or nothing in it is refused whole, and nothing is installed;
//     so is one with anything but files and folders (no links);
//   - a skill folder that is a symlink (a developer's checkout) is left
//     alone;
//   - a failed fetch or unpack keeps the installed copies, and the job
//     runs.
//
// local.json's no_skills_update turns it off. Under the user executor the
// skills are the account's, which the daemon doesn't write as itself: the
// archive is checked here as for any other, and only the entries that
// passed are packed again and unpacked by the account (putSkillsAs, #2642),
// with the same swap and the same symlink rule.

// skillsPath is where the server serves every skill as one archive. It
// needs no key, so none is sent.
const skillsPath = "/api/skills.tar.gz"

// skillsMax bounds the archive, packed and unpacked.
const skillsMax = 8 << 20

// skillEntry is a path the archive may hold: a slipdock* folder, then a
// path inside it, as the shell runner's pattern.
var skillEntry = regexp.MustCompile(`^slipdock[A-Za-z0-9_-]*/[A-Za-z0-9_./-]*$`)

// fetchSkills gets the server's skills archive.
func (c *Client) fetchSkills(ctx context.Context) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.Server+skillsPath, nil)
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
	data, err := io.ReadAll(io.LimitReader(resp.Body, skillsMax+1))
	if err != nil {
		return nil, err
	}
	if len(data) > skillsMax {
		return nil, fmt.Errorf("the archive is over %d bytes", skillsMax)
	}
	return data, nil
}

// skillFile is one file from the archive: its path inside its skill's
// folder, its mode and its contents.
type skillFile struct {
	rel  string
	mode os.FileMode
	data []byte
}

// readSkills reads the whole archive and checks every entry before
// anything is written: the skills by folder name, or why it was refused.
func readSkills(archive []byte) (map[string][]skillFile, error) {
	gz, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return nil, fmt.Errorf("could not unpack the server's skills: %v", err)
	}
	tr := tar.NewReader(gz)
	skills := map[string][]skillFile{}
	total, entries := 0, 0
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("could not unpack the server's skills: %v", err)
		}
		entries++
		name := strings.TrimPrefix(h.Name, "./")
		if bad := badEntry(name); bad != "" {
			return nil, fmt.Errorf("the server's archive has an entry outside a slipdock skill (%s: %s)", h.Name, bad)
		}
		skill, rel, _ := strings.Cut(name, "/")
		switch h.Typeflag {
		case tar.TypeDir:
			if _, ok := skills[skill]; !ok {
				skills[skill] = nil
			}
			continue
		case tar.TypeReg:
		default:
			return nil, fmt.Errorf("the server's archive has an entry outside a slipdock skill (%s: not a file or folder)", h.Name)
		}
		if rel == "" || strings.HasSuffix(rel, "/") {
			return nil, fmt.Errorf("the server's archive has an entry outside a slipdock skill (%s: no file name)", h.Name)
		}
		total += int(h.Size)
		if h.Size < 0 || total > skillsMax {
			return nil, fmt.Errorf("could not unpack the server's skills: over %d bytes", skillsMax)
		}
		data, err := io.ReadAll(io.LimitReader(tr, h.Size))
		if err != nil {
			return nil, fmt.Errorf("could not unpack the server's skills: %v", err)
		}
		skills[skill] = append(skills[skill], skillFile{rel: rel, mode: os.FileMode(h.Mode).Perm() | 0o600, data: data})
	}
	if entries == 0 {
		return nil, errors.New("the server's archive has an entry outside a slipdock skill (empty)")
	}
	return skills, nil
}

// badEntry is why name can't be in the archive, or "".
func badEntry(name string) string {
	if !skillEntry.MatchString(name) {
		return "not in a slipdock* folder"
	}
	for _, part := range strings.Split(name, "/") {
		if part == ".." || part == "." {
			return "a '" + part + "' in it"
		}
	}
	if path.Clean(name) != strings.TrimSuffix(name, "/") {
		return "not a clean path"
	}
	return ""
}

// putSkills puts each skill in dir in place of the copy there: written
// whole to <name>.new, then swapped in. A skill folder that is a symlink
// is left alone. It returns the skills put in place, and what it left
// alone or couldn't do, a line each.
func putSkills(dir string, skills map[string][]skillFile) (put, notes []string) {
	names := make([]string, 0, len(skills))
	for name := range skills {
		names = append(names, name)
	}
	sort.Strings(names)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, []string{fmt.Sprintf("can't make %s: %v; keeping the installed skills", dir, err)}
	}
	for _, name := range names {
		target := filepath.Join(dir, name)
		if fi, err := os.Lstat(target); err == nil && fi.Mode()&os.ModeSymlink != 0 {
			notes = append(notes, fmt.Sprintf("%s is a symlink; left alone", target))
			continue
		}
		if err := putSkill(target, skills[name]); err != nil {
			notes = append(notes, fmt.Sprintf("could not put %s in place: %v; kept the installed copy", name, err))
			continue
		}
		put = append(put, name)
	}
	return put, notes
}

func putSkill(target string, files []skillFile) error {
	staged := target + ".new"
	if err := os.RemoveAll(staged); err != nil {
		return err
	}
	if err := os.MkdirAll(staged, 0o755); err != nil {
		return err
	}
	for _, f := range files {
		p := filepath.Join(staged, filepath.FromSlash(f.rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			_ = os.RemoveAll(staged)
			return err
		}
		if err := os.WriteFile(p, f.data, f.mode); err != nil {
			_ = os.RemoveAll(staged)
			return err
		}
	}
	if err := os.RemoveAll(target); err != nil {
		_ = os.RemoveAll(staged)
		return err
	}
	return os.Rename(staged, target)
}

// keepSkills installs the server's skills for the job about to run. A
// failure is said in the daemon's log and the job's, and the job runs.
func (w *Worker) keepSkills(ctx context.Context, j *jobRun) {
	say := func(format string, a ...any) {
		line := "skills: " + fmt.Sprintf(format, a...)
		w.say("job #%d: %s", j.job.ID, line)
		j.note("slipdock-runner: " + line)
	}
	if w.Local.NoSkillsUpdate {
		return
	}
	dir := w.skillsDir()
	var feeder executor.Feeder
	if w.Executor != nil && w.Executor.Name() == executor.User {
		f, ok := w.Executor.(executor.Feeder)
		if !ok {
			say("the jobs run as another account, which this executor can't write as; keeping the ones in %s", dir)
			return
		}
		feeder = f
	}
	archive, err := w.Client.fetchSkills(ctx)
	if err != nil {
		say("could not fetch the server's skills (%v); keeping the ones in %s", err, dir)
		return
	}
	skills, err := readSkills(archive)
	if err != nil {
		say("%v; keeping the ones in %s", err, dir)
		return
	}
	var put, notes []string
	if feeder != nil {
		put, notes = putSkillsAs(ctx, feeder, dir, skills)
	} else {
		put, notes = putSkills(dir, skills)
	}
	for _, n := range notes {
		say("%s", n)
	}
	if len(put) > 0 {
		say("installed the server's %s in %s", strings.Join(put, " "), dir)
	}
}

// putSkillsScript puts the skills on its stdin (a tar of checked entries)
// in place in $1, as the account it runs as: unpacked into a staging
// folder there, then each skill named after $1 as putSkill does, written
// whole to <name>.new and swapped in, unless its folder is a symlink. A
// line for each: put, link or fail, and the name.
const putSkillsScript = `dir=$1; shift
mkdir -p "$dir" || exit 3
stage=$(mktemp -d "$dir/.slipdock-skills.XXXXXX") || exit 3
trap 'rm -rf "$stage"' EXIT
tar -xf - -C "$stage" || exit 4
for name do
	target=$dir/$name
	if [ -L "$target" ]; then printf 'link %s\n' "$name"; continue; fi
	[ -d "$stage/$name" ] || mkdir "$stage/$name" || { printf 'fail %s\n' "$name"; continue; }
	if rm -rf "$target.new" && mv "$stage/$name" "$target.new" && rm -rf "$target" && mv "$target.new" "$target"; then
		printf 'put %s\n' "$name"
	else
		rm -rf "$target.new"
		printf 'fail %s\n' "$name"
	fi
done`

// putSkillsAs is putSkills, done by the account jobs run as (the user
// executor) through f: the daemon writes nothing in its home. Only the
// entries readSkills checked are packed and fed in, so the account's tar
// sees no link and no path outside a skill.
func putSkillsAs(ctx context.Context, f executor.Feeder, dir string, skills map[string][]skillFile) (put, notes []string) {
	names := make([]string, 0, len(skills))
	for name := range skills {
		names = append(names, name)
	}
	sort.Strings(names)
	archive, err := packSkills(names, skills)
	if err != nil {
		return nil, []string{fmt.Sprintf("could not pack the server's skills: %v; keeping the installed skills", err)}
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	out, err := f.Feed(ctx, archive, "/bin/sh", append([]string{"-c", putSkillsScript, "sh", dir}, names...)...)
	var other []string
	for _, line := range strings.Split(out, "\n") {
		what, name, _ := strings.Cut(strings.TrimSpace(line), " ")
		switch {
		case what == "put" && hasSkill(names, name):
			put = append(put, name)
		case what == "link" && hasSkill(names, name):
			notes = append(notes, fmt.Sprintf("%s is a symlink; left alone", filepath.Join(dir, name)))
		case what == "fail" && hasSkill(names, name):
			notes = append(notes, fmt.Sprintf("could not put %s in place as the account; kept the installed copy", name))
		case strings.TrimSpace(line) != "":
			other = append(other, strings.TrimSpace(line))
		}
	}
	switch {
	case err != nil && len(other) > 0:
		notes = append(notes, fmt.Sprintf("could not unpack the server's skills as the account (%v: %s); keeping the installed skills in %s", err, strings.Join(other, "; "), dir))
	case err != nil:
		notes = append(notes, fmt.Sprintf("could not unpack the server's skills as the account (%v); keeping the installed skills in %s", err, dir))
	case len(other) > 0:
		notes = append(notes, "the account said: "+strings.Join(other, "; "))
	}
	return put, notes
}

func hasSkill(names []string, name string) bool {
	i := sort.SearchStrings(names, name)
	return i < len(names) && names[i] == name
}

// packSkills is a plain tar of the checked skills: a folder for each, then
// its files, with the folders they need.
func packSkills(names []string, skills map[string][]skillFile) ([]byte, error) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	dirs := map[string]bool{}
	addDir := func(name string) error {
		if dirs[name] {
			return nil
		}
		dirs[name] = true
		return tw.WriteHeader(&tar.Header{Name: name + "/", Typeflag: tar.TypeDir, Mode: 0o755})
	}
	for _, name := range names {
		if err := addDir(name); err != nil {
			return nil, err
		}
		for _, f := range skills[name] {
			p := name + "/" + f.rel
			if err := addParents(addDir, name, f.rel); err != nil {
				return nil, err
			}
			if err := tw.WriteHeader(&tar.Header{Name: p, Typeflag: tar.TypeReg, Mode: int64(f.mode), Size: int64(len(f.data))}); err != nil {
				return nil, err
			}
			if _, err := tw.Write(f.data); err != nil {
				return nil, err
			}
		}
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// addParents adds the folders between a skill's and its file rel, top
// first.
func addParents(addDir func(string) error, skill, rel string) error {
	var parents []string
	for d := path.Dir(rel); d != "."; d = path.Dir(d) {
		parents = append([]string{skill + "/" + d}, parents...)
	}
	for _, d := range parents {
		if err := addDir(d); err != nil {
			return err
		}
	}
	return nil
}

package release

import (
	"crypto/ed25519"
	_ "embed"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Files in a release, beside the binaries.
const (
	ManifestFile  = "release.json"
	SignatureFile = "release.json.sig"
)

//go:embed release_key.pub
var embeddedKey string

// Key is the project's release key, embedded at build time. ErrNoKey when
// the build has none.
func Key() (ed25519.PublicKey, error) { return ParsePublicKey(embeddedKey) }

// Manifest is release.json: the release's version and, for each platform
// ("linux/amd64"), its binary.
type Manifest struct {
	Version string          `json:"version"`
	Files   map[string]File `json:"files"`
}

// File is one platform's binary in a release.
type File struct {
	Name   string `json:"name"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

var (
	versionRe = regexp.MustCompile(`^v(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$`)
	nameRe    = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
	shaRe     = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// VerifyManifest checks sig is the project's signature of data, and only
// then reads data as a manifest. Nothing in an unsigned manifest is read.
func VerifyManifest(key ed25519.PublicKey, data, sig []byte) (Manifest, error) {
	var m Manifest
	if len(key) == 0 {
		return m, ErrNoKey
	}
	if err := Verify(key, data, sig); err != nil {
		return m, err
	}
	if err := json.Unmarshal(data, &m); err != nil {
		return m, fmt.Errorf("%s is signed but not valid JSON: %w", ManifestFile, err)
	}
	if !versionRe.MatchString(m.Version) {
		return m, fmt.Errorf("%s names version %q, not vX.Y.Z", ManifestFile, m.Version)
	}
	for platform, f := range m.Files {
		// A name is a URL path segment and a file name: nothing that climbs.
		if !nameRe.MatchString(f.Name) || f.Name == "." || f.Name == ".." || !shaRe.MatchString(f.SHA256) || f.Size <= 0 {
			return m, fmt.Errorf("%s's entry for %s is malformed", ManifestFile, platform)
		}
	}
	return m, nil
}

// For is the platform's binary, if the release has one.
func (m Manifest) For(goos, goarch string) (File, bool) {
	f, ok := m.Files[goos+"/"+goarch]
	return f, ok
}

// Newer says whether version a is later than b. Both are vX.Y.Z, with an
// optional pre-release, which comes before the release it names. A version
// that isn't one (a "dev" build) is older than any release.
func Newer(a, b string) (bool, error) {
	pa, ok := parseVersion(a)
	if !ok {
		return false, fmt.Errorf("%q is not a release version", a)
	}
	pb, ok := parseVersion(b)
	if !ok {
		return true, nil
	}
	for i := 0; i < 3; i++ {
		if pa.n[i] != pb.n[i] {
			return pa.n[i] > pb.n[i], nil
		}
	}
	switch {
	case pa.pre == pb.pre:
		return false, nil
	case pa.pre == "":
		return true, nil
	case pb.pre == "":
		return false, nil
	default:
		return comparePre(pa.pre, pb.pre) > 0, nil
	}
}

// IsRelease says whether v is a release version, not a dev build.
func IsRelease(v string) bool { _, ok := parseVersion(v); return ok }

type version struct {
	n   [3]int
	pre string
}

func parseVersion(v string) (version, bool) {
	m := versionRe.FindStringSubmatch(v)
	if m == nil {
		return version{}, false
	}
	var p version
	for i := 0; i < 3; i++ {
		n, err := strconv.Atoi(m[i+1])
		if err != nil {
			return version{}, false
		}
		p.n[i] = n
	}
	p.pre = m[4]
	return p, true
}

// comparePre compares dot-separated pre-release parts as semver does:
// numbers numerically and below words, words by their bytes.
func comparePre(a, b string) int {
	as, bs := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(as) && i < len(bs); i++ {
		an, aerr := strconv.Atoi(as[i])
		bn, berr := strconv.Atoi(bs[i])
		switch {
		case aerr == nil && berr == nil:
			if an != bn {
				return sign(an - bn)
			}
		case aerr == nil:
			return -1
		case berr == nil:
			return 1
		case as[i] != bs[i]:
			return strings.Compare(as[i], bs[i])
		}
	}
	return sign(len(as) - len(bs))
}

func sign(n int) int {
	switch {
	case n > 0:
		return 1
	case n < 0:
		return -1
	}
	return 0
}

// Platforms are the builds a release has, as GOOS/GOARCH.
var Platforms = []string{
	"darwin/amd64", "darwin/arm64",
	"linux/amd64", "linux/arm64",
	"windows/amd64", "windows/arm64",
}

// BinaryName is the release file for a platform: the version is in the
// name, so the latest release's URL for it is only ever that version.
func BinaryName(version, platform string) string {
	goos, goarch, _ := strings.Cut(platform, "/")
	name := "slipdock-runner_" + version + "_" + goos + "_" + goarch
	if goos == "windows" {
		name += ".exe"
	}
	return name
}

// MarshalManifest writes m as release.json: one platform to a line, in
// Platforms' order, so the install one-liner can read its line with sed
// once the signature has checked out (it has no JSON parser to hand).
func MarshalManifest(m Manifest) ([]byte, error) {
	if !versionRe.MatchString(m.Version) {
		return nil, fmt.Errorf("version %q is not vX.Y.Z", m.Version)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "{\n  \"version\": %q,\n  \"files\": {\n", m.Version)
	n := 0
	for _, p := range Platforms {
		f, ok := m.Files[p]
		if !ok {
			continue
		}
		if n > 0 {
			b.WriteString(",\n")
		}
		fmt.Fprintf(&b, "    %q: {\"name\": %q, \"sha256\": %q, \"size\": %d}", p, f.Name, f.SHA256, f.Size)
		n++
	}
	if n != len(m.Files) {
		return nil, fmt.Errorf("the manifest names a platform that isn't one of %v", Platforms)
	}
	b.WriteString("\n  }\n}\n")
	return []byte(b.String()), nil
}

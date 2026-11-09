// Command release-manifest writes release.json for a release (W-2542): the
// version, and each platform's binary with its SHA-256 and size, from the
// binaries in a directory. The release job runs it and then signs the file
// with ssh-keygen -Y sign; nothing here touches a key.
//
//	go run ./cmd/release-manifest -version v1.2.3 -platforms   what to build
//	go run ./cmd/release-manifest -version v1.2.3 -dir dist    release.json
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/dadamsuk/slipdock/daemon/internal/release"
)

func main() {
	version := flag.String("version", "", "the release's version, vX.Y.Z")
	dir := flag.String("dir", "dist", "the directory holding the binaries; release.json is written there")
	platforms := flag.Bool("platforms", false, "print each platform and its file name, for the build loop, and stop")
	flag.Parse()
	if *platforms {
		for _, p := range release.Platforms {
			fmt.Println(p, release.BinaryName(*version, p))
		}
		return
	}
	if err := run(*version, *dir); err != nil {
		fmt.Fprintln(os.Stderr, "release-manifest:", err)
		os.Exit(1)
	}
}

func run(version, dir string) error {
	m := release.Manifest{Version: version, Files: map[string]release.File{}}
	for _, p := range release.Platforms {
		name := release.BinaryName(version, p)
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return fmt.Errorf("the %s build: %w", p, err)
		}
		sum := sha256.Sum256(data)
		m.Files[p] = release.File{Name: name, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(data))}
	}
	out, err := release.MarshalManifest(m)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, release.ManifestFile), out, 0o644)
}

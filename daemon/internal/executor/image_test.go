package executor

import (
	"strings"
	"testing"
)

func TestValidImage(t *testing.T) {
	digest := "@sha256:" + strings.Repeat("a1", 32)
	for _, ok := range []string{
		"alpine", "alpine:3.20", "ghcr.io/me/agent:1.2.3", "localhost:5000/team/agent:latest",
		"registry.example.com/a/b/c", "me/agent" + digest, "ghcr.io/me/agent:v1" + digest,
		"my_org/agent-x__y:Tag_1.0",
	} {
		if err := ValidImage(ok); err != nil {
			t.Errorf("ValidImage(%q) = %v", ok, err)
		}
	}
	for _, bad := range []string{
		"", "-alpine", "--privileged", "--volume=/:/host", "alpine --privileged", "alpine\n--privileged",
		"Alpine", "ghcr.io/Me/agent", "alpine;rm -rf /", "$(id)", "alpine:", "alpine:-x", ":tag",
		"ghcr.io/me/agent:*", "ghcr.io//agent", "/alpine", "alpine/", "alpine@sha256:short",
		"alpine:" + strings.Repeat("x", 129), strings.Repeat("a", 256), "a b", "alpine\x00",
		"ghcr.io/me/agent,readonly", "ghcr.io/me/agent\"",
	} {
		if err := ValidImage(bad); err == nil {
			t.Errorf("ValidImage(%q) took it", bad)
		}
	}
}

func TestValidImagePattern(t *testing.T) {
	for _, ok := range []string{"alpine:*", "ghcr.io/me/*", "ghcr.io/me/agent:*", "ghcr.io/me/agent:1", "localhost:5000/*"} {
		if err := ValidImagePattern(ok); err != nil {
			t.Errorf("ValidImagePattern(%q) = %v", ok, err)
		}
	}
	for _, bad := range []string{"", "*", "**", "*/agent", "*:latest", "u*", "*.io/me/agent", "@sha256:x",
		"ghcr.io/me agent", "ghcr.io/me/[ab]", "ghcr.io/*/*/*/*/*", "ghcr.io/me/agent\n"} {
		if err := ValidImagePattern(bad); err == nil {
			t.Errorf("ValidImagePattern(%q) took it", bad)
		}
	}
}

func TestMatchImage(t *testing.T) {
	for _, c := range []struct {
		pattern, image string
		want           bool
	}{
		{"ghcr.io/me/agent:1", "ghcr.io/me/agent:1", true},
		{"ghcr.io/me/agent:1", "ghcr.io/me/agent:12", false},
		{"ghcr.io/me/agent", "ghcr.io/me/agent:1", false},
		{"ghcr.io/me/agent", "ghcr.io/me/agent2", false},
		{"ghcr.io/me/agent:*", "ghcr.io/me/agent:anything", true},
		{"ghcr.io/me/agent:*", "ghcr.io/me/agent", false},
		{"ghcr.io/me/agent:*", "ghcr.io/me/agent-evil:1", false},
		{"ghcr.io/me/*", "ghcr.io/me/agent", true},
		{"ghcr.io/me/*", "ghcr.io/me/agent:1", true},
		{"ghcr.io/me/*", "ghcr.io/me/team/agent", false},
		{"ghcr.io/me/*", "ghcr.io/meme/agent", false},
		{"ghcr.io/me/*", "ghcr.io/me", false},
		{"ghcr.io/me/*", "evil.io/ghcr.io/me/agent", false},
		{"alpine:*", "alpine:3", true},
		{"alpine:*", "docker.io/library/alpine:3", false},
		{"ghcr.io/me/*:1", "ghcr.io/me/agent:1", true},
		{"ghcr.io/me/*:1", "ghcr.io/me/a/b:1", false},
	} {
		if got := MatchImage(c.pattern, c.image); got != c.want {
			t.Errorf("MatchImage(%q, %q) = %v, want %v", c.pattern, c.image, got, c.want)
		}
	}
}

func TestImageAllowed(t *testing.T) {
	if err := ImageAllowed("ghcr.io/me/agent:1", []string{"alpine:*", "ghcr.io/me/agent:*"}); err != nil {
		t.Fatalf("an image on the list: %v", err)
	}
	for _, c := range []struct {
		image    string
		patterns []string
		want     string
	}{
		{"ghcr.io/me/agent:1", nil, "allows no images"},
		{"ghcr.io/me/agent:1", []string{}, "allows no images"},
		// A pattern the ceiling's check would refuse allows nothing.
		{"alpine:3", []string{"*"}, "allows no images"},
		{"ghcr.io/me/agent:1", []string{"*/*"}, "allows no images"},
		{"docker.io/someone/agent:1", []string{"ghcr.io/me/*"}, `"docker.io/someone/agent:1" is not on this machine's allow-list (container_images in its ceiling: ghcr.io/me/*)`},
		{"--privileged", []string{"ghcr.io/me/*"}, "is not an image name"},
		{"", []string{"ghcr.io/me/*"}, "no image is named"},
	} {
		err := ImageAllowed(c.image, c.patterns)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("ImageAllowed(%q, %q) = %v, want %q", c.image, c.patterns, err, c.want)
		}
	}
}

func TestValidPassEnv(t *testing.T) {
	for _, ok := range []string{"CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "GOFLAGS"} {
		if err := ValidPassEnv(ok); err != nil {
			t.Errorf("%s: %v", ok, err)
		}
	}
	for name, want := range map[string]string{
		"SLIPDOCK_TOKEN": "never pass", "slipdock_token": "never pass", "SLIPDOCK_PROMPT": "never pass",
		"HOME": "container's own", "path": "container's own", "A=B": "not a variable", "": "not a variable", "1X": "not a variable",
	} {
		if err := ValidPassEnv(name); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("ValidPassEnv(%q) = %v, want %q", name, err, want)
		}
	}
}

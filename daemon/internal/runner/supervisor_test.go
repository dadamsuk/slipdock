package runner

import (
	"context"
	"errors"
	"net/http"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

func ceiling(root string) machine.Ceiling {
	return machine.Ceiling{Roots: []string{root}, Agents: []string{"claude", "lint"}, MaxPermissionMode: "acceptEdits",
		MaxTimeoutMinutes: 60, Boards: []int64{3}}
}

func TestCheckAgainstTheCeiling(t *testing.T) {
	defer func(g string) { goos = g }(goos)
	goos = "linux" // where user is offered at all
	root := filepath.Join(t.TempDir(), "src")
	good := Runner{ID: 1, BoardID: 3, Config: Config{Agent: "claude", Directory: filepath.Join(root, "repo"),
		PermissionMode: "default", TimeoutMinutes: 60, Executor: "me"}}
	if err := good.Check(ceiling(root)); err != nil {
		t.Fatalf("inside the ceiling: %v", err)
	}
	if err := (Runner{BoardID: 3, Config: Config{Agent: "claude", Directory: root, PermissionMode: "plan", TimeoutMinutes: 1, Executor: "me"}}).Check(ceiling(root)); err != nil {
		t.Fatalf("the root itself is inside: %v", err)
	}
	atMost := good
	atMost.Config.PermissionMode = "acceptEdits"
	atMost.Config.TimeoutMinutes = 60
	if err := atMost.Check(ceiling(root)); err != nil {
		t.Fatalf("exactly the highest mode and the longest timeout are inside: %v", err)
	}
	cases := map[string]struct {
		change func(*Runner)
		want   string
	}{
		"agent":     {func(r *Runner) { r.Config.Agent = "codex" }, `agent "codex"`},
		"outside":   {func(r *Runner) { r.Config.Directory = filepath.Join(filepath.Dir(root), "other") }, "is not inside"},
		"dot-dot":   {func(r *Runner) { r.Config.Directory = filepath.Join(root, "..", "x") }, "is not inside"},
		"prefix":    {func(r *Runner) { r.Config.Directory = root + "2" }, "is not inside"},
		"relative":  {func(r *Runner) { r.Config.Directory = "src/repo" }, "is not inside"},
		"mode":      {func(r *Runner) { r.Config.PermissionMode = "bypassPermissions" }, "permission mode"},
		"bad mode":  {func(r *Runner) { r.Config.PermissionMode = "yolo" }, "permission mode"},
		"timeout":   {func(r *Runner) { r.Config.TimeoutMinutes = 61 }, "timeout 61"},
		"zero time": {func(r *Runner) { r.Config.TimeoutMinutes = 0 }, "timeout 0"},
		"board":     {func(r *Runner) { r.BoardID = 4 }, "board #4"},
		"executor":  {func(r *Runner) { r.Config.Executor = "user" }, `executor "user" is not one this machine offers`},
	}
	for name, c := range cases {
		r := good
		c.change(&r)
		if err := r.Check(ceiling(root)); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v, want %q", name, err, c.want)
		}
	}
}

func TestBuildLeavesOutWhatIsOutsideAndSeesSharedDirectories(t *testing.T) {
	root := filepath.Join(t.TempDir(), "src")
	cfg := func(dir string) Config {
		return Config{Agent: "claude", Directory: filepath.Join(root, dir), PermissionMode: "default", TimeoutMinutes: 5, Executor: "me"}
	}
	mc := &MachineConfig{Version: 9, Runners: []Runner{
		{ID: 1, BoardID: 3, Config: cfg("a")},
		{ID: 2, BoardID: 3, Config: cfg("a")},
		{ID: 3, BoardID: 3, Config: cfg("b")},
		{ID: 4, BoardID: 9, Config: cfg("b")},
	}}
	workers, refused := Build(mc, ceiling(root), Worker{Version: "v1"})
	if len(workers) != 3 || len(refused) != 1 || refused[4] == nil {
		t.Fatalf("workers %d, refused %v", len(workers), refused)
	}
	shared := map[int64]bool{}
	for _, w := range workers {
		shared[w.Runner.ID] = w.SharedDir
		if w.Version != "v1" {
			t.Fatal("each worker starts from the base")
		}
	}
	if !shared[1] || !shared[2] || shared[3] {
		t.Fatalf("shared = %v: runners 1 and 2 share a directory", shared)
	}
	// Board 9 shares runner 3's directory but doesn't run: 3 has it alone.
}

func TestOneRunnerCrashingLeavesTheOthersRunning(t *testing.T) {
	old := Restart
	Restart = 10 * time.Millisecond
	defer func() { Restart = old }()

	srv := newServer(t)
	logs := &logBuf{}
	var lookups atomic.Int32
	worker := func(id int64, lookPath func(string) (string, error)) *Worker {
		return &Worker{Runner: Runner{ID: id, Name: "r", BoardID: 3, Config: Config{Agent: "claude"}},
			Client: &Client{Server: srv.ts.URL, Key: "sdm_test_key", HTTP: &http.Client{}}, Logf: logs.logf,
			LookPath: lookPath, Getenv: func(string) string { return "" }, Home: t.TempDir()}
	}
	// Runner 1 panics on its first two claims: a bug, say. Runner 2 is fine.
	crashy := worker(1, func(string) (string, error) {
		if lookups.Add(1) <= 2 {
			panic("boom")
		}
		return "", errors.New("not found")
	})
	steady := worker(2, func(string) (string, error) { return "", errors.New("not found") })

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Supervise(ctx, []*Worker{crashy, steady}, logs.logf) }()
	waitFor(t, "runner 1 to claim after two crashes, and runner 2 to keep claiming", func() bool {
		srv.mu.Lock()
		defer srv.mu.Unlock()
		return srv.claims[1] >= 1 && srv.claims[2] >= 3
	})
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(logs.String(), "crashed, starting it again"); n != 2 {
		t.Fatalf("crashes logged: %d\n%s", n, logs)
	}
	if !strings.Contains(logs.String(), "panic: boom") {
		t.Fatalf("the crash's reason is logged:\n%s", logs)
	}
}

func TestARefusedRunnerStopsAndARevokedMachineStopsThemAll(t *testing.T) {
	srv := newServer(t)
	logs := &logBuf{}
	worker := func(id int64, key string) *Worker {
		return &Worker{Runner: Runner{ID: id, Name: "r", BoardID: 3, Config: Config{Agent: "claude"}},
			Client: &Client{Server: srv.ts.URL, Key: key, HTTP: &http.Client{}}, Logf: logs.logf,
			LookPath: func(string) (string, error) { return "", errors.New("no") }, Getenv: func(string) string { return "" }}
	}
	// Runner 5 isn't this machine's any more (403): it stops; 6 carries on.
	srv.refuse[5] = 403
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- Supervise(ctx, []*Worker{worker(5, "sdm_test_key"), worker(6, "sdm_test_key")}, logs.logf)
	}()
	waitFor(t, "runner 6 to keep claiming", func() bool {
		srv.mu.Lock()
		defer srv.mu.Unlock()
		return srv.claims[6] >= 5
	})
	srv.mu.Lock()
	if srv.claims[5] != 1 {
		t.Fatalf("runner 5 claimed %d times after a 403", srv.claims[5])
	}
	srv.mu.Unlock()
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(logs.String(), "stopped: the server refused the runner (HTTP 403)") {
		t.Fatalf("log:\n%s", logs)
	}

	// The machine key refused (401): every worker stops, and Supervise says so.
	err := Supervise(context.Background(), []*Worker{worker(7, "sdm_revoked"), worker(8, "sdm_test_key")}, logs.logf)
	if !errors.Is(err, ErrRevoked) {
		t.Fatalf("Supervise = %v, want ErrRevoked", err)
	}
}

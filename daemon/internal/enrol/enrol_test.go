package enrol

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

var about = About{Hostname: "box", OS: "linux", Arch: "amd64", Fingerprint: "ab12:cd34"}

// server answers each POST to /api/machines/enrol/token with the next of
// answers, recording the bodies and the requests' headers.
type server struct {
	mu      sync.Mutex
	answers []answer
	bodies  []map[string]string
	agents  []string
}

type answer struct {
	status int
	body   string
}

func (s *server) start(t *testing.T) *httptest.Server {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		s.bodies = append(s.bodies, body)
		s.agents = append(s.agents, r.Header.Get("User-Agent"))
		switch r.URL.Path {
		case "/api/machines/enrol":
			w.Write([]byte(`{"device_code":"dc","user_code":"ABCD-EFGH","verification_uri":"https://x.example.com/approve","expires_in":900,"interval":5}`))
		case "/api/machines/enrol/token":
			a := s.answers[0]
			if len(s.answers) > 1 {
				s.answers = s.answers[1:]
			}
			w.WriteHeader(a.status)
			w.Write([]byte(a.body))
		case "/api/machine":
			if r.Header.Get("Authorization") != "Bearer sdm_good" {
				w.WriteHeader(401)
				w.Write([]byte(`{"error":"unauthorized: pass the machine key"}`))
				return
			}
			w.Write([]byte(`{"machine":{"id":7,"name":"box","boards":[3],"state":"enrolled"}}`))
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(ts.Close)
	return ts
}

const enrolled = `{"machine_key":"sdm_good","machine":{"id":7,"name":"box","boards":[3],"enrolled_via":"device","state":"enrolled"}}`

func client(url string, waits *[]time.Duration) *Client {
	c := NewClient(url+"/", "slipdock-runner/test")
	c.Sleep = func(_ context.Context, d time.Duration) error {
		*waits = append(*waits, d)
		return nil
	}
	return c
}

func pending(code string) answer {
	return answer{400, `{"error":"` + code + `","error_description":"x"}`}
}

func TestDeviceFlowWaitsForApproval(t *testing.T) {
	s := &server{answers: []answer{pending("authorization_pending"), pending("slow_down"), pending("authorization_pending"), {200, enrolled}}}
	ts := s.start(t)
	var waits []time.Duration
	c := client(ts.URL, &waits)

	start, err := c.StartDevice(context.Background(), about)
	if err != nil || start.UserCode != "ABCD-EFGH" {
		t.Fatalf("StartDevice = %+v, %v", start, err)
	}
	if s.bodies[0]["fingerprint"] != about.Fingerprint || s.bodies[0]["hostname"] != "box" {
		t.Fatalf("the machine describes itself: %v", s.bodies[0])
	}
	if s.agents[0] != "slipdock-runner/test" {
		t.Fatalf("user agent %q", s.agents[0])
	}

	res, err := c.Poll(context.Background(), start)
	if err != nil || res.Key != "sdm_good" || res.Machine.ID != 7 || res.Machine.Boards[0] != 3 {
		t.Fatalf("Poll = %+v, %v", res, err)
	}
	want := []time.Duration{5 * time.Second, 5 * time.Second, 10 * time.Second, 10 * time.Second}
	if len(waits) != len(want) {
		t.Fatalf("waits %v, want %v", waits, want)
	}
	for i := range want {
		if waits[i] != want[i] {
			t.Fatalf("waits %v, want %v: slow_down adds five seconds", waits, want)
		}
	}
	if s.bodies[1]["device_code"] != "dc" {
		t.Fatalf("polls with the device code: %v", s.bodies[1])
	}
}

func TestDeviceFlowEndings(t *testing.T) {
	cases := map[string]answer{
		"refused":             pending("access_denied"),
		"expired":             pending("expired_token"),
		"rate":                {429, `{"error":"rate","error_description":"too many"}`},
		"isn't JSON (200)":    {200, `<html>`},
		"http_502":            {502, `bad gateway`},
		"sent no machine key": {200, `{"machine":{"id":1}}`},
	}
	for want, a := range cases {
		s := &server{answers: []answer{a}}
		ts := s.start(t)
		var waits []time.Duration
		_, err := client(ts.URL, &waits).Poll(context.Background(), Start{DeviceCode: "dc"})
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: got %v", want, err)
		}
		if len(waits) == 0 || waits[0] != 5*time.Second {
			t.Errorf("%s: with no interval given it waits five seconds: %v", want, waits)
		}
	}
}

func TestPollStopsWhenCancelled(t *testing.T) {
	c := NewClient("http://127.0.0.1:1", "")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := c.Poll(ctx, Start{DeviceCode: "dc", Interval: 1}); err != context.Canceled {
		t.Fatalf("got %v", err)
	}
}

func TestStartDeviceNeedsACode(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{}`)) }))
	defer ts.Close()
	if _, err := NewClient(ts.URL, "").StartDevice(context.Background(), about); err == nil || !strings.Contains(err.Error(), "no device code") {
		t.Fatalf("got %v", err)
	}
}

func TestWithKey(t *testing.T) {
	s := &server{answers: []answer{{200, enrolled}}}
	ts := s.start(t)
	var waits []time.Duration
	res, err := client(ts.URL, &waits).WithKey(context.Background(), "sdk_once", about)
	if err != nil || res.Key != "sdm_good" {
		t.Fatalf("WithKey = %+v, %v", res, err)
	}
	b := s.bodies[0]
	if b["enrolment_key"] != "sdk_once" || b["hostname"] != "box" || b["fingerprint"] != about.Fingerprint || b["os"] != "linux" || b["arch"] != "amd64" {
		t.Fatalf("body %v", b)
	}
	if len(waits) != 0 {
		t.Fatal("a key enrols at once, without polling")
	}

	s.answers = []answer{{400, `{"error":"invalid_grant","error_description":"that enrolment key is unknown, used or lapsed"}`}}
	if _, err := client(ts.URL, &waits).WithKey(context.Background(), "used", about); err == nil || !strings.Contains(err.Error(), "invalid_grant: that enrolment key") {
		t.Fatalf("got %v", err)
	}
}

func TestMe(t *testing.T) {
	ts := (&server{}).start(t)
	c := NewClient(ts.URL, "")
	m, err := c.Me(context.Background(), "sdm_good")
	if err != nil || m.Name != "box" || m.State != "enrolled" {
		t.Fatalf("Me = %+v, %v", m, err)
	}
	_, err = c.Me(context.Background(), "sdm_revoked")
	if !IsUnauthorized(err) || !strings.Contains(err.Error(), "revoked") {
		t.Fatalf("got %v", err)
	}
	if IsUnauthorized(nil) {
		t.Fatal("nil is not unauthorized")
	}
}

func TestUnreachableServer(t *testing.T) {
	_, err := NewClient("http://127.0.0.1:1", "").Me(context.Background(), "k")
	if err == nil || !strings.Contains(err.Error(), "can't reach") || IsUnauthorized(err) {
		t.Fatalf("got %v", err)
	}
}

func TestSetupPrompt(t *testing.T) {
	var path, auth string
	body, status := `{"prompt":"Read W-1 and set this machine up."}`, 200
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path, auth = r.Method+" "+r.URL.Path, r.Header.Get("Authorization")
		w.WriteHeader(status)
		w.Write([]byte(body))
	}))
	defer ts.Close()
	c := NewClient(ts.URL, "")

	p, err := c.SetupPrompt(context.Background(), "sdm_good")
	if err != nil || p != "Read W-1 and set this machine up." {
		t.Fatalf("SetupPrompt = %q, %v", p, err)
	}
	if path != "GET /api/machine/setup-prompt" || auth != "Bearer sdm_good" {
		t.Fatalf("asked %q with %q", path, auth)
	}

	body, status = `{"error":"unauthorized"}`, 401
	if _, err := c.SetupPrompt(context.Background(), "sdm_revoked"); !IsUnauthorized(err) || IsNotFound(err) {
		t.Fatalf("revoked: %v", err)
	}

	body, status = ``, 404
	if _, err := c.SetupPrompt(context.Background(), "sdm_good"); !IsNotFound(err) || IsUnauthorized(err) {
		t.Fatalf("an older server: %v", err)
	}
	if IsNotFound(nil) {
		t.Fatal("nil is not a 404")
	}

	body, status = `{"prompt":"  "}`, 200
	if _, err := c.SetupPrompt(context.Background(), "sdm_good"); err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("an empty prompt: %v", err)
	}
}

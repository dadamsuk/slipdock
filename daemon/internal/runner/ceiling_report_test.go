package runner

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

func TestReportCeilingPutsTheCeilingWithItsExecutors(t *testing.T) {
	var method, path, auth, ctype string
	var body map[string]map[string]any
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method, path, auth, ctype = r.Method, r.URL.Path, r.Header.Get("Authorization"), r.Header.Get("Content-Type")
		json.NewDecoder(r.Body).Decode(&body)
		w.Write([]byte(`{"machine":{}}`))
	}))
	defer ts.Close()
	c := &Client{Server: ts.URL, Key: "sdm_key", HTTP: ts.Client()}
	ceil := machine.Ceiling{Roots: []string{"/src"}, Agents: []string{"claude"}, MaxPermissionMode: "acceptEdits",
		MaxTimeoutMinutes: 60, Boards: []int64{3, 9}}
	if err := c.ReportCeiling(context.Background(), ceil); err != nil {
		t.Fatal(err)
	}
	if method != http.MethodPut || path != "/api/machine/ceiling" || auth != "Bearer sdm_key" || ctype != "application/json" {
		t.Fatalf("sent %s %s (auth %q, %q)", method, path, auth, ctype)
	}
	got := body["ceiling"]
	if got == nil {
		t.Fatalf("no ceiling in the body: %v", body)
	}
	if ex, _ := got["executors"].([]any); len(ex) != 1 || ex[0] != "me" {
		t.Errorf("executors %v, want [me] for a ceiling naming none", got["executors"])
	}
	if b, _ := got["boards"].([]any); len(b) != 2 || got["max_permission_mode"] != "acceptEdits" || got["max_timeout_minutes"] != float64(60) {
		t.Errorf("the ceiling sent isn't the machine's: %v", got)
	}
}

func TestReportCeilingSaysWhichAnswersAreFinal(t *testing.T) {
	ceil := machine.Ceiling{Roots: []string{"/src"}, Agents: []string{"claude"}, MaxPermissionMode: "plan", MaxTimeoutMinutes: 5, Boards: []int64{3}}
	for _, tc := range []struct {
		status  int
		refused bool
	}{
		{http.StatusUnprocessableEntity, true},
		{http.StatusUnauthorized, true},
		{http.StatusBadRequest, true},
		{http.StatusServiceUnavailable, false},
		{http.StatusNotFound, false},
	} {
		ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(tc.status)
			w.Write([]byte(`{"error":"executors is required, as a list"}`))
		}))
		c := &Client{Server: ts.URL, Key: "sdm_key", HTTP: ts.Client()}
		err := c.ReportCeiling(context.Background(), ceil)
		ts.Close()
		var r *Refused
		if err == nil || errors.As(err, &r) != tc.refused {
			t.Errorf("HTTP %d: got %v, want refused=%v", tc.status, err, tc.refused)
		}
		if tc.status == http.StatusUnauthorized && !IsRevoked(err) {
			t.Errorf("a 401 doesn't read as revoked: %v", err)
		}
	}
}

func TestReportCeilingWithNoServerIsAnError(t *testing.T) {
	ts := httptest.NewServer(http.NotFoundHandler())
	ts.Close()
	c := &Client{Server: ts.URL, Key: "sdm_key", HTTP: &http.Client{}}
	err := c.ReportCeiling(context.Background(), machine.Ceiling{})
	var r *Refused
	if err == nil || errors.As(err, &r) {
		t.Fatalf("got %v, want an error worth retrying", err)
	}
}

package intent

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
	"time"
)

// vector is one case of testdata/canonical-v1.json, which the server's
// test (test/slipdock/intent_test.exs) reads too.
type vector struct {
	Name        string `json:"name"`
	Origin      string `json:"origin"`
	CardID      int64  `json:"card_id"`
	SignedAt    string `json:"signed_at"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Bar         string `json:"bar"`
	Canonical   string `json:"canonical_base64"`
	Challenge   string `json:"challenge_hex"`
}

func vectors(t *testing.T) []vector {
	t.Helper()
	raw, err := os.ReadFile("testdata/canonical-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Version string   `json:"version"`
		Cases   []vector `json:"cases"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	if file.Version != Version {
		t.Fatalf("vectors are for %q, this is %q", file.Version, Version)
	}
	if len(file.Cases) == 0 {
		t.Fatal("no vectors")
	}
	return file.Cases
}

func TestCanonicalMatchesTheSharedVectors(t *testing.T) {
	for _, v := range vectors(t) {
		at, err := time.Parse(time.RFC3339, v.SignedAt)
		if err != nil {
			t.Fatalf("%s: %v", v.Name, err)
		}
		f := Fields{Origin: v.Origin, CardID: v.CardID, SignedAt: at, Title: v.Title, Description: v.Description, Bar: v.Bar}
		if got := base64.StdEncoding.EncodeToString(Canonical(f)); got != v.Canonical {
			t.Errorf("%s: canonical\n got %q\nwant %q", v.Name, got, v.Canonical)
		}
		if got := hex.EncodeToString(Challenge(f)); got != v.Challenge {
			t.Errorf("%s: challenge %s, want %s", v.Name, got, v.Challenge)
		}
	}
}

func TestCanonicalKeepsFieldsApart(t *testing.T) {
	at := time.Date(2026, 11, 20, 5, 0, 0, 0, time.UTC)
	a := Fields{Origin: "https://slipdock.example.com", CardID: 1, SignedAt: at, Title: "a", Description: "b\nbar 1\nc", Bar: ""}
	b := Fields{Origin: "https://slipdock.example.com", CardID: 1, SignedAt: at, Title: "a", Description: "b", Bar: "c"}
	if string(Canonical(a)) == string(Canonical(b)) {
		t.Fatal("text in the description posed as the bar")
	}
}

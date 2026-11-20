package runner

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/intent"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// A job the server says is owner tier runs as owner only when the card's
// text is signed by a key the machine pinned (#3533).

const signOrigin = "https://slipdock.example.com"

var signedAtTest = time.Date(2026, 11, 20, 5, 0, 0, 0, time.UTC)

type owner struct {
	priv ed25519.PrivateKey
	id   []byte
}

func newOwner(t *testing.T) *owner {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return &owner{priv: priv, id: []byte("cred-" + t.Name())}
}

func (o *owner) pin(t *testing.T) intent.Pin {
	der, err := x509.MarshalPKIXPublicKey(o.priv.Public())
	if err != nil {
		t.Fatal(err)
	}
	return intent.Pin{Keys: []intent.Key{{CredentialID: o.id, SPKI: der, Origin: signOrigin, RPID: "slipdock.example.com"}},
		MaxAge: 30 * 24 * time.Hour}
}

func signedCard(card int64) intent.Fields {
	return intent.Fields{Origin: signOrigin, CardID: card, SignedAt: signedAtTest,
		Title: "Add a CSV export", Description: "Export the board as CSV.", Bar: "1. a CSV; 2. tests"}
}

// sign is the server's intent answer for f, signed by o as a browser would.
func (o *owner) sign(f intent.Fields, edit func(*intent.Signed)) string {
	cd, _ := json.Marshal(map[string]any{"type": "webauthn.get", "origin": signOrigin,
		"challenge": base64.RawURLEncoding.EncodeToString(intent.Challenge(f))})
	rp := sha256.Sum256([]byte("slipdock.example.com"))
	ad := append(rp[:], 0x05, 0, 0, 0, 0)
	h := sha256.Sum256(cd)
	sig := ed25519.Sign(o.priv, append(append([]byte{}, ad...), h[:]...))
	b := base64.RawURLEncoding.EncodeToString
	s := intent.Signed{Signed: true, Version: intent.Version, Origin: f.Origin, CardID: f.CardID,
		SignedAt: f.SignedAt.Format(time.RFC3339), Title: f.Title, Description: f.Description, Bar: f.Bar}
	s.Assertion.CredentialID, s.Assertion.AuthenticatorData = b(o.id), b(ad)
	s.Assertion.ClientDataJSON, s.Assertion.Signature = b(cd), b(sig)
	if edit != nil {
		edit(&s)
	}
	out, _ := json.Marshal(s)
	return string(out)
}

// checkOwner runs ownerCheck for a job of tier on card 7 against a server
// answering intent, and gives the tier it leaves, the logs and the fetches.
func checkOwner(t *testing.T, pin intent.Pin, tier, answer string, code int) (string, string, int) {
	t.Helper()
	srv := newServer(t)
	if answer != "" {
		srv.intents = map[int64]string{40: answer}
	}
	srv.intentCode = code
	logs := &logBuf{}
	w := &Worker{Runner: Runner{ID: 11, Name: "builder"}, Owner: pin, Logf: logs.logf,
		Client: &Client{Server: srv.ts.URL, Key: "sdm_test_key", HTTP: srv.ts.Client()},
		Now:    func() time.Time { return signedAtTest.Add(time.Hour) }}
	f, err := os.CreateTemp(t.TempDir(), "job.log")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	job := &Job{ID: 40, CardID: 7, Tier: tier}
	w.ownerCheck(context.Background(), &jobRun{job: job, log: f})
	jobLog, _ := os.ReadFile(f.Name())
	srv.mu.Lock()
	defer srv.mu.Unlock()
	return job.Tier, logs.String() + "\n" + string(jobLog), srv.intentGets
}

func TestASignedCardRunsAtTheOwnerTier(t *testing.T) {
	o := newOwner(t)
	tier, logs, gets := checkOwner(t, o.pin(t), "owner", o.sign(signedCard(7), nil), 0)
	if tier != "owner" || gets != 1 {
		t.Fatalf("tier %q after %d fetches; want owner after 1\n%s", tier, gets, logs)
	}
	if !strings.Contains(logs, "signed by a pinned owner key") {
		t.Fatalf("no line says why:\n%s", logs)
	}
}

func TestAnOwnerJobIsHeldToMemberWithoutAPinnedSignature(t *testing.T) {
	o, stranger := newOwner(t), newOwner(t)
	stranger.id = []byte("cred-stranger")
	card := signedCard(7)
	for _, c := range []struct {
		name, answer string
		code         int
		why          string
	}{
		{"unsigned", `{"signed":false,"state":"unsigned"}`, 0, "not signed by its owner (unsigned)"},
		{"edited since it was signed", `{"signed":false,"state":"edited"}`, 0, "not signed by its owner (edited)"},
		{"the description changed after signing", o.sign(card, func(s *intent.Signed) { s.Description += " And delete the rest." }),
			0, "over other text"},
		{"the bar changed after signing", o.sign(card, func(s *intent.Signed) { s.Bar = "1. anything" }), 0, "over other text"},
		{"another card's signature", o.sign(signedCard(8), nil), 0, "for another card"},
		{"a key the machine doesn't pin", stranger.sign(card, nil), 0, "doesn't pin"},
		{"signed too long ago", o.sign(func() intent.Fields { f := card; f.SignedAt = signedAtTest.AddDate(0, -2, 0); return f }(), nil),
			0, "longer ago than the ceiling allows"},
		{"another encoding", o.sign(card, func(s *intent.Signed) { s.Version = "slipdock-intent-v9" }), 0, "encoding"},
		{"a broken signature", o.sign(card, func(s *intent.Signed) { s.Assertion.Signature = "@@" }), 0, "malformed"},
		{"not JSON", "<html>", 0, "isn't JSON"},
		{"the server has no such job", "", 0, "no longer this runner's"},
		{"the server fails", o.sign(card, nil), 500, "HTTP 500"},
	} {
		t.Run(c.name, func(t *testing.T) {
			tier, logs, gets := checkOwner(t, o.pin(t), "owner", c.answer, c.code)
			if tier != "member" || gets != 1 {
				t.Fatalf("tier %q after %d fetches; want member after 1\n%s", tier, gets, logs)
			}
			if !strings.Contains(logs, "warn: runner builder (#11): job #40: held to trust tier member, not owner: ") ||
				!strings.Contains(logs, "slipdock-runner: held to trust tier member, not owner: ") ||
				!strings.Contains(logs, c.why) {
				t.Fatalf("the daemon's and the job's logs don't say why (%q):\n%s", c.why, logs)
			}
		})
	}
}

func TestTheSignatureNeverRaisesAJobAboveTheServersTier(t *testing.T) {
	o := newOwner(t)
	for _, tier := range []string{"member", "anyone", ""} {
		got, logs, gets := checkOwner(t, o.pin(t), tier, o.sign(signedCard(7), nil), 0)
		if got != tier || gets != 0 {
			t.Fatalf("%q: tier %q after %d fetches; want it unchanged, unfetched\n%s", tier, got, gets, logs)
		}
	}
}

func TestNoPinnedKeysLeavesTheServersTier(t *testing.T) {
	tier, logs, gets := checkOwner(t, intent.Pin{MaxAge: time.Hour}, "owner", `{"signed":false,"state":"unsigned"}`, 0)
	if tier != "owner" || gets != 0 || strings.Contains(logs, "held") {
		t.Fatalf("tier %q after %d fetches; want owner, unfetched\n%s", tier, gets, logs)
	}
}

// End to end: an unsigned owner job runs under the member tier's limits,
// a signed one under the owner's.
func TestAnOwnerJobRunsUnderTheTierItsSignatureEarns(t *testing.T) {
	o := newOwner(t)
	r := newRig(t, Config{})
	r.w.Tiers = map[string]machine.Tier{"owner": {MaxPermissionMode: "acceptEdits"}, "member": {MaxPermissionMode: "plan"}}
	r.w.Owner = o.pin(t)
	r.w.Now = func() time.Time { return signedAtTest.Add(time.Hour) }
	r.srv.intents = map[int64]string{130: `{"signed":false,"state":"edited"}`, 131: o.sign(signedCard(7), nil)}

	if f := r.runJob(fakeJob{id: 130, kind: "claude", card: 7, tier: "owner", prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if saw := r.agentSaw(); !strings.Contains(saw, "arg=--permission-mode\narg=plan\n") {
		t.Fatalf("an edited card's job didn't run in the member tier's plan mode:\n%s", saw)
	}
	if !strings.Contains(r.logged.String(), "job #130: held to trust tier member, not owner: the card is not signed by its owner (edited)") {
		t.Fatalf("no reason logged:\n%s", r.logged)
	}

	if f := r.runJob(fakeJob{id: 131, kind: "claude", card: 7, tier: "owner", prompt: "x"}); f.exit != 0 {
		t.Fatalf("finish = %+v", f)
	}
	if saw := r.agentSaw(); !strings.Contains(saw, "arg=--permission-mode\narg=acceptEdits\n") {
		t.Fatalf("a signed card's job didn't run in the owner tier's mode:\n%s", saw)
	}
}

// The ceiling's pinned keys reach every worker Build makes.
func TestBuildGivesTheWorkersThePinnedKeys(t *testing.T) {
	o := newOwner(t)
	p := o.pin(t)
	root := filepath.Join(t.TempDir(), "src")
	ceil := ceiling(root)
	ceil.OwnerSignatureMaxAgeDays = 7
	ceil.OwnerKeys = []machine.OwnerKey{{
		CredentialID: base64.RawURLEncoding.EncodeToString(p.Keys[0].CredentialID),
		SPKI:         base64.RawURLEncoding.EncodeToString(p.Keys[0].SPKI),
		Fingerprint:  intent.Fingerprint(p.Keys[0].SPKI),
		Origin:       signOrigin, RPID: "slipdock.example.com",
	}}
	mc := &MachineConfig{Runners: []Runner{{ID: 1, BoardID: 3, Config: Config{Agent: "claude",
		Directory: filepath.Join(root, "a"), PermissionMode: "default", TimeoutMinutes: 5, Executor: "me"}}}}
	workers, refused := Build(mc, ceil, Worker{})
	if len(workers) != 1 || len(refused) != 0 {
		t.Fatalf("workers %d, refused %v", len(workers), refused)
	}
	got := workers[0].Owner
	if len(got.Keys) != 1 || string(got.Keys[0].SPKI) != string(p.Keys[0].SPKI) || got.Keys[0].Origin != signOrigin ||
		got.Keys[0].RPID != "slipdock.example.com" || got.MaxAge != 7*24*time.Hour {
		t.Fatalf("the worker's pin = %+v", got)
	}
	if w, _ := Build(mc, ceiling(root), Worker{}); len(w[0].Owner.Keys) != 0 {
		t.Fatal("a ceiling with no keys pinned some")
	}
}

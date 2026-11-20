package machine

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/intent"
)

func TestReportedNamesTheExecutorsAlways(t *testing.T) {
	old := Ceiling{Roots: []string{"/src"}, Agents: []string{"claude"}, MaxPermissionMode: "plan", MaxTimeoutMinutes: 30, Boards: []int64{3}}
	if got := old.Reported().Executors; len(got) != 1 || got[0] != "me" {
		t.Fatalf("a ceiling written before executors reports %v, want [me]", got)
	}
	c := old
	c.Executors = []string{"me", "confined"}
	r := c.Reported()
	if strings.Join(r.Executors, ",") != "me,confined" {
		t.Fatalf("reported executors %v, want the ceiling's", r.Executors)
	}
	r.Executors[0] = "user"
	if c.Executors[0] != "me" {
		t.Fatal("Reported shares the ceiling's executors: changing one changed the other")
	}
}

func TestReportedSendsEveryRequiredFieldAsAList(t *testing.T) {
	data, err := json.Marshal(Ceiling{MaxPermissionMode: "plan", MaxTimeoutMinutes: 30}.Reported())
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	json.Unmarshal(data, &got)
	for _, key := range []string{"roots", "agents", "boards", "executors"} {
		if _, ok := got[key].([]any); !ok {
			t.Errorf("%s is %#v, want a list (the server requires one): %s", key, got[key], data)
		}
	}
	if got["max_permission_mode"] != "plan" || got["max_timeout_minutes"] != float64(30) {
		t.Errorf("limits not sent as they are: %s", data)
	}
}

// The ceiling's trust tiers (#3516).
func TestTheTiersAreChecked(t *testing.T) {
	base := Ceiling{Roots: []string{"/src"}, Agents: []string{"claude"}, MaxPermissionMode: "acceptEdits",
		MaxTimeoutMinutes: 30, Boards: []int64{3}, Executors: []string{"me", "container"}}
	if err := base.Validate(); err != nil {
		t.Fatalf("a ceiling without tiers: %v", err)
	}
	good := base
	good.Tiers = map[string]Tier{
		"owner":  {Executor: "me", MaxPermissionMode: "acceptEdits"},
		"member": {Executor: "container", Network: "on"},
		"anyone": {Executor: "container", Network: "off", MaxPermissionMode: "plan"},
	}
	if err := good.Validate(); err != nil {
		t.Fatalf("good tiers: %v", err)
	}
	// A network allowlist (#3517), under the container or confined
	// executor or the runner's own, with hosts of its own.
	allow := base
	allow.Executors = []string{"me", "confined", "container"}
	allow.Tiers = map[string]Tier{
		"owner":  {Network: "allowlist"},
		"member": {Executor: "confined", Network: "allowlist", AllowHosts: []string{"registry.npmjs.org", "*.example.com:8443", "localhost:5432"}},
		"anyone": {Executor: "container", Network: "allowlist", AllowHosts: []string{"Example.COM."}},
	}
	if err := allow.Validate(); err != nil {
		t.Fatalf("allowlist tiers: %v", err)
	}
	for tiers, want := range map[*map[string]Tier]string{
		{"root": {}}:                       `tiers: "root" is not one of owner, member, anyone`,
		{"member": {Executor: "confined"}}: `tiers.member.executor: "confined" is not one this machine offers`,
		{"owner": {MaxPermissionMode: "bypassPermissions"}}:                             `above the ceiling's "acceptEdits"`,
		{"owner": {MaxPermissionMode: "all"}}:                                           `tiers.owner.max_permission_mode: "all" is not one of`,
		{"anyone": {Executor: "me", Network: "off"}}:                                    "tiers.anyone.network: off needs the container executor",
		{"anyone": {Network: "wifi"}}:                                                   `tiers.anyone.network: "wifi" is not on, off or allowlist`,
		{"anyone": {Executor: "me", Network: "allowlist"}}:                              "tiers.anyone.network: allowlist needs the confined or container executor",
		{"anyone": {Network: "on", AllowHosts: []string{"example.com"}}}:                "tiers.anyone.allow_hosts: only with network allowlist",
		{"anyone": {AllowHosts: []string{"example.com"}}}:                               "tiers.anyone.allow_hosts: only with network allowlist",
		{"anyone": {Network: "allowlist", AllowHosts: []string{"https://example.com"}}}: `tiers.anyone.allow_hosts: "https://example.com"`,
		{"anyone": {Network: "allowlist", AllowHosts: []string{"example.com:99999"}}}:   "the port must be a number",
		{"anyone": {Network: "allowlist", AllowHosts: []string{"*"}}}:                   `"*" is not a host name`,
		{"anyone": {Network: "allowlist", AllowHosts: []string{"localhost"}}}:           "name the port on this machine",
	} {
		c := base
		c.Tiers = *tiers
		if err := c.Validate(); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("tiers %v: %v; want %q", *tiers, err, want)
		}
	}
}

func TestTheTiersAreReadFromTheFile(t *testing.T) {
	data := []byte(`{"roots":["/src"],"agents":["claude"],"max_permission_mode":"acceptEdits",
		"max_timeout_minutes":30,"boards":[3],"executors":["me","container"],
		"tiers":{"anyone":{"executor":"container","network":"off","max_permission_mode":"plan"}}}`)
	c, err := ParseCeiling("ceiling.json", data)
	if err != nil {
		t.Fatal(err)
	}
	if got := c.Tiers["anyone"]; !reflect.DeepEqual(got, Tier{Executor: "container", Network: "off", MaxPermissionMode: "plan"}) {
		t.Fatalf("tiers = %+v", c.Tiers)
	}
	data = []byte(`{"roots":["/src"],"agents":["claude"],"max_permission_mode":"acceptEdits",
		"max_timeout_minutes":30,"boards":[3],"executors":["me","confined"],
		"tiers":{"anyone":{"executor":"confined","network":"allowlist","allow_hosts":["registry.npmjs.org"]}}}`)
	if c, err = ParseCeiling("ceiling.json", data); err != nil {
		t.Fatal(err)
	}
	if got := c.Tiers["anyone"]; !reflect.DeepEqual(got, Tier{Executor: "confined", Network: "allowlist", AllowHosts: []string{"registry.npmjs.org"}}) {
		t.Fatalf("tiers = %+v", c.Tiers)
	}
}

// The pinned owner keys (#3533).

func ownerKey(t *testing.T) OwnerKey {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return OwnerKey{OwnerID: 1, Name: "Laptop", CredentialID: "Y3JlZC0x", Algorithm: "EdDSA",
		SPKI: base64.RawURLEncoding.EncodeToString(der), Fingerprint: intent.Fingerprint(der),
		Origin: "https://slipdock.example.com", RPID: "slipdock.example.com"}
}

func TestTheOwnerKeysAreChecked(t *testing.T) {
	base := Ceiling{Roots: []string{"/src"}, Agents: []string{"claude"}, MaxPermissionMode: "acceptEdits",
		MaxTimeoutMinutes: 30, Boards: []int64{3}}
	good := base
	good.OwnerKeys = []OwnerKey{ownerKey(t)}
	if err := good.Validate(); err != nil {
		t.Fatalf("a good key: %v", err)
	}
	under := ownerKey(t)
	under.Origin = "https://app.slipdock.example.com"
	good.OwnerKeys = []OwnerKey{under}
	if err := good.Validate(); err != nil {
		t.Fatalf("an rp id the origin's host is under: %v", err)
	}

	other := ownerKey(t)
	for name, c := range map[string]struct {
		edit func(*OwnerKey)
		max  int
		want string
	}{
		"no credential id":      {func(k *OwnerKey) { k.CredentialID = "" }, 0, "owner_keys[0].credential_id: not base64url"},
		"a bad credential id":   {func(k *OwnerKey) { k.CredentialID = "@@" }, 0, "owner_keys[0].credential_id: not base64url"},
		"no key":                {func(k *OwnerKey) { k.SPKI = "" }, 0, "owner_keys[0].spki: not a public key"},
		"another key's print":   {func(k *OwnerKey) { k.Fingerprint = other.Fingerprint }, 0, "owner_keys[0].fingerprint: not the key's"},
		"no fingerprint":        {func(k *OwnerKey) { k.Fingerprint = "" }, 0, "owner_keys[0].fingerprint: not the key's"},
		"an origin with a path": {func(k *OwnerKey) { k.Origin = "https://slipdock.example.com/x" }, 0, "owner_keys[0].origin"},
		"no origin":             {func(k *OwnerKey) { k.Origin = "" }, 0, "owner_keys[0].origin"},
		"another rp id":         {func(k *OwnerKey) { k.RPID = "evil.example.com" }, 0, "owner_keys[0].rp_id"},
		"no rp id":              {func(k *OwnerKey) { k.RPID = "" }, 0, "owner_keys[0].rp_id"},
		"a lookalike rp id":     {func(k *OwnerKey) { k.Origin = "https://evilslipdock.example.com"; k.RPID = "slipdock.example.com" }, 0, "owner_keys[0].rp_id"},
		"a negative max age":    {func(*OwnerKey) {}, -1, "owner_signature_max_age_days"},
		"a max age too long":    {func(*OwnerKey) {}, 3651, "owner_signature_max_age_days"},
	} {
		k := ownerKey(t)
		c.edit(&k)
		bad := base
		bad.OwnerKeys = []OwnerKey{k}
		bad.OwnerSignatureMaxAgeDays = c.max
		if err := bad.Validate(); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v; want %q", name, err, c.want)
		}
	}
	twice := base
	twice.OwnerKeys = []OwnerKey{ownerKey(t), ownerKey(t)}
	if err := twice.Validate(); err == nil || !strings.Contains(err.Error(), "owner_keys[1].credential_id: pinned twice") {
		t.Errorf("a credential id pinned twice: %v", err)
	}
}

func TestTheOwnerKeysAreTheMachinesOwnAndReadAsAPin(t *testing.T) {
	k := ownerKey(t)
	c := Ceiling{Roots: []string{"/src"}, Agents: []string{"claude"}, MaxPermissionMode: "plan", MaxTimeoutMinutes: 30,
		Boards: []int64{3}, OwnerKeys: []OwnerKey{k}, OwnerSignatureMaxAgeDays: 9}
	data, _ := json.Marshal(c.Reported())
	if strings.Contains(string(data), "owner") {
		t.Fatalf("the report to the server carries the pinned keys: %s", data)
	}
	p := c.OwnerPin()
	if len(p.Keys) != 1 || p.MaxAge != 9*24*time.Hour || p.Keys[0].Origin != k.Origin || p.Keys[0].RPID != k.RPID ||
		string(p.Keys[0].CredentialID) != "cred-1" || intent.Fingerprint(p.Keys[0].SPKI) != k.Fingerprint {
		t.Fatalf("OwnerPin = %+v", p)
	}
	c.OwnerSignatureMaxAgeDays = 0
	if got := c.OwnerPin().MaxAge; got != 30*24*time.Hour {
		t.Fatalf("no max age set reads as %s, want 30 days", got)
	}
	if got := (Ceiling{}).OwnerPin(); len(got.Keys) != 0 {
		t.Fatalf("no keys pinned: %+v", got)
	}

	// Through the file, as written.
	data, _ = json.Marshal(c)
	back, err := ParseCeiling("ceiling.json", data)
	if err != nil || len(back.OwnerKeys) != 1 || back.OwnerKeys[0] != k {
		t.Fatalf("ParseCeiling: %+v, %v", back.OwnerKeys, err)
	}
}

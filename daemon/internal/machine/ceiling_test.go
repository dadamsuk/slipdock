package machine

import (
	"encoding/json"
	"strings"
	"testing"
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
	for tiers, want := range map[*map[string]Tier]string{
		{"root": {}}:                                        `tiers: "root" is not one of owner, member, anyone`,
		{"member": {Executor: "confined"}}:                  `tiers.member.executor: "confined" is not one this machine offers`,
		{"owner": {MaxPermissionMode: "bypassPermissions"}}: `above the ceiling's "acceptEdits"`,
		{"owner": {MaxPermissionMode: "all"}}:               `tiers.owner.max_permission_mode: "all" is not one of`,
		{"anyone": {Executor: "me", Network: "off"}}:        "tiers.anyone.network: off needs the container executor",
		{"anyone": {Network: "allowlist"}}:                  `tiers.anyone.network: "allowlist" is not on or off`,
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
	if got := c.Tiers["anyone"]; got != (Tier{Executor: "container", Network: "off", MaxPermissionMode: "plan"}) {
		t.Fatalf("tiers = %+v", c.Tiers)
	}
}

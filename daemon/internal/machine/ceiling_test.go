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

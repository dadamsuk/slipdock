package cli

import (
	"reflect"
	"testing"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// show says, for each executor the ceiling allows, who a job runs as on
// this machine.
func TestRunsAsNamesWhoEachAllowedExecutorRunsAs(t *testing.T) {
	account := machine.Local{User: &machine.Account{Name: "slipdock", Home: "/home/slipdock"}}
	cases := []struct {
		name  string
		c     machine.Ceiling
		local machine.Local
		want  []string
	}{
		{"an old ceiling is me", machine.Ceiling{}, machine.Local{}, []string{
			"me:         builder, as it is"}},
		{"as me", machine.Ceiling{Executors: []string{"me", "confined"}}, machine.Local{}, []string{
			"me:         builder, as it is",
			"confined:   builder, unable to write outside the job's directory"}},
		{"a dedicated account", machine.Ceiling{Executors: []string{"user"}}, account, []string{
			"user:       the dedicated account slipdock (/home/slipdock)"}},
		{"user without the account", machine.Ceiling{Executors: []string{"user"}}, machine.Local{}, []string{
			"user:       no dedicated account is set up (local.json has no user), so no job can run"}},
		{"container and an unknown one", machine.Ceiling{Executors: []string{"container", "chroot"}}, machine.Local{}, []string{
			"container:  a container, from an image this machine's allow-list names",
			"chroot:     an executor this daemon doesn't know, so no job can run"}},
	}
	for _, tc := range cases {
		if got := runsAs(tc.c, tc.local, "builder"); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s:\n got %q\nwant %q", tc.name, got, tc.want)
		}
	}
}

//go:build !windows

package executor

import (
	"fmt"
	"os"
	"syscall"
)

// homeClosed says why the account could read home: others may read or
// enter it, or its group may and the account is in that group.
func homeClosed(home, acct string, groups func() ([]int, error)) error {
	fi, err := os.Stat(home)
	if err != nil {
		return fmt.Errorf("can't check your home %s: %v", home, err)
	}
	mode := fi.Mode().Perm()
	if mode&0o007 != 0 {
		return fmt.Errorf("your home %s is open to every account (mode %04o), so a job as %s could read it: "+
			"close it with `chmod o-rwx %s`", home, mode, acct, home)
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if mode&0o070 == 0 || !ok {
		return nil
	}
	ids, err := groups()
	if err != nil {
		return err
	}
	for _, id := range ids {
		if uint32(id) == uint32(st.Gid) {
			return fmt.Errorf("your home %s is open to its group (mode %04o), and %s is in that group, so a job could read it: "+
				"close it with `chmod g-rwx %s`", home, mode, acct, home)
		}
	}
	return nil
}

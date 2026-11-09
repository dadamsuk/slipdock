package executor

import "os"

// HomeOpen says whether home is open to other accounts: to every account,
// or, on macOS, where every account is in the home's group (staff), to
// its group.
func HomeOpen(goos, home string) bool {
	if goos == "windows" {
		return false
	}
	fi, err := os.Stat(home)
	if err != nil {
		return false
	}
	mode := fi.Mode().Perm()
	if goos == "darwin" {
		return mode&0o077 != 0
	}
	return mode&0o007 != 0
}

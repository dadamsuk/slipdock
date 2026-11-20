//go:build linux

package executor

import (
	"fmt"
	"os"
	"runtime"
	"syscall"
	"unsafe"
)

// Landlock (Documentation/userspace-api/landlock.rst): the same numbers on
// every architecture.
const (
	sysLandlockCreateRuleset = 444
	sysLandlockAddRule       = 445
	sysLandlockRestrictSelf  = 446

	landlockCreateRulesetVersion = 1 << 0
	landlockRulePathBeneath      = 1
	landlockRuleNetPort          = 2 // ABI 4

	netConnectTCP = 1 << 1 // ABI 4

	prSetNoNewPrivs = 38

	oPath = 0x200000 // O_PATH: not in package syscall; the same on amd64 and arm64
)

// minLandlockABI is the first that handles truncate(2): below it, a
// confined job could empty any file it can open.
const minLandlockABI = 3

// landlockNetABI is the first that limits TCP connections: a network
// allowlist needs it.
const landlockNetABI = 4

// landlockABI is this kernel's Landlock ABI, 0 for none (a variable, so a
// test can be an older kernel).
var landlockABI = func() int {
	r, _, e := syscall.Syscall(sysLandlockCreateRuleset, 0, 0, landlockCreateRulesetVersion)
	if e != 0 {
		return 0
	}
	return int(r)
}

type pathBeneath struct {
	allowed uint64
	fd      int32
} // the kernel reads the first 12 bytes: the struct is packed there

type netPort struct {
	allowed uint64
	port    uint64
}

// restrict denies this thread, and what it runs, every write outside
// c.write (and the devices), every read of c.deny but c.read beneath them
// and, when c.connect names any, every TCP connection but to those ports.
// It must be followed by exec on the same, locked, thread. The rules on
// paths are pathRules'.
func restrict(c confinement) error {
	abi := landlockABI()
	if abi < minLandlockABI {
		return fmt.Errorf("this kernel's Landlock is ABI %d, and confined needs %d", abi, minLandlockABI)
	}
	if len(c.connect) > 0 && abi < landlockNetABI {
		return fmt.Errorf("this kernel's Landlock is ABI %d, and a network allowlist needs %d", abi, landlockNetABI)
	}
	handled, rules := pathRules(c)
	var fd uintptr
	var e syscall.Errno
	if len(c.connect) > 0 {
		attr := struct{ fs, net uint64 }{handled, netConnectTCP}
		fd, _, e = syscall.Syscall(sysLandlockCreateRuleset, uintptr(unsafe.Pointer(&attr)), unsafe.Sizeof(attr), 0)
	} else {
		attr := struct{ fs uint64 }{handled}
		fd, _, e = syscall.Syscall(sysLandlockCreateRuleset, uintptr(unsafe.Pointer(&attr)), unsafe.Sizeof(attr), 0)
	}
	if e != 0 {
		return fmt.Errorf("landlock_create_ruleset: %v", e)
	}
	defer syscall.Close(int(fd))
	for _, port := range c.connect {
		rule := netPort{allowed: netConnectTCP, port: uint64(port)}
		if _, _, e := syscall.Syscall6(sysLandlockAddRule, fd, landlockRuleNetPort, uintptr(unsafe.Pointer(&rule)), 0, 0, 0); e != 0 {
			return fmt.Errorf("landlock_add_rule port %d: %v", port, e)
		}
	}
	for _, r := range rules {
		if err := addPathRule(fd, r.path, r.allowed, r.nofollow); err != nil && !r.optional {
			return err
		}
	}
	if _, _, e := syscall.RawSyscall6(syscall.SYS_PRCTL, prSetNoNewPrivs, 1, 0, 0, 0, 0); e != 0 {
		return fmt.Errorf("prctl(PR_SET_NO_NEW_PRIVS): %v", e)
	}
	if _, _, e := syscall.Syscall(sysLandlockRestrictSelf, fd, 0, 0); e != 0 {
		return fmt.Errorf("landlock_restrict_self: %v", e)
	}
	return nil
}

// fileRights are the rights Landlock takes on a rule for a file, not a
// directory.
const fileRights = fsReadFile | fsWriteFile | fsTruncate

// addPathRule allows path the rights (those a file can take, when it isn't
// a directory). A path that isn't there needs none; nofollow puts the rule
// on a symbolic link itself, never its target.
func addPathRule(fd uintptr, path string, allowed uint64, nofollow bool) error {
	flags := oPath | syscall.O_CLOEXEC
	if nofollow {
		flags |= syscall.O_NOFOLLOW
	}
	pfd, err := syscall.Open(path, flags, 0)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("%s: %v", path, err)
	}
	defer syscall.Close(pfd)
	var st syscall.Stat_t
	if err := syscall.Fstat(pfd, &st); err != nil {
		return fmt.Errorf("%s: %v", path, err)
	}
	if st.Mode&syscall.S_IFMT == syscall.S_IFLNK {
		return nil
	}
	if st.Mode&syscall.S_IFMT != syscall.S_IFDIR {
		allowed &= fileRights
	}
	if allowed == 0 {
		return nil
	}
	rule := pathBeneath{allowed: allowed, fd: int32(pfd)}
	if _, _, e := syscall.Syscall6(sysLandlockAddRule, fd, landlockRulePathBeneath, uintptr(unsafe.Pointer(&rule)), 0, 0, 0); e != 0 {
		return fmt.Errorf("landlock_add_rule %s: %v", path, e)
	}
	return nil
}

// confineExec restricts and runs prog in this process's place.
func confineExec(c confinement, prog string, args []string) error {
	runtime.LockOSThread()
	if err := restrict(c); err != nil {
		return err
	}
	return syscall.Exec(prog, append([]string{prog}, args...), os.Environ())
}

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

	fsWriteFile  = 1 << 1
	fsRemoveDir  = 1 << 4
	fsRemoveFile = 1 << 5
	fsMakeChar   = 1 << 6
	fsMakeDir    = 1 << 7
	fsMakeReg    = 1 << 8
	fsMakeSock   = 1 << 9
	fsMakeFifo   = 1 << 10
	fsMakeBlock  = 1 << 11
	fsMakeSym    = 1 << 12
	fsRefer      = 1 << 13 // ABI 2
	fsTruncate   = 1 << 14 // ABI 3

	prSetNoNewPrivs = 38

	oPath = 0x200000 // O_PATH: not in package syscall; the same on amd64 and arm64
)

func landlockABI() int {
	r, _, e := syscall.Syscall(sysLandlockCreateRuleset, 0, 0, landlockCreateRulesetVersion)
	if e != 0 {
		return 0
	}
	return int(r)
}

// writeRights are the rights to change the file system that this kernel's
// Landlock knows: all of them are handled, so all are denied outside the
// rules.
func writeRights(abi int) uint64 {
	w := uint64(fsWriteFile | fsRemoveDir | fsRemoveFile | fsMakeChar | fsMakeDir | fsMakeReg |
		fsMakeSock | fsMakeFifo | fsMakeBlock | fsMakeSym)
	if abi >= 2 {
		w |= fsRefer
	}
	if abi >= 3 {
		w |= fsTruncate
	}
	return w
}

type pathBeneath struct {
	allowed uint64
	fd      int32
} // the kernel reads the first 12 bytes: the struct is packed there

// restrict denies this thread, and what it runs, every write outside
// writable (and the devices). It must be followed by exec on the same,
// locked, thread.
func restrict(writable []string) error {
	abi := landlockABI()
	if abi < 1 {
		return fmt.Errorf("this kernel has no Landlock")
	}
	handled := writeRights(abi)
	attr := struct{ fs uint64 }{handled}
	fd, _, e := syscall.Syscall(sysLandlockCreateRuleset, uintptr(unsafe.Pointer(&attr)), unsafe.Sizeof(attr), 0)
	if e != 0 {
		return fmt.Errorf("landlock_create_ruleset: %v", e)
	}
	defer syscall.Close(int(fd))
	for _, path := range append(append([]string(nil), writable...), devices...) {
		pfd, err := syscall.Open(path, oPath|syscall.O_CLOEXEC, 0)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return fmt.Errorf("%s: %v", path, err)
		}
		var st syscall.Stat_t
		allowed := handled
		if syscall.Fstat(pfd, &st) == nil && st.Mode&syscall.S_IFMT != syscall.S_IFDIR {
			allowed &= fsWriteFile | fsTruncate
		}
		rule := pathBeneath{allowed: allowed, fd: int32(pfd)}
		_, _, e := syscall.Syscall6(sysLandlockAddRule, fd, landlockRulePathBeneath, uintptr(unsafe.Pointer(&rule)), 0, 0, 0)
		syscall.Close(pfd)
		if e != 0 {
			return fmt.Errorf("landlock_add_rule %s: %v", path, e)
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

// confineExec restricts and runs prog in this process's place.
func confineExec(writable []string, prog string, args []string) error {
	runtime.LockOSThread()
	if err := restrict(writable); err != nil {
		return err
	}
	return syscall.Exec(prog, append([]string{prog}, args...), os.Environ())
}

package executor

// Landlock's file-system rights (Documentation/userspace-api/landlock.rst),
// beside the rules made of them rather than with the Linux code, so that
// the rules can be checked on any system.
const (
	fsWriteFile  = 1 << 1
	fsReadFile   = 1 << 2
	fsReadDir    = 1 << 3
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
)

// writeRights are the rights to change the file system that this kernel's
// Landlock knows: all of them are handled, so all are denied outside the
// rules.
func writeRights() uint64 {
	return uint64(fsWriteFile | fsRemoveDir | fsRemoveFile | fsMakeChar | fsMakeDir | fsMakeReg |
		fsMakeSock | fsMakeFifo | fsMakeBlock | fsMakeSym | fsRefer | fsTruncate)
}

// pathRule is one rule restrict gives Landlock: path may be used with the
// rights allowed. nofollow puts it on a symbolic link itself, never its
// target; an optional one that can't be put on is left out.
type pathRule struct {
	path               string
	allowed            uint64
	nofollow, optional bool
}

// pathRules are the file-system rights restrict has Landlock handle for c,
// and the rules that allow them back: every write in c.write (and the
// devices) and, when c.deny names a path, every read but of c.deny.
//
// Landlock only allows, so reads are handled only when c.deny names a
// path, and then allowed everywhere else by rules (readRules): each
// directory on the way to a denied path may be listed, and all else in it
// read. A writable path that holds a denied one may be written, not read:
// its reads come from those rules. c.read adds reads beneath c.deny, never
// of a path that holds one.
func pathRules(c confinement) (handled uint64, rules []pathRule) {
	reads := uint64(0)
	if len(c.deny) > 0 {
		reads = fsReadFile | fsReadDir
	}
	handled = writeRights() | reads
	deny := outermost(append([]string(nil), c.deny...))
	for _, path := range append(append([]string(nil), c.write...), devices...) {
		allowed := handled
		if holdsAny(path, deny) {
			allowed &^= reads
		}
		rules = append(rules, pathRule{path: path, allowed: allowed})
	}
	if reads == 0 {
		return handled, rules
	}
	dirs, others := readRules(deny)
	for _, path := range dirs {
		rules = append(rules, pathRule{path: path, allowed: fsReadDir, nofollow: true})
	}
	// Only what was there a moment ago: one gone since, or one the rule
	// can't be put on, is left unreadable.
	for _, path := range others {
		rules = append(rules, pathRule{path: path, allowed: reads, nofollow: true, optional: true})
	}
	for _, path := range c.read {
		if !holdsAny(path, deny) {
			rules = append(rules, pathRule{path: path, allowed: reads})
		}
	}
	return handled, rules
}

//go:build !go1.24 || windows

package executor

// BeneathMax is the most of one file Beneath reads.
const BeneathMax = 128 << 20

// Beneath reads nothing in this build: reading beneath a directory safely
// needs Go 1.24's os.Root (and container jobs don't run on Windows). A
// container job built so sends no live transcript; its log still streams.
func Beneath(string, int64) Files { return noFiles{} }

// BeneathReads says whether this build reads a container job's
// transcripts.
const BeneathReads = false

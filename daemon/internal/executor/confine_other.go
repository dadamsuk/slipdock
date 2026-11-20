//go:build !linux

package executor

import "errors"

const (
	minLandlockABI = 3
	landlockNetABI = 4
)

var landlockABI = func() int { return 0 }

func confineExec([]string, []int, string, []string) error {
	return errors.New("confine is Linux only: on macOS a confined job runs under sandbox-exec")
}

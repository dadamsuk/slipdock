//go:build !linux

package executor

import "errors"

const minLandlockABI = 3

var landlockABI = func() int { return 0 }

func confineExec([]string, string, []string) error {
	return errors.New("confine is Linux only: on macOS a confined job runs under sandbox-exec")
}

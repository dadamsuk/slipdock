//go:build !linux

package executor

import "errors"

func landlockABI() int { return 0 }

func confineExec([]string, string, []string) error {
	return errors.New("confine is Linux only: on macOS a confined job runs under sandbox-exec")
}

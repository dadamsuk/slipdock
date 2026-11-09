//go:build windows

package executor

import "errors"

func homeClosed(string, string, func() ([]int, error)) error {
	return errors.New("on Windows jobs run as the current account only")
}

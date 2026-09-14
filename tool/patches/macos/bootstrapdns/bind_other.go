//go:build !darwin

package keqdisdns

import (
	"errors"
	"syscall"
)

// The override cannot activate off Darwin. An accidental call must fail instead
// of opening an unbound DNS socket on a platform this patch does not own.
func bindPhysicalInterface(syscall.RawConn, bool, int) error {
	return errors.New("physical bootstrap DNS binding is Darwin-only")
}

//go:build darwin

package keqdisdns

import (
	"errors"
	"syscall"
)

func bindPhysicalInterface(socket syscall.RawConn, ipv6 bool, index int) error {
	if index <= 0 {
		return errors.New("bootstrap interface has no index")
	}
	var bindErr error
	err := socket.Control(func(fd uintptr) {
		if ipv6 {
			bindErr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IPV6, syscall.IPV6_BOUND_IF, index)
		} else {
			bindErr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_BOUND_IF, index)
		}
	})
	if err != nil {
		return err
	}
	return bindErr
}

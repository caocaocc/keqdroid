package tun

import (
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/net/route"
	"golang.org/x/sys/unix"
)

type keqdisOwnedRoute struct {
	destination    netip.Prefix
	gateway        netip.Addr
	interfaceIndex int
	interfaceScope bool
}

var (
	errKeqdisRouteSessionRebuild = errors.New("Darwin TUN route changes require a new session")
	errKeqdisRouteOperation      = errors.New("Darwin TUN only permits adding routes; close the interface to clean up")
)

func keqdisStartRouteSession(start func() error, closeInterface func() error) error {
	if err := start(); err != nil {
		return errors.Join(err, closeInterface())
	}
	return nil
}

func keqdisAddRoute(candidate keqdisOwnedRoute, execute func(keqdisOwnedRoute) error,
	snapshot func() ([]route.Message, error)) error {
	if candidate.interfaceIndex <= 0 || !candidate.destination.IsValid() || !candidate.gateway.IsValid() ||
		candidate.destination.Addr().Is4() != candidate.gateway.Is4() {
		return errors.New("route has no verified interface or IP family")
	}
	// EEXIST belongs to its creator; cleanup must never delete by a shared prefix.
	if err := execute(candidate); err != nil {
		return err
	}
	messages, err := snapshot()
	if err != nil {
		return err
	}
	for _, message := range messages {
		current, ok := message.(*route.RouteMessage)
		if ok && candidate.matches(current) {
			return nil
		}
	}
	return fmt.Errorf("route %s is not bound to this session's utun", candidate.destination)
}

func (wanted keqdisOwnedRoute) matches(message *route.RouteMessage) bool {
	if message.Index != wanted.interfaceIndex || message.Flags&unix.RTF_UP == 0 ||
		message.Flags&(unix.RTF_REJECT|unix.RTF_BLACKHOLE) != 0 ||
		(message.Flags&unix.RTF_IFSCOPE != 0) != wanted.interfaceScope || len(message.Addrs) <= syscall.RTAX_NETMASK {
		return false
	}
	if wanted.gateway.Is4() {
		dst, ok1 := message.Addrs[syscall.RTAX_DST].(*route.Inet4Addr)
		gateway, ok2 := message.Addrs[syscall.RTAX_GATEWAY].(*route.Inet4Addr)
		mask, ok3 := message.Addrs[syscall.RTAX_NETMASK].(*route.Inet4Addr)
		if !ok1 || !ok2 || !ok3 {
			return false
		}
		ones, bits := net.IPMask(mask.IP[:]).Size()
		return bits == 32 && ones == wanted.destination.Bits() &&
			netip.AddrFrom4(dst.IP) == wanted.destination.Masked().Addr() && netip.AddrFrom4(gateway.IP) == wanted.gateway
	}
	dst, ok1 := message.Addrs[syscall.RTAX_DST].(*route.Inet6Addr)
	gateway, ok2 := message.Addrs[syscall.RTAX_GATEWAY].(*route.Inet6Addr)
	mask, ok3 := message.Addrs[syscall.RTAX_NETMASK].(*route.Inet6Addr)
	if !ok1 || !ok2 || !ok3 {
		return false
	}
	ones, bits := net.IPMask(mask.IP[:]).Size()
	return bits == 128 && ones == wanted.destination.Bits() &&
		netip.AddrFrom16(dst.IP) == wanted.destination.Masked().Addr() && netip.AddrFrom16(gateway.IP) == wanted.gateway
}

func keqdisRouteSnapshot() ([]route.Message, error) {
	data, err := route.FetchRIB(unix.AF_UNSPEC, route.RIBTypeRoute, 0)
	if err != nil {
		return nil, err
	}
	return route.ParseRIB(route.RIBTypeRoute, data)
}

func keqdisExecuteRoute(owned keqdisOwnedRoute) error {
	message := keqdisRouteMessage(owned.interfaceScope, owned.interfaceIndex, owned.destination, owned.gateway)
	return useSocket(unix.AF_ROUTE, unix.SOCK_RAW, 0, func(socketFd int) error {
		return keqdisRouteExchange(socketFd, message)
	})
}

func keqdisRouteMessage(scoped bool, index int, destination netip.Prefix, gateway netip.Addr) *route.RouteMessage {
	message := &route.RouteMessage{Type: unix.RTM_ADD, Version: unix.RTM_VERSION,
		Flags: unix.RTF_STATIC | unix.RTF_GATEWAY | unix.RTF_UP}
	if scoped {
		message.Flags |= unix.RTF_IFSCOPE
		message.Index = index
	}
	if gateway.Is4() {
		message.Addrs = []route.Addr{
			syscall.RTAX_DST:     &route.Inet4Addr{IP: destination.Masked().Addr().As4()},
			syscall.RTAX_NETMASK: &route.Inet4Addr{IP: [4]byte(net.CIDRMask(destination.Bits(), 32))},
			syscall.RTAX_GATEWAY: &route.Inet4Addr{IP: gateway.As4()},
			syscall.RTAX_IFP:     &route.LinkAddr{Index: index},
		}
	} else {
		message.Addrs = []route.Addr{
			syscall.RTAX_DST:     &route.Inet6Addr{IP: destination.Masked().Addr().As16()},
			syscall.RTAX_NETMASK: &route.Inet6Addr{IP: [16]byte(net.CIDRMask(destination.Bits(), 128))},
			syscall.RTAX_GATEWAY: &route.Inet6Addr{IP: gateway.As16()},
			syscall.RTAX_IFP:     &route.LinkAddr{Index: index},
		}
	}
	return message
}

func keqdisRouteReply(messages []route.Message, request *route.RouteMessage) (error, bool) {
	for _, message := range messages {
		response, ok := message.(*route.RouteMessage)
		if ok && response.ID == request.ID && response.Seq == request.Seq && response.Type == request.Type {
			return response.Err, true
		}
	}
	return nil, false
}

var keqdisRouteSequence atomic.Uint32

func keqdisRouteExchange(socketFd int, message *route.RouteMessage) error {
	if message.Type != unix.RTM_ADD {
		return errKeqdisRouteOperation
	}
	message.ID = uintptr(os.Getpid())
	message.Seq = int(keqdisRouteSequence.Add(1) & 0x7fffffff)
	request, err := message.Marshal()
	if err != nil {
		return err
	}
	if err = unix.SetNonblock(socketFd, true); err != nil {
		return err
	}
	if err = unix.SetsockoptInt(socketFd, unix.SOL_SOCKET, unix.SO_USELOOPBACK, 1); err != nil {
		return err
	}
	written, err := unix.Write(socketFd, request)
	if err != nil {
		return err
	}
	if written != len(request) {
		return io.ErrShortWrite
	}
	buffer := make([]byte, 64*1024)
	deadline := time.Now().Add(2 * time.Second)
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return errors.New("route acknowledgement timed out")
		}
		poll := []unix.PollFd{{Fd: int32(socketFd), Events: unix.POLLIN}}
		if _, err = unix.Poll(poll, int(remaining.Milliseconds())+1); err != nil {
			if errors.Is(err, unix.EINTR) {
				continue
			}
			return err
		}
		if poll[0].Revents&(unix.POLLERR|unix.POLLHUP|unix.POLLNVAL) != 0 {
			return errors.New("route acknowledgement socket closed")
		}
		if poll[0].Revents&unix.POLLIN == 0 {
			continue
		}
		count, readErr := unix.Read(socketFd, buffer)
		if errors.Is(readErr, unix.EAGAIN) || errors.Is(readErr, unix.EINTR) {
			continue
		}
		if readErr != nil {
			return readErr
		}
		messages, parseErr := route.ParseRIB(route.RIBTypeRoute, buffer[:count])
		if parseErr != nil {
			return parseErr
		}
		if replyErr, found := keqdisRouteReply(messages, message); found {
			return replyErr
		}
	}
}

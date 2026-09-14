//go:build darwin

package keqdisdns

import (
	"errors"
	"testing"
)

type failedSocket struct{ err error }

func (s failedSocket) Control(func(uintptr)) error    { return s.err }
func (s failedSocket) Read(func(uintptr) bool) error  { return s.err }
func (s failedSocket) Write(func(uintptr) bool) error { return s.err }

func TestBindingFailureIsNotIgnored(t *testing.T) {
	want := errors.New("socket was closed")
	for _, ipv6 := range []bool{false, true} {
		if err := bindPhysicalInterface(failedSocket{want}, ipv6, 3); !errors.Is(err, want) {
			t.Fatalf("binding error = %v", err)
		}
		if err := bindPhysicalInterface(failedSocket{nil}, ipv6, 0); err == nil {
			t.Fatal("zero interface index accepted")
		}
	}
}

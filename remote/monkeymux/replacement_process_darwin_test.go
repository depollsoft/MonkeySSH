//go:build darwin

package main

import (
	"os"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestReplacementIdentityUsesDarwinKernelStartTime(t *testing.T) {
	pid := os.Getpid()
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		t.Fatal(err)
	}
	start := info.Proc.P_starttime
	want := time.Unix(start.Sec, int64(start.Usec)*int64(time.Microsecond))
	got := replacementPaneGroupsSystem().inspect(pid)
	if !got.known || !got.running || !got.started.Equal(want) {
		t.Fatalf("identity = %+v, want kernel start time %v", got, want)
	}
}

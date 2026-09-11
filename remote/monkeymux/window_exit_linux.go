//go:build linux

package main

import (
	"os"
	"path/filepath"
	"strconv"

	"golang.org/x/sys/unix"
)

const supportsWindowExitObservation = true

func windowProcessCommand(pid int) (string, bool) {
	path, err := os.Readlink(filepath.Join("/proc", strconv.Itoa(pid), "exe"))
	return filepath.Base(path), err == nil
}

// Wait for exit without reaping: shutdown may still be signaling this PGID.
func awaitWindowProcessExit(pid int) {
	var info unix.Siginfo
	for unix.Waitid(unix.P_PID, pid, &info, unix.WEXITED|unix.WNOWAIT, nil) == unix.EINTR {
	}
}

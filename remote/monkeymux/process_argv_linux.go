//go:build linux

package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// processCommandLine returns a process's argument vector as /proc records it,
// with every argument boundary, empty arguments included.
func processCommandLine(pid int) []string {
	if pid <= 0 {
		return nil
	}
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
	if err != nil || len(data) == 0 {
		return nil
	}
	return strings.Split(strings.TrimSuffix(string(data), "\x00"), "\x00")
}

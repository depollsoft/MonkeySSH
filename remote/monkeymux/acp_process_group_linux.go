//go:build linux

package main

import (
	"os"
	"os/exec"
	"strconv"
)

// acpProviderProcessGroupHasLiveMember reads procfs directly instead of
// spawning a full process-table command for every shutdown poll.
func acpProviderProcessGroupHasLiveMember(cmd *exec.Cmd) (bool, error) {
	if cmd == nil || cmd.Process == nil || cmd.Process.Pid <= 0 {
		return false, nil
	}
	pgid := cmd.Process.Pid
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return false, err
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		_, fields, ok := readProcStat(pid)
		if !ok || len(fields) < 3 {
			continue
		}
		memberGroup, err := strconv.Atoi(fields[2])
		if err != nil || memberGroup != pgid {
			continue
		}
		state := fields[0]
		if state != "" && state[0] != 'Z' && state[0] != 'X' {
			return true, nil
		}
	}
	return false, nil
}

//go:build windows

package main

import "os/exec"

func acpProviderProcessGroupHasLiveMember(cmd *exec.Cmd) (bool, error) {
	if cmd == nil || cmd.Process == nil {
		return false, nil
	}
	return processIDAlive(cmd.Process.Pid), nil
}

func stopAcpProvider(cmd *exec.Cmd, _ <-chan struct{}) {
	killCommandProcessGroup(cmd)
}

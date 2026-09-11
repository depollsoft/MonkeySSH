//go:build !windows

package main

import (
	"os/exec"
	"syscall"
	"time"
)

func stopAcpProvider(cmd *exec.Cmd, providerOutputDone <-chan struct{}) {
	stopAcpProviderAfter(cmd, providerOutputDone, 2*time.Second, forceStopAcpProvider)
}

// stopAcpProviderAfter must run while the provider reap gate is closed. Keeping
// the process-group leader unreaped reserves its PID/PGID, so every group signal
// below targets the original provider tree rather than a recycled process group.
func stopAcpProviderAfter(
	cmd *exec.Cmd,
	providerOutputDone <-chan struct{},
	grace time.Duration,
	force func(*exec.Cmd),
) {
	if cmd == nil || cmd.Process == nil || cmd.Process.Pid <= 0 {
		return
	}
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	_ = cmd.Process.Signal(syscall.SIGTERM)

	forceTimer := time.NewTimer(grace)
	defer forceTimer.Stop()
	forceReady := forceTimer.C
	pollDelay := 25 * time.Millisecond
	pollTimer := time.NewTimer(pollDelay)
	defer pollTimer.Stop()
	outputDone := providerOutputDone
	for {
		if live, err := acpProviderProcessGroupHasLiveMember(cmd); err == nil && !live {
			return
		}
		select {
		case <-outputDone:
			// Output EOF is only a wake-up hint. A descendant may have closed its
			// inherited descriptors while remaining alive in the provider group.
			outputDone = nil
		case <-pollTimer.C:
			if forceReady == nil && pollDelay < 500*time.Millisecond {
				pollDelay *= 2
				if pollDelay > 500*time.Millisecond {
					pollDelay = 500 * time.Millisecond
				}
			}
			pollTimer.Reset(pollDelay)
		case <-forceReady:
			force(cmd)
			// SIGKILL is asynchronous and may fail or wait behind uninterruptible
			// kernel work. Keep the reap gate closed and inspect with bounded
			// backoff until the original group is truly empty. Persistent failure
			// deliberately blocks completion instead of risking a recycled PGID.
			forceReady = nil
		}
	}
}

func forceStopAcpProvider(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	if cmd.Process.Pid > 0 {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	_ = cmd.Process.Kill()
}

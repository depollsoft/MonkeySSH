//go:build darwin || linux

package main

import (
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Assumption pending the host lease-release experiment. Change this one signal
// if Codex needs a different clean-disconnect request.
const codexGracefulShutdownSignal = syscall.SIGTERM

const (
	codexShutdownGrace       = 250 * time.Millisecond
	codexShutdownHangupGrace = 100 * time.Millisecond
)

func (p *unixProcess) shutdownCodex(window *muxWindow, deadline time.Time) {
	p.shutdownCodexWithCommand(window, deadline, windowProcessCommand)
}

func (p *unixProcess) shutdownCodexWithCommand(window *muxWindow, deadline time.Time, lookup func(int) (string, bool)) {
	p.reapMu.Lock()
	defer p.reapMu.Unlock()
	if p.cmd == nil || p.cmd.Process == nil {
		return
	}
	if p.reaping {
		// Wait owns the PID now. os.Process safely rejects an already reaped
		// process; a numeric group signal could target a recycled PGID.
		_ = p.cmd.Process.Kill()
		return
	}
	// Interactive shells may put Codex in a separate foreground process group.
	// Freeze the wrapping shell so a TERM exit cannot run `|| launch` or the
	// startup-error hold shell. It also cannot reap the foreground group leader
	// until all group signals are finished. Never stop a directly launched CLI.
	// Inspect the current image: a shell may have exec'd Codex since Start.
	// Stopping that CLI would defeat the graceful disconnect entirely.
	foreground := foregroundProcessGroupForWindow(window)
	command, known := lookup(p.cmd.Process.Pid)
	if !known {
		// Without an image, take the forced path. Stop the possible wrapper
		// before killing its foreground job so resume || fresh cannot run.
		if err := p.cmd.Process.Signal(syscall.SIGSTOP); err == nil {
			if foreground > 0 && foreground != p.cmd.Process.Pid {
				_ = syscall.Kill(-foreground, syscall.SIGKILL)
			}
		}
		signalCommandProcessGroup(p.cmd, syscall.SIGKILL)
		return
	}
	shell := codexProcessIsShell(command, p.cmd)
	if shell {
		_ = p.cmd.Process.Signal(syscall.SIGSTOP)
	}
	signalGroup := func(signal syscall.Signal) {
		if shell && foreground > 0 && foreground != p.cmd.Process.Pid {
			_ = syscall.Kill(-foreground, signal)
		}
		signalCommandProcessGroup(p.cmd, signal)
	}
	signalGroup(codexGracefulShutdownSignal)
	waitCodexShutdownStage(codexShutdownGrace, deadline)
	signalGroup(syscall.SIGHUP)
	waitCodexShutdownStage(codexShutdownHangupGrace, deadline)
	// The shell stays stopped through SIGKILL. Resuming it between TERM and
	// KILL would let it launch a fresh agent after a failed resume.
	signalGroup(syscall.SIGKILL)
}

func waitCodexShutdownStage(grace time.Duration, deadline time.Time) {
	if remaining := time.Until(deadline); grace > remaining {
		grace = remaining
	}
	if grace > 0 {
		time.Sleep(grace)
	}
}

// BusyBox reports its multicall executable even when invoked through /bin/sh.
// Use the launch path/argv only for that image, never for an exec'd Codex CLI.
func codexProcessIsShell(command string, cmd *exec.Cmd) bool {
	isShell := func(name string) bool {
		return isShellCommandName(name) || strings.EqualFold(filepath.Base(name), "ash")
	}
	if isShell(command) {
		return true
	}
	if filepath.Base(command) != "busybox" || cmd == nil {
		return false
	}
	if isShell(cmd.Path) || (len(cmd.Args) > 0 && isShell(cmd.Args[0])) {
		return true
	}
	return len(cmd.Args) > 1 && isShell(cmd.Args[1])
}

//go:build darwin || linux

package main

import (
	"errors"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestCodexShutdownAgentHelper(t *testing.T) {
	if os.Getenv("MONKEYMUX_TEST_CODEX_AGENT") != "1" {
		return
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM)
	if err := os.WriteFile(os.Getenv("MONKEYMUX_TEST_CODEX_READY"), nil, 0o600); err != nil {
		os.Exit(2)
	}
	<-signals
	if err := os.WriteFile(os.Getenv("MONKEYMUX_TEST_CODEX_TERM"), nil, 0o600); err != nil {
		os.Exit(2)
	}
	os.Exit(0)
}

func TestCodexShutdownDoesNotStopExecedCLI(t *testing.T) {
	dir := t.TempDir()
	ready, terminated := filepath.Join(dir, "ready"), filepath.Join(dir, "terminated")
	cmd := exec.Command("/bin/sh", "-c", "exec "+shellQuote(os.Args[0])+" -test.run=^TestCodexShutdownAgentHelper$")
	cmd.Env = append(os.Environ(), "MONKEYMUX_TEST_CODEX_AGENT=1",
		"MONKEYMUX_TEST_CODEX_READY="+ready, "MONKEYMUX_TEST_CODEX_TERM="+terminated)
	windowPty, proc, err := startWindow(cmd, 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	window := &muxWindow{id: "@1", agentTool: "codex", proc: proc, pty: windowPty}
	server := &muxServer{windows: []*muxWindow{window}}
	server.windowWatchers.Add(2)
	go func() { defer server.windowWatchers.Done(); server.readWindow(window) }()
	go func() { defer server.windowWatchers.Done(); _ = proc.Wait() }()
	t.Cleanup(server.close)
	waitRejectedCondition(t, "exec'd CLI readiness", func() bool { _, err := os.Stat(ready); return err == nil })
	server.close()
	if _, err := os.Stat(terminated); err != nil {
		t.Fatalf("exec'd CLI did not handle TERM: %v", err)
	}
}

func TestCodexShutdownReapsWithoutFreshFallback(t *testing.T) {
	for _, shell := range []string{"/bin/sh", "/bin/bash", "/bin/zsh"} {
		if _, err := os.Stat(shell); os.IsNotExist(err) {
			continue
		}
		for _, mode := range []string{"term-exit", "ignores-term-and-hup", "deliberate-close"} {
			graceful := mode != "ignores-term-and-hup"
			name := filepath.Base(shell) + "/" + mode
			t.Run(name, func(t *testing.T) {
				dir := t.TempDir()
				ready := filepath.Join(dir, "ready")
				terminated := filepath.Join(dir, "terminated")
				relaunched := filepath.Join(dir, "relaunched")
				hungup := filepath.Join(dir, "hungup")
				script := "trap '' TERM HUP\n"
				if graceful {
					script = "trap 'echo term > " + shellQuote(terminated) + "; exit 1' TERM\n" +
						"trap 'echo hup > " + shellQuote(hungup) + "; exit 1' HUP\n"
				}
				script += "echo ready > " + shellQuote(ready) + "\nwhile :; do sleep 0.02; done\n"
				agentPath := filepath.Join(dir, "agent")
				if err := os.WriteFile(agentPath, []byte(script), 0o600); err != nil {
					t.Fatal(err)
				}
				command := agentResumeCommandWithFreshFallback("/bin/sh "+shellQuote(agentPath),
					"echo relaunched > "+shellQuote(relaunched))
				cmd := exec.Command(shell, "-i", "-c", holdAgentWindowCommand(shell, command))
				windowPty, proc, err := startWindow(cmd, 80, 24)
				if err != nil {
					t.Fatal(err)
				}
				window := &muxWindow{id: "@1", agentTool: "codex", proc: proc, pty: windowPty}
				server := &muxServer{windows: []*muxWindow{window}}
				server.windowWatchers.Add(2)
				go func() { defer server.windowWatchers.Done(); server.readWindow(window) }()
				reaped := make(chan struct{})
				go func() { defer server.windowWatchers.Done(); _ = proc.Wait(); close(reaped) }()
				t.Cleanup(server.close)
				waitRejectedCondition(t, "agent readiness", func() bool { _, err := os.Stat(ready); return err == nil })
				start := time.Now()
				if mode == "deliberate-close" {
					if _, err := server.closeWindow(window.id); err != nil {
						t.Fatal(err)
					}
				}
				server.close()
				if elapsed := time.Since(start); elapsed > windowWatcherShutdownTimeout {
					t.Fatalf("shutdown exceeded budget: %v", elapsed)
				}
				select {
				case <-reaped:
				default:
					t.Fatal("child was not reaped")
				}
				if !errors.Is(cmd.Process.Signal(syscall.Signal(0)), os.ErrProcessDone) {
					t.Fatal("process still alive")
				}
				if _, err := os.Stat(relaunched); !os.IsNotExist(err) {
					t.Fatalf("fresh fallback ran: %v", err)
				}
				if graceful && mode != "deliberate-close" {
					if _, err := os.Stat(terminated); err != nil {
						t.Fatalf("CLI did not handle TERM: %v", err)
					}
					if _, err := os.Stat(hungup); !os.IsNotExist(err) {
						t.Fatalf("CLI received HUP before clean exit: %v", err)
					}
				}
				if mode == "deliberate-close" {
					if _, err := os.Stat(terminated); !os.IsNotExist(err) {
						t.Fatalf("deliberate close used graceful TERM: %v", err)
					}
				}
			})
		}
	}
}

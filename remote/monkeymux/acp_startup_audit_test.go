//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestServeAcpBridgeStartupFailureStopsProvider(t *testing.T) {
	for _, failure := range []string{"invalid_id", "runtime_directory", "listen"} {
		t.Run(failure, func(t *testing.T) {
			dir := shortUnixSocketDir(t)
			t.Setenv("XDG_RUNTIME_DIR", dir)
			id, err := newAcpBridgeID()
			if err != nil {
				t.Fatal(err)
			}
			switch failure {
			case "invalid_id":
				id = "invalid"
			case "runtime_directory":
				file := filepath.Join(dir, "not-a-directory")
				if err := os.WriteFile(file, nil, 0o600); err != nil {
					t.Fatal(err)
				}
				t.Setenv("XDG_RUNTIME_DIR", file)
			case "listen":
				socket, err := acpSocketPath(id)
				if err != nil {
					t.Fatal(err)
				}
				// A nonempty directory cannot be removed or bound as a socket.
				if err := os.Mkdir(socket, 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(socket, "keep"), nil, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			bridge, err := newAcpBridge(id, "", "test", "cat", ".")
			if err != nil {
				t.Fatal(err)
			}
			defer bridge.stop()
			if err := serveAcpBridge(bridge); err == nil {
				t.Fatal("expected socket setup failure")
			}
			select {
			case <-bridge.done:
			default:
				t.Fatal("startup failure left the provider running")
			}
			select {
			case <-bridge.providerDone:
			case <-time.After(3 * time.Second):
				t.Fatal("failed startup did not reap the provider")
			}
			select {
			case <-bridge.providerOutputDone:
			case <-time.After(time.Second):
				t.Fatal("failed startup left the provider output reader running")
			}
			if state := bridge.snapshot().State; state != "stopped" {
				t.Fatalf("bridge state = %q, want stopped", state)
			}
		})
	}
}

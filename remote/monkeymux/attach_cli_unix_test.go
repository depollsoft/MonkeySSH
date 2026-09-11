//go:build !windows

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/creack/pty"
	"golang.org/x/term"
)

func TestAttachCLI(t *testing.T) {
	if os.Getenv("MONKEYMUX_ATTACH_TEST") == "1" {
		attachCommand([]string{"--quiet", "--existing", "--width", "120", "--height", "40", "audit"})
		os.Exit(0)
	}
	for _, failingOutput := range []bool{false, true} {
		name := "explicit_size_without_pty"
		if failingOutput {
			name = "restore_terminal_after_output_error"
		}
		t.Run(name, func(t *testing.T) {
			dir := shortUnixSocketDir(t)
			t.Setenv("XDG_RUNTIME_DIR", dir)
			path, err := socketPath("audit")
			if err != nil {
				t.Fatal(err)
			}
			listener, err := net.Listen("unix", path)
			if err != nil {
				t.Fatal(err)
			}
			var workers sync.WaitGroup
			messages := make(chan controlMessage, 10)
			workers.Add(1)
			go func() {
				defer workers.Done()
				for {
					conn, err := listener.Accept()
					if err != nil {
						return
					}
					workers.Add(1)
					go func() {
						defer workers.Done()
						defer conn.Close()
						_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
						dec := json.NewDecoder(conn)
						var hello controlMessage
						if dec.Decode(&hello) != nil {
							return
						}
						messages <- hello
						if hello.Role == "attach" {
							_, _ = io.WriteString(conn, "attached output")
							return
						}
						enc := json.NewEncoder(conn)
						_ = enc.Encode(controlResponse{Type: "hello", Status: "ok", Version: monkeyMuxVersion})
						var request controlMessage
						if dec.Decode(&request) == nil {
							messages <- request
							_ = enc.Encode(controlResponse{ID: request.ID, Status: "ok"})
						}
					}()
				}
			}()
			defer func() { listener.Close(); workers.Wait() }()
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestAttachCLI$")
			cmd.Env = append(os.Environ(), "MONKEYMUX_ATTACH_TEST=1")
			var stderr, stdout bytes.Buffer
			cmd.Stderr = &stderr
			cmd.Stdout = &stdout
			var tty *os.File
			var before *term.State
			if failingOutput {
				master, slave, err := pty.Open()
				if err != nil {
					t.Fatal(err)
				}
				defer master.Close()
				defer slave.Close()
				tty = slave
				before, err = term.GetState(int(tty.Fd()))
				if err != nil {
					t.Fatal(err)
				}
				sink, err := os.Open(os.DevNull) // Read-only: writes fail without SIGPIPE.
				if err != nil {
					t.Fatal(err)
				}
				defer sink.Close()
				cmd.Stdin, cmd.Stdout = tty, sink
			}
			err = cmd.Run()
			listener.Close()
			workers.Wait()
			if failingOutput {
				if err == nil || !bytes.Contains(stderr.Bytes(), []byte("bad file descriptor")) {
					t.Fatalf("attach error = %v, stderr = %q", err, stderr.String())
				}
				after, err := term.GetState(int(tty.Fd()))
				if err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(before, after) {
					t.Fatal("attach left terminal in raw mode")
				}
			} else if err != nil || stdout.String() != "attached output" {
				t.Fatalf("attach = %v, stdout = %q, stderr = %q", err, stdout.String(), stderr.String())
			}
			close(messages)
			sawAttach := false
			for message := range messages {
				if message.Type == "resize" {
					t.Fatalf("explicit dimensions overwritten by resize: %+v", message)
				}
				if message.Role == "attach" {
					sawAttach = true
					if message.Width != 120 || message.Height != 40 {
						t.Fatalf("attach dimensions: %+v", message)
					}
				}
			}
			if !sawAttach {
				t.Fatal("no attach hello")
			}
		})
	}
}

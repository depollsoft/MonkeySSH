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
	for _, test := range []struct {
		name          string
		failingOutput bool
		output        string
		wantStdout    string
	}{
		{
			name:       "explicit_size_without_pty",
			output:     "attached output",
			wantStdout: "attached output",
		},
		{
			name:          "restore_terminal_after_output_error",
			failingOutput: true,
			output:        "attached output",
		},
		{
			// An agent pane switched on the kitty keyboard protocol, mouse
			// reporting, and a hidden cursor; ending the attach must hand the
			// shell back a terminal that sends plain keys again.
			name:   "reset_input_modes_after_detach",
			output: "\x1b[>5u\x1b[?1000h\x1b[?1006h\x1b[?25lagent",
			wantStdout: "\x1b[>5u\x1b[?1000h\x1b[?1006h\x1b[?25lagent" +
				"\x1b[<99u\x1b[=0;1u\x1b[?1000l\x1b[?1006l\x1b[?25h",
		},
	} {
		failingOutput := test.failingOutput
		t.Run(test.name, func(t *testing.T) {
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
							_, _ = io.WriteString(conn, test.output)
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
			} else if err != nil || stdout.String() != test.wantStdout {
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

// A server that takes delivery reports gets a token in the attach hello and,
// on a control connection of the client's own, a report for exactly the
// output the terminal has been written, while the attach is still open.
func TestAttachCLIReportsDeliveryToAServerThatTakesIt(t *testing.T) {
	if os.Getenv("MONKEYMUX_ATTACH_DELIVERY_TEST") == "1" {
		attachCommand([]string{"--quiet", "--existing", "--width", "120", "--height", "40", "audit"})
		os.Exit(0)
	}
	const output = "attached output"
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
	attachHellos := make(chan controlMessage, 1)
	reports := make(chan controlMessage, 16)
	allDelivered := make(chan struct{})
	var allDeliveredOnce sync.Once
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
				if hello.Role == "attach" {
					attachHellos <- hello
					_, _ = io.WriteString(conn, output)
					// Stay attached until the terminal's copy is reported.
					select {
					case <-allDelivered:
					case <-time.After(3 * time.Second):
					}
					return
				}
				enc := json.NewEncoder(conn)
				_ = enc.Encode(controlResponse{
					Type:         "hello",
					Status:       "ok",
					Version:      monkeyMuxVersion,
					Capabilities: []string{attachOutputDeliveryCapability},
				})
				for {
					var request controlMessage
					if dec.Decode(&request) != nil {
						return
					}
					if request.Type == attachDeliveredRequest {
						reports <- request
						if request.Delivered == uint64(len(output)) {
							allDeliveredOnce.Do(func() { close(allDelivered) })
						}
						continue
					}
					_ = enc.Encode(controlResponse{ID: request.ID, Status: "ok"})
				}
			}()
		}
	}()
	defer func() { listener.Close(); workers.Wait() }()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestAttachCLIReportsDeliveryToAServerThatTakesIt$")
	cmd.Env = append(os.Environ(), "MONKEYMUX_ATTACH_DELIVERY_TEST=1")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil || stdout.String() != output {
		t.Fatalf("attach = %v, stdout = %q, stderr = %q", err, stdout.String(), stderr.String())
	}
	hello := <-attachHellos
	if hello.AttachToken == "" {
		t.Fatal("attach hello carries no delivery token")
	}
	var last controlMessage
	for len(reports) > 0 {
		last = <-reports
		if last.AttachToken != hello.AttachToken {
			t.Fatalf("report token %q, want the attach's %q", last.AttachToken, hello.AttachToken)
		}
	}
	if last.Delivered != uint64(len(output)) {
		t.Fatalf("last report %d, want %d", last.Delivered, len(output))
	}
}

// A reporter whose control connection the server ends must fail, so the
// attach closes instead of leaving the server waiting for reports.
func TestAttachDeliveryReporterFailsWhenTheServerHangsUp(t *testing.T) {
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
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var hello controlMessage
		if json.NewDecoder(conn).Decode(&hello) != nil {
			return
		}
		_ = json.NewEncoder(conn).Encode(controlResponse{
			Type:         "hello",
			Status:       "ok",
			Capabilities: []string{attachOutputDeliveryCapability},
		})
	}()

	reporter := openAttachDeliveryReporter("audit")
	if reporter == nil {
		t.Fatal("no reporter for a server that takes reports")
	}
	defer reporter.close()
	select {
	case <-reporter.failed:
	case <-time.After(2 * time.Second):
		t.Fatal("reporter did not fail after the server hung up")
	}
}

// When the reporter's connection ends, the attach hangs up its input only. An
// ending session closes its control connections after the attach, but the
// client can see them in either order, and the session's last output must
// still arrive. A session that stays up sees the client leave and closes the
// attach, which then ends normally.
func TestAttachCLIEndsCleanlyWhenItsReporterIsLost(t *testing.T) {
	if os.Getenv("MONKEYMUX_ATTACH_REPORTER_LOST_TEST") == "1" {
		attachCommand([]string{"--quiet", "--existing", "--width", "120", "--height", "40", "audit"})
		os.Exit(0)
	}
	for _, test := range []struct {
		name       string
		sessionEnd bool
		wantStdout string
	}{
		{name: "session_ends", sessionEnd: true, wantStdout: "first output, last output"},
		{name: "session_stays", wantStdout: "first output"},
	} {
		t.Run(test.name, func(t *testing.T) {
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
			clientLeft := make(chan struct{})
			var workers sync.WaitGroup
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
						if hello.Role != "attach" {
							// Answer the hello, then hang up on the reporter
							// and on the --existing check alike.
							_ = json.NewEncoder(conn).Encode(controlResponse{
								Type:         "hello",
								Status:       "ok",
								Version:      monkeyMuxVersion,
								Capabilities: []string{attachOutputDeliveryCapability},
							})
							return
						}
						_, _ = io.WriteString(conn, "first output")
						if test.sessionEnd {
							time.Sleep(300 * time.Millisecond)
							_, _ = io.WriteString(conn, ", last output")
							return
						}
						// Stay up until the client leaves, as the server does. A
						// read that ends on the deadline is not the client
						// leaving.
						_, _ = io.Copy(io.Discard, dec.Buffered())
						if _, err := io.Copy(io.Discard, conn); err == nil {
							close(clientLeft)
						}
					}()
				}
			}()
			defer func() { listener.Close(); workers.Wait() }()

			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestAttachCLIEndsCleanlyWhenItsReporterIsLost$")
			cmd.Env = append(os.Environ(), "MONKEYMUX_ATTACH_REPORTER_LOST_TEST=1")
			var stdout, stderr bytes.Buffer
			cmd.Stdout, cmd.Stderr = &stdout, &stderr
			if err := cmd.Run(); err != nil || stdout.String() != test.wantStdout {
				t.Fatalf("attach = %v, stdout = %q (want %q), stderr = %q", err, stdout.String(), test.wantStdout, stderr.String())
			}
			if !test.sessionEnd {
				select {
				case <-clientLeft:
				default:
					t.Fatal("the session never saw the client leave")
				}
			}
		})
	}
}

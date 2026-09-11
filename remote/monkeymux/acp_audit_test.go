package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"reflect"
	"strings"
	"testing"
	"time"
)

type auditAcpWriteCloser struct {
	write func([]byte) (int, error)
}

func (w auditAcpWriteCloser) Write(data []byte) (int, error) { return w.write(data) }
func (w auditAcpWriteCloser) Close() error                   { return nil }

func TestAcpAuditFastProviderResponse(t *testing.T) {
	for _, method := range []string{"initialize", "session/new", "session/load", "session/prompt"} {
		t.Run(method, func(t *testing.T) {
			bridge := newTestAcpBridge()
			var input bytes.Buffer
			bridge.stdin = auditAcpWriteCloser{write: func(data []byte) (int, error) {
				input.Write(data)
				if bytes.Contains(data, []byte{'\n'}) {
					bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","id":1,"result":{"sessionId":"returned-session"}}`), "", nil)
				}
				return len(data), nil
			}}
			status := auditAcpSendAndStatus(t, bridge, json.RawMessage(`{"jsonrpc":"2.0","id":1,"method":"`+method+`","params":{"sessionId":"requested-session"}}`))
			if status.InFlightTurn != 0 {
				t.Errorf("completed request still in flight: %d", status.InFlightTurn)
			}
			if isAcpSessionSetupMethod(method) && status.SessionID != "returned-session" {
				t.Errorf("session ID = %q, want provider's returned-session", status.SessionID)
			}
			bridge.mu.Lock()
			defer bridge.mu.Unlock()
			if len(bridge.sessionSetupRequests) != 0 || len(bridge.initializeRequestIDs) != 0 {
				t.Error("completed request retained in tracking maps")
			}
		})
	}
}

func auditAcpSendAndStatus(t *testing.T, bridge *acpBridge, data json.RawMessage) *acpBridgeInfo {
	t.Helper()
	peer, reader, _ := auditAcpAttach(t, bridge)
	if err := writeAcpWireFrame(peer, acpWireMessage{Version: 1, Type: "input", Data: data}); err != nil {
		t.Fatal(err)
	}
	return auditAcpStatus(t, peer, reader)
}

func auditAcpAttach(t *testing.T, bridge *acpBridge) (net.Conn, *bufio.Reader, *deadlineRecordingConn) {
	t.Helper()
	server, peer := newDeadlineTestPipe(t)
	done := make(chan struct{})
	go func() {
		defer close(done)
		bridge.handleConnection(server)
	}()
	t.Cleanup(func() {
		peer.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Error("attach did not exit")
		}
	})
	peer.SetDeadline(time.Now().Add(3 * time.Second))
	if err := writeAcpWireFrame(peer, acpWireMessage{Version: 1, Type: "hello"}); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(peer)
	if _, err := readAcpWireFrame(reader); err != nil {
		t.Fatal(err)
	}
	return peer, reader, server
}

func auditAcpStatus(t *testing.T, peer net.Conn, reader *bufio.Reader) *acpBridgeInfo {
	t.Helper()
	if err := writeAcpWireFrame(peer, acpWireMessage{Version: 1, Type: "status"}); err != nil {
		t.Fatal(err)
	}
	for {
		message, err := readAcpWireFrame(reader)
		if err != nil {
			t.Fatal(err)
		}
		if message.Type == "status" {
			return message.Bridge
		}
	}
}

func TestAcpAuditFailedProviderWriteDoesNotRetainRequest(t *testing.T) {
	for _, method := range []string{"initialize", "session/new", "session/load", "session/resume", "session/fork", "session/prompt"} {
		for _, failOn := range []string{"payload", "newline"} {
			t.Run(method+"/"+failOn, func(t *testing.T) {
				bridge := newTestAcpBridge()
				bridge.sessionID = "existing-session"
				bridge.stdin = auditAcpWriteCloser{write: func(data []byte) (int, error) {
					if failOn == "payload" || bytes.Equal(data, []byte{'\n'}) {
						return 0, io.ErrClosedPipe
					}
					return len(data), nil
				}}
				status := auditAcpSendAndStatus(t, bridge, json.RawMessage(`{"id":1,"method":"`+method+`","params":{"sessionId":"failed-session"}}`))
				if status.InFlightTurn != 0 || status.SessionID != "existing-session" {
					t.Fatalf("failed write changed metadata: %+v", status)
				}
				bridge.mu.Lock()
				defer bridge.mu.Unlock()
				if len(bridge.sessionSetupRequests) != 0 || len(bridge.initializeRequestIDs) != 0 {
					t.Error("failed write retained request")
				}
			})
		}
	}
}

func TestAcpAuditSessionSetupCommitsOnlySuccessfulResponse(t *testing.T) {
	responses := []struct {
		name      string
		body      string
		sessionID string
	}{
		{"provider_error", `"error":{"code":-32000,"message":"Session not found"}`, "existing-session"},
		{"returned_id", `"result":{"sessionId":"returned-session"}`, "returned-session"},
		{"no_id", `"result":{}`, "requested-session"},
		{"null_result", `"result":null`, "requested-session"},
		{"missing_result", `"unexpected":{}`, "existing-session"},
		{"error_with_result", `"error":{"code":-32000,"message":"Session not found"},"result":{"sessionId":"returned-session"}`, "existing-session"},
	}
	for _, method := range []string{"session/new", "session/load", "session/resume", "session/fork"} {
		for _, timing := range []string{"fast", "delayed"} {
			for _, response := range responses {
				t.Run(method+"/"+timing+"/"+response.name, func(t *testing.T) {
					bridge := newTestAcpBridge()
					bridge.sessionID = "existing-session"
					rawResponse := json.RawMessage(`{"jsonrpc":"2.0","id":1,` + response.body + `}`)
					bridge.stdin = auditAcpWriteCloser{write: func(data []byte) (int, error) {
						if timing == "fast" && bytes.Equal(data, []byte{'\n'}) {
							// Respond before Write returns to exercise pre-write tracking.
							bridge.publish("output", rawResponse, "", nil)
						}
						return len(data), nil
					}}
					peer, reader, _ := auditAcpAttach(t, bridge)
					request := json.RawMessage(`{"jsonrpc":"2.0","id":1,"method":"` + method + `","params":{"sessionId":"requested-session"}}`)
					if err := writeAcpWireFrame(peer, acpWireMessage{Version: 1, Type: "input", Data: request}); err != nil {
						t.Fatal(err)
					}
					if timing == "delayed" {
						// Status is a barrier: handleAttach has finished observing the
						// successful write, but no provider response has arrived yet.
						pending := auditAcpStatus(t, peer, reader)
						if pending.SessionID != "existing-session" || pending.InFlightTurn != 1 {
							t.Errorf("pending setup changed durable metadata: %+v", pending)
						}
						bridge.mu.Lock()
						requestedID, tracked := bridge.sessionSetupRequests["1"]
						bridge.mu.Unlock()
						if !tracked || requestedID != "requested-session" {
							t.Errorf("pending setup tracking = %q, %v", requestedID, tracked)
						}
						bridge.publish("output", rawResponse, "", nil)
					}
					status := auditAcpStatus(t, peer, reader)
					if status.SessionID != response.sessionID || status.InFlightTurn != 0 {
						t.Errorf("completed setup metadata = %+v, want session %q and no in-flight requests", status, response.sessionID)
					}
					bridge.mu.Lock()
					defer bridge.mu.Unlock()
					if len(bridge.sessionSetupRequests) != 0 || len(bridge.initializeRequestIDs) != 0 {
						t.Error("completed setup retained request tracking")
					}
				})
			}
		}
	}
}

func TestAcpAuditStopInterruptsBlockedProviderWrite(t *testing.T) {
	input, peer := net.Pipe()
	defer peer.Close()
	bridge := newTestAcpBridge()
	bridge.stdin = input
	writeDone := make(chan error, 1)
	go func() { writeDone <- bridge.writeProvider(json.RawMessage(`{"method":"notification"}`)) }()
	// The provider never reads. Even if stop wins the scheduling race, the
	// write must fail, rather than prevent stop from closing the pipe.
	select {
	case err := <-writeDone:
		t.Fatalf("write completed before shutdown: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	stopDone := make(chan struct{})
	go func() { bridge.stop(); close(stopDone) }()
	select {
	case <-stopDone:
	case <-time.After(time.Second):
		peer.Close() // Release the original implementation before failing.
		<-stopDone
		t.Error("stop waited for a provider that never reads stdin")
	}
	select {
	case err := <-writeDone:
		if err == nil {
			t.Error("blocked write succeeded after stop")
		}
	case <-time.After(time.Second):
		t.Error("provider write did not unblock")
	}
}

type auditAcpExhaustedReader struct{ readPastLimit bool }

func (r *auditAcpExhaustedReader) Read([]byte) (int, error) {
	r.readPastLimit = true
	return 0, errors.New("provider is still waiting without sending a newline")
}

func TestAcpAuditOversizedFrameDoesNotDrain(t *testing.T) {
	tail := &auditAcpExhaustedReader{}
	reader := bufio.NewReader(io.MultiReader(strings.NewReader(strings.Repeat("x", acpMaxFrameBytes+4096)), tail))
	if _, err := readBoundedAcpLine(reader); err == nil {
		t.Fatal("oversized frame accepted")
	}
	if tail.readPastLimit {
		t.Fatal("oversized frame reader waited for more input instead of rejecting immediately")
	}
}

func TestAcpAuditReplayTrimWithinBudgetDoesNotAllocate(t *testing.T) {
	bridge := newTestAcpBridge()
	for i := 0; i < 1000; i++ {
		bridge.appendReplayLocked(acpWireMessage{Sequence: uint64(i + 1)}, "")
	}
	if allocations := testing.AllocsPerRun(100, bridge.trimReplayLocked); allocations != 0 {
		t.Fatalf("trimming unchanged replay allocates %.0f times per call", allocations)
	}
}

func TestAcpAuditIncompleteHandshakeExpires(t *testing.T) {
	for _, stopped := range []bool{false, true} {
		t.Run(fmt.Sprint(stopped), func(t *testing.T) {
			bridge := newTestAcpBridge()
			server, peer := newDeadlineTestPipe(t)
			defer peer.Close()
			done := make(chan struct{})
			go func() { bridge.handleConnection(server); close(done) }()
			if _, err := io.WriteString(peer, `{"version":1,"type":"hello"`); err != nil {
				t.Fatal(err)
			}
			assertTestDeadline(t, server.readDeadlines, false)
			if stopped {
				bridge.stop()
			}
			if err := server.Conn.SetReadDeadline(time.Now().Add(-time.Second)); err != nil {
				t.Fatal(err)
			}
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("incomplete handshake retained its connection")
			}
		})
	}
}

func TestAcpAuditHandshakeDeadlineClearedAfterHello(t *testing.T) {
	bridge := newTestAcpBridge()
	peer, reader, conn := auditAcpAttach(t, bridge)
	assertTestDeadline(t, conn.readDeadlines, false)
	assertTestDeadline(t, conn.readDeadlines, true)
	if status := auditAcpStatus(t, peer, reader); status.State != "running" {
		t.Fatalf("attached bridge state = %q", status.State)
	}
}

func TestAcpAuditProviderCommandMatchesPlatform(t *testing.T) {
	for _, shell := range []string{"cmd.exe", "powershell.exe", "pwsh.exe"} {
		t.Run(shell, func(t *testing.T) {
			t.Setenv("ComSpec", shell)
			got := newAcpProviderCommand("echo hello")
			want := newRunCommand("echo hello")
			if got.Path != want.Path || !reflect.DeepEqual(got.Args, want.Args) ||
				!reflect.DeepEqual(got.SysProcAttr, want.SysProcAttr) {
				t.Fatalf("ACP command = %+v, want %+v", got, want)
			}
		})
	}
}

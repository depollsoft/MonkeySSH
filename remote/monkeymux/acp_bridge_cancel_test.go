package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"testing"
	"time"
)

// newCancelTestBridge returns a bridge whose provider stdin is observable.
// Every line the bridge writes to the provider arrives on the channel.
func newCancelTestBridge(t *testing.T) (*acpBridge, <-chan string) {
	t.Helper()
	bridge := newTestAcpBridge()
	providerInput, providerPeer := net.Pipe()
	bridge.stdin = providerInput
	lines := make(chan string, 16)
	go func() {
		reader := bufio.NewReader(providerPeer)
		for {
			line, err := readBoundedAcpLine(reader)
			if err != nil {
				close(lines)
				return
			}
			lines <- string(line)
		}
	}()
	t.Cleanup(func() {
		bridge.closeProviderInput()
		_ = providerPeer.Close()
	})
	return bridge, lines
}

func nextProviderLine(t *testing.T, lines <-chan string) string {
	t.Helper()
	select {
	case line, ok := <-lines:
		if !ok {
			t.Fatal("provider input closed")
		}
		return line
	case <-time.After(time.Second):
		t.Fatal("bridge did not write to the provider")
		return ""
	}
}

func expectNoProviderLine(t *testing.T, lines <-chan string) {
	t.Helper()
	select {
	case line := <-lines:
		t.Fatalf("unexpected provider input %s", line)
	case <-time.After(100 * time.Millisecond):
	}
}

func publishTestProviderFrame(t *testing.T, bridge *acpBridge, frame string) {
	t.Helper()
	if !bridge.publish("output", json.RawMessage(frame), "", nil) {
		t.Fatalf("publish(%s) failed", frame)
	}
}

func cancelFrame(requestID string) string {
	return fmt.Sprintf(
		`{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":%s}}`,
		requestID,
	)
}

func assertCancelResponse(t *testing.T, line string, wantID string) {
	t.Helper()
	var response struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Error   struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(line), &response); err != nil {
		t.Fatalf("provider input %s: %v", line, err)
	}
	if response.JSONRPC != "2.0" || string(response.ID) != wantID ||
		response.Error.Code != acpRequestCancelledCode {
		t.Fatalf("provider input = %s, want -32800 for id %s", line, wantID)
	}
}

// attachTestClient attaches a writer client with hello and returns its
// connection and a reader positioned at the first primed frame.
func attachTestClient(
	t *testing.T,
	bridge *acpBridge,
	hello acpWireMessage,
) (net.Conn, *bufio.Reader) {
	t.Helper()
	server, peer := net.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		hello.Version = acpBridgeProtocolVersion
		hello.Type = "hello"
		bridge.handleAttach(server, bufio.NewReader(server), hello)
	}()
	t.Cleanup(func() {
		_ = peer.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Error("attach did not stop")
		}
	})
	return peer, bufio.NewReader(peer)
}

func sendTestClientInput(t *testing.T, conn net.Conn, data string) {
	t.Helper()
	_ = conn.SetWriteDeadline(time.Now().Add(time.Second))
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version: acpBridgeProtocolVersion,
		Type:    "input",
		Data:    json.RawMessage(data),
	}); err != nil {
		t.Fatal(err)
	}
}

const testPermissionRequest = `{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission","params":{"sessionId":"s"}}`

func TestAcpProviderCancelAnswersAndUnpinsPendingRequest(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	publishTestProviderFrame(t, bridge, testPermissionRequest)
	publishTestProviderFrame(t, bridge, cancelFrame(`"permission-1"`))

	assertCancelResponse(t, nextProviderLine(t, lines), `"permission-1"`)
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if len(bridge.pendingRequests) != 0 {
		t.Fatalf("pending requests = %v, want none", bridge.pendingRequests)
	}
	if bridge.pendingReplayEvents != 0 || bridge.pendingReplayBytes != 0 {
		t.Fatalf(
			"pinned replay = %d events / %d bytes, want none",
			bridge.pendingReplayEvents,
			bridge.pendingReplayBytes,
		)
	}
	if len(bridge.replay) != 2 || bridge.replay[0].pendingID != "" ||
		bridge.replay[1].pendingID != "" {
		t.Fatalf("replay = %#v, want request and cancel unpinned", bridge.replay)
	}
	if _, ok := bridge.cancelledRequests[`"permission-1"`]; !ok {
		t.Fatal("bridge did not remember the cancelled request")
	}
}

func TestAcpFreshAttachDoesNotResurrectCancelledRequest(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	publishTestProviderFrame(t, bridge, testPermissionRequest)
	publishTestProviderFrame(t, bridge, cancelFrame(`"permission-1"`))
	_ = nextProviderLine(t, lines)

	conn, reader := attachTestClient(t, bridge, acpWireMessage{ReplayMode: "pending"})
	hello := readTestAcpFrame(t, reader, conn)
	if hello.Type != "hello" || hello.ReplayMode != "pending" ||
		hello.Bridge == nil || hello.Bridge.PendingRequest != 0 {
		t.Fatalf("hello = %#v, want pending mode with no pending requests", hello)
	}
	next := readTestAcpFrame(t, reader, conn)
	if next.Type != "replay_end" {
		t.Fatalf("frame after hello = %#v, want replay_end without the request", next)
	}
}

func TestAcpResumeReplaysCancelAfterRequest(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	publishTestProviderFrame(t, bridge, testPermissionRequest)
	publishTestProviderFrame(t, bridge, cancelFrame(`"permission-1"`))
	_ = nextProviderLine(t, lines)

	conn, reader := attachTestClient(t, bridge, acpWireMessage{})
	_ = readTestAcpFrame(t, reader, conn) // hello
	request := readTestAcpFrame(t, reader, conn)
	cancel := readTestAcpFrame(t, reader, conn)
	if request.Sequence != 1 || !bytes.Contains(request.Data, []byte("request_permission")) {
		t.Fatalf("first replayed frame = %#v, want the request", request)
	}
	if cancel.Sequence != 2 || !bytes.Contains(cancel.Data, []byte(acpCancelRequestMethod)) {
		t.Fatalf("second replayed frame = %#v, want its cancellation", cancel)
	}
}

func TestAcpClientAnswerToCancelledRequestIsNotForwarded(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	publishTestProviderFrame(t, bridge, testPermissionRequest)
	publishTestProviderFrame(t, bridge, cancelFrame(`"permission-1"`))
	_ = nextProviderLine(t, lines)

	conn, reader := attachTestClient(t, bridge, acpWireMessage{LastAck: 2})
	_ = readTestAcpFrame(t, reader, conn) // hello
	sendTestClientInput(
		t,
		conn,
		`{"jsonrpc":"2.0","id":"permission-1","error":{"code":-32800,"message":"Request cancelled"}}`,
	)
	sendTestClientInput(t, conn, `{"jsonrpc":"2.0","method":"after"}`)
	if line := nextProviderLine(t, lines); !bytes.Contains([]byte(line), []byte(`"after"`)) {
		t.Fatalf("provider input = %s, want only the following notification", line)
	}
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if _, ok := bridge.cancelledRequests[`"permission-1"`]; ok {
		t.Fatal("dropped answer did not clear the cancelled marker")
	}
}

func TestAcpProviderCancelMatchesExactIDType(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	publishTestProviderFrame(
		t,
		bridge,
		`{"jsonrpc":"2.0","id":1,"method":"session/request_permission"}`,
	)
	publishTestProviderFrame(t, bridge, cancelFrame(`"1"`))
	expectNoProviderLine(t, lines)
	bridge.mu.Lock()
	_, stillPending := bridge.pendingRequests["1"]
	bridge.mu.Unlock()
	if !stillPending {
		t.Fatal("string id cancelled a numeric request")
	}

	publishTestProviderFrame(t, bridge, cancelFrame(`1`))
	assertCancelResponse(t, nextProviderLine(t, lines), `1`)
}

func TestAcpProviderCancelMatchesEquivalentStringSpelling(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	publishTestProviderFrame(
		t,
		bridge,
		`{"jsonrpc":"2.0","id":"abc","method":"session/request_permission"}`,
	)
	publishTestProviderFrame(t, bridge, cancelFrame(`"abc"`))
	assertCancelResponse(t, nextProviderLine(t, lines), `"abc"`)
}

func TestAcpProviderCancelIgnoresAnsweredAndUnknownRequests(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	publishTestProviderFrame(t, bridge, testPermissionRequest)
	answer := parseAcpEnvelope(json.RawMessage(
		`{"jsonrpc":"2.0","id":"permission-1","result":{"outcome":{"outcome":"cancelled"}}}`,
	))
	if !bridge.claimClientResponse(answer) {
		t.Fatal("first client answer was not forwarded")
	}
	bridge.observeClientMessage(answer)

	publishTestProviderFrame(t, bridge, cancelFrame(`"permission-1"`))
	publishTestProviderFrame(t, bridge, cancelFrame(`"never-sent"`))
	expectNoProviderLine(t, lines)
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if len(bridge.cancelledRequests) != 0 {
		t.Fatalf("cancelled = %v, want none for answered or unknown ids", bridge.cancelledRequests)
	}
}

func TestAcpReusedRequestIDIsForwardedAfterCancellation(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	publishTestProviderFrame(t, bridge, testPermissionRequest)
	publishTestProviderFrame(t, bridge, cancelFrame(`"permission-1"`))
	_ = nextProviderLine(t, lines)
	publishTestProviderFrame(t, bridge, testPermissionRequest)

	answer := parseAcpEnvelope(json.RawMessage(
		`{"jsonrpc":"2.0","id":"permission-1","result":{}}`,
	))
	if !bridge.claimClientResponse(answer) {
		t.Fatal("answer to the new request with a reused id was dropped")
	}
}

func TestAcpCancelledRequestMemoryIsBounded(t *testing.T) {
	bridge := newTestAcpBridge()
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	for index := 0; index < acpCancelledRequestMemory+10; index++ {
		key := fmt.Sprintf("%d", index)
		bridge.pendingRequests[key] = struct{}{}
		if bridge.cancelPendingRequestLocked(key) == nil {
			t.Fatalf("pending request %s was not cancelled", key)
		}
	}
	if len(bridge.cancelledRequests) != acpCancelledRequestMemory ||
		len(bridge.cancelledOrder) != acpCancelledRequestMemory {
		t.Fatalf(
			"cancelled memory = %d / %d, want %d",
			len(bridge.cancelledRequests),
			len(bridge.cancelledOrder),
			acpCancelledRequestMemory,
		)
	}
	if _, ok := bridge.cancelledRequests["0"]; ok {
		t.Fatal("oldest cancelled id was not evicted")
	}
}

func TestParseAcpProviderOutputRecognizesOnlyCancelNotifications(t *testing.T) {
	tests := []struct {
		name    string
		frame   string
		wantKey string
	}{
		{name: "string id", frame: cancelFrame(`"x"`), wantKey: `"x"`},
		{name: "numeric id", frame: cancelFrame(`7`), wantKey: `7`},
		{name: "null id", frame: cancelFrame(`null`)},
		{
			name:  "request form is not a notification",
			frame: `{"jsonrpc":"2.0","id":3,"method":"$/cancel_request","params":{"requestId":1}}`,
		},
		{name: "other notification", frame: `{"jsonrpc":"2.0","method":"session/update","params":{"requestId":1}}`},
		{name: "missing params", frame: `{"jsonrpc":"2.0","method":"$/cancel_request"}`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, key := parseAcpProviderOutput(json.RawMessage(test.frame))
			if key != test.wantKey {
				t.Fatalf("cancel key = %q, want %q", key, test.wantKey)
			}
		})
	}
}

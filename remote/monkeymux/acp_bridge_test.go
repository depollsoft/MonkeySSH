//go:build !windows

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestRequestAcpBridgeStopAndWaitTreatsMissingBridgeAsStopped(t *testing.T) {
	runtimeRoot := shortUnixSocketDir(t)
	t.Setenv("XDG_RUNTIME_DIR", runtimeRoot)

	const bridgeID = "0123456789abcdef0123456789abcdef"
	if err := requestAcpBridgeStopAndWait(bridgeID); err != nil {
		t.Fatalf("missing bridge stop = %v, want success", err)
	}
}

func TestRequestAcpBridgeStopAndWaitPropagatesRuntimePathFailure(t *testing.T) {
	runtimeRoot := shortUnixSocketDir(t)
	brokenRuntime := filepath.Join(runtimeRoot, "broken-runtime")
	if err := os.Symlink(filepath.Join(runtimeRoot, "missing", "runtime"), brokenRuntime); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_RUNTIME_DIR", brokenRuntime)

	const bridgeID = "fedcba9876543210fedcba9876543210"
	if err := requestAcpBridgeStopAndWait(bridgeID); err == nil {
		t.Fatal("runtime path failure was treated as an already-stopped bridge")
	}
}

func TestRequestAcpBridgeStopAndWaitRemovesAbandonedSocket(t *testing.T) {
	runtimeRoot := shortUnixSocketDir(t)
	t.Setenv("XDG_RUNTIME_DIR", runtimeRoot)

	const bridgeID = "abcdef0123456789abcdef0123456789"
	socket, err := acpSocketPath(bridgeID)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socket, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	listener.SetUnlinkOnClose(false)
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(socket); err != nil {
		t.Fatalf("abandoned socket was not retained: %v", err)
	}

	if err := requestAcpBridgeStopAndWait(bridgeID); err != nil {
		t.Fatalf("abandoned bridge stop = %v, want success", err)
	}
	if _, err := os.Stat(socket); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("abandoned socket stat = %v, want not exist", err)
	}
}

func TestRequestAcpBridgeStopAndWaitPreservesStatusFailures(t *testing.T) {
	for _, response := range []string{"", "invalid\n", `{"version":1,"type":"status"}` + "\n",
		`{"version":1,"type":"error","bridge":{}}` + "\n",
		`{"version":2,"type":"status","bridge":{}}` + "\n"} {
		t.Run(response, func(t *testing.T) {
			t.Setenv("XDG_RUNTIME_DIR", shortUnixSocketDir(t))
			bridge := newTestAcpBridge()
			socket, err := acpSocketPath(bridge.id)
			if err != nil {
				t.Fatal(err)
			}
			listener, err := net.Listen("unix", socket)
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			done := make(chan struct{})
			go func() {
				defer close(done)
				for {
					conn, err := listener.Accept()
					if err != nil {
						return
					}
					_ = conn.SetDeadline(time.Now().Add(2 * socketTimeout))
					message, err := readAcpWireFrame(bufio.NewReader(conn))
					if err == nil && message.Command == "status" {
						if response == "" {
							_, _ = io.Copy(io.Discard, conn)
						} else {
							_, _ = io.WriteString(conn, response)
						}
					}
					_ = conn.Close()
				}
			}()
			server := newMuxServer("test")
			server.windows = []*muxWindow{{id: "@1", nativeAcpBridgeID: bridge.id}}
			server.activeID = "@1"
			for _, stop := range []func() error{
				func() error { return requestAcpBridgeStopAndWait(bridge.id) },
				func() error {
					shutdown, err := server.closeWindow("@1")
					if shutdown || server.windows[0].closed || server.windows[0].closing {
						t.Error("status failure did not preserve a retryable window")
					}
					return err
				},
			} {
				started := time.Now()
				err := stop()
				if err == nil {
					t.Fatal("status failure was treated as successful shutdown")
				}
				if response == "" {
					var timeout net.Error
					if !errors.As(err, &timeout) || !timeout.Timeout() {
						t.Fatalf("status error = %v, want preserved timeout", err)
					}
				}
				if response == "invalid\n" {
					var syntax *json.SyntaxError
					if !errors.As(err, &syntax) {
						t.Fatalf("status error = %v, want preserved JSON error", err)
					}
				}
				if time.Since(started) > 2*acpRequestTimeout {
					t.Error("status request exceeded its deadline")
				}
			}
			_ = listener.Close()
			<-done
			if _, err := server.closeWindow("@1"); err != nil {
				t.Fatalf("retry after bridge disappeared: %v", err)
			}
		})
	}
}

func TestGCAcpArtifactsPreservesUnconfirmedSockets(t *testing.T) {
	for _, state := range []string{"live", "abandoned", "live_without_identity", "abandoned_without_identity", "runtime_error", "permission"} {
		t.Run(state, func(t *testing.T) {
			runtimeRoot := shortUnixSocketDir(t)
			t.Setenv("XDG_RUNTIME_DIR", runtimeRoot)
			socket, err := acpSocketPath(newTestAcpBridge().id)
			if err != nil {
				t.Fatal(err)
			}
			listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socket, Net: "unix"})
			if err != nil {
				t.Fatal(err)
			}
			listener.SetUnlinkOnClose(false)
			defer listener.Close()
			switch state {
			case "abandoned", "abandoned_without_identity":
				_ = listener.Close()
			case "runtime_error":
				t.Setenv("XDG_RUNTIME_DIR", socket)
			case "permission":
				private := filepath.Join(runtimeRoot, "private")
				if err := os.Mkdir(private, 0o700); err != nil {
					t.Fatal(err)
				}
				target, err := filepath.Abs(filepath.Join(private, "bridge.sock"))
				if err != nil {
					t.Fatal(err)
				}
				if err := os.Rename(socket, target); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(target, socket); err != nil {
					t.Fatal(err)
				}
				if err := os.Chmod(private, 0); err != nil {
					t.Fatal(err)
				}
				defer os.Chmod(private, 0o700)
				conn, err := dialAcpBridge(newTestAcpBridge().id)
				if err == nil {
					_ = conn.Close()
					t.Skip("current user bypasses directory permissions")
				}
				if !errors.Is(err, os.ErrPermission) {
					t.Fatalf("dial = %v, want permission error", err)
				}
			}
			if strings.HasSuffix(state, "_without_identity") {
				// Windows cannot identify socket inodes. Exercise its fallback
				// against real Unix sockets, including a still-live listener.
				identityRequested := false
				gcAcpArtifactsWithSocketIdentity(filepath.Dir(socket), func(path string) (socketIdentity, error) {
					identityRequested = true
					if path != socket {
						t.Fatalf("identity path = %q, want %q", path, socket)
					}
					return socketIdentity{}, errors.New("windows socket identity unavailable")
				})
				if !identityRequested {
					t.Fatal("GC did not attempt socket identity lookup")
				}
			} else {
				gcAcpArtifacts(filepath.Dir(socket))
			}
			_, err = os.Lstat(socket)
			if state == "abandoned" || state == "abandoned_without_identity" {
				if !errors.Is(err, os.ErrNotExist) {
					t.Fatalf("abandoned socket remains: %v", err)
				}
			} else if err != nil {
				t.Fatalf("unconfirmed socket was removed: %v", err)
			}
		})
	}
}

func TestAcpWireFramingRoundTrip(t *testing.T) {
	var buffer bytes.Buffer
	want := acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "input",
		BridgeID: "0123456789abcdef0123456789abcdef",
		Data:     json.RawMessage(`{"jsonrpc":"2.0","method":"session/prompt"}`),
	}
	if err := writeAcpWireFrame(&buffer, want); err != nil {
		t.Fatal(err)
	}
	got, err := readAcpWireFrame(bufio.NewReader(&buffer))
	if err != nil {
		t.Fatal(err)
	}
	if got.Type != want.Type || got.BridgeID != want.BridgeID ||
		!bytes.Equal(got.Data, want.Data) {
		t.Fatalf("wire frame = %#v, want %#v", got, want)
	}
	want.Data = nil
	base, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	for _, size := range []int{acpMaxFrameBytes - 1, acpMaxFrameBytes, acpMaxFrameBytes + 1} {
		want.Type = strings.Repeat("x", size-len(base)+len("input"))
		buffer.Reset()
		err := writeAcpWireFrame(&buffer, want)
		if size >= acpMaxFrameBytes {
			if err == nil || buffer.Len() != 0 {
				t.Fatalf("accepted oversized JSON payload of %d bytes", size)
			}
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		if _, err := readAcpWireFrame(bufio.NewReader(&buffer)); err != nil {
			t.Fatal(err)
		}
	}

}

func TestAcpAdaptiveReplayPolicy(t *testing.T) {
	tests := []struct {
		name                  string
		mode                  string
		lastAck               uint64
		replayBytes           int
		replayIncomplete      bool
		containsClientRequest bool
		want                  string
	}{
		{name: "short complete replay stays direct", mode: "adaptive", replayBytes: acpAdaptiveReplayMaxBytes, want: "direct"},
		{name: "large replay becomes pending-only", mode: "adaptive", replayBytes: acpAdaptiveReplayMaxBytes + 1, want: "pending"},
		{name: "incomplete replay becomes pending-only", mode: "adaptive", replayIncomplete: true, want: "pending"},
		{name: "historical client request becomes pending-only", mode: "adaptive", containsClientRequest: true, want: "pending"},
		{name: "explicit pending remains supported", mode: "pending", replayBytes: 1, want: "pending"},
		{name: "nonzero ack always resumes strictly", mode: "adaptive", lastAck: 1, replayBytes: acpReplayMaxBytes, want: ""},
		{name: "unknown mode stays ordinary", mode: "unknown", replayBytes: acpReplayMaxBytes, want: ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			hello := acpWireMessage{ReplayMode: test.mode, LastAck: test.lastAck}
			got := replayModeForAttach(
				hello,
				test.replayBytes,
				test.replayIncomplete,
				test.containsClientRequest,
			)
			if got != test.want {
				t.Fatalf("replayModeForAttach() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestAcpResolvedClientRequestRemainsUnsafeForDirectReplay(t *testing.T) {
	bridge := newTestAcpBridge()
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission"}`),
		"",
		nil,
	)
	bridge.mu.Lock()
	bridge.releasePendingReplayLocked(`"permission-1"`)
	replay := append([]acpReplayEvent(nil), bridge.replay...)
	bridge.mu.Unlock()

	if len(replay) != 1 || replay[0].pendingID != "" {
		t.Fatalf("resolved replay = %#v, want retained non-pending event", replay)
	}
	if !replayContainsClientRequest(replay) {
		t.Fatal("resolved client request was incorrectly marked safe for direct replay")
	}
}

func TestAcpCachedInitializeResponseAvoidsDuplicateProviderRequest(t *testing.T) {
	bridge := newTestAcpBridge()
	providerInput := &testWriteCloser{}
	bridge.stdin = providerInput
	firstInitialize := json.RawMessage(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
	for _, response := range []string{
		`{"id":1}`, `{"id":1,"result":null}`, `{"id":"1","result":{}}`,
		`{"id":1,"result":{},"error":null}`, `{"id":1,"error":{"code":-1}}`,
	} {
		bridge := newTestAcpBridge()
		bridge.trackClientRequest(parseAcpEnvelope(firstInitialize))
		bridge.publish("output", json.RawMessage(response), "", nil)
		if got := bridge.cachedInitializeResponse(parseAcpEnvelope(firstInitialize)); got != nil {
			t.Fatalf("cached unsuccessful or mismatched initialize %s: %s", response, got)
		}
	}
	if _, ok := bridge.trackClientRequest(parseAcpEnvelope(firstInitialize)); !ok {
		t.Fatal("first initialize request was not tracked")
	}
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}}`),
		"",
		nil,
	)

	server, peer := net.Pipe()
	attachDone := make(chan struct{})
	go func() {
		defer close(attachDone)
		bridge.handleAttach(
			server,
			bufio.NewReader(server),
			acpWireMessage{
				Version: acpBridgeProtocolVersion,
				Type:    "hello",
				LastAck: 1,
			},
		)
	}()
	defer func() {
		_ = peer.Close()
		select {
		case <-attachDone:
		case <-time.After(time.Second):
			t.Error("cached initialize attach did not stop")
		}
	}()

	reader := bufio.NewReader(peer)
	if hello := readTestAcpFrame(t, reader, peer); hello.Type != "hello" {
		t.Fatalf("first attach frame = %#v, want hello", hello)
	}
	secondInitialize := json.RawMessage(`{"jsonrpc":"2.0","id":"reattach","method":"initialize","params":{}}`)
	if err := writeAcpWireFrame(peer, acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "input",
		BridgeID: bridge.id,
		Data:     secondInitialize,
	}); err != nil {
		t.Fatal(err)
	}
	response := readTestAcpFrame(t, reader, peer)
	var envelope struct {
		ID     string `json:"id"`
		Result struct {
			ProtocolVersion int `json:"protocolVersion"`
		} `json:"result"`
	}
	if response.Type != "output" || json.Unmarshal(response.Data, &envelope) != nil ||
		envelope.ID != "reattach" || envelope.Result.ProtocolVersion != 1 {
		t.Fatalf("cached initialize response = %#v / %#v", response, envelope)
	}
	if providerInput.Len() != 0 {
		t.Fatalf("duplicate initialize reached provider: %q", providerInput.String())
	}
}

func TestAcpAttachQueuesHelloBeforeConcurrentLiveEvent(t *testing.T) {
	bridge := newTestAcpBridge()
	peer, primed, release, attachDone := startPrimedTestAttach(t, bridge)
	defer finishPrimedTestAttach(t, peer, release, attachDone)
	<-primed

	published := make(chan struct{})
	go func() {
		bridge.publish(
			"output",
			json.RawMessage(`{"jsonrpc":"2.0","method":"live"}`),
			"",
			nil,
		)
		close(published)
	}()
	close(release)
	<-published

	reader := bufio.NewReader(peer)
	hello := readTestAcpFrame(t, reader, peer)
	live := readTestAcpFrame(t, reader, peer)
	if hello.Type != "hello" {
		t.Fatalf("first attach frame = %#v, want hello", hello)
	}
	if live.Type != "output" || live.Sequence != 1 {
		t.Fatalf("second attach frame = %#v, want live sequence 1", live)
	}
}

func TestAcpAttachQueuesReplayBeforeConcurrentLiveEvent(t *testing.T) {
	bridge := newTestAcpBridge()
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"one"}`), "", nil)
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"two"}`), "", nil)
	peer, primed, release, attachDone := startPrimedTestAttach(t, bridge)
	defer finishPrimedTestAttach(t, peer, release, attachDone)
	<-primed

	published := make(chan struct{})
	go func() {
		bridge.publish(
			"output",
			json.RawMessage(`{"jsonrpc":"2.0","method":"live"}`),
			"",
			nil,
		)
		close(published)
	}()
	close(release)
	<-published

	reader := bufio.NewReader(peer)
	frames := []acpWireMessage{
		readTestAcpFrame(t, reader, peer),
		readTestAcpFrame(t, reader, peer),
		readTestAcpFrame(t, reader, peer),
		readTestAcpFrame(t, reader, peer),
	}
	if frames[0].Type != "hello" {
		t.Fatalf("first attach frame = %#v, want hello", frames[0])
	}
	for index, sequence := range []uint64{1, 2, 3} {
		frame := frames[index+1]
		if frame.Type != "output" || frame.Sequence != sequence {
			t.Fatalf(
				"attach frame %d = %#v, want output sequence %d",
				index+1,
				frame,
				sequence,
			)
		}
	}
}

func TestAcpAdaptiveAttachEchoesDirectForSafeShortReplay(t *testing.T) {
	bridge := newTestAcpBridge()
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","method":"session/update"}`),
		"",
		nil,
	)
	server, peer := net.Pipe()
	attachDone := make(chan struct{})
	go func() {
		defer close(attachDone)
		bridge.handleAttach(
			server,
			bufio.NewReader(server),
			acpWireMessage{
				Version:    acpBridgeProtocolVersion,
				Type:       "hello",
				ReplayMode: "adaptive",
			},
		)
	}()
	defer func() {
		_ = peer.Close()
		select {
		case <-attachDone:
		case <-time.After(time.Second):
			t.Error("adaptive direct attach did not stop")
		}
	}()

	reader := bufio.NewReader(peer)
	hello := readTestAcpFrame(t, reader, peer)
	replayed := readTestAcpFrame(t, reader, peer)
	if hello.Type != "hello" || hello.ReplayMode != "direct" {
		t.Fatalf("adaptive hello = %#v, want direct replay", hello)
	}
	if replayed.Type != "output" || replayed.Sequence != 1 {
		t.Fatalf("adaptive direct replay = %#v, want output sequence 1", replayed)
	}
}

func TestAcpFreshAttachSkipsHistoricalReplayButKeepsPending(t *testing.T) {
	bridge := newTestAcpBridge()
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","method":"historical"}`),
		"",
		nil,
	)
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission"}`),
		"",
		nil,
	)

	server, peer := net.Pipe()
	primed := make(chan struct{})
	release := make(chan struct{})
	bridge.beforeClientVisible = func() {
		close(primed)
		<-release
	}
	attachDone := make(chan struct{})
	go func() {
		defer close(attachDone)
		bridge.handleAttach(
			server,
			bufio.NewReader(server),
			acpWireMessage{
				Version:    acpBridgeProtocolVersion,
				Type:       "hello",
				ReplayMode: "pending",
			},
		)
	}()
	defer finishPrimedTestAttach(t, peer, release, attachDone)
	<-primed
	close(release)

	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","method":"live"}`),
		"",
		nil,
	)

	reader := bufio.NewReader(peer)
	hello := readTestAcpFrame(t, reader, peer)
	pending := readTestAcpFrame(t, reader, peer)
	replayEnd := readTestAcpFrame(t, reader, peer)
	live := readTestAcpFrame(t, reader, peer)
	if hello.Type != "hello" || hello.ReplayMode != "pending" ||
		hello.Bridge == nil || hello.Bridge.NextSequence != 2 {
		t.Fatalf("fresh attach hello = %#v", hello)
	}
	if pending.Type != "pending" || pending.Sequence != 0 ||
		!bytes.Contains(pending.Data, []byte("session/request_permission")) {
		t.Fatalf("fresh attach pending frame = %#v", pending)
	}
	if replayEnd.Type != "replay_end" || replayEnd.ReplayMode != "pending" {
		t.Fatalf("fresh attach replay end = %#v", replayEnd)
	}
	if live.Type != "output" || live.Sequence != 3 ||
		!bytes.Contains(live.Data, []byte("live")) {
		t.Fatalf("fresh attach live frame = %#v", live)
	}
}

func TestAcpPendingReplayModeRequiresFreshAck(t *testing.T) {
	bridge := newTestAcpBridge()
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","method":"one"}`),
		"",
		nil,
	)
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","method":"two"}`),
		"",
		nil,
	)

	server, peer := net.Pipe()
	attachDone := make(chan struct{})
	go func() {
		defer close(attachDone)
		bridge.handleAttach(
			server,
			bufio.NewReader(server),
			acpWireMessage{
				Version:    acpBridgeProtocolVersion,
				Type:       "hello",
				LastAck:    1,
				ReplayMode: "pending",
			},
		)
	}()
	defer func() {
		_ = peer.Close()
		select {
		case <-attachDone:
		case <-time.After(time.Second):
			t.Error("non-fresh attach did not stop")
		}
	}()

	reader := bufio.NewReader(peer)
	hello := readTestAcpFrame(t, reader, peer)
	replayed := readTestAcpFrame(t, reader, peer)
	if hello.Type != "hello" || hello.ReplayMode != "" {
		t.Fatalf("non-fresh hello = %#v, want ordinary replay", hello)
	}
	if replayed.Type != "output" || replayed.Sequence != 2 {
		t.Fatalf("non-fresh replay = %#v, want sequence 2", replayed)
	}
}

func TestAcpAttachPrimesMaximumPinnedReplay(t *testing.T) {
	bridge := newTestAcpBridge()
	pinnedCount := acpPendingReplayMaxEvents
	for index := range pinnedCount {
		request := json.RawMessage(fmt.Sprintf(
			`{"jsonrpc":"2.0","id":"permission-%d","method":"session/request_permission"}`,
			index,
		))
		if !bridge.publish("output", request, "", nil) {
			t.Fatalf("pending request %d was rejected below the limit", index)
		}
	}
	peer, primed, release, attachDone := startPrimedTestAttach(t, bridge)
	defer finishPrimedTestAttach(t, peer, release, attachDone)
	select {
	case <-primed:
	case <-time.After(time.Second):
		t.Fatal("attach blocked while priming pinned replay")
	}

	published := make(chan struct{})
	go func() {
		bridge.publish(
			"output",
			json.RawMessage(`{"jsonrpc":"2.0","method":"live"}`),
			"",
			nil,
		)
		close(published)
	}()
	close(release)
	<-published

	reader := bufio.NewReader(peer)
	hello := readTestAcpFrame(t, reader, peer)
	if hello.Type != "hello" {
		t.Fatalf("first attach frame = %#v, want hello", hello)
	}
	for sequence := uint64(1); sequence <= uint64(pinnedCount+1); sequence++ {
		frame := readTestAcpFrame(t, reader, peer)
		if frame.Type != "output" || frame.Sequence != sequence {
			t.Fatalf(
				"replay frame sequence %d = %#v, want ordered output",
				sequence,
				frame,
			)
		}
	}
}

func TestAcpPublishSerializesSequenceAndClientVisibility(t *testing.T) {
	bridge := newTestAcpBridge()
	client := &acpBridgeClient{
		id:         "client",
		send:       make(chan acpWireMessage, 2),
		done:       make(chan struct{}),
		writerDone: make(chan struct{}),
	}
	bridge.clients[client.id] = client

	firstVisible := make(chan struct{})
	releaseFirst := make(chan struct{})
	bridge.beforePublishVisible = func(message acpWireMessage) {
		if message.Sequence == 1 {
			close(firstVisible)
			<-releaseFirst
		}
	}

	firstDone := make(chan struct{})
	go func() {
		bridge.publish(
			"output",
			json.RawMessage(`{"jsonrpc":"2.0","method":"first"}`),
			"",
			nil,
		)
		close(firstDone)
	}()
	<-firstVisible

	secondStarted := make(chan struct{})
	secondDone := make(chan struct{})
	go func() {
		close(secondStarted)
		bridge.publish("state", nil, "exited", nil)
		close(secondDone)
	}()
	<-secondStarted
	select {
	case <-secondDone:
		t.Fatal("later publish became visible before the first publish")
	case <-time.After(25 * time.Millisecond):
	}

	close(releaseFirst)
	<-firstDone
	<-secondDone
	first := <-client.send
	second := <-client.send
	if first.Sequence != 1 || second.Sequence != 2 {
		t.Fatalf(
			"client sequence order = %d, %d, want 1, 2",
			first.Sequence,
			second.Sequence,
		)
	}
}

func TestAcpDetachedClientCannotReclaimWriter(t *testing.T) {
	bridge := newTestAcpBridge()
	if bridge.clientCanSend("detached") {
		t.Fatal("detached client was allowed to send")
	}
	if bridge.writerClientID != "" {
		t.Fatalf("detached client claimed writer role: %q", bridge.writerClientID)
	}
}

func TestAcpBridgeCapturesSessionIdentityForDurableListing(t *testing.T) {
	bridge := newTestAcpBridge()
	bridge.providerID = "builtin:pi-acp"
	bridge.cwd = "/repo"
	bridge.trackClientRequest(parseAcpEnvelope(json.RawMessage(
		`{"jsonrpc":"2.0","id":7,"method":"session/new","params":{"cwd":"/repo"}}`,
	)))
	bridge.publish("output", json.RawMessage(
		`{"jsonrpc":"2.0","id":7,"result":{"sessionId":"session-7"}}`,
	), "", nil)

	info := bridge.snapshot()
	if info.ProviderID != "builtin:pi-acp" || info.SessionID != "session-7" ||
		info.Cwd != "/repo" {
		t.Fatalf("durable metadata = %#v", info)
	}
}

func TestAcpProviderExitWaitsForFinalOutputDrain(t *testing.T) {
	cmd := newAcpProviderCommand("exit 0")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	bridge := newTestAcpBridge()
	bridge.cmd = cmd
	bridge.providerDone = make(chan struct{})
	bridge.providerOutputDone = make(chan struct{})

	waitDone := make(chan struct{})
	go func() {
		bridge.waitForProvider()
		close(waitDone)
	}()
	select {
	case <-bridge.providerDone:
	case <-time.After(time.Second):
		t.Fatal("provider process did not exit")
	}

	bridge.mu.Lock()
	replayBeforeDrain := len(bridge.replay)
	bridge.mu.Unlock()
	if replayBeforeDrain != 0 {
		t.Fatal("provider exit was published before stdout finished draining")
	}

	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","method":"final"}`),
		"",
		nil,
	)
	close(bridge.providerOutputDone)
	select {
	case <-waitDone:
	case <-time.After(time.Second):
		t.Fatal("provider exit was not published after stdout drained")
	}

	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if len(bridge.replay) != 2 {
		t.Fatalf("replay length = %d, want final output and exit", len(bridge.replay))
	}
	if bridge.replay[0].message.Type != "output" ||
		bridge.replay[0].message.Sequence != 1 ||
		bridge.replay[1].message.State != "exited" ||
		bridge.replay[1].message.Sequence != 2 {
		t.Fatalf("provider replay order = %#v", bridge.replay)
	}
}

func TestValidateAcpProviderEnvironmentDetectsLockedCursorKeychain(t *testing.T) {
	originalGOOS := acpRuntimeGOOS
	originalProbe := cursorAgentKeychainProbe
	t.Cleanup(func() {
		acpRuntimeGOOS = originalGOOS
		cursorAgentKeychainProbe = originalProbe
	})
	t.Setenv("CURSOR_API_KEY", "")
	t.Setenv("AGENT_CLI_CREDENTIAL_STORE", "")
	acpRuntimeGOOS = "darwin"
	cursorAgentKeychainProbe = func() int { return 36 }

	if err := validateAcpProviderEnvironment(cursorAgentAcpProviderID); !errors.Is(err, errCursorAgentKeychainLocked) {
		t.Fatalf("locked Cursor keychain error = %v", err)
	}
	if err := validateAcpProviderEnvironment("builtin:other"); err != nil {
		t.Fatalf("other provider inherited Cursor keychain error: %v", err)
	}
	cursorAgentKeychainProbe = func() int { return 44 }
	if err := validateAcpProviderEnvironment(cursorAgentAcpProviderID); err != nil {
		t.Fatalf("missing Cursor credential was classified as locked: %v", err)
	}
	t.Setenv("CURSOR_API_KEY", "configured")
	cursorAgentKeychainProbe = func() int { return 36 }
	if err := validateAcpProviderEnvironment(cursorAgentAcpProviderID); err != nil {
		t.Fatalf("API-key Cursor launch probed keychain: %v", err)
	}
}

func TestAcpProviderExitDrainsRealPipeBeforePublishingExit(t *testing.T) {
	const outputCount = 300
	bridge, err := newAcpBridge(
		"0123456789abcdef0123456789abcdef",
		"",
		"test",
		`sleep 0.2; i=0; while [ "$i" -lt 300 ]; do printf '{"jsonrpc":"2.0","method":"final/%s"}\n' "$i"; i=$((i+1)); done`,
		".",
	)
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.stop()
	bridge.mu.Lock()
	bridge.beforePublishVisible = func(message acpWireMessage) {
		if message.Type == "output" {
			time.Sleep(100 * time.Microsecond)
		}
	}
	bridge.mu.Unlock()

	select {
	case <-bridge.providerDone:
	case <-time.After(2 * time.Second):
		t.Fatal("provider process did not exit")
	}
	select {
	case <-bridge.providerOutputDone:
	case <-time.After(2 * time.Second):
		t.Fatal("provider output did not finish draining")
	}

	deadline := time.Now().Add(time.Second)
	for {
		bridge.mu.Lock()
		outputs := 0
		for _, event := range bridge.replay {
			if event.message.Type == "output" {
				outputs++
			}
		}
		replay := append([]acpReplayEvent(nil), bridge.replay...)
		bridge.mu.Unlock()
		exitPublished :=
			len(replay) > 0 && replay[len(replay)-1].message.State == "exited"
		if exitPublished {
			if outputs != outputCount {
				t.Fatalf(
					"retained output frames = %d, want %d before exit",
					outputs,
					outputCount,
				)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("provider exit state was not published")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestAcpPendingProviderRequestsAreBoundedByCount(t *testing.T) {
	bridge := newTestAcpBridge()
	for index := range acpPendingReplayMaxEvents {
		request := json.RawMessage(fmt.Sprintf(
			`{"jsonrpc":"2.0","id":"permission-%d","method":"session/request_permission"}`,
			index,
		))
		if !bridge.publish("output", request, "", nil) {
			t.Fatalf("pending request %d was rejected below the limit", index)
		}
	}
	overflow := json.RawMessage(
		`{"jsonrpc":"2.0","id":"overflow","method":"session/request_permission"}`,
	)
	if bridge.publish("output", overflow, "", nil) {
		t.Fatal("pending request above the count limit was retained")
	}

	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if len(bridge.pendingRequests) != acpPendingReplayMaxEvents {
		t.Fatalf(
			"pending request count = %d, want %d",
			len(bridge.pendingRequests),
			acpPendingReplayMaxEvents,
		)
	}
	if bridge.pendingReplayEvents != acpPendingReplayMaxEvents {
		t.Fatalf(
			"pending replay event count = %d, want %d",
			bridge.pendingReplayEvents,
			acpPendingReplayMaxEvents,
		)
	}
}

func TestAcpPendingProviderRequestsAreBoundedByBytes(t *testing.T) {
	bridge := newTestAcpBridge()
	value := strings.Repeat("x", acpMaxFrameBytes/2)
	rejected := false
	for index := range acpPendingReplayMaxEvents {
		request := json.RawMessage(fmt.Sprintf(
			`{"jsonrpc":"2.0","id":"permission-%d","method":"session/request_permission","params":{"value":"%s"}}`,
			index,
			value,
		))
		if !bridge.publish("output", request, "", nil) {
			rejected = true
			break
		}
	}
	if !rejected {
		t.Fatal("pending request bytes were not bounded")
	}

	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if bridge.pendingReplayBytes > acpPendingReplayMaxBytes {
		t.Fatalf(
			"pending replay bytes = %d, limit %d",
			bridge.pendingReplayBytes,
			acpPendingReplayMaxBytes,
		)
	}
	if bridge.pendingReplayEvents >= acpPendingReplayMaxEvents {
		t.Fatal("byte limit did not trigger before the event limit")
	}
}

type testWriteCloser struct {
	bytes.Buffer
}

func (*testWriteCloser) Close() error { return nil }

func startPrimedTestAttach(
	t *testing.T,
	bridge *acpBridge,
) (net.Conn, <-chan struct{}, chan struct{}, <-chan struct{}) {
	t.Helper()
	server, peer := net.Pipe()
	primed := make(chan struct{})
	release := make(chan struct{})
	bridge.beforeClientVisible = func() {
		close(primed)
		<-release
	}
	attachDone := make(chan struct{})
	go func() {
		defer close(attachDone)
		bridge.handleAttach(
			server,
			bufio.NewReader(server),
			acpWireMessage{Version: acpBridgeProtocolVersion, Type: "hello"},
		)
	}()
	return peer, primed, release, attachDone
}

func finishPrimedTestAttach(
	t *testing.T,
	peer net.Conn,
	release chan struct{},
	attachDone <-chan struct{},
) {
	t.Helper()
	select {
	case <-release:
	default:
		close(release)
	}
	_ = peer.Close()
	select {
	case <-attachDone:
	case <-time.After(time.Second):
		t.Error("primed attach did not stop")
	}
}

func TestAcpDetachedIdleClientStopsWriter(t *testing.T) {
	server, peer := net.Pipe()
	defer peer.Close()
	client := &acpBridgeClient{
		id:         "client",
		conn:       server,
		send:       make(chan acpWireMessage, 1),
		done:       make(chan struct{}),
		writerDone: make(chan struct{}),
	}
	bridge := &acpBridge{
		clients: map[string]*acpBridgeClient{client.id: client},
	}
	go bridge.writeClient(client)

	bridge.detachClient(client.id)

	select {
	case <-client.writerDone:
	case <-time.After(time.Second):
		t.Fatal("idle detached client left its writer goroutine running")
	}
}

func TestAcpProviderReapGateBlocksWaitUntilGroupCleanup(t *testing.T) {
	cmd := newAcpProviderCommand("sleep 30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	bridge := newTestAcpBridge()
	bridge.cmd = cmd
	bridge.providerDone = make(chan struct{})
	bridge.providerOutputDone = make(chan struct{})
	bridge.providerReapReady = make(chan struct{})
	close(bridge.providerOutputDone)

	go bridge.waitForProvider()
	select {
	case <-bridge.providerDone:
		t.Fatal("provider was reaped while its process group was still live")
	case <-time.After(50 * time.Millisecond):
	}

	bridge.stopProviderProcess()
	select {
	case <-bridge.providerDone:
	case <-time.After(time.Second):
		t.Fatal("provider was not reaped after group cleanup opened the gate")
	}
}

func TestAcpProviderExitCancelsDelayedForceStop(t *testing.T) {
	cmd := newAcpProviderCommand("sleep 30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	forced := make(chan struct{}, 1)

	stopAcpProviderAfter(cmd, nil, 250*time.Millisecond, func(*exec.Cmd) {
		forced <- struct{}{}
	})
	_ = cmd.Wait()

	select {
	case <-forced:
		t.Fatal("force stop ran after the provider had exited")
	default:
	}
}

func TestAcpProviderWrapperExitStillForcesSurvivingProcessGroup(t *testing.T) {
	readyPath := filepath.Join(t.TempDir(), "child-ready")
	cmd := newAcpProviderCommand(fmt.Sprintf( // nosemgrep
		"trap 'exit 0' TERM; "+
			"(trap '' TERM; : > %q; while :; do sleep 1; done) & wait",
		readyPath,
	))
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	forced := make(chan struct{}, 1)
	leaderReservedBeforeForce := false
	readyDeadline := time.Now().Add(time.Second)
	for {
		if _, err := os.Stat(readyPath); err == nil {
			break
		}
		if time.Now().After(readyDeadline) {
			forceStopAcpProvider(cmd)
			_ = cmd.Wait()
			t.Fatal("TERM-ignoring provider child did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}

	stopAcpProviderAfter(cmd, nil, 100*time.Millisecond, func(cmd *exec.Cmd) {
		snapshot := inspectProcess(cmd.Process.Pid)
		leaderReservedBeforeForce = snapshot.known && !snapshot.running &&
			syscall.Kill(-cmd.Process.Pid, 0) == nil
		forced <- struct{}{}
		forceStopAcpProvider(cmd)
	})

	select {
	case <-forced:
	default:
		t.Fatal("wrapper exit skipped force-stop for a surviving process group")
	}
	if !leaderReservedBeforeForce {
		t.Fatal("provider group leader was not an unreaped zombie before force-stop")
	}
	deadline := time.Now().Add(time.Second)
	groupStopped := false
	for time.Now().Before(deadline) {
		live, err := acpProviderProcessGroupHasLiveMember(cmd)
		if err == nil && !live {
			groupStopped = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = cmd.Wait()
	if !groupStopped {
		t.Fatal("provider process group survived force-stop")
	}
}

func TestAcpProviderForceWaitsForProcessGroupExit(t *testing.T) {
	readyPath := filepath.Join(t.TempDir(), "async-force-child-ready")
	cmd := newAcpProviderCommand(fmt.Sprintf( // nosemgrep
		"trap 'exit 0' TERM; "+
			"(trap '' TERM; : > %q; while :; do sleep 1; done) & wait",
		readyPath,
	))
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	reaped := false
	defer func() {
		if reaped {
			return
		}
		forceStopAcpProvider(cmd)
		_ = cmd.Wait()
	}()
	readyDeadline := time.Now().Add(time.Second)
	for {
		if _, err := os.Stat(readyPath); err == nil {
			break
		}
		if time.Now().After(readyDeadline) {
			t.Fatal("TERM-ignoring provider child did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}

	forced := make(chan struct{})
	stopDone := make(chan struct{})
	go func() {
		stopAcpProviderAfter(cmd, nil, 50*time.Millisecond, func(cmd *exec.Cmd) {
			close(forced)
			go func() {
				time.Sleep(100 * time.Millisecond)
				forceStopAcpProvider(cmd)
			}()
		})
		close(stopDone)
	}()
	select {
	case <-forced:
	case <-time.After(time.Second):
		t.Fatal("force-stop was not requested")
	}
	select {
	case <-stopDone:
		t.Fatal("provider stop returned before the process group exited")
	case <-time.After(50 * time.Millisecond):
	}
	select {
	case <-stopDone:
	case <-time.After(time.Second):
		t.Fatal("provider stop did not finish after the process group exited")
	}
	_ = cmd.Wait()
	reaped = true
}

func TestAcpConcurrentProviderWritesKeepFramesIntact(t *testing.T) {
	providerInput, peer := net.Pipe()
	defer peer.Close()
	bridge := &acpBridge{stdin: providerInput}
	defer bridge.closeProviderInput()
	payloads := []json.RawMessage{
		json.RawMessage(`{"jsonrpc":"2.0","method":"first"}`),
		json.RawMessage(`{"jsonrpc":"2.0","method":"second"}`),
	}
	writerDone := make(chan error, len(payloads))
	for _, payload := range payloads {
		go func() { writerDone <- bridge.writeProvider(payload) }()
	}
	peer.SetReadDeadline(time.Now().Add(time.Second))
	reader := bufio.NewReader(peer)
	seen := make(map[string]bool)
	for range payloads {
		line, err := readBoundedAcpLine(reader)
		if err != nil {
			t.Fatal(err)
		}
		seen[string(line)] = true
	}
	for _, payload := range payloads {
		if !seen[string(payload)] {
			t.Fatalf("provider did not receive intact frame %s", payload)
		}
		select {
		case err := <-writerDone:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(time.Second):
			t.Fatal("provider write did not finish")
		}
	}
}

func TestAcpBridgeStartConnectListStatusAndStop(t *testing.T) {
	bridge, cleanup := startTestAcpBridge(t, "cat")
	defer cleanup()

	ids, err := listAcpBridgeIDs()
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) != 1 || ids[0] != bridge.id {
		t.Fatalf("bridge IDs = %#v, want %q", ids, bridge.id)
	}
	status, err := acpBridgeStatus(bridge.id)
	if err != nil {
		t.Fatal(err)
	}
	if status.ID != bridge.id || status.State != "running" || status.CommandHash == "" {
		t.Fatalf("status = %#v", status)
	}

	conn, err := dialAcpBridge(bridge.id)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "hello",
		BridgeID: bridge.id,
	}); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	hello := readTestAcpFrame(t, reader, conn)
	if hello.Type != "hello" || !hello.CanSend || hello.Bridge == nil {
		t.Fatalf("attach hello = %#v", hello)
	}
	if err := requestAcpBridgeStopAndWait(bridge.id); err != nil {
		t.Fatal(err)
	}
	select {
	case <-bridge.done:
	case <-time.After(time.Second):
		t.Fatal("bridge did not stop")
	}
}

func TestAcpReconnectReplaysAfterAck(t *testing.T) {
	bridge, cleanup := startTestAcpBridge(t, "cat")
	defer cleanup()
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"one"}`), "", nil)
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"two"}`), "", nil)

	conn, err := dialAcpBridge(bridge.id)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "hello",
		BridgeID: bridge.id,
		LastAck:  1,
	}); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	_ = readTestAcpFrame(t, reader, conn) // hello
	replayed := readTestAcpFrame(t, reader, conn)
	if replayed.Type != "output" || replayed.Sequence != 2 {
		t.Fatalf("replayed event = %#v, want sequence 2", replayed)
	}
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version: acpBridgeProtocolVersion,
		Type:    "ack",
		Ack:     replayed.Sequence,
	}); err != nil {
		t.Fatal(err)
	}
	_ = conn.Close()

	conn, err = dialAcpBridge(bridge.id)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "hello",
		BridgeID: bridge.id,
		LastAck:  2,
	}); err != nil {
		t.Fatal(err)
	}
	reader = bufio.NewReader(conn)
	_ = readTestAcpFrame(t, reader, conn)
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"three"}`), "", nil)
	next := readTestAcpFrame(t, reader, conn)
	if next.Type != "output" || next.Sequence != 3 {
		t.Fatalf("next event = %#v, want sequence 3", next)
	}
}

func TestAcpReplayRetainsManyTinyStreamingUpdates(t *testing.T) {
	bridge := newTestAcpBridge()
	const updates = 4096
	for range updates {
		bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"update"}`), "", nil)
	}
	if len(bridge.replay) != updates || bridge.replay[0].message.Sequence != 1 {
		t.Fatalf("retained replay = %d events from %d, want %d events from 1", len(bridge.replay), bridge.replay[0].message.Sequence, updates)
	}
}

func TestAcpReplayOverflowSignalsRetainedSequence(t *testing.T) {
	bridge, cleanup := startTestAcpBridge(t, "cat")
	defer cleanup()
	bridge.mu.Lock()
	bridge.nextSequence = 2
	bridge.appendReplayLocked(acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "output",
		BridgeID: bridge.id,
		Sequence: 2,
		Data:     json.RawMessage(`{"jsonrpc":"2.0","method":"update"}`),
	}, "")
	bridge.mu.Unlock()
	conn, err := dialAcpBridge(bridge.id)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "hello",
		BridgeID: bridge.id,
	}); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	_ = readTestAcpFrame(t, reader, conn)
	overflow := readTestAcpFrame(t, reader, conn)
	if overflow.Type != "overflow" || overflow.RetainedFrom != 2 {
		t.Fatalf("overflow = %#v, want retained sequence 2", overflow)
	}
}

func TestAcpPendingProviderRequestSurvivesDetachAndBlocksIdleCleanup(t *testing.T) {
	bridge := newTestAcpBridge()
	bridge.publish("output", json.RawMessage(
		`{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission"}`,
	), "", nil)
	bridge.lastActivity = time.Now().Add(-acpIdleTimeout - time.Second)
	pending := len(bridge.pendingRequests)
	if pending != 1 {
		t.Fatalf("pending request count = %d, want 1", pending)
	}
	if bridge.shouldIdleShutdown(time.Now()) {
		t.Fatal("pending provider request allowed idle shutdown")
	}
}

func TestAcpReplayRetainsPendingProviderRequest(t *testing.T) {
	bridge := newTestAcpBridge()
	permission := json.RawMessage(
		`{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission"}`,
	)
	bridge.publish("output", permission, "", nil)
	bridge.replay = append(bridge.replay, acpReplayEvent{
		message: acpWireMessage{Sequence: 2},
		bytes:   acpReplayMaxBytes,
	})
	bridge.replayBytes += acpReplayMaxBytes
	bridge.trimReplayLocked()
	found := false
	for _, event := range bridge.replay {
		if event.pendingID == `"permission-1"` &&
			bytes.Equal(event.message.Data, permission) {
			found = true
		}
	}
	if !found {
		t.Fatal("pending provider request was evicted from replay")
	}
	bridge.observeClientMessage(parseAcpEnvelope(json.RawMessage(
		`{"jsonrpc":"2.0","id":"permission-1","result":{"outcome":"selected"}}`,
	)))
	if len(bridge.pendingRequests) != 0 {
		t.Fatal("provider request remained pending after its real response")
	}
}

func TestAcpIdleCleanupRequiresTrueIdle(t *testing.T) {
	bridge := newTestAcpBridge()
	bridge.lastActivity = time.Now().Add(-acpIdleTimeout - time.Second)
	if !bridge.shouldIdleShutdown(time.Now()) {
		t.Fatal("true idle bridge was not eligible for cleanup")
	}
	bridge.inFlightTurns["turn"] = struct{}{}
	if bridge.shouldIdleShutdown(time.Now()) {
		t.Fatal("in-flight turn allowed idle shutdown")
	}
}

func TestCursorAcpProviderRejectsLockedKeychainBeforeLaunch(t *testing.T) {
	originalGOOS := acpRuntimeGOOS
	originalProbe := cursorAgentKeychainProbe
	t.Cleanup(func() {
		acpRuntimeGOOS = originalGOOS
		cursorAgentKeychainProbe = originalProbe
	})
	t.Setenv("CURSOR_API_KEY", "")
	t.Setenv("AGENT_CLI_CREDENTIAL_STORE", "")
	acpRuntimeGOOS = "darwin"
	cursorAgentKeychainProbe = func() int { return 36 }

	bridge, err := newAcpBridge(
		"0123456789abcdef0123456789abcdef",
		cursorAgentAcpProviderID,
		"Cursor Agent",
		"exit 0",
		".",
	)
	if bridge != nil || !errors.Is(err, errCursorAgentKeychainLocked) {
		t.Fatalf("locked Cursor bridge = %#v, %v", bridge, err)
	}
}

func TestStartAcpBridgePreservesLockedKeychainError(t *testing.T) {
	originalGOOS := acpRuntimeGOOS
	originalProbe := cursorAgentKeychainProbe
	t.Cleanup(func() {
		acpRuntimeGOOS = originalGOOS
		cursorAgentKeychainProbe = originalProbe
	})
	t.Setenv("CURSOR_API_KEY", "")
	t.Setenv("AGENT_CLI_CREDENTIAL_STORE", "")
	acpRuntimeGOOS = "darwin"
	cursorAgentKeychainProbe = func() int { return 36 }

	bridgeID, err := startAcpBridgeInProcess(
		context.Background(),
		cursorAgentAcpProviderID,
		"Cursor Agent",
		"exit 0",
		".",
	)
	if bridgeID != "" || !errors.Is(err, errCursorAgentKeychainLocked) {
		t.Fatalf("locked Cursor start = %q, %v", bridgeID, err)
	}
}

func TestAcpProviderExitPublishesExitedState(t *testing.T) {
	dir := shortUnixSocketDir(t)
	t.Setenv("XDG_RUNTIME_DIR", dir)
	bridge, err := newAcpBridge(
		"0123456789abcdef0123456789abcdef",
		"",
		"test",
		"exit 7",
		".",
	)
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.stop()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		info := bridge.snapshot()
		if info.State == "exited" {
			if bridge.exitCode == nil || *bridge.exitCode != 7 {
				t.Fatalf("exit code = %#v, want 7", bridge.exitCode)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("provider did not enter exited state")
}

func TestAcpProviderCommandUsesPipesNotTerminal(t *testing.T) {
	bridge, err := newAcpBridge(
		"0123456789abcdef0123456789abcdef",
		"",
		"test",
		"test ! -t 0 && test ! -t 1",
		".",
	)
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.stop()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if bridge.snapshot().State == "exited" {
			if bridge.exitCode == nil || *bridge.exitCode != 0 {
				t.Fatalf("non-pipe provider exit = %#v", bridge.exitCode)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("provider did not exit")
}

func TestReplayHasGapIncludesTrailingHighWaterGap(t *testing.T) {
	replay := []acpReplayEvent{
		{message: acpWireMessage{Sequence: 3}},
		{message: acpWireMessage{Sequence: 4}},
	}
	if !replayHasGap(replay, 2, 6) {
		t.Fatal("expected missing trailing sequences 5-6 to be reported")
	}
	if replayHasGap(replay, 2, 4) {
		t.Fatal("contiguous replay through high-water was reported as incomplete")
	}
}

func TestReadProviderOutputFailsMalformedAndOversizedFrames(t *testing.T) {
	for _, test := range []struct {
		name   string
		output string
	}{
		{name: "malformed", output: "not-json\n"},
		{name: "oversized", output: strings.Repeat("x", acpMaxFrameBytes+1) + "\n"},
	} {
		t.Run(test.name, func(t *testing.T) {
			bridge := &acpBridge{
				state:        "running",
				providerDone: make(chan struct{}),
			}
			bridge.readProviderOutput(strings.NewReader(test.output))
			if bridge.state != "protocol_error" {
				t.Fatalf("state = %q, want protocol_error", bridge.state)
			}
			if len(bridge.replay) != 1 || bridge.replay[0].message.State != "protocol_error" {
				t.Fatalf("protocol failure replay = %#v", bridge.replay)
			}
		})
	}
}

func startTestAcpBridge(t *testing.T, command string) (*acpBridge, func()) {
	t.Helper()
	dir := shortUnixSocketDir(t)
	t.Setenv("XDG_RUNTIME_DIR", dir)
	id, err := newAcpBridgeID()
	if err != nil {
		t.Fatal(err)
	}
	bridge, err := newAcpBridge(id, "", "test", command, ".")
	if err != nil {
		t.Fatal(err)
	}
	errs := make(chan error, 1)
	go func() {
		errs <- serveAcpBridge(bridge)
	}()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if conn, err := dialAcpBridge(id); err == nil {
			_ = conn.Close()
			return bridge, func() {
				bridge.stop()
				select {
				case err := <-errs:
					if err != nil {
						t.Errorf("ACP serve: %v", err)
					}
				case <-time.After(time.Second):
					t.Error("ACP server did not stop")
				}
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	bridge.stop()
	t.Fatal("ACP socket did not start")
	return nil, nil
}

func readTestAcpFrame(
	t *testing.T,
	reader *bufio.Reader,
	conn net.Conn,
) acpWireMessage {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	message, err := readAcpWireFrame(reader)
	if err != nil {
		t.Fatal(err)
	}
	return message
}

func TestAcpWaitRejectsInvalidStatusFrame(t *testing.T) {
	for _, response := range []string{
		"invalid\n", "\n", `{"type":1}` + "\n",
		`{"version":1,"type":"status"}` + "\n",
		`{"version":1,"type":"error","bridge":{}}` + "\n",
		`{"version":2,"type":"status","bridge":{}}` + "\n",
	} {
		t.Run(response, func(t *testing.T) {
			polls := 0
			status := func(string) (acpBridgeInfo, error) {
				polls++
				if polls > acpWaitMaxFailures {
					t.Fatal("waiter kept polling invalid status frames")
				}
				client, server := net.Pipe()
				defer client.Close()
				done := make(chan struct{})
				go func() {
					defer close(done)
					defer server.Close()
					_ = server.SetDeadline(time.Now().Add(time.Second))
					request, err := readAcpWireFrame(bufio.NewReader(server))
					if err != nil || request.Command != "status" {
						t.Errorf("request = %+v, error = %v, want status only", request, err)
						return
					}
					_, _ = io.WriteString(server, response)
				}()
				info, err := acpBridgeStatusFromConn(client)
				<-done
				return info, err
			}
			// A ready clock avoids real polling delays while bounding a regression.
			ticks := make(chan time.Time)
			close(ticks)
			var output bytes.Buffer
			err := waitForAcpBridge("test", status, ticks, &output)
			var protocolErr *protocolFrameError
			if !errors.As(err, &protocolErr) {
				t.Fatalf("wait error = %v, want protocol error", err)
			}
			if polls != 1 {
				t.Fatalf("status polls = %d, want immediate exit after 1", polls)
			}
			if output.Len() != 0 {
				t.Fatalf("introduction printed without successful status: %q", output.String())
			}
		})
	}
}

func TestAcpWaitBoundsNonTransientFailures(t *testing.T) {
	for _, failure := range []error{errors.New("status unavailable"), io.EOF, os.ErrPermission} {
		t.Run(failure.Error(), func(t *testing.T) {
			polls := 0
			var lastErr error
			status := func(string) (acpBridgeInfo, error) {
				polls++
				if polls > acpWaitMaxFailures {
					t.Fatal("waiter exceeded failure limit")
				}
				lastErr = fmt.Errorf("poll %d: %w", polls, failure)
				return acpBridgeInfo{}, lastErr
			}
			ticks := make(chan time.Time)
			close(ticks)
			if err := waitForAcpBridge("test", status, ticks, io.Discard); err == nil || err != lastErr {
				t.Fatalf("wait error = %v, want last error %v", err, lastErr)
			}
			if polls != acpWaitMaxFailures {
				t.Fatalf("status polls = %d, want %d", polls, acpWaitMaxFailures)
			}
		})
	}
}

func TestAcpWaitResetsFailuresAfterTransientTimeoutsAndSuccess(t *testing.T) {
	for _, terminalState := range []string{"exited", "stopped", "protocol_error"} {
		t.Run(terminalState, func(t *testing.T) {
			var failures []error
			// Timeouts must not consume the bounded failure budget. A successful
			// status between two near-limit runs must reset that budget.
			for range 2 {
				for range acpWaitMaxFailures - 1 {
					failures = append(failures, io.EOF)
				}
				for range acpWaitMaxFailures + 1 {
					failures = append(failures, fmt.Errorf("status read: %w", os.ErrDeadlineExceeded))
				}
				failures = append(failures, nil)
			}
			var output bytes.Buffer
			polls := 0
			status := func(string) (acpBridgeInfo, error) {
				if polls >= len(failures) {
					t.Fatal("waiter polled after terminal status")
				}
				failure := failures[polls]
				polls++
				if polls <= len(failures)/2 && output.Len() != 0 {
					t.Fatal("introduction printed before first successful status")
				}
				state := "running"
				if polls == len(failures) {
					state = terminalState
				}
				return acpBridgeInfo{State: state, Provider: "Test agent"}, failure
			}
			ticks := make(chan time.Time)
			close(ticks)
			if err := waitForAcpBridge("test", status, ticks, &output); err != nil {
				t.Fatalf("wait error = %v, want recovery and normal exit", err)
			}
			if polls != len(failures) {
				t.Fatalf("status polls = %d, want %d", polls, len(failures))
			}
			if strings.Count(output.String(), "Native agent window: Test agent\r\n") != 1 {
				t.Fatalf("want exactly one introduction, got %q", output.String())
			}
		})
	}
}

type acpWaitTemporaryError struct{}

func (acpWaitTemporaryError) Error() string   { return "temporary network failure" }
func (acpWaitTemporaryError) Timeout() bool   { return false }
func (acpWaitTemporaryError) Temporary() bool { return true }

func TestAcpWaitClassifiesTransientStatusErrors(t *testing.T) {
	for _, err := range []error{
		context.DeadlineExceeded, os.ErrDeadlineExceeded, syscall.ECONNRESET,
		syscall.EAGAIN, syscall.EWOULDBLOCK, syscall.EINTR, acpWaitTemporaryError{},
	} {
		t.Run(err.Error(), func(t *testing.T) {
			if !isTransientAcpStatusError(fmt.Errorf("status: %w", err)) {
				t.Fatalf("%v was not classified as transient", err)
			}
		})
	}
	for _, err := range []error{io.EOF, os.ErrPermission, errors.New("unknown failure")} {
		if isTransientAcpStatusError(err) {
			t.Errorf("%v was classified as transient", err)
		}
	}
}

func TestAcpWaitSurvivesTransientStatusTimeout(t *testing.T) {
	for _, timeoutRequest := range []int{0, 1} {
		t.Run(fmt.Sprintf("timeout request %d", timeoutRequest), func(t *testing.T) {
			polls := 0
			status := func(string) (acpBridgeInfo, error) {
				index := polls
				polls++
				if polls > timeoutRequest+3 {
					t.Fatal("waiter polled after terminal status")
				}
				client, server := net.Pipe()
				defer client.Close()
				done := make(chan struct{})
				go func() {
					defer close(done)
					defer server.Close()
					_ = server.SetDeadline(time.Now().Add(2 * time.Second))
					request, err := readAcpWireFrame(bufio.NewReader(server))
					if err != nil || request.Command != "status" {
						t.Errorf("request = %+v, error = %v, want status only", request, err)
						return
					}
					if index == timeoutRequest {
						// Wait for the client's actual status deadline, then its close.
						_, _ = io.Copy(io.Discard, server)
						return
					}
					state := "running"
					if index == timeoutRequest+2 {
						state = "exited"
					}
					_ = writeAcpWireFrame(server, acpWireMessage{
						Version: acpBridgeProtocolVersion, Type: "status",
						Bridge: &acpBridgeInfo{State: state, Provider: "Test agent"},
					})
				}()
				info, err := acpBridgeStatusFromConn(client)
				_ = client.Close()
				<-done
				if index == timeoutRequest {
					var netErr net.Error
					if !errors.As(err, &netErr) || !netErr.Timeout() {
						t.Fatalf("status error = %v, want timeout", err)
					}
				}
				return info, err
			}
			ticker := time.NewTicker(500 * time.Millisecond)
			defer ticker.Stop()
			if err := waitForAcpBridge("test", status, ticker.C, io.Discard); err != nil {
				t.Fatalf("wait error = %v, want recovery and normal exit", err)
			}
			if polls != timeoutRequest+3 {
				t.Fatalf("status requests = %d, waiter exited before recovery", polls)
			}
		})
	}
}

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// These tests are untagged and use only untagged helpers, because CI vets the
// package for darwin and windows too.

type testLeaseClock struct {
	mu  sync.Mutex
	now time.Time
}

func newTestLeaseClock(bridge *acpBridge) *testLeaseClock {
	clock := &testLeaseClock{now: time.Unix(1_800_000_000, 0)}
	bridge.now = clock.Now
	return clock
}

func (c *testLeaseClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *testLeaseClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

const (
	testTokenIPad   = "ipad-process-token-0001"
	testTokenIPhone = "iphone-process-token-002"
	testPromptInput = `{"jsonrpc":"2.0","id":"prompt-1","method":"session/prompt","params":{"sessionId":"s"}}`
	testAllowAnswer = `{"jsonrpc":"2.0","id":"permission-1","result":{"outcome":{"outcome":"selected","optionId":"allow"}}}`
)

// attachLeaseClient attaches a lease-aware client and returns its hello.
func attachLeaseClient(
	t *testing.T,
	bridge *acpBridge,
	label string,
	token string,
	takeover bool,
) (net.Conn, *bufio.Reader, acpWireMessage) {
	t.Helper()
	conn, reader := attachTestClient(t, bridge, acpWireMessage{
		Capabilities: []string{acpWriterLeaseCapability},
		DeviceLabel:  label,
		ClientToken:  token,
		Takeover:     takeover,
		ReplayMode:   "adaptive",
	})
	return conn, reader, readTestAcpFrame(t, reader, conn)
}

func assertAdvertisesWriterLease(t *testing.T, hello acpWireMessage) {
	t.Helper()
	for _, capability := range hello.Capabilities {
		if capability == acpWriterLeaseCapability {
			return
		}
	}
	t.Fatalf("hello %#v does not advertise %q", hello, acpWriterLeaseCapability)
}

func assertLeaseLost(t *testing.T, message acpWireMessage, wantLabel string) {
	t.Helper()
	if message.Type != "lease" || message.CanSend || message.Writer == nil ||
		message.Writer.Label != wantLabel || message.Writer.IdleSeconds != 0 {
		t.Fatalf("lease notice = %#v (writer %#v), want lost to %q",
			message, message.Writer, wantLabel)
	}
}

func TestAcpWriterLeaseTakeoverMovesLeaseAndNotifiesOldWriter(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	newTestLeaseClock(bridge)

	ipad, ipadReader, ipadHello := attachLeaseClient(t, bridge, "iPad", testTokenIPad, false)
	if !ipadHello.CanSend {
		t.Fatalf("first client hello = %#v, want writer", ipadHello)
	}
	assertAdvertisesWriterLease(t, ipadHello)

	iphone, _, iphoneHello := attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, true)
	if !iphoneHello.CanSend || iphoneHello.Writer != nil {
		t.Fatalf("takeover hello = %#v, want writer", iphoneHello)
	}
	assertLeaseLost(t, readTestAcpFrame(t, ipadReader, ipad), "iPhone")

	// The old writer cannot reach the provider any more.
	sendTestClientInput(t, ipad, `{"jsonrpc":"2.0","id":"late","method":"session/prompt"}`)
	expectNoProviderLine(t, lines)

	sendTestClientInput(t, iphone, testPromptInput)
	if line := nextProviderLine(t, lines); line != testPromptInput {
		t.Fatalf("provider input = %s, want the new writer's prompt", line)
	}
	if info := bridge.snapshot(); info.ClientCount != 1 {
		t.Fatalf("client count = %d, want only the new writer", info.ClientCount)
	}
}

func TestAcpWriterLeaseCarriesPendingRequestsAndInFlightTurns(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	newTestLeaseClock(bridge)

	ipad, ipadReader, _ := attachLeaseClient(t, bridge, "iPad", testTokenIPad, false)
	sendTestClientInput(t, ipad, testPromptInput)
	if line := nextProviderLine(t, lines); line != testPromptInput {
		t.Fatalf("provider input = %s", line)
	}
	publishTestProviderFrame(t, bridge, testPermissionRequest)
	if output := readTestAcpFrame(t, ipadReader, ipad); output.Type != "output" ||
		!bytes.Contains(output.Data, []byte("permission-1")) {
		t.Fatalf("old writer output = %#v", output)
	}

	iphone, iphoneReader, hello := attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, true)
	if !hello.CanSend || hello.Bridge == nil ||
		hello.Bridge.PendingRequest != 1 || hello.Bridge.InFlightTurn != 1 ||
		hello.ReplayMode != "pending" {
		t.Fatalf("takeover hello = %#v (bridge %#v)", hello, hello.Bridge)
	}
	pending := readTestAcpFrame(t, iphoneReader, iphone)
	if pending.Type != "pending" || !bytes.Contains(pending.Data, []byte("permission-1")) {
		t.Fatalf("takeover pending frame = %#v, want the permission request", pending)
	}
	if end := readTestAcpFrame(t, iphoneReader, iphone); end.Type != "replay_end" {
		t.Fatalf("takeover replay end = %#v", end)
	}
	assertLeaseLost(t, readTestAcpFrame(t, ipadReader, ipad), "iPhone")

	// Moving the lease never answers the request on anyone's behalf, and the
	// old writer's late answer does not reach the provider.
	expectNoProviderLine(t, lines)
	sendTestClientInput(t, ipad, testAllowAnswer)
	expectNoProviderLine(t, lines)

	sendTestClientInput(t, iphone, testAllowAnswer)
	if line := nextProviderLine(t, lines); line != testAllowAnswer {
		t.Fatalf("provider input = %s, want the new writer's answer", line)
	}
	// The turn the old writer started finishes on the new writer.
	publishTestProviderFrame(t, bridge, `{"jsonrpc":"2.0","id":"prompt-1","result":{"stopReason":"end_turn"}}`)
	if output := readTestAcpFrame(t, iphoneReader, iphone); output.Type != "output" ||
		!bytes.Contains(output.Data, []byte("prompt-1")) {
		t.Fatalf("new writer output = %#v, want the prompt result", output)
	}
	if info := bridge.snapshot(); info.PendingRequest != 0 || info.InFlightTurn != 0 {
		t.Fatalf("after takeover: pending %d, in flight %d, want none",
			info.PendingRequest, info.InFlightTurn)
	}
}

func TestAcpWriterLeaseProbeReportsLiveWriterWithoutAttaching(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	clock := newTestLeaseClock(bridge)

	ipad, ipadReader, _ := attachLeaseClient(t, bridge, "iPad", testTokenIPad, false)
	clock.Advance(3 * time.Minute)
	// A heartbeat proves the writer is alive but is not input, so the
	// reported idle time keeps counting from its last input.
	if err := writeAcpWireFrame(ipad, acpWireMessage{
		Version: acpBridgeProtocolVersion,
		Type:    "status",
	}); err != nil {
		t.Fatal(err)
	}
	if status := readTestAcpFrame(t, ipadReader, ipad); status.Type != "status" {
		t.Fatalf("status reply = %#v", status)
	}
	clock.Advance(10 * time.Second)

	iphone, iphoneReader, probe := attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, false)
	if probe.CanSend || probe.Writer == nil || probe.Writer.Label != "iPad" ||
		probe.Writer.IdleSeconds != 190 || probe.Bridge == nil {
		t.Fatalf("probe hello = %#v (writer %#v)", probe, probe.Writer)
	}
	assertAdvertisesWriterLease(t, probe)
	if info := bridge.snapshot(); info.ClientCount != 1 {
		t.Fatalf("client count = %d, want the probe left unregistered", info.ClientCount)
	}
	// The probe gets nothing else, and the writer keeps its lease.
	sendTestClientInput(t, iphone, testPromptInput)
	_ = iphone.Close()
	_ = iphoneReader
	expectNoProviderLine(t, lines)
	sendTestClientInput(t, ipad, testPromptInput)
	if line := nextProviderLine(t, lines); line != testPromptInput {
		t.Fatalf("provider input = %s, want the writer's prompt", line)
	}
}

func TestAcpWriterLeaseStaleWriterIsReplacedOnAttach(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	clock := newTestLeaseClock(bridge)

	ipad, ipadReader, _ := attachLeaseClient(t, bridge, "iPad", testTokenIPad, false)
	// The iPad goes to sleep with its connection half-open: no heartbeat.
	clock.Advance(acpWriterStaleAfter - time.Second)
	_, _, early := attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, false)
	if early.CanSend {
		t.Fatalf("attach before the stale bound = %#v, want a probe", early)
	}

	clock.Advance(time.Second)
	iphone, _, hello := attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, false)
	if !hello.CanSend {
		t.Fatalf("attach after the stale bound = %#v, want writer", hello)
	}
	assertLeaseLost(t, readTestAcpFrame(t, ipadReader, ipad), "iPhone")
	sendTestClientInput(t, iphone, testPromptInput)
	if line := nextProviderLine(t, lines); line != testPromptInput {
		t.Fatalf("provider input = %s", line)
	}
}

func TestAcpWriterLeaseSameProcessReclaimsItsOwnLease(t *testing.T) {
	bridge, _ := newCancelTestBridge(t)
	newTestLeaseClock(bridge)

	old, oldReader, _ := attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, false)
	// The same app process reattaches after a network change while its old
	// connection is still open on the host.
	_, _, hello := attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, false)
	if !hello.CanSend {
		t.Fatalf("same-process reattach = %#v, want writer", hello)
	}
	assertLeaseLost(t, readTestAcpFrame(t, oldReader, old), "iPhone")
}

func TestAcpWriterLeaseDisconnectsDisplacedLegacyWriter(t *testing.T) {
	bridge, _ := newCancelTestBridge(t)
	newTestLeaseClock(bridge)

	legacy, legacyReader := attachTestClient(t, bridge, acpWireMessage{})
	if hello := readTestAcpFrame(t, legacyReader, legacy); !hello.CanSend {
		t.Fatalf("legacy writer hello = %#v", hello)
	}
	_, _, hello := attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, true)
	if !hello.CanSend {
		t.Fatalf("takeover hello = %#v", hello)
	}
	// A client that cannot read a lease frame is disconnected instead, so it
	// reattaches and reports the writer held elsewhere as it always has.
	_ = legacy.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := legacyReader.ReadByte(); !errors.Is(err, io.EOF) &&
		!errors.Is(err, io.ErrClosedPipe) {
		t.Fatalf("displaced legacy writer read = %v, want closed", err)
	}
}

func TestAcpWriterLeaseLegacyReaderCannotTakeOver(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	newTestLeaseClock(bridge)

	ipad, _, _ := attachLeaseClient(t, bridge, "iPad", testTokenIPad, false)
	// Without the capability the takeover flag is ignored and the attach is
	// the reader it always was.
	legacy, legacyReader := attachTestClient(t, bridge, acpWireMessage{Takeover: true})
	hello := readTestAcpFrame(t, legacyReader, legacy)
	if hello.CanSend || hello.Writer != nil {
		t.Fatalf("legacy reader hello = %#v", hello)
	}
	sendTestClientInput(t, legacy, testPromptInput)
	if reply := readTestAcpFrame(t, legacyReader, legacy); reply.Type != "error" ||
		reply.Error != "ACP bridge is attached by another writer" {
		t.Fatalf("legacy reader input reply = %#v", reply)
	}
	expectNoProviderLine(t, lines)
	sendTestClientInput(t, ipad, testPromptInput)
	if line := nextProviderLine(t, lines); line != testPromptInput {
		t.Fatalf("provider input = %s", line)
	}
}

func TestAcpWriterLeaseIgnoresMalformedTokens(t *testing.T) {
	bridge, _ := newCancelTestBridge(t)
	newTestLeaseClock(bridge)

	attachLeaseClient(t, bridge, "iPad", "short", false)
	_, _, hello := attachLeaseClient(t, bridge, "iPhone", "short", false)
	if hello.CanSend {
		t.Fatalf("attach with a malformed shared token = %#v, want a probe", hello)
	}
}

func TestSanitizeAcpDeviceLabel(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want string
	}{
		{"iPad", "iPad"},
		{"  Android \t tablet ", "Android tablet"},
		{"line\nbreak", "line break"},
		{"bell\a", ""},
		{"\xff", ""},
		{strings.Repeat("x", acpDeviceLabelMaxRunes), strings.Repeat("x", acpDeviceLabelMaxRunes)},
		{strings.Repeat("x", acpDeviceLabelMaxRunes+1), ""},
	} {
		if got := sanitizeAcpDeviceLabel(tc.in); got != tc.want {
			t.Errorf("sanitizeAcpDeviceLabel(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// writerClient returns the client currently holding the lease.
func writerClient(t *testing.T, bridge *acpBridge) *acpBridgeClient {
	t.Helper()
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	client := bridge.clients[bridge.writerClientID]
	if client == nil {
		t.Fatal("no writer is attached")
	}
	return client
}

func TestAcpWriterLeaseClosesDisplacedWriterThatStoppedReading(t *testing.T) {
	bridge, _ := newCancelTestBridge(t)
	newTestLeaseClock(bridge)
	bridge.leaseLinger = 50 * time.Millisecond

	attachLeaseClient(t, bridge, "iPad", testTokenIPad, false)
	ipad := writerClient(t, bridge)
	// The iPad is asleep: its socket is full, so the bridge's write blocks.
	publishTestProviderFrame(t, bridge, `{"jsonrpc":"2.0","method":"unread"}`)
	attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, true)

	select {
	case <-ipad.done:
	case <-time.After(time.Second):
		t.Fatal("displaced writer that stopped reading was never closed")
	}
}

func TestAcpWriterLeaseNoticePreemptsQueuedOutput(t *testing.T) {
	bridge, _ := newCancelTestBridge(t)
	newTestLeaseClock(bridge)

	ipad, ipadReader, _ := attachLeaseClient(t, bridge, "iPad", testTokenIPad, false)
	for index := 0; index < 3; index++ {
		publishTestProviderFrame(t, bridge, `{"jsonrpc":"2.0","method":"queued"}`)
	}
	attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, true)

	// At most the frame already being written gets through before the notice.
	for {
		message := readTestAcpFrame(t, ipadReader, ipad)
		if message.Type == "lease" {
			assertLeaseLost(t, message, "iPhone")
			return
		}
		if message.Sequence > 1 {
			t.Fatalf("displaced writer still received output %#v", message)
		}
	}
}

func TestAcpWriterLeaseNoticeCountsAcceptedInputs(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	newTestLeaseClock(bridge)

	ipad, ipadReader, _ := attachLeaseClient(t, bridge, "iPad", testTokenIPad, false)
	sendTestClientInput(t, ipad, `{"jsonrpc":"2.0","method":"one"}`)
	sendTestClientInput(t, ipad, `{"jsonrpc":"2.0","method":"two"}`)
	_ = nextProviderLine(t, lines)
	_ = nextProviderLine(t, lines)
	attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, true)

	notice := readTestAcpFrame(t, ipadReader, ipad)
	assertLeaseLost(t, notice, "iPhone")
	// The client compares this with the frames it wrote: anything after the
	// second never reached the provider.
	if notice.AcceptedInputs != 2 {
		t.Fatalf("accepted inputs = %d, want 2", notice.AcceptedInputs)
	}
}

func TestAcpAnsweredRequestIsNeitherReplayedNorAnsweredTwice(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	newTestLeaseClock(bridge)
	publishTestProviderFrame(t, bridge, testPermissionRequest)

	// The iPad's answer has been claimed but its write to the provider has
	// not finished when the iPhone takes over.
	if !bridge.claimClientResponse(parseAcpEnvelope(json.RawMessage(testAllowAnswer))) {
		t.Fatal("first answer was not forwarded")
	}
	iphone, iphoneReader, hello := attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, true)
	if hello.Bridge == nil || hello.Bridge.PendingRequest != 0 {
		t.Fatalf("takeover hello = %#v, want no pending requests", hello.Bridge)
	}
	if next := readTestAcpFrame(t, iphoneReader, iphone); next.Type != "replay_end" {
		t.Fatalf("takeover replayed %#v, want only replay_end", next)
	}
	// A second answer to the same request must never reach the provider.
	sendTestClientInput(t, iphone, `{"jsonrpc":"2.0","id":"permission-1","result":{"outcome":{"outcome":"selected","optionId":"deny"}}}`)
	expectNoProviderLine(t, lines)
}

func TestAcpWriterLeaseKeepsLegacyWriterUntilAskedToTakeOver(t *testing.T) {
	bridge, _ := newCancelTestBridge(t)
	clock := newTestLeaseClock(bridge)

	legacy, legacyReader := attachTestClient(t, bridge, acpWireMessage{})
	_ = readTestAcpFrame(t, legacyReader, legacy)
	// An older app sends nothing while its user reads, so silence does not
	// mean it is gone.
	clock.Advance(acpWriterStaleAfter + time.Minute)
	_, _, probe := attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, false)
	if probe.CanSend || probe.Writer == nil {
		t.Fatalf("attach over a quiet legacy writer = %#v, want a probe", probe)
	}
	_, _, hello := attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, true)
	if !hello.CanSend {
		t.Fatalf("explicit takeover = %#v, want writer", hello)
	}
}

func TestAcpWriterLeaseHeartbeatKeepsLeasePastStaleBound(t *testing.T) {
	bridge, _ := newCancelTestBridge(t)
	clock := newTestLeaseClock(bridge)

	ipad, ipadReader, _ := attachLeaseClient(t, bridge, "iPad", testTokenIPad, false)
	for elapsed := time.Duration(0); elapsed < 2*acpWriterStaleAfter; elapsed += 30 * time.Second {
		clock.Advance(30 * time.Second)
		if err := writeAcpWireFrame(ipad, acpWireMessage{
			Version: acpBridgeProtocolVersion,
			Type:    "ack",
		}); err != nil {
			t.Fatal(err)
		}
	}
	// A status round trip proves the bridge read every heartbeat.
	if err := writeAcpWireFrame(ipad, acpWireMessage{
		Version: acpBridgeProtocolVersion,
		Type:    "status",
	}); err != nil {
		t.Fatal(err)
	}
	if status := readTestAcpFrame(t, ipadReader, ipad); status.Type != "status" {
		t.Fatalf("status reply = %#v", status)
	}
	_, _, probe := attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, false)
	if probe.CanSend {
		t.Fatalf("attach over a heartbeating writer = %#v, want a probe", probe)
	}
}

func TestAcpWriterLeaseResumeAfterAnotherWriterIsAProbe(t *testing.T) {
	bridge, _ := newCancelTestBridge(t)
	newTestLeaseClock(bridge)
	publishTestProviderFrame(t, bridge, `{"jsonrpc":"2.0","method":"history"}`)

	attachLeaseClient(t, bridge, "iPad", testTokenIPad, false)
	iphone, _, _ := attachLeaseClient(t, bridge, "iPhone", testTokenIPhone, true)
	// The iPhone leaves, so the lease is free when the iPad wakes up and
	// resumes from its old position.
	_ = iphone.Close()
	waitForNoWriter(t, bridge)

	ipad, ipadReader := attachTestClient(t, bridge, acpWireMessage{
		Capabilities: []string{acpWriterLeaseCapability},
		DeviceLabel:  "iPad",
		ClientToken:  testTokenIPad,
		LastAck:      1,
	})
	probe := readTestAcpFrame(t, ipadReader, ipad)
	// Replaying from there would hand it requests the iPhone already
	// answered, so it must take the chat back with a fresh attach instead.
	if probe.CanSend || probe.Writer == nil || probe.Writer.Label != "iPhone" {
		t.Fatalf("resume after another writer = %#v (writer %#v), want a probe",
			probe, probe.Writer)
	}
}

func TestAcpWriterLeaseSameProcessResumesNormally(t *testing.T) {
	bridge, _ := newCancelTestBridge(t)
	newTestLeaseClock(bridge)
	publishTestProviderFrame(t, bridge, `{"jsonrpc":"2.0","method":"history"}`)

	first, _, _ := attachLeaseClient(t, bridge, "iPad", testTokenIPad, false)
	_ = first.Close()
	waitForNoWriter(t, bridge)

	ipad, ipadReader := attachTestClient(t, bridge, acpWireMessage{
		Capabilities: []string{acpWriterLeaseCapability},
		DeviceLabel:  "iPad",
		ClientToken:  testTokenIPad,
		LastAck:      1,
	})
	if hello := readTestAcpFrame(t, ipadReader, ipad); !hello.CanSend {
		t.Fatalf("same-process resume = %#v, want writer", hello)
	}
}

func TestAcpWriterLeaseStatusReportsTheWriter(t *testing.T) {
	bridge, _ := newCancelTestBridge(t)
	clock := newTestLeaseClock(bridge)

	attachLeaseClient(t, bridge, "iPad", testTokenIPad, false)
	clock.Advance(time.Minute)
	info := bridge.snapshot()
	if info.Writer == nil || info.Writer.Label != "iPad" ||
		info.Writer.IdleSeconds != 60 || info.Writer.Stale {
		t.Fatalf("status writer = %#v", info.Writer)
	}
	clock.Advance(acpWriterStaleAfter)
	if info := bridge.snapshot(); info.Writer == nil || !info.Writer.Stale {
		t.Fatalf("silent writer = %#v, want stale", info.Writer)
	}
}

func TestAcpWriterLeaseConcurrentTakeoversLeaveOneWriter(t *testing.T) {
	bridge, lines := newCancelTestBridge(t)
	newTestLeaseClock(bridge)
	bridge.leaseLinger = 50 * time.Millisecond

	const clients = 6
	var wait sync.WaitGroup
	for index := 0; index < clients; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			server, peer := net.Pipe()
			go func() {
				reader := bufio.NewReader(peer)
				for {
					if _, err := readAcpWireFrame(reader); err != nil {
						return
					}
				}
			}()
			t.Cleanup(func() { _ = peer.Close() })
			go bridge.handleAttach(server, bufio.NewReader(server), acpWireMessage{
				Version:      acpBridgeProtocolVersion,
				Type:         "hello",
				Capabilities: []string{acpWriterLeaseCapability},
				DeviceLabel:  "device",
				ClientToken:  strings.Repeat(string(rune('a'+index)), 20),
				Takeover:     true,
			})
		}()
	}
	wait.Wait()
	deadline := time.Now().Add(time.Second)
	for {
		bridge.mu.Lock()
		count := len(bridge.clients)
		writer := bridge.clients[bridge.writerClientID]
		bridge.mu.Unlock()
		if count == 1 && writer != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("clients = %d, writer = %v, want exactly the writer", count, writer)
		}
		time.Sleep(5 * time.Millisecond)
	}
	expectNoProviderLine(t, lines)
}

func waitForNoWriter(t *testing.T, bridge *acpBridge) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for {
		bridge.mu.Lock()
		free := bridge.clients[bridge.writerClientID] == nil
		bridge.mu.Unlock()
		if free {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("the writer never detached")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

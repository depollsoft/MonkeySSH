package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// Regression tests for the round-1 review of PR #965.

func (h *pushTestHarness) registerResult(t *testing.T, device pushTestDevice) controlResponse {
	t.Helper()
	return h.control(t, controlMessage{
		ID:   "r",
		Type: "push_register",
		Push: &pushControlRequest{
			DeviceID:  device.record.DeviceID,
			Ticket:    device.record.Ticket,
			PublicKey: device.record.PublicKey,
			HostRef:   device.record.HostRef,
		},
	})
}

func (h *pushTestHarness) presenceLocal(t *testing.T, device pushTestDevice, clientID string) {
	t.Helper()
	response := h.control(t, controlMessage{
		Type:     "push_presence",
		ClientID: clientID,
		Push: &pushControlRequest{
			DeviceID: device.id,
			Local:    true,
			Alerts:   true,
			Bridges:  []string{"0123456789abcdef0123456789abcde1"},
		},
	})
	if response.Status != "ok" {
		t.Fatalf("presence response = %+v", response)
	}
}

func (h *pushTestHarness) kinds() string {
	requests := h.endpoint.received()
	kinds := make([]string, 0, len(requests))
	for _, request := range requests {
		kinds = append(kinds, request.Kind)
	}
	return strings.Join(kinds, ",")
}

func TestPushStoreLocksTheFileAcrossServers(t *testing.T) {
	h := newPushTestHarness(t)
	other := newPushNotifier()
	other.now = h.clock.Now
	first := newPushTestDevice(t, 1)
	second := newPushTestDevice(t, 2)

	release := make(chan struct{})
	paused := make(chan struct{})
	var once sync.Once
	firstDone := make(chan error, 1)
	go func() {
		firstDone <- h.notifier.store.mutate(func(state *pushStateFile, now time.Time) bool {
			upsertPushRecord(state, first.record, now)
			once.Do(func() { close(paused) })
			<-release
			return true
		})
	}()
	<-paused
	secondDone := make(chan error, 1)
	go func() {
		_, err := other.register(second.record)
		secondDone <- err
	}()
	select {
	case err := <-secondDone:
		t.Fatalf("second server wrote while the first held the file: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	if err := <-firstDone; err != nil {
		t.Fatal(err)
	}
	if err := <-secondDone; err != nil {
		t.Fatal(err)
	}
	ids := h.registeredIDs(t)
	if len(ids) != 2 {
		t.Fatalf("lost an update across servers: %v", ids)
	}
}

func TestPushRejectedTicketAsksTheAppForANewOne(t *testing.T) {
	for _, tc := range []struct {
		status int
		result string
	}{
		{http.StatusUnauthorized, pushResultStaleTicket},
		{http.StatusGone, pushResultTokenUnregistered},
	} {
		t.Run(tc.result, func(t *testing.T) {
			h := newPushTestHarness(t, tc.status)
			phone := newPushTestDevice(t, 1)
			h.register(t, phone)
			h.raise("@1", pushKindAlert)
			if ids := h.registeredIDs(t); len(ids) != 0 {
				t.Fatalf("rejected registration kept: %v", ids)
			}

			// A fresh attach that offers the same ticket is refused with a
			// reason, so the app fetches a new ticket instead of looping.
			response := h.registerResult(t, phone)
			if response.Type != "push_register_rejected" || response.Push == nil ||
				response.Push.Result != tc.result {
				t.Fatalf("stale register response = %+v", response)
			}
			if ids := h.registeredIDs(t); len(ids) != 0 {
				t.Fatalf("stale ticket reinstalled: %v", ids)
			}

			phone.record.Ticket = "v1.k2.fresh"
			response = h.registerResult(t, phone)
			if response.Type != "push_registered" || response.Push.Result != pushResultRegistered {
				t.Fatalf("fresh register response = %+v", response)
			}
			path, _ := pushStatePath()
			data, _ := os.ReadFile(path)
			if strings.Contains(string(data), `"rejected"`) {
				t.Fatal("a fresh ticket left the device's rejections behind")
			}
		})
	}
}

func TestPushPendingPermissionIsRaisedWhenTheGraceEnds(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	h.server.mu.Lock()
	h.server.activeID = "@7"
	h.server.mu.Unlock()
	h.presence(t, phone, "phone-client", true)

	// The user sends a prompt and locks the phone; the agent then asks.
	h.presence(t, phone, "phone-client", false)
	const bridgeID = "0123456789abcdef0123456789abcdef"
	h.server.raisePushAttention("@7", bridgeID, pushKindPermission, 1, nil)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "" {
		t.Fatalf("pushed inside the view grace: %s", got)
	}
	h.clock.Advance(pushViewGrace + time.Second)
	h.server.raisePushAttention("@7", bridgeID, pushKindPermission, 1, nil)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "permission" {
		t.Fatalf("pending permission after the grace = %q", got)
	}
	// Delivered once; later polls of the same request stay quiet.
	h.clock.Advance(pushCoalesceWindow)
	h.server.raisePushAttention("@7", bridgeID, pushKindPermission, 1, nil)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "permission" {
		t.Fatalf("same request pushed twice: %q", got)
	}
}

func TestPushPendingPermissionIsRaisedAfterABackoff(t *testing.T) {
	h := newPushTestHarness(t, http.StatusTooManyRequests)
	h.endpoint.headers["Retry-After"] = "60"
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	const bridgeID = "0123456789abcdef0123456789abcdef"
	h.server.raisePushAttention("@7", bridgeID, pushKindPermission, 1, nil)
	h.notifier.inflight.Wait()
	h.server.raisePushAttention("@7", bridgeID, pushKindPermission, 1, nil)
	h.notifier.inflight.Wait()
	if got := len(h.endpoint.received()); got != 1 {
		t.Fatalf("sent during backoff: %d", got)
	}
	h.clock.Advance(61 * time.Second)
	h.server.raisePushAttention("@7", bridgeID, pushKindPermission, 1, nil)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "permission,permission" {
		t.Fatalf("rate-limited request was not raised again: %q", got)
	}
}

func TestPushRoutineEventsLeaveTheUrgentBudgetAlone(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	for index := 0; index < pushHourlyCap+5; index++ {
		h.raise(fmt.Sprintf("@%d", 100+index), pushKindAlert)
	}
	if got := len(h.endpoint.received()); got != pushHourlyCap {
		t.Fatalf("routine sends = %d", got)
	}
	h.raise("@1", pushKindPermission)
	if got := len(h.endpoint.received()); got != pushHourlyCap+1 {
		t.Fatal("routine events used up the approval budget")
	}

	// A 429 on a routine event backs off routine events only.
	h2 := newPushTestHarness(t, http.StatusTooManyRequests)
	other := newPushTestDevice(t, 2)
	h2.register(t, other)
	h2.raise("@1", pushKindFinished)
	h2.raise("@2", pushKindAlert)
	h2.raise("@3", pushKindPermission)
	if got := h2.kinds(); got != "finished,permission" {
		t.Fatalf("after a routine 429: %q", got)
	}
}

func TestPushLocalPresenceCoversWhatTheAppAlertsFor(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	h.presenceLocal(t, phone, "phone-client")

	h.raise("@2", pushKindAlert)
	h.server.raisePushEvent("@3", pushKindFinished, "0123456789abcdef0123456789abcde1")
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "" {
		t.Fatalf("pushed what the backgrounded app alerts for: %q", got)
	}
	// A bridge the app is not attached to still pushes.
	h.server.raisePushEvent("@4", pushKindFinished, "0123456789abcdef0123456789abcde2")
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "finished" {
		t.Fatalf("unattached bridge event = %q", got)
	}
	// Once the background heartbeat stops, push takes over.
	h.clock.Advance(pushPresenceTTL + time.Second)
	h.raise("@5", pushKindAlert)
	if got := h.kinds(); got != "finished,alert" {
		t.Fatalf("after the heartbeat stopped = %q", got)
	}
}

func TestPushTwoSavedHostsOfOneMachineSendOnceAndUnregisterSeparately(t *testing.T) {
	h := newPushTestHarness(t)
	lan := newPushTestDevice(t, 1)
	tailnet := lan
	tailnet.record.HostRef = "tailnetRef"
	h.register(t, lan)
	h.clock.Advance(time.Second)
	h.register(t, tailnet)

	h.raise("@1", pushKindPermission)
	if got := len(h.endpoint.received()); got != 1 {
		t.Fatalf("one event for one device sent %d times", got)
	}

	response := h.control(t, controlMessage{
		Type: "push_unregister",
		Push: &pushControlRequest{DeviceID: lan.id, HostRef: tailnet.record.HostRef},
	})
	if response.Type != "push_unregistered" {
		t.Fatalf("unregister = %+v", response)
	}
	devices, _ := h.notifier.store.snapshot()
	if len(devices) != 1 || devices[0].HostRef != lan.record.HostRef {
		t.Fatalf("turning one saved host off removed the other: %+v", devices)
	}
	h.raise("@2", pushKindPermission)
	requests := h.endpoint.received()
	var event struct {
		HostRef string `json:"hostRef"`
	}
	_ = json.Unmarshal(openPushPayloadForTest(t, lan.private, requests[len(requests)-1].Payload), &event)
	if len(requests) != 2 || event.HostRef != lan.record.HostRef {
		t.Fatalf("remaining saved host event = %+v (%d sends)", event, len(requests))
	}
}

func TestPushCapsRecordsPerDevice(t *testing.T) {
	h := newPushTestHarness(t)
	device := newPushTestDevice(t, 1)
	for index := 0; index <= pushMaxRecordsPerDevice; index++ {
		device.record.HostRef = fmt.Sprintf("ref%d", index)
		h.register(t, device)
		h.clock.Advance(time.Second)
	}
	devices, _ := h.notifier.store.snapshot()
	if len(devices) != pushMaxRecordsPerDevice {
		t.Fatalf("records = %d", len(devices))
	}
	for _, record := range devices {
		if record.HostRef == "ref0" {
			t.Fatal("the oldest saved host was not evicted")
		}
	}
}

func TestPushRegistrationsExpireWhenTheAppStopsRefreshingThem(t *testing.T) {
	h := newPushTestHarness(t)
	h.register(t, newPushTestDevice(t, 1))
	h.clock.Advance(pushRecordTTL + time.Hour)
	h.raise("@1", pushKindAlert)
	if got := len(h.endpoint.received()); got != 0 {
		t.Fatalf("expired registration still pushed %d times", got)
	}
}

func TestPushNeverOverwritesANewerStateFile(t *testing.T) {
	h := newPushTestHarness(t)
	path, _ := pushStatePath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	newer := []byte(`{"version":2,"devices":[{"future":true}]}`)
	if err := os.WriteFile(path, newer, 0o600); err != nil {
		t.Fatal(err)
	}
	response := h.registerResult(t, newPushTestDevice(t, 1))
	if response.Status != "error" {
		t.Fatalf("registered over a newer file: %+v", response)
	}
	data, _ := os.ReadFile(path)
	if string(data) != string(newer) {
		t.Fatal("newer state file was overwritten")
	}
}

func TestPushAlertQueueNeverBlocksTheReader(t *testing.T) {
	h := newPushTestHarness(t)
	h.server.notePushAlert("@1")
	if got := len(h.notifier.alerts); got != 0 {
		t.Fatalf("queued %d alerts with nothing registered", got)
	}
	h.register(t, newPushTestDevice(t, 1))
	done := make(chan struct{})
	go func() {
		for index := 0; index < pushEventQueueSize*4; index++ {
			h.server.notePushAlert("@1")
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("a full alert queue blocked the PTY reader")
	}
	if got := len(h.notifier.alerts); got != pushEventQueueSize {
		t.Fatalf("queued %d alerts, want a full queue", got)
	}
}

func TestPushBridgeStatusErrorKeepsTheBaseline(t *testing.T) {
	h := newPushTestHarness(t)
	h.register(t, newPushTestDevice(t, 1))
	const bridgeID = "0123456789abcdef0123456789abcdef"
	h.server.mu.Lock()
	h.server.windows = append(h.server.windows, &muxWindow{id: "@7", nativeAcpBridgeID: bridgeID})
	h.server.mu.Unlock()
	var mu sync.Mutex
	status := acpBridgeInfo{ID: bridgeID, StartedAt: 100}
	failing := false
	previous := pushBridgeStatus
	pushBridgeStatus = func(string) (acpBridgeInfo, error) {
		mu.Lock()
		defer mu.Unlock()
		if failing {
			return acpBridgeInfo{}, errors.New("timeout")
		}
		return status, nil
	}
	t.Cleanup(func() { pushBridgeStatus = previous })
	poll := func() {
		h.server.pollPushBridges()
		h.notifier.inflight.Wait()
	}
	poll()
	mu.Lock()
	failing = true
	mu.Unlock()
	poll()
	mu.Lock()
	failing = false
	status.CompletedTurns = 1
	mu.Unlock()
	poll()
	if got := h.kinds(); got != "finished" {
		t.Fatalf("turn that finished during a failed status read = %q", got)
	}
}

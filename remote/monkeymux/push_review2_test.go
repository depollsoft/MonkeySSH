package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"
)

// Regression tests for the round-2 review of PR #965.

const pushTestBridgeID = "0123456789abcdef0123456789abcdef"

func (h *pushTestHarness) presenceReport(t *testing.T, device pushTestDevice, clientID string, report pushControlRequest) {
	t.Helper()
	report.DeviceID = device.id
	response := h.control(t, controlMessage{Type: "push_presence", ClientID: clientID, Push: &report})
	if response.Status != "ok" {
		t.Fatalf("presence response = %+v", response)
	}
}

func TestPushLocalCoverageIsPerDeviceBridgeAndAlertListener(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	// Backgrounded with this connection alive, but its window bar is not
	// mounted and it is attached to no bridge (another device has the chat).
	h.presenceReport(t, phone, "phone-client", pushControlRequest{Local: true})

	h.raise("@2", pushKindAlert)
	h.server.raisePushEvent("@3", pushKindFinished, pushTestBridgeID)
	h.server.raisePushAttention("@3", pushTestBridgeID, pushKindPermission, 1, nil)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "alert,finished,permission" {
		t.Fatalf("events nobody raises locally = %q", got)
	}
}

func TestPushLocalClaimLapsesAfterOneHeartbeat(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	h.presenceReport(t, phone, "phone-client", pushControlRequest{Local: true, Alerts: true})
	h.raise("@2", pushKindAlert)
	if got := h.kinds(); got != "" {
		t.Fatalf("covered alert sent: %q", got)
	}
	// iOS suspends the app before the 45-second presence TTL; the local claim
	// itself must not outlive one heartbeat.
	h.clock.Advance(pushLocalTTL + time.Second)
	h.raise("@3", pushKindAlert)
	if got := h.kinds(); got != "alert" {
		t.Fatalf("alert after the local claim lapsed = %q", got)
	}
}

func TestPushDeferredEventIsSentWhenLocalCoverageLapses(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	h.presenceReport(t, phone, "phone-client", pushControlRequest{
		Local:   true,
		Bridges: []string{pushTestBridgeID},
	})
	h.server.raisePushEvent("@7", pushKindFinished, pushTestBridgeID)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "" {
		t.Fatalf("covered turn sent at once: %q", got)
	}
	// The app is suspended before it raised anything.
	h.clock.Advance(pushLocalTTL + time.Second)
	h.server.flushPushDeferred()
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "finished" {
		t.Fatalf("deferred turn after coverage lapsed = %q", got)
	}

	// While the app keeps covering it, the event is dropped after the window.
	h.presenceReport(t, phone, "phone-client", pushControlRequest{
		Local:   true,
		Bridges: []string{pushTestBridgeID},
	})
	h.server.raisePushEvent("@8", pushKindFinished, pushTestBridgeID)
	for elapsed := time.Duration(0); elapsed <= pushDeferWindow; elapsed += 20 * time.Second {
		h.clock.Advance(20 * time.Second)
		h.presenceReport(t, phone, "phone-client", pushControlRequest{
			Local:   true,
			Bridges: []string{pushTestBridgeID},
		})
		h.server.flushPushDeferred()
	}
	h.clock.Advance(pushLocalTTL + time.Second)
	h.server.flushPushDeferred()
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "finished" {
		t.Fatalf("an event the app covered was sent later: %q", got)
	}
}

func TestPushLegacyBridgeStatusStillRaisesPendingRequests(t *testing.T) {
	h := newPushTestHarness(t)
	h.register(t, newPushTestDevice(t, 1))
	h.server.mu.Lock()
	h.server.windows = append(h.server.windows, &muxWindow{id: "@7", nativeAcpBridgeID: pushTestBridgeID})
	h.server.mu.Unlock()
	var raw []byte
	previous := pushBridgeStatus
	pushBridgeStatus = func(string) (acpBridgeInfo, error) {
		var info acpBridgeInfo
		err := json.Unmarshal(raw, &info)
		return info, err
	}
	t.Cleanup(func() { pushBridgeStatus = previous })
	// What a bridge from an earlier build reports: one combined count.
	raw = []byte(`{"id":"` + pushTestBridgeID + `","state":"running","clientCount":0,` +
		`"pendingRequestCount":1,"inFlightTurnCount":0,"lastActivityUnix":0,` +
		`"startedAtUnix":5,"nextSequence":3,"permissionRequestCount":1,"pendingAttentionCount":1}`)
	h.server.pollPushBridges()
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "permission" {
		t.Fatalf("legacy bridge pending request = %q", got)
	}
}

func TestPushTestsHaveTheirOwnBudget(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	for index := 0; index < pushHourlyCap; index++ {
		h.control(t, controlMessage{Type: "push_test", Push: &pushControlRequest{DeviceID: phone.id}})
	}
	capped := h.control(t, controlMessage{Type: "push_test", Push: &pushControlRequest{DeviceID: phone.id}})
	if capped.Push == nil || capped.Push.Result != pushResultCapped {
		t.Fatalf("test past its cap = %+v", capped)
	}
	h.raise("@1", pushKindPermission)
	if got := len(h.endpoint.received()); got != pushHourlyCap+1 {
		t.Fatal("tests used up the approval budget")
	}
}

func TestPushPermanentRejectionIsNotRetried(t *testing.T) {
	for _, status := range []int{http.StatusBadRequest, http.StatusRequestEntityTooLarge, http.StatusUnsupportedMediaType} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			h := newPushTestHarness(t, status, status, status)
			h.register(t, newPushTestDevice(t, 1))
			h.server.raisePushAttention("@7", pushTestBridgeID, pushKindPermission, 1, nil)
			h.notifier.inflight.Wait()
			h.clock.Advance(pushCoalesceWindow + time.Second)
			h.server.raisePushAttention("@7", pushTestBridgeID, pushKindPermission, 1, nil)
			h.notifier.inflight.Wait()
			if got := len(h.endpoint.received()); got != 1 {
				t.Fatalf("a refused event was sent %d times", got)
			}
		})
	}
}

func TestPushDeliveryRecordInTheBridgeSurvivesTheServer(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	var mu sync.Mutex
	recorded := map[string]uint64{}
	pushRecordBridgeDelivered = func(bridgeID string, deviceID string, kind string, generation uint64) error {
		mu.Lock()
		defer mu.Unlock()
		recorded[bridgeID+"/"+acpPushDeliveredKey(deviceID, kind)] = generation
		return nil
	}
	h.server.raisePushAttention("@7", pushTestBridgeID, pushKindPermission, 3, nil)
	h.notifier.inflight.Wait()
	mu.Lock()
	got := recorded[pushTestBridgeID+"/"+acpPushDeliveredKey(phone.id, pushKindPermission)]
	mu.Unlock()
	if got != 3 {
		t.Fatalf("bridge delivery record = %d", got)
	}

	// A replacement server starts with no memory but reads the bridge's.
	fresh := newPushTestHarness(t)
	fresh.register(t, phone)
	fresh.server.raisePushAttention("@7", pushTestBridgeID, pushKindPermission, 3,
		map[string]uint64{acpPushDeliveredKey(phone.id, pushKindPermission): 3})
	fresh.notifier.inflight.Wait()
	if got := len(fresh.endpoint.received()); got != 0 {
		t.Fatalf("a successor re-sent a delivered approval %d times", got)
	}
}

func TestAcpBridgeStoresPushDeliveryRecords(t *testing.T) {
	bridge := newTestAcpBridge()
	send := func(record any) acpWireMessage {
		t.Helper()
		server, client := net.Pipe()
		defer client.Close()
		data, _ := json.Marshal(record)
		go func() {
			defer server.Close()
			bridge.handleCommand(server, acpWireMessage{
				Version: acpBridgeProtocolVersion,
				Type:    "command",
				Command: acpPushDeliveredCommand,
				Data:    data,
			})
		}()
		_ = client.SetDeadline(time.Now().Add(2 * time.Second))
		message, err := readAcpWireFrame(bufio.NewReader(client))
		if err != nil {
			t.Fatal(err)
		}
		return message
	}
	if reply := send(acpPushDeliveredRecord{DeviceID: "device_0000000000000001", Kind: "permission", Generation: 4}); reply.Type != acpPushDeliveredCommand {
		t.Fatalf("reply = %+v", reply)
	}
	if reply := send(map[string]any{"deviceId": "bad", "kind": "permission", "generation": 1}); reply.Type != "error" {
		t.Fatalf("invalid record accepted: %+v", reply)
	}
	info := bridge.snapshot()
	if info.PushDelivered[acpPushDeliveredKey("device_0000000000000001", "permission")] != 4 {
		t.Fatalf("snapshot delivered = %v", info.PushDelivered)
	}
}

func TestPushRefusedRegistrationLeavesThePendingRequestToRaise(t *testing.T) {
	for _, status := range []int{http.StatusUnauthorized, http.StatusGone} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			h := newPushTestHarness(t, status)
			phone := newPushTestDevice(t, 1)
			h.register(t, phone)
			// The bridge keeps the delivery record across the refusal.
			var mu sync.Mutex
			bridgeRecord := map[string]uint64{}
			pushRecordBridgeDelivered = func(_ string, deviceID string, kind string, generation uint64) error {
				mu.Lock()
				defer mu.Unlock()
				bridgeRecord[acpPushDeliveredKey(deviceID, kind)] = generation
				return nil
			}
			snapshot := func() map[string]uint64 {
				mu.Lock()
				defer mu.Unlock()
				copied := map[string]uint64{}
				for key, value := range bridgeRecord {
					copied[key] = value
				}
				return copied
			}
			h.server.raisePushAttention("@7", pushTestBridgeID, pushKindPermission, 1, snapshot())
			h.notifier.inflight.Wait()
			// The app registers again with a fresh ticket.
			phone.record.Ticket = "v1.k2.fresh"
			h.register(t, phone)
			h.clock.Advance(pushCoalesceWindow + time.Second)
			h.server.raisePushAttention("@7", pushTestBridgeID, pushKindPermission, 1, snapshot())
			h.notifier.inflight.Wait()
			requests := h.endpoint.received()
			if len(requests) != 2 || requests[1].Ticket != "v1.k2.fresh" {
				t.Fatalf("pending approval after re-registration: %+v", requests)
			}
		})
	}
}

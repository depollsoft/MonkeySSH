package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// newPushTestSessionServer adds a second session's server to h. Every server
// for the user shares the registration file, as on a real host.
func newPushTestSessionServer(t *testing.T, h *pushTestHarness, session string) (*muxServer, *pushNotifier) {
	t.Helper()
	server := newMuxServerWithSize(session, 80, 24)
	notifier := newPushNotifier()
	notifier.endpoint = h.notifier.endpoint
	notifier.now = h.clock.Now
	notifier.sleep = func(time.Duration) {}
	server.push = notifier
	server.mu.Lock()
	server.activeID = "@1"
	server.mu.Unlock()
	t.Cleanup(notifier.inflight.Wait)
	return server, notifier
}

func pushTestRegisterRequest(device pushTestDevice) controlMessage {
	return controlMessage{
		Type: "push_register",
		Push: &pushControlRequest{
			DeviceID:  device.record.DeviceID,
			Ticket:    device.record.Ticket,
			PublicKey: device.record.PublicKey,
			HostRef:   device.record.HostRef,
		},
	}
}

func TestPushRegistrationsAreScopedToTheirSession(t *testing.T) {
	h := newPushTestHarness(t)
	play, playNotifier := newPushTestSessionServer(t, h, "play")
	// Two saved hosts reach the same machine, one per MonkeyMux session.
	work := newPushTestDevice(t, 1)
	other := work
	other.record.HostRef = "hostref-play"

	// Only "work" has been attached: "play" has nothing to send to.
	h.register(t, work)
	play.raisePushEvent("@2", pushKindAlert, "")
	playNotifier.inflight.Wait()
	if got := h.kinds(); got != "" {
		t.Fatalf("play pushed %q to a device registered through work", got)
	}
	if result := playNotifier.sendTest(work.id, "play"); result != pushResultNotRegistered {
		t.Fatalf("test through play = %q, want %q", result, pushResultNotRegistered)
	}

	// Attaching the second saved host to "play" registers it separately.
	if response := play.pushControlResponse(pushTestRegisterRequest(other)); response.Type != "push_registered" {
		t.Fatalf("register through play = %+v", response)
	}
	if ids := h.registeredIDs(t); len(ids) != 2 {
		t.Fatalf("registrations = %v, want one per saved host", ids)
	}
	h.raise("@2", pushKindAlert)
	play.raisePushEvent("@3", pushKindAlert, "")
	playNotifier.inflight.Wait()
	requests := h.endpoint.received()
	if len(requests) != 2 {
		t.Fatalf("pushes = %d, want one per session", len(requests))
	}
	// Each session's event names its own saved host and session, so a tap
	// opens that saved host on that session and never the other.
	for index, want := range []struct{ hostRef, session, window string }{
		{"hostref1", "work", "@2"},
		{"hostref-play", "play", "@3"},
	} {
		var event struct {
			HostRef   string `json:"hostRef"`
			SessionID string `json:"sessionId"`
			Window    string `json:"window"`
		}
		plain := openPushPayloadForTest(t, work.private, requests[index].Payload)
		if err := json.Unmarshal(plain, &event); err != nil {
			t.Fatal(err)
		}
		if event.HostRef != want.hostRef || event.SessionID != want.session || event.Window != want.window {
			t.Fatalf("push %d = %+v, want %+v", index, event, want)
		}
	}

	// The shared file names sessions by key, never by name.
	path, _ := pushStatePath()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), `"work"`) || strings.Contains(string(data), `"play"`) {
		t.Fatalf("registration file names a session: %s", data)
	}

	// Turning off one saved host leaves the other.
	response := h.control(t, controlMessage{
		Type: "push_unregister",
		Push: &pushControlRequest{DeviceID: work.id, HostRef: work.record.HostRef},
	})
	if response.Type != "push_unregistered" {
		t.Fatalf("unregister = %+v", response)
	}
	if ids := h.registeredIDs(t); len(ids) != 1 {
		t.Fatalf("registrations after unregister = %v, want the play saved host", ids)
	}
}

func TestPushSavedHostAttachingToAnotherSessionMovesItsRegistration(t *testing.T) {
	h := newPushTestHarness(t)
	play, playNotifier := newPushTestSessionServer(t, h, "play")
	device := newPushTestDevice(t, 1)

	h.register(t, device)
	// The saved host's session setting changed: it now attaches to "play".
	if response := play.pushControlResponse(pushTestRegisterRequest(device)); response.Type != "push_registered" {
		t.Fatalf("register through play = %+v", response)
	}
	if ids := h.registeredIDs(t); len(ids) != 1 {
		t.Fatalf("registrations = %v, want the saved host moved, not copied", ids)
	}
	// Each server rereads the shared file at most once a second.
	h.clock.Advance(2 * time.Second)
	h.raise("@2", pushKindAlert)
	if got := h.kinds(); got != "" {
		t.Fatalf("work still pushed %q after the saved host moved to play", got)
	}
	play.raisePushEvent("@3", pushKindAlert, "")
	playNotifier.inflight.Wait()
	if got := h.kinds(); got != "alert" {
		t.Fatalf("play pushed %q, want alert", got)
	}
}

func TestPushRegistrationWithoutSessionIsReplacedOnAttach(t *testing.T) {
	h := newPushTestHarness(t)
	device := newPushTestDevice(t, 1)
	// A helper before sessions were recorded wrote a host-wide record.
	if err := h.notifier.store.mutate(func(state *pushStateFile, now time.Time) bool {
		upsertPushRecord(state, device.record, now)
		return true
	}); err != nil {
		t.Fatal(err)
	}
	h.raise("@2", pushKindAlert)
	if got := h.kinds(); got != "" {
		t.Fatalf("a record without a session received %q", got)
	}

	h.register(t, device)
	if ids := h.registeredIDs(t); len(ids) != 1 {
		t.Fatalf("registrations = %v, want the old record replaced", ids)
	}
	h.raise("@3", pushKindAlert)
	if got := h.kinds(); got != "alert" {
		t.Fatalf("after attaching, pushes = %q, want alert", got)
	}
}

func TestPushSessionKeyIsStableAndOpaque(t *testing.T) {
	salt := make([]byte, 32)
	work := pushSessionKey(salt, "work")
	if work != pushSessionKey(salt, "work") {
		t.Fatal("session key is not stable")
	}
	if work == pushSessionKey(salt, "play") {
		t.Fatal("two sessions share a key")
	}
	other := make([]byte, 32)
	other[0] = 1
	if work == pushSessionKey(other, "work") {
		t.Fatal("session key ignores the host salt")
	}
	if len(work) != 32 || strings.Contains(work, "work") {
		t.Fatalf("session key = %q", work)
	}
}

func TestPushVersion1FileIsReplacedAndOlderHelpersAreLockedOut(t *testing.T) {
	h := newPushTestHarness(t)
	device := newPushTestDevice(t, 1)
	path, err := pushStatePath()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), pushStateDirMode); err != nil {
		t.Fatal(err)
	}
	// A 0.1.228 helper wrote a host-wide registration.
	legacy := fmt.Sprintf(`{"version":1,"salt":"","devices":[{"deviceId":%q,"ticket":%q,"publicKey":%q,"hostRef":%q,"registeredAt":%d,"updatedAt":%d}]}`,
		device.id, device.record.Ticket, device.record.PublicKey, device.record.HostRef,
		h.clock.Now().Unix(), h.clock.Now().Unix())
	if err := os.WriteFile(path, []byte(legacy), pushStateFileMode); err != nil {
		t.Fatal(err)
	}
	h.raise("@2", pushKindAlert)
	if got := h.kinds(); got != "" {
		t.Fatalf("a version 1 registration received %q", got)
	}

	h.register(t, device)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var state struct {
		Version int `json:"version"`
		Devices []struct {
			SessionKey string `json:"sessionKey"`
		} `json:"devices"`
	}
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatal(err)
	}
	if state.Version != pushStateSchemaVersion || len(state.Devices) != 1 || state.Devices[0].SessionKey == "" {
		t.Fatalf("after attaching, file = %s", data)
	}
	// A version 1 helper reads this file as from a newer MonkeyMux: it neither
	// delivers from it nor rewrites it (and so cannot drop the session keys).
	if pushStateSchemaVersion < 2 {
		t.Fatal("session-scoped registrations must use a schema older helpers refuse")
	}
	h.raise("@3", pushKindAlert)
	if got := h.kinds(); got != "alert" {
		t.Fatalf("after attaching, pushes = %q, want alert", got)
	}
}

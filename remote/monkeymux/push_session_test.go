package main

import (
	"os"
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
	device := newPushTestDevice(t, 1)

	// The app attached to "work" only, so "play" has nothing to send: a
	// notification must name a session the app opened and can reopen.
	h.register(t, device)
	play.raisePushEvent("@2", pushKindAlert, "")
	playNotifier.inflight.Wait()
	if got := h.kinds(); got != "" {
		t.Fatalf("play pushed %q to a device registered through work", got)
	}
	if result := playNotifier.sendTest(device.id, "play"); result != pushResultNotRegistered {
		t.Fatalf("test through play = %q, want %q", result, pushResultNotRegistered)
	}
	h.raise("@2", pushKindAlert)
	if got := h.kinds(); got != "alert" {
		t.Fatalf("work pushed %q, want alert", got)
	}

	// Attaching to "play" registers that session separately.
	if response := play.pushControlResponse(pushTestRegisterRequest(device)); response.Type != "push_registered" {
		t.Fatalf("register through play = %+v", response)
	}
	play.raisePushEvent("@3", pushKindAlert, "")
	playNotifier.inflight.Wait()
	if got := h.kinds(); got != "alert,alert" {
		t.Fatalf("after attaching to play, pushes = %q", got)
	}
	if ids := h.registeredIDs(t); len(ids) != 2 {
		t.Fatalf("registrations = %v, want one per session", ids)
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

	// Turning off the saved host removes it from every session.
	response := h.control(t, controlMessage{
		Type: "push_unregister",
		Push: &pushControlRequest{DeviceID: device.id, HostRef: device.record.HostRef},
	})
	if response.Type != "push_unregistered" {
		t.Fatalf("unregister = %+v", response)
	}
	if ids := h.registeredIDs(t); len(ids) != 0 {
		t.Fatalf("registrations after unregister = %v", ids)
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

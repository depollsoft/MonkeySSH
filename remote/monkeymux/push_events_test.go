package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// registerEvents registers device asking for events (nil sends no list).
func (h *pushTestHarness) registerEvents(t *testing.T, device pushTestDevice, events *[]string) {
	t.Helper()
	request := pushTestRegisterRequest(device)
	request.Push.Events = events
	response := h.control(t, request)
	if response.Status != "ok" || response.Type != "push_registered" {
		t.Fatalf("register response = %+v", response)
	}
}

// raiseEveryCategory raises one event of each category, each in its own
// window so none coalesces with another.
func (h *pushTestHarness) raiseEveryCategory() {
	h.server.raisePushAlert("@2", pushAlertBell)
	h.server.raisePushAlert("@3", pushAlertNotice)
	h.server.raisePushEvent("@4", pushKindFinished, pushTestBridgeID)
	h.server.raisePushAttention("@5", pushTestBridgeID, pushKindPermission, 1, nil)
	h.server.raisePushAttention("@6", pushTestBridgeID, pushKindInput, 1, nil)
	h.notifier.inflight.Wait()
}

// ticketsSent lists, per request, the ticket number of the device it went to.
func (h *pushTestHarness) ticketsSent() string {
	requests := h.endpoint.received()
	tickets := make([]string, 0, len(requests))
	for _, request := range requests {
		tickets = append(tickets, strings.TrimPrefix(request.Ticket, "v1.k1.ticket"))
	}
	return strings.Join(tickets, ",")
}

func pushTestEvents(events ...string) *[]string { return &events }

func TestPushEventsFilterEachCategory(t *testing.T) {
	cases := []struct {
		events []string
		want   string
	}{
		{[]string{pushEventBell}, "alert"},
		{[]string{pushEventNotice}, "alert"},
		{[]string{pushEventFinished}, "finished"},
		{[]string{pushEventAttention}, "permission,input"},
		{[]string{pushEventBell, pushEventAttention}, "alert,permission,input"},
	}
	for _, tc := range cases {
		t.Run(strings.Join(tc.events, "+"), func(t *testing.T) {
			h := newPushTestHarness(t)
			h.registerEvents(t, newPushTestDevice(t, 1), pushTestEvents(tc.events...))
			h.raiseEveryCategory()
			if got := h.kinds(); got != tc.want {
				t.Fatalf("pushes = %q, want %q", got, tc.want)
			}
		})
	}
	// The bell and notice cases above both send one alert; check each comes
	// from the right window.
	for _, tc := range []struct {
		event  string
		window string
	}{{pushEventBell, "@2"}, {pushEventNotice, "@3"}} {
		t.Run(tc.event+" window", func(t *testing.T) {
			testPushAlertComesFromWindow(t, tc.event, tc.window)
		})
	}
}

// testPushAlertComesFromWindow checks that a registration wanting only
// category is sent the alert raised in window.
func testPushAlertComesFromWindow(t *testing.T, category string, window string) {
	t.Helper()
	h := newPushTestHarness(t)
	device := newPushTestDevice(t, 1)
	h.registerEvents(t, device, pushTestEvents(category))
	h.raiseEveryCategory()
	requests := h.endpoint.received()
	if len(requests) != 1 {
		t.Fatalf("pushes = %d, want 1", len(requests))
	}
	var event struct {
		Window string `json:"window"`
	}
	if err := json.Unmarshal(openPushPayloadForTest(t, device.private, requests[0].Payload), &event); err != nil {
		t.Fatal(err)
	}
	if event.Window != window {
		t.Fatalf("%s alert came from %s, want %s", category, event.Window, window)
	}
}

func TestPushAlertWithBellAndNoticeReachesEitherPreference(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), pushTestEvents(pushEventBell))
	h.registerEvents(t, newPushTestDevice(t, 2), pushTestEvents(pushEventNotice))
	h.registerEvents(t, newPushTestDevice(t, 3), pushTestEvents(pushEventAttention))
	// One chunk of output rang the bell and posted a notification.
	h.server.raisePushAlert("@2", pushAlertBell|pushAlertNotice)
	h.notifier.inflight.Wait()
	if got := h.ticketsSent(); got != "1,2" {
		t.Fatalf("alert went to devices %q, want 1,2", got)
	}
}

func TestPushRegistrationWithoutEventsWantsEverything(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.raiseEveryCategory()
	if got := h.kinds(); got != "alert,alert,finished,permission,input" {
		t.Fatalf("pushes = %q, want every category", got)
	}
	path, _ := pushStatePath()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), `"events"`) {
		t.Fatalf("a registration without a list stored one: %s", data)
	}
}

func TestPushEmptyEventsListWantsNothingButTheTest(t *testing.T) {
	h := newPushTestHarness(t)
	device := newPushTestDevice(t, 1)
	h.registerEvents(t, device, pushTestEvents())
	h.raiseEveryCategory()
	if got := h.kinds(); got != "" {
		t.Fatalf("a registration wanting nothing received %q", got)
	}
	path, _ := pushStatePath()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"events": []`) {
		t.Fatalf("an empty list was not stored as one: %s", data)
	}
	// Send test still reaches the device: it checks the path, not a preference.
	if result := h.notifier.sendTest(device.id, "work"); result != pushResultSent {
		t.Fatalf("test = %q, want %q", result, pushResultSent)
	}
}

func TestPushRegisteringAgainReplacesTheEvents(t *testing.T) {
	h := newPushTestHarness(t)
	device := newPushTestDevice(t, 1)
	h.registerEvents(t, device, pushTestEvents(pushEventBell))
	h.server.raisePushAlert("@2", pushAlertNotice)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "" {
		t.Fatalf("a notice reached a bell-only registration: %q", got)
	}
	// Unknown categories are ignored, not stored.
	h.registerEvents(t, device, pushTestEvents("bogus", pushEventNotice, pushEventNotice))
	if ids := h.registeredIDs(t); len(ids) != 1 {
		t.Fatalf("registrations = %v, want the one replaced", ids)
	}
	path, _ := pushStatePath()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var state pushStateFile
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatal(err)
	}
	if events := state.Devices[0].Events; events == nil || strings.Join(*events, ",") != pushEventNotice {
		t.Fatalf("stored events = %v, want [notice]", events)
	}
	h.server.raisePushAlert("@3", pushAlertNotice)
	h.server.raisePushAlert("@4", pushAlertBell)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "alert" {
		t.Fatalf("after re-registering, pushes = %q, want the notice only", got)
	}
}

func TestPushTwoSavedHostsOfOneMachineKeepTheirOwnEvents(t *testing.T) {
	h := newPushTestHarness(t)
	lan := newPushTestDevice(t, 1)
	tailscale := lan
	tailscale.record.HostRef = "hostref-tailscale"
	h.registerEvents(t, lan, pushTestEvents(pushEventNotice))
	h.clock.Advance(time.Second)
	h.registerEvents(t, tailscale, pushTestEvents(pushEventBell))
	// The newer saved host does not want notices; the event goes through the
	// one that does, still once.
	h.server.raisePushAlert("@2", pushAlertNotice)
	h.notifier.inflight.Wait()
	requests := h.endpoint.received()
	if len(requests) != 1 {
		t.Fatalf("pushes = %d, want 1", len(requests))
	}
	var event struct {
		HostRef string `json:"hostRef"`
	}
	if err := json.Unmarshal(openPushPayloadForTest(t, lan.private, requests[0].Payload), &event); err != nil {
		t.Fatal(err)
	}
	if event.HostRef != lan.record.HostRef {
		t.Fatalf("notice named saved host %q, want %q", event.HostRef, lan.record.HostRef)
	}
}

func TestPushNoticesClaimCoversDesktopNotificationsSeparately(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	notices := false
	// The app raises bell alerts itself but not desktop notifications (the
	// user turned shell notifications off on this device).
	h.presenceReport(t, phone, "phone-client", pushControlRequest{Local: true, Alerts: true, Notices: &notices})
	h.server.raisePushAlert("@2", pushAlertBell)
	h.server.raisePushAlert("@3", pushAlertNotice)
	h.notifier.inflight.Wait()
	if got := h.ticketsSent(); got != "1" || h.kinds() != "alert" {
		t.Fatalf("pushes = %q, want only the notice", h.kinds())
	}
	// An alert carrying both needs both covered.
	h.server.raisePushAlert("@4", pushAlertBell|pushAlertNotice)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "alert,alert" {
		t.Fatalf("a bell+notice alert half covered = %q, want it sent", got)
	}

	notices = true
	h.presenceReport(t, phone, "phone-client", pushControlRequest{Local: true, Notices: &notices})
	h.server.raisePushAlert("@5", pushAlertNotice)
	h.server.raisePushAlert("@6", pushAlertBell)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "alert,alert,alert" {
		t.Fatalf("with notices covered, pushes = %q, want the bell only added", got)
	}
}

func TestPushAlertsClaimWithoutNoticesCoversBoth(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	// An app from before the notices field.
	h.presenceReport(t, phone, "phone-client", pushControlRequest{Local: true, Alerts: true})
	h.server.raisePushAlert("@2", pushAlertBell)
	h.server.raisePushAlert("@3", pushAlertNotice)
	h.server.raisePushAlert("@4", pushAlertBell|pushAlertNotice)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "" {
		t.Fatalf("covered alerts sent: %q", got)
	}
}

func TestPushDeferredNoticeIsSentWhenItsClaimLapses(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	covered := true
	h.presenceReport(t, phone, "phone-client", pushControlRequest{Local: true, Alerts: true, Notices: &covered})
	h.server.raisePushAlert("@2", pushAlertNotice)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "" {
		t.Fatalf("covered notice sent at once: %q", got)
	}
	// The app still raises bells, but no longer notices.
	covered = false
	h.presenceReport(t, phone, "phone-client", pushControlRequest{Local: true, Alerts: true, Notices: &covered})
	h.server.flushPushDeferred()
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "alert" {
		t.Fatalf("deferred notice after its claim lapsed = %q, want alert", got)
	}
}

func TestPushVersion2FileKeepsItsRegistrations(t *testing.T) {
	h := newPushTestHarness(t)
	device := newPushTestDevice(t, 1)
	salt := make([]byte, 32)
	salt[0] = 7
	path, err := pushStatePath()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), pushStateDirMode); err != nil {
		t.Fatal(err)
	}
	// A 0.1.230 helper registered this device for the "work" session.
	now := h.clock.Now().Unix()
	v2 := fmt.Sprintf(`{"version":2,"salt":%q,"devices":[{"deviceId":%q,"ticket":%q,"publicKey":%q,"hostRef":%q,"sessionKey":%q,"registeredAt":%d,"updatedAt":%d}]}`,
		base64.RawURLEncoding.EncodeToString(salt), device.id, device.record.Ticket,
		device.record.PublicKey, device.record.HostRef, pushSessionKey(salt, "work"), now, now)
	if err := os.WriteFile(path, []byte(v2), pushStateFileMode); err != nil {
		t.Fatal(err)
	}
	h.raiseEveryCategory()
	if got := h.kinds(); got != "alert,alert,finished,permission,input" {
		t.Fatalf("a version 2 registration received %q, want everything", got)
	}

	// The next write stamps version 3, which helpers that only know version
	// 2 refuse to read or write, and keeps the version 2 record.
	h.registerEvents(t, newPushTestDevice(t, 2), pushTestEvents(pushEventAttention))
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var state pushStateFile
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatal(err)
	}
	if state.Version != 3 || len(state.Devices) != 2 || state.Devices[0].Events != nil {
		t.Fatalf("after a write, file = %s", data)
	}
}

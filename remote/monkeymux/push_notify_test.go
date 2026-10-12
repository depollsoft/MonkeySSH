package main

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

type pushTestRequest struct {
	Ticket   string `json:"ticket"`
	Kind     string `json:"kind"`
	Collapse string `json:"collapse"`
	Payload  string `json:"payload"`
}

type pushTestEndpoint struct {
	mu       sync.Mutex
	requests []pushTestRequest
	statuses []int
	headers  map[string]string
	server   *httptest.Server
}

func newPushTestEndpoint(t *testing.T, statuses ...int) *pushTestEndpoint {
	t.Helper()
	endpoint := &pushTestEndpoint{statuses: statuses, headers: map[string]string{}}
	endpoint.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Header.Get("Content-Type") != "application/json" {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		var request pushTestRequest
		_ = json.NewDecoder(r.Body).Decode(&request)
		endpoint.mu.Lock()
		endpoint.requests = append(endpoint.requests, request)
		status := http.StatusAccepted
		if len(endpoint.statuses) > 0 {
			status = endpoint.statuses[0]
			endpoint.statuses = endpoint.statuses[1:]
		}
		for name, value := range endpoint.headers {
			w.Header().Set(name, value)
		}
		endpoint.mu.Unlock()
		w.WriteHeader(status)
	}))
	t.Cleanup(endpoint.server.Close)
	return endpoint
}

func (e *pushTestEndpoint) received() []pushTestRequest {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]pushTestRequest(nil), e.requests...)
}

type pushTestClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *pushTestClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *pushTestClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

type pushTestDevice struct {
	id      string
	private *ecdh.PrivateKey
	record  pushDeviceRecord
}

func newPushTestDevice(t *testing.T, index int) pushTestDevice {
	t.Helper()
	private, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	id := fmt.Sprintf("device_%016d", index)
	return pushTestDevice{
		id:      id,
		private: private,
		record: pushDeviceRecord{
			DeviceID:  id,
			Ticket:    fmt.Sprintf("v1.k1.ticket%d", index),
			PublicKey: base64.RawURLEncoding.EncodeToString(private.PublicKey().Bytes()),
			HostRef:   fmt.Sprintf("hostref%d", index),
		},
	}
}

type pushTestHarness struct {
	server   *muxServer
	notifier *pushNotifier
	endpoint *pushTestEndpoint
	clock    *pushTestClock
	home     string
}

func newPushTestHarness(t *testing.T, statuses ...int) *pushTestHarness {
	t.Helper()
	home := t.TempDir()
	setTestHomeDir(t, home)
	endpoint := newPushTestEndpoint(t, statuses...)
	clock := &pushTestClock{now: time.Unix(1_760_000_000, 0)}
	server := newMuxServerWithSize("work", 80, 24)
	notifier := newPushNotifier()
	notifier.endpoint = endpoint.server.URL
	notifier.now = clock.Now
	notifier.sleep = func(time.Duration) {}
	server.push = notifier
	previousRecord := pushRecordBridgeDelivered
	pushRecordBridgeDelivered = func(string, string, string, uint64) error { return nil }
	t.Cleanup(func() { pushRecordBridgeDelivered = previousRecord })
	server.mu.Lock()
	server.activeID = "@1"
	server.mu.Unlock()
	t.Cleanup(notifier.inflight.Wait)
	return &pushTestHarness{server: server, notifier: notifier, endpoint: endpoint, clock: clock, home: home}
}

func (h *pushTestHarness) control(t *testing.T, request controlMessage) controlResponse {
	t.Helper()
	return h.server.pushControlResponse(request)
}

func (h *pushTestHarness) register(t *testing.T, device pushTestDevice) {
	t.Helper()
	response := h.control(t, controlMessage{
		ID:   "r",
		Type: "push_register",
		Push: &pushControlRequest{
			DeviceID:  device.record.DeviceID,
			Ticket:    device.record.Ticket,
			PublicKey: device.record.PublicKey,
			HostRef:   device.record.HostRef,
		},
	})
	if response.Status != "ok" || response.Type != "push_registered" {
		t.Fatalf("register response = %+v", response)
	}
}

func (h *pushTestHarness) presence(t *testing.T, device pushTestDevice, clientID string, foreground bool) {
	t.Helper()
	response := h.control(t, controlMessage{
		Type:     "push_presence",
		ClientID: clientID,
		Push:     &pushControlRequest{DeviceID: device.id, Foreground: foreground},
	})
	if response.Status != "ok" {
		t.Fatalf("presence response = %+v", response)
	}
}

func (h *pushTestHarness) raise(windowID string, kind string) {
	h.server.raisePushEvent(windowID, kind, "")
	h.notifier.inflight.Wait()
}

func (h *pushTestHarness) registeredIDs(t *testing.T) []string {
	t.Helper()
	path, err := pushStatePath()
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var state pushStateFile
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatal(err)
	}
	ids := make([]string, 0, len(state.Devices))
	for _, device := range state.Devices {
		ids = append(ids, device.DeviceID)
	}
	return ids
}

func TestPushRegisterStoresPrivateFileWithDeviceCap(t *testing.T) {
	h := newPushTestHarness(t)
	devices := make([]pushTestDevice, 0, pushMaxDevices+1)
	for index := 0; index <= pushMaxDevices; index++ {
		device := newPushTestDevice(t, index)
		devices = append(devices, device)
		h.register(t, device)
		h.clock.Advance(time.Second)
	}
	ids := h.registeredIDs(t)
	if len(ids) != pushMaxDevices {
		t.Fatalf("stored %d devices, want %d", len(ids), pushMaxDevices)
	}
	for _, id := range ids {
		if id == devices[0].id {
			t.Fatal("the least recently updated device was not evicted")
		}
	}
	path, _ := pushStatePath()
	if path != filepath.Join(h.home, ".monkeyssh", "state", "push-devices.json") {
		t.Fatalf("state path = %s", path)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if mode := info.Mode().Perm(); mode != pushStateFileMode {
			t.Fatalf("state file mode = %v", mode)
		}
		dirInfo, err := os.Stat(filepath.Dir(path))
		if err != nil {
			t.Fatal(err)
		}
		if mode := dirInfo.Mode().Perm(); mode != pushStateDirMode {
			t.Fatalf("state dir mode = %v", mode)
		}
	}
	data, _ := os.ReadFile(path)
	if strings.Contains(string(data), "work") {
		t.Fatal("state file names the session")
	}

	// Re-registering replaces the ticket in place.
	updated := devices[1]
	updated.record.Ticket = "v1.k2.fresh"
	h.register(t, updated)
	stored, _ := h.notifier.store.snapshot()
	for _, record := range stored {
		if record.DeviceID == updated.id && record.Ticket != "v1.k2.fresh" {
			t.Fatalf("ticket not replaced: %s", record.Ticket)
		}
	}

	response := h.control(t, controlMessage{
		Type: "push_unregister",
		Push: &pushControlRequest{DeviceID: updated.id},
	})
	if response.Type != "push_unregistered" {
		t.Fatalf("unregister response = %+v", response)
	}
	for _, id := range h.registeredIDs(t) {
		if id == updated.id {
			t.Fatal("unregister kept the device")
		}
	}
}

func TestPushRegisterRejectsInvalidFields(t *testing.T) {
	h := newPushTestHarness(t)
	valid := newPushTestDevice(t, 1).record
	cases := map[string]func(*pushControlRequest){
		"device id":  func(p *pushControlRequest) { p.DeviceID = "short" },
		"ticket":     func(p *pushControlRequest) { p.Ticket = "v2.k1.abc" },
		"ticket url": func(p *pushControlRequest) { p.Ticket = "v1.k1.a/b" },
		"public key": func(p *pushControlRequest) { p.PublicKey = "AAAA" },
		"host ref":   func(p *pushControlRequest) { p.HostRef = "has space" },
		"long":       func(p *pushControlRequest) { p.Ticket = "v1.k1." + strings.Repeat("a", 3000) },
	}
	for name, mutate := range cases {
		request := &pushControlRequest{
			DeviceID:  valid.DeviceID,
			Ticket:    valid.Ticket,
			PublicKey: valid.PublicKey,
			HostRef:   valid.HostRef,
		}
		mutate(request)
		response := h.control(t, controlMessage{Type: "push_register", Push: request})
		if response.Status != "error" {
			t.Fatalf("%s: accepted invalid registration", name)
		}
	}
	if path, _ := pushStatePath(); fileExists(path) {
		t.Fatal("invalid registrations wrote the state file")
	}
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func TestPushEventIsEncryptedToEachDevice(t *testing.T) {
	h := newPushTestHarness(t)
	first := newPushTestDevice(t, 1)
	second := newPushTestDevice(t, 2)
	h.register(t, first)
	h.register(t, second)

	h.raise("@2", pushKindPermission)

	requests := h.endpoint.received()
	if len(requests) != 2 {
		t.Fatalf("sent %d requests, want 2", len(requests))
	}
	byTicket := map[string]pushTestRequest{}
	for _, request := range requests {
		byTicket[request.Ticket] = request
		if request.Kind != pushKindPermission {
			t.Fatalf("kind = %s", request.Kind)
		}
		if len(request.Collapse) != 32 || strings.Contains(request.Collapse, "@2") {
			t.Fatalf("collapse key = %q", request.Collapse)
		}
	}
	for _, device := range []pushTestDevice{first, second} {
		request, ok := byTicket[device.record.Ticket]
		if !ok {
			t.Fatalf("no request for %s", device.id)
		}
		var event struct {
			V         int    `json:"v"`
			HostRef   string `json:"hostRef"`
			Window    string `json:"window"`
			SessionID string `json:"sessionId"`
			Kind      string `json:"kind"`
			TS        int64  `json:"ts"`
		}
		if err := json.Unmarshal(openPushPayloadForTest(t, device.private, request.Payload), &event); err != nil {
			t.Fatal(err)
		}
		if event.V != 1 || event.HostRef != device.record.HostRef || event.Window != "@2" ||
			event.SessionID != "work" || event.Kind != pushKindPermission || event.TS != 1_760_000_000 {
			t.Fatalf("event = %+v", event)
		}
		if strings.Contains(request.Payload, "work") {
			t.Fatal("session name leaked outside the ciphertext")
		}
	}
	if byTicket[first.record.Ticket].Collapse == byTicket[second.record.Ticket].Collapse {
		t.Fatal("devices share a collapse key")
	}
}

func TestPushAttendanceSkipsTheWatchingDeviceOnly(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	tablet := newPushTestDevice(t, 2)
	h.register(t, phone)
	h.register(t, tablet)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	// A desktop attach without presence never suppresses anyone.
	registerTestAttachClient(t, h.server, &recordingConn{}, "desktop-client", 80, 24)
	h.server.mu.Lock()
	h.server.activeID = "@1"
	h.server.mu.Unlock()
	h.presence(t, phone, "phone-client", true)

	h.raise("@1", pushKindPermission)
	requests := h.endpoint.received()
	if len(requests) != 1 || requests[0].Ticket != tablet.record.Ticket {
		t.Fatalf("watching phone was not skipped: %+v", requests)
	}

	// Another window still reaches the phone.
	h.raise("@2", pushKindPermission)
	if got := len(h.endpoint.received()); got != 3 {
		t.Fatalf("requests after an unwatched window = %d, want 3", got)
	}
}

func TestPushAttendanceGraceAndPresenceExpiry(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	h.server.mu.Lock()
	h.server.activeID = "@1"
	h.server.mu.Unlock()
	h.presence(t, phone, "phone-client", true)

	// Leaving the app keeps the window suppressed for 30 seconds.
	h.clock.Advance(5 * time.Second)
	h.presence(t, phone, "phone-client", false)
	h.clock.Advance(20 * time.Second)
	h.raise("@1", pushKindFinished)
	if got := len(h.endpoint.received()); got != 0 {
		t.Fatalf("pushed within the grace period: %d", got)
	}
	h.clock.Advance(11 * time.Second)
	h.raise("@1", pushKindFinished)
	if got := len(h.endpoint.received()); got != 1 {
		t.Fatalf("requests after the grace period = %d, want 1", got)
	}

	// A foreground report that stops arriving expires.
	h.presence(t, phone, "phone-client", true)
	h.clock.Advance(pushPresenceTTL + time.Second)
	h.raise("@1", pushKindPermission)
	if got := len(h.endpoint.received()); got != 2 {
		t.Fatalf("stale presence still suppressed: %d", got)
	}
}

func TestPushAttendanceRequiresAttachedClient(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	// Foreground, but its attach client is not connected to this server.
	h.presence(t, phone, "gone-client", true)
	h.raise("@1", pushKindPermission)
	if got := len(h.endpoint.received()); got != 1 {
		t.Fatalf("detached device was treated as watching: %d", got)
	}
}

func TestPushAlertIsSkippedWhenAnyDeviceWatches(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	tablet := newPushTestDevice(t, 2)
	h.register(t, phone)
	h.register(t, tablet)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	h.server.mu.Lock()
	h.server.activeID = "@1"
	h.server.mu.Unlock()
	h.presence(t, phone, "phone-client", true)

	h.raise("@1", pushKindAlert)
	if got := len(h.endpoint.received()); got != 0 {
		t.Fatalf("alert in a watched window was sent %d times", got)
	}
	h.raise("@2", pushKindAlert)
	if got := len(h.endpoint.received()); got != 2 {
		t.Fatalf("alert in an unwatched window sent %d times, want 2", got)
	}
}

func TestPushCoalescesAndCapsPerDevice(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)

	h.raise("@1", pushKindAlert)
	h.raise("@1", pushKindAlert)
	h.raise("@1", pushKindFinished)
	if got := len(h.endpoint.received()); got != 2 {
		t.Fatalf("coalesced sends = %d, want 2", got)
	}
	h.clock.Advance(pushCoalesceWindow)
	h.raise("@1", pushKindAlert)
	if got := len(h.endpoint.received()); got != 3 {
		t.Fatalf("sends after the coalescing window = %d, want 3", got)
	}

	for index := 0; index < 40; index++ {
		h.raise(fmt.Sprintf("@%d", 100+index), pushKindAlert)
	}
	if got := len(h.endpoint.received()); got != pushHourlyCap {
		t.Fatalf("sends in one hour = %d, want %d", got, pushHourlyCap)
	}
	h.clock.Advance(time.Hour)
	h.raise("@500", pushKindAlert)
	if got := len(h.endpoint.received()); got != pushHourlyCap+1 {
		t.Fatalf("cap did not reset after an hour: %d", got)
	}
}

func TestPushUnregisteredAndBadTicketsDropTheRegistration(t *testing.T) {
	for _, status := range []int{http.StatusGone, http.StatusUnauthorized} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			h := newPushTestHarness(t, status)
			phone := newPushTestDevice(t, 1)
			tablet := newPushTestDevice(t, 2)
			h.register(t, phone)
			h.register(t, tablet)
			h.endpoint.mu.Lock()
			h.endpoint.statuses = []int{status, http.StatusAccepted}
			h.endpoint.mu.Unlock()
			// Only the phone's request fails; send to it alone first.
			h.notifier.deliver(pushJob{deviceID: phone.id, ticket: phone.record.Ticket, kind: "alert", collapse: "c", payload: "p"})
			ids := h.registeredIDs(t)
			if len(ids) != 1 || ids[0] != tablet.id {
				t.Fatalf("registrations after %d = %v", status, ids)
			}
		})
	}
}

func TestPushDropKeepsAReplacedTicket(t *testing.T) {
	h := newPushTestHarness(t, http.StatusGone)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	stale := phone.record.Ticket
	phone.record.Ticket = "v1.k1.replaced"
	h.register(t, phone)
	h.notifier.deliver(pushJob{deviceID: phone.id, ticket: stale, kind: "alert", collapse: "c", payload: "p"})
	if ids := h.registeredIDs(t); len(ids) != 1 {
		t.Fatalf("a 410 for an old ticket dropped the new registration: %v", ids)
	}
}

func TestPushRateLimitBacksOffTheDevice(t *testing.T) {
	h := newPushTestHarness(t, http.StatusTooManyRequests)
	h.endpoint.headers["Retry-After"] = "120"
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)

	h.raise("@1", pushKindPermission)
	h.raise("@2", pushKindPermission)
	if got := len(h.endpoint.received()); got != 1 {
		t.Fatalf("sent during backoff: %d", got)
	}
	h.clock.Advance(121 * time.Second)
	h.raise("@3", pushKindPermission)
	if got := len(h.endpoint.received()); got != 2 {
		t.Fatalf("backoff did not end: %d", got)
	}
}

func TestPushRetriesServerErrorsTwice(t *testing.T) {
	h := newPushTestHarness(t, http.StatusServiceUnavailable, http.StatusInternalServerError, http.StatusAccepted)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	var slept []time.Duration
	h.notifier.sleep = func(d time.Duration) { slept = append(slept, d) }
	result := h.notifier.deliver(pushJob{deviceID: phone.id, ticket: phone.record.Ticket, kind: "alert", collapse: "c", payload: "p"})
	if result != pushResultSent || len(h.endpoint.received()) != 3 {
		t.Fatalf("result = %s after %d attempts", result, len(h.endpoint.received()))
	}
	if len(slept) != 2 || slept[0] != time.Second || slept[1] != 3*time.Second {
		t.Fatalf("backoff delays = %v", slept)
	}

	h.endpoint.mu.Lock()
	h.endpoint.statuses = []int{503, 503, 503, 202}
	h.endpoint.mu.Unlock()
	result = h.notifier.deliver(pushJob{deviceID: phone.id, ticket: phone.record.Ticket, kind: "alert", collapse: "c", payload: "p"})
	if result != pushResultFailed || len(h.endpoint.received()) != 6 {
		t.Fatalf("result = %s after %d attempts, want failed after 3 more", result, len(h.endpoint.received()))
	}
	if ids := h.registeredIDs(t); len(ids) != 1 {
		t.Fatal("a server error dropped the registration")
	}
}

func TestPushTestControlReportsTheOutcome(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	missing := h.control(t, controlMessage{ID: "t", Type: "push_test", Push: &pushControlRequest{DeviceID: phone.id}})
	if missing.Push == nil || missing.Push.Result != pushResultNotRegistered {
		t.Fatalf("unregistered test = %+v", missing)
	}
	h.register(t, phone)
	// A test ignores attendance and coalescing.
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	h.presence(t, phone, "phone-client", true)
	for index := 0; index < 2; index++ {
		response := h.control(t, controlMessage{ID: "t", Type: "push_test", Push: &pushControlRequest{DeviceID: phone.id}})
		if response.Type != "push_test_result" || response.Push == nil || response.Push.Result != pushResultSent {
			t.Fatalf("test response = %+v", response)
		}
	}
	requests := h.endpoint.received()
	if len(requests) != 2 || requests[0].Kind != pushKindTest {
		t.Fatalf("test requests = %+v", requests)
	}
	var event struct {
		Window  string `json:"window"`
		HostRef string `json:"hostRef"`
	}
	_ = json.Unmarshal(openPushPayloadForTest(t, phone.private, requests[0].Payload), &event)
	if event.Window != "" || event.HostRef != phone.record.HostRef {
		t.Fatalf("test event = %+v", event)
	}
}

func TestPushControlIsAdvertisedAndRoutedThroughTheControlSwitch(t *testing.T) {
	found := false
	for _, capability := range capabilities {
		if capability == "push-v1" {
			found = true
		}
	}
	if !found {
		t.Fatal("push-v1 capability is not advertised")
	}
	h := newPushTestHarness(t)
	conn := &recordingConn{}
	client := newControlClient(conn)
	defer client.close()
	h.server.handleControlRequest(client, controlMessage{
		ID:   "reg",
		Type: "push_register",
		Push: &pushControlRequest{DeviceID: "bad"},
	})
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && !strings.Contains(conn.String(), `"id":"reg"`) {
		time.Sleep(5 * time.Millisecond)
	}
	if !strings.Contains(conn.String(), `"id":"reg"`) || !strings.Contains(conn.String(), `"status":"error"`) {
		t.Fatalf("control output = %s", conn.String())
	}
}

func TestPushWithoutRegistrationsDoesNothing(t *testing.T) {
	h := newPushTestHarness(t)
	h.raise("@1", pushKindAlert)
	if got := len(h.endpoint.received()); got != 0 {
		t.Fatalf("sent %d without registrations", got)
	}
	if path, _ := pushStatePath(); fileExists(path) {
		t.Fatal("an event created the state file")
	}
}

func TestPushStoreReloadsChangesFromOtherServers(t *testing.T) {
	h := newPushTestHarness(t)
	other := newPushNotifier()
	other.now = h.clock.Now
	if other.store.hasDevices() {
		t.Fatal("fresh store has devices")
	}
	h.register(t, newPushTestDevice(t, 1))
	h.clock.Advance(pushStoreRecheckInterval)
	if !other.store.hasDevices() {
		t.Fatal("second server did not see the registration")
	}
}

func TestPushAlertOutputDetection(t *testing.T) {
	cases := []struct {
		name string
		bell bool
		oscs []string
		want bool
	}{
		{"bell", true, nil, true},
		{"osc 9", false, []string{"9;Build finished"}, true},
		{"osc 777", false, []string{"777;notify;Title;Body"}, true},
		{"osc 777 precmd", false, []string{"777;precmd"}, false},
		{"osc 777 preexec", false, []string{"777;preexec"}, false},
		{"osc 99", false, []string{"99;;Hello"}, true},
		{"osc 99 query", false, []string{"99;i=1:p=?;"}, false},
		{"osc 99 close", false, []string{"99;i=1:p=close;"}, false},
		{"progress", false, []string{"9;4;1;50"}, false},
		{"title", false, []string{"0;window title"}, false},
		{"agent identity", false, []string{"1337;MonkeyMuxPi=1"}, false},
		{"nothing", false, nil, false},
	}
	for _, tc := range cases {
		oscs := make([][]byte, 0, len(tc.oscs))
		for _, osc := range tc.oscs {
			oscs = append(oscs, []byte(osc))
		}
		if got := isPushAlertOutput(tc.bell, oscs); got != tc.want {
			t.Fatalf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestPushBridgeCountersRaiseEvents(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.register(t, phone)
	const bridgeID = "0123456789abcdef0123456789abcdef"
	h.server.mu.Lock()
	h.server.windows = append(h.server.windows, &muxWindow{id: "@7", nativeAcpBridgeID: bridgeID})
	h.server.mu.Unlock()

	var statusMu sync.Mutex
	status := acpBridgeInfo{ID: bridgeID, StartedAt: 100}
	previous := pushBridgeStatus
	pushBridgeStatus = func(id string) (acpBridgeInfo, error) {
		statusMu.Lock()
		defer statusMu.Unlock()
		if id != bridgeID {
			return acpBridgeInfo{}, os.ErrNotExist
		}
		return status, nil
	}
	t.Cleanup(func() { pushBridgeStatus = previous })
	setStatus := func(update func(*acpBridgeInfo)) {
		statusMu.Lock()
		update(&status)
		statusMu.Unlock()
	}
	poll := func() {
		h.server.pollPushBridges()
		h.notifier.inflight.Wait()
	}

	poll() // baseline
	setStatus(func(s *acpBridgeInfo) { s.PermissionRequests = 1; s.PendingPermission = 1 })
	poll()
	// Still pending on the next poll: already sent, not sent again.
	h.clock.Advance(pushCoalesceWindow)
	poll()
	setStatus(func(s *acpBridgeInfo) { s.CompletedTurns = 1; s.PendingPermission = 0 })
	poll()
	// An elicitation answered before the poll saw it is not worth a push, and
	// a pending permission count does not stand in for it.
	setStatus(func(s *acpBridgeInfo) { s.InputRequests = 1; s.PendingPermission = 1 })
	poll()
	// A restarted bridge resets the turn baseline without a "finished", and its
	// pending request is a new one.
	h.clock.Advance(pushCoalesceWindow)
	setStatus(func(s *acpBridgeInfo) {
		*s = acpBridgeInfo{ID: bridgeID, StartedAt: 200, PermissionRequests: 1, PendingPermission: 1}
	})
	poll()

	requests := h.endpoint.received()
	kinds := make([]string, 0, len(requests))
	for _, request := range requests {
		kinds = append(kinds, request.Kind)
	}
	if strings.Join(kinds, ",") != "permission,finished,permission" {
		t.Fatalf("bridge events = %v", kinds)
	}
	var event struct {
		Window string `json:"window"`
	}
	_ = json.Unmarshal(openPushPayloadForTest(t, phone.private, requests[0].Payload), &event)
	if event.Window != "@7" {
		t.Fatalf("bridge event window = %q", event.Window)
	}
}

func TestAcpBridgeCountsPushSignals(t *testing.T) {
	bridge := newTestAcpBridge()
	prompt := parseAcpEnvelope(json.RawMessage(`{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{}}`))
	if _, ok := bridge.trackClientRequest(prompt); !ok {
		t.Fatal("prompt not tracked")
	}
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{}}`), "", nil)
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","id":"e1","method":"elicitation/create","params":{}}`), "", nil)
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","id":"f1","method":"fs/read_text_file","params":{}}`), "", nil)

	info := bridge.snapshot()
	if info.PermissionRequests != 1 || info.InputRequests != 1 || info.PendingPermission != 1 ||
		info.PendingInput != 1 || info.CompletedTurns != 0 {
		t.Fatalf("after requests: %+v", info)
	}

	// The app answers the permission request.
	bridge.observeClientMessage(parseAcpEnvelope(json.RawMessage(`{"jsonrpc":"2.0","id":"p1","result":{}}`)))
	if info := bridge.snapshot(); info.PendingPermission != 0 || info.PendingInput != 1 {
		t.Fatalf("pending after an answer = %d permission, %d input", info.PendingPermission, info.PendingInput)
	}

	// The prompt turn ends; a response to another request does not count.
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","id":99,"result":{}}`), "", nil)
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","id":7,"result":{"stopReason":"end_turn"}}`), "", nil)
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","id":7,"result":{}}`), "", nil)
	if info := bridge.snapshot(); info.CompletedTurns != 1 {
		t.Fatalf("completed turns = %d", info.CompletedTurns)
	}

	// A prompt whose write failed never completes.
	failed := parseAcpEnvelope(json.RawMessage(`{"jsonrpc":"2.0","id":8,"method":"session/prompt","params":{}}`))
	id, _ := bridge.trackClientRequest(failed)
	bridge.untrackClientRequest(id)
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","id":8,"result":{}}`), "", nil)
	if info := bridge.snapshot(); info.CompletedTurns != 1 {
		t.Fatalf("an untracked prompt counted as a turn: %d", info.CompletedTurns)
	}
}

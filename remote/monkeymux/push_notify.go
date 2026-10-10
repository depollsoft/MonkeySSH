package main

// Push notifications for agent events (docs/push-notifications.md).
//
// The app registers each device with push_register. When a native agent
// waits for the user, finishes a turn, or a window rings the bell or posts a
// desktop notification, the server encrypts a small event to every registered
// device that is not already covering it and posts it to the pushNotify
// Firebase Function. Nothing readable about the session leaves the host apart
// from the coarse event kind.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	pushKindPermission = "permission"
	pushKindInput      = "input"
	pushKindFinished   = "finished"
	pushKindAlert      = "alert"
	pushKindTest       = "test"

	defaultPushEndpoint = "https://us-central1-monkeyssh.cloudfunctions.net/pushNotify"
	pushEndpointEnv     = "MONKEYMUX_PUSH_ENDPOINT"
	pushPresenceTTL     = 45 * time.Second
	// A background ("local") report lapses after one app heartbeat plus slack:
	// iOS suspends a backgrounded app within about 30 seconds and Android can
	// kill it, and a stale claim must not swallow events.
	pushLocalTTL = 25 * time.Second
	// One-off events skipped because the app claimed to alert locally are kept
	// this long and sent if that claim lapses first.
	pushDeferWindow        = 2 * time.Minute
	pushViewGrace          = 30 * time.Second
	pushCoalesceWindow     = 30 * time.Second
	pushHourlyCap          = 20
	pushRequestTimeout     = 10 * time.Second
	pushDefaultBackoff     = 60 * time.Second
	pushMaxBackoff         = time.Hour
	pushMaxConcurrentPosts = 4
	pushBridgePollInterval = 2 * time.Second
	pushResponseBodyLimit  = 4096
	pushEventQueueSize     = 64
)

// Results reported by push_test and push_register.
const (
	pushResultSent          = "sent"
	pushResultNotRegistered = "not_registered"
	pushResultBadTicket     = "bad_ticket"
	pushResultUnregistered  = "unregistered"
	pushResultRateLimited   = "rate_limited"
	pushResultCapped        = "capped"
	pushResultFailed        = "failed"
	// The function refused the event itself (400, 413, 415, other 4xx);
	// sending it again cannot help.
	pushResultRejected   = "rejected"
	pushResultRegistered = "registered"
	// The ticket offered to push_register was refused by the function; the
	// app must fetch a new one (and, for a dead token, a new token first).
	pushResultStaleTicket       = "stale_ticket"
	pushResultTokenUnregistered = "token_unregistered"
)

// pushBudget separates rate limits so routine events (finished turns, bells)
// can never use up the allowance approval requests depend on.
type pushBudget int

const (
	pushBudgetUrgent pushBudget = iota
	pushBudgetRoutine
	// Tests have their own budget so tapping "Send test" cannot hold back an
	// approval request.
	pushBudgetTest
)

func pushBudgetFor(kind string) pushBudget {
	switch kind {
	case pushKindPermission, pushKindInput:
		return pushBudgetUrgent
	case pushKindTest:
		return pushBudgetTest
	default:
		return pushBudgetRoutine
	}
}

// pushRetryDelays are the waits before the second and third attempts after a
// server error or network failure.
var pushRetryDelays = []time.Duration{time.Second, 3 * time.Second}

// pushBridgeStatus reads a native bridge's status; replaced in tests.
var pushBridgeStatus = acpBridgeStatus

// pushRecordBridgeDelivered stores a delivery record in a bridge; replaced in
// tests.
var pushRecordBridgeDelivered = recordAcpBridgePushDelivered

// pushControlRequest carries push fields on a control message.
type pushControlRequest struct {
	DeviceID   string `json:"deviceId,omitempty"`
	Ticket     string `json:"ticket,omitempty"`
	PublicKey  string `json:"publicKey,omitempty"`
	HostRef    string `json:"hostRef,omitempty"`
	Foreground bool   `json:"foreground,omitempty"`
	// Local reports that the app is alive in the background with this attach.
	// Alerts says it raises its own window alerts for this connection (its
	// window bar is mounted); Bridges lists the native agent bridges whose
	// events it raises itself.
	Local   bool     `json:"local,omitempty"`
	Alerts  bool     `json:"alerts,omitempty"`
	Bridges []string `json:"bridges,omitempty"`
}

// pushControlResult carries push fields on a control response.
type pushControlResult struct {
	Result string `json:"result,omitempty"`
}

// pushPresence is what one device last told this server about itself.
type pushPresence struct {
	clientID    string
	foreground  bool
	local       bool
	localAlerts bool
	// localBridges are the bridges the backgrounded app raises events for.
	localBridges map[string]bool
	reportedAt   time.Time
	// viewed records when a report last saw the device viewing each window.
	viewed map[string]time.Time
}

type pushCoalesceKey struct {
	deviceID string
	windowID string
	kind     string
}

type pushBudgetKey struct {
	deviceID string
	budget   pushBudget
}

// pushAttentionKey names one device's view of one kind of pending request on
// one bridge.
type pushAttentionKey struct {
	deviceID string
	bridgeID string
	kind     string
}

type pushBridgeBaseline struct {
	startedAt int64
	turns     uint64
}

// pushDeferred is a one-off event a device's app claimed to raise itself. It
// is sent if that claim lapses within pushDeferWindow.
type pushDeferred struct {
	deviceID string
	windowID string
	bridgeID string
	kind     string
	at       time.Time
}

// pushServerView is the server state attendance depends on, captured under
// the server mutex so the notifier never takes it.
type pushServerView struct {
	session  string
	activeID string
	attached map[string]bool
}

// pushJob is one event addressed to one device.
type pushJob struct {
	deviceID string
	ticket   string
	kind     string
	collapse string
	payload  string
}

// pushNotifier holds a server's push state. Its mutex is never held while the
// server mutex is taken.
type pushNotifier struct {
	store    pushStore
	endpoint string
	client   *http.Client
	now      func() time.Time
	sleep    func(time.Duration)
	posts    chan struct{}
	// alerts queues windows whose output rang the bell or posted a desktop
	// notification, so the PTY reader never waits on push work.
	alerts chan string

	mu           sync.Mutex
	presence     map[string]*pushPresence
	lastSent     map[pushCoalesceKey]time.Time
	sentTimes    map[pushBudgetKey][]time.Time
	backoffUntil map[pushBudgetKey]time.Time
	bridges      map[string]pushBridgeBaseline
	// delivered holds, per device, the newest pending-request generation that
	// device has been sent. A pending request below it is re-raised later.
	delivered map[pushAttentionKey]uint64
	deferred  []pushDeferred
	// inflight tracks posts so tests can wait for them.
	inflight sync.WaitGroup
}

func newPushNotifier() *pushNotifier {
	endpoint := strings.TrimSpace(os.Getenv(pushEndpointEnv))
	if endpoint == "" {
		endpoint = defaultPushEndpoint
	}
	notifier := &pushNotifier{
		endpoint:     endpoint,
		client:       &http.Client{Timeout: pushRequestTimeout},
		now:          time.Now,
		sleep:        time.Sleep,
		posts:        make(chan struct{}, pushMaxConcurrentPosts),
		alerts:       make(chan string, pushEventQueueSize),
		presence:     map[string]*pushPresence{},
		lastSent:     map[pushCoalesceKey]time.Time{},
		sentTimes:    map[pushBudgetKey][]time.Time{},
		backoffUntil: map[pushBudgetKey]time.Time{},
		bridges:      map[string]pushBridgeBaseline{},
		delivered:    map[pushAttentionKey]uint64{},
	}
	notifier.store.now = func() time.Time { return notifier.now() }
	return notifier
}

func (s *muxServer) pushNotifier() *pushNotifier {
	s.pushOnce.Do(func() {
		if s.push == nil {
			s.push = newPushNotifier()
		}
	})
	return s.push
}

// handlePushControl answers the push_* control operations.
func (s *muxServer) handlePushControl(client *controlClient, request controlMessage) {
	if request.Type == "push_test" {
		go func() { client.send(s.pushControlResponse(request)) }()
		return
	}
	client.send(s.pushControlResponse(request))
}

func (s *muxServer) pushControlResponse(request controlMessage) controlResponse {
	push := request.Push
	if push == nil {
		push = &pushControlRequest{}
	}
	fail := func(err error) controlResponse {
		return controlResponse{ID: request.ID, Type: "error", Status: "error", Error: err.Error()}
	}
	notifier := s.pushNotifier()
	deviceID := strings.TrimSpace(push.DeviceID)
	switch request.Type {
	case "push_register":
		record := pushDeviceRecord{
			DeviceID:  deviceID,
			Ticket:    strings.TrimSpace(push.Ticket),
			PublicKey: strings.TrimSpace(push.PublicKey),
			HostRef:   strings.TrimSpace(push.HostRef),
		}
		result, err := notifier.register(record)
		if err != nil {
			return fail(err)
		}
		if result != pushResultRegistered {
			return controlResponse{
				ID:     request.ID,
				Type:   "push_register_rejected",
				Status: "ok",
				Push:   &pushControlResult{Result: result},
			}
		}
		return controlResponse{
			ID:     request.ID,
			Type:   "push_registered",
			Status: "ok",
			Push:   &pushControlResult{Result: result},
		}
	case "push_unregister":
		if !pushDeviceIDPattern.MatchString(deviceID) {
			return fail(errPushInvalidDeviceID)
		}
		hostRef := strings.TrimSpace(push.HostRef)
		if hostRef != "" && !pushHostRefPattern.MatchString(hostRef) {
			return fail(errPushInvalidHostRef)
		}
		if err := notifier.unregister(deviceID, hostRef); err != nil {
			return fail(err)
		}
		return controlResponse{ID: request.ID, Type: "push_unregistered", Status: "ok"}
	case "push_presence":
		if !pushDeviceIDPattern.MatchString(deviceID) {
			return fail(errPushInvalidDeviceID)
		}
		clientID := strings.TrimSpace(request.ClientID)
		view := s.pushView([]string{clientID})
		notifier.recordPresence(deviceID, clientID, push, view)
		return controlResponse{ID: request.ID, Type: "push_presence_ack", Status: "ok"}
	case "push_test":
		if !pushDeviceIDPattern.MatchString(deviceID) {
			return fail(errPushInvalidDeviceID)
		}
		result := notifier.sendTest(deviceID, s.session)
		return controlResponse{
			ID:     request.ID,
			Type:   "push_test_result",
			Status: "ok",
			Push:   &pushControlResult{Result: result},
		}
	default:
		return fail(errors.New("unsupported push command"))
	}
}

// register stores a registration, or reports that the offered ticket was
// already refused by the function.
func (n *pushNotifier) register(record pushDeviceRecord) (string, error) {
	if err := validatePushRecord(record); err != nil {
		return "", err
	}
	result := pushResultRegistered
	err := n.store.mutate(func(state *pushStateFile, now time.Time) bool {
		switch pushRejectionFor(*state, record.DeviceID, record.Ticket) {
		case pushRejectedBadTicket:
			result = pushResultStaleTicket
			return false
		case pushRejectedUnregistered:
			result = pushResultTokenUnregistered
			return false
		}
		upsertPushRecord(state, record, now)
		return true
	})
	return result, err
}

// unregister removes one saved host's registration, or every registration
// for the device when hostRef is empty.
func (n *pushNotifier) unregister(deviceID string, hostRef string) error {
	err := n.store.mutate(func(state *pushStateFile, _ time.Time) bool {
		changed := false
		kept := state.Devices[:0]
		for _, record := range state.Devices {
			if record.DeviceID == deviceID && (hostRef == "" || record.HostRef == hostRef) {
				changed = true
				continue
			}
			kept = append(kept, record)
		}
		state.Devices = kept
		return changed
	})
	if err != nil {
		return err
	}
	devices, _ := n.store.snapshot()
	for _, record := range devices {
		if record.DeviceID == deviceID {
			return nil
		}
	}
	n.forgetDevice(deviceID)
	return nil
}

// rejectTicket removes the registrations the function refused for good and
// remembers the ticket so the app is told to replace it.
func (n *pushNotifier) rejectTicket(deviceID string, ticket string, reason string) {
	_ = n.store.mutate(func(state *pushStateFile, now time.Time) bool {
		return rejectPushTicket(state, deviceID, ticket, reason, now)
	})
	devices, _ := n.store.snapshot()
	for _, record := range devices {
		if record.DeviceID == deviceID {
			return
		}
	}
	n.forgetDevice(deviceID)
}

func (n *pushNotifier) forgetDevice(deviceID string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	delete(n.presence, deviceID)
	for key := range n.sentTimes {
		if key.deviceID == deviceID {
			delete(n.sentTimes, key)
		}
	}
	for key := range n.backoffUntil {
		if key.deviceID == deviceID {
			delete(n.backoffUntil, key)
		}
	}
	for key := range n.lastSent {
		if key.deviceID == deviceID {
			delete(n.lastSent, key)
		}
	}
	for key := range n.delivered {
		if key.deviceID == deviceID {
			delete(n.delivered, key)
		}
	}
}

// pushView captures the state attendance depends on.
func (s *muxServer) pushView(clientIDs []string) pushServerView {
	s.mu.Lock()
	defer s.mu.Unlock()
	view := pushServerView{
		session:  s.session,
		activeID: s.activeID,
		attached: map[string]bool{},
	}
	for _, clientID := range clientIDs {
		if clientID != "" && s.attachClientByIDLocked(clientID) != nil {
			view.attached[clientID] = true
		}
	}
	return view
}

func (n *pushNotifier) recordPresence(
	deviceID string,
	clientID string,
	report *pushControlRequest,
	view pushServerView,
) {
	foreground := report.Foreground
	now := n.now()
	n.mu.Lock()
	defer n.mu.Unlock()
	presence := n.presence[deviceID]
	if presence == nil {
		presence = &pushPresence{viewed: map[string]time.Time{}}
		n.presence[deviceID] = presence
	}
	// A device in the foreground with its attach client attached is viewing
	// the active window; one that just left was viewing it until now.
	wasViewing := presence.foreground && presence.clientID != "" &&
		view.attached[presence.clientID]
	isViewing := foreground && clientID != "" && view.attached[clientID]
	if view.activeID != "" && (wasViewing || isViewing) {
		presence.viewed[view.activeID] = now
	}
	for windowID, at := range presence.viewed {
		if now.Sub(at) > pushViewGrace {
			delete(presence.viewed, windowID)
		}
	}
	presence.clientID = clientID
	presence.foreground = foreground
	presence.local = report.Local && !foreground
	presence.localAlerts = presence.local && report.Alerts
	presence.localBridges = map[string]bool{}
	if presence.local {
		for _, bridgeID := range report.Bridges {
			if validAcpBridgeID(bridgeID) && len(presence.localBridges) < 64 {
				presence.localBridges[bridgeID] = true
			}
		}
	}
	presence.reportedAt = now
}

func (n *pushNotifier) presentLocked(presence *pushPresence, view pushServerView, now time.Time) bool {
	return now.Sub(presence.reportedAt) <= pushPresenceTTL && view.attached[presence.clientID]
}

// attendingLocked reports whether the device is looking at windowID or did so
// in the last pushViewGrace.
func (n *pushNotifier) attendingLocked(
	deviceID string,
	windowID string,
	view pushServerView,
	now time.Time,
) bool {
	presence := n.presence[deviceID]
	if presence == nil {
		return false
	}
	if presence.foreground && n.presentLocked(presence, view, now) && view.activeID == windowID {
		return true
	}
	at, ok := presence.viewed[windowID]
	return ok && now.Sub(at) <= pushViewGrace
}

// coveredLocallyLocked reports whether the app on that device is alive in the
// background with this attach and says it raises this event itself: window
// alerts while its window bar is mounted, and native agent events from a
// bridge it is attached to. The claim lapses after pushLocalTTL.
func (n *pushNotifier) coveredLocallyLocked(
	deviceID string,
	kind string,
	bridgeID string,
	view pushServerView,
	now time.Time,
) bool {
	presence := n.presence[deviceID]
	if presence == nil || !presence.local ||
		now.Sub(presence.reportedAt) > pushLocalTTL ||
		!view.attached[presence.clientID] {
		return false
	}
	if kind == pushKindAlert {
		return presence.localAlerts
	}
	return bridgeID != "" && presence.localBridges[bridgeID]
}

// admitLocked applies backoff, coalescing and the hourly cap of the event's
// budget, and records the send when it is admitted.
func (n *pushNotifier) admitLocked(key pushCoalesceKey, now time.Time, coalesce bool) string {
	budget := pushBudgetKey{deviceID: key.deviceID, budget: pushBudgetFor(key.kind)}
	if until, ok := n.backoffUntil[budget]; ok {
		if now.Before(until) {
			return pushResultRateLimited
		}
		delete(n.backoffUntil, budget)
	}
	if coalesce {
		if last, ok := n.lastSent[key]; ok && now.Sub(last) < pushCoalesceWindow {
			return pushResultCapped
		}
	}
	recent := n.sentTimes[budget][:0]
	for _, at := range n.sentTimes[budget] {
		if now.Sub(at) < time.Hour {
			recent = append(recent, at)
		}
	}
	n.sentTimes[budget] = recent
	if len(recent) >= pushHourlyCap {
		return pushResultCapped
	}
	n.sentTimes[budget] = append(recent, now)
	if coalesce {
		n.lastSent[key] = now
		for candidate, at := range n.lastSent {
			if now.Sub(at) >= pushCoalesceWindow {
				delete(n.lastSent, candidate)
			}
		}
	}
	return ""
}

// pushDevicesByID keeps one registration per device, preferring the most
// recently updated, so a machine reached through two saved hosts sends each
// event once.
func pushDevicesByID(devices []pushDeviceRecord) []pushDeviceRecord {
	best := map[string]int{}
	order := make([]string, 0, len(devices))
	for index, record := range devices {
		current, ok := best[record.DeviceID]
		if !ok {
			order = append(order, record.DeviceID)
			best[record.DeviceID] = index
			continue
		}
		if record.UpdatedAt > devices[current].UpdatedAt {
			best[record.DeviceID] = index
		}
	}
	unique := make([]pushDeviceRecord, 0, len(order))
	for _, id := range order {
		unique = append(unique, devices[best[id]])
	}
	return unique
}

// notePushAlert queues a window alert from the PTY reader without blocking
// it. Nothing is queued while no device is registered.
func (s *muxServer) notePushAlert(windowID string) {
	notifier := s.pushNotifier()
	if !notifier.store.mayHaveDevices() {
		return
	}
	select {
	case notifier.alerts <- windowID:
	default:
	}
}

// raisePushEvent sends a one-off event (a finished turn or a window alert) for
// windowID to every device that is not already covering it. bridgeID names
// the native agent bridge behind a finished turn.
func (s *muxServer) raisePushEvent(windowID string, kind string, bridgeID string) {
	notifier := s.pushNotifier()
	devices, salt := notifier.store.snapshot()
	if len(devices) == 0 || windowID == "" {
		return
	}
	view := s.pushView(notifier.presenceClientIDs())
	now := notifier.now()

	notifier.mu.Lock()
	if kind == pushKindAlert {
		for deviceID := range notifier.presence {
			if notifier.attendingLocked(deviceID, windowID, view, now) {
				notifier.mu.Unlock()
				return
			}
		}
	}
	admitted := make([]pushDeviceRecord, 0, len(devices))
	for _, device := range pushDevicesByID(devices) {
		if notifier.attendingLocked(device.DeviceID, windowID, view, now) {
			continue
		}
		if notifier.coveredLocallyLocked(device.DeviceID, kind, bridgeID, view, now) {
			notifier.deferLocked(pushDeferred{
				deviceID: device.DeviceID,
				windowID: windowID,
				bridgeID: bridgeID,
				kind:     kind,
				at:       now,
			})
			continue
		}
		key := pushCoalesceKey{deviceID: device.DeviceID, windowID: windowID, kind: kind}
		if notifier.admitLocked(key, now, true) != "" {
			continue
		}
		admitted = append(admitted, device)
	}
	notifier.mu.Unlock()

	for _, device := range admitted {
		job, err := buildPushJob(device, salt, view.session, windowID, kind, now)
		if err != nil {
			continue
		}
		notifier.post(job, nil)
	}
}

// raisePushAttention sends a pending permission or input request on bridgeID
// (shown in windowID) to every device that has not been sent this generation
// of it yet. A device that is watching, covered locally, backed off or capped
// is not marked, so the next poll tries again while the request is pending.
// bridgeDelivered is the bridge's own delivery record, which outlives this
// server.
func (s *muxServer) raisePushAttention(
	windowID string,
	bridgeID string,
	kind string,
	generation uint64,
	bridgeDelivered map[string]uint64,
) {
	notifier := s.pushNotifier()
	devices, salt := notifier.store.snapshot()
	if len(devices) == 0 || windowID == "" || generation == 0 {
		return
	}
	view := s.pushView(notifier.presenceClientIDs())
	now := notifier.now()

	type admittedDevice struct {
		record   pushDeviceRecord
		key      pushAttentionKey
		previous uint64
	}
	notifier.mu.Lock()
	admitted := make([]admittedDevice, 0, len(devices))
	for _, device := range pushDevicesByID(devices) {
		key := pushAttentionKey{deviceID: device.DeviceID, bridgeID: bridgeID, kind: kind}
		previous := max(notifier.delivered[key], bridgeDelivered[acpPushDeliveredKey(device.DeviceID, kind)])
		if previous >= generation {
			notifier.delivered[key] = previous
			continue
		}
		if notifier.attendingLocked(device.DeviceID, windowID, view, now) ||
			notifier.coveredLocallyLocked(device.DeviceID, kind, bridgeID, view, now) {
			continue
		}
		coalesceKey := pushCoalesceKey{deviceID: device.DeviceID, windowID: windowID, kind: kind}
		if notifier.admitLocked(coalesceKey, now, true) != "" {
			continue
		}
		notifier.delivered[key] = generation
		admitted = append(admitted, admittedDevice{device, key, previous})
	}
	notifier.mu.Unlock()

	for _, entry := range admitted {
		job, err := buildPushJob(entry.record, salt, view.session, windowID, kind, now)
		if err != nil {
			continue
		}
		key, previous := entry.key, entry.previous
		// Recorded in the bridge before sending, so a successor server does not
		// push it again even if this one exits mid-delivery.
		_ = pushRecordBridgeDelivered(bridgeID, key.deviceID, kind, generation)
		notifier.post(job, func(result string) {
			switch result {
			case pushResultSent, pushResultRejected:
				// Delivered, or the function refused the event itself:
				// sending it again cannot help.
				return
			}
			// Not delivered: throttled, failed, or the registration was
			// refused (bad ticket, dead token). Let a later poll raise it
			// again, which reaches the app once it registers afresh.
			notifier.mu.Lock()
			current := notifier.delivered[key]
			if current == generation {
				notifier.delivered[key] = previous
			}
			notifier.mu.Unlock()
			// A refused registration also clears this device's memory, so the
			// bridge's record must be rolled back even when ours is gone.
			if current == generation || result == pushResultBadTicket ||
				result == pushResultUnregistered {
				_ = pushRecordBridgeDelivered(bridgeID, key.deviceID, kind, previous)
			}
		})
	}
}

func (n *pushNotifier) presenceClientIDs() []string {
	n.mu.Lock()
	defer n.mu.Unlock()
	clientIDs := make([]string, 0, len(n.presence))
	for _, presence := range n.presence {
		clientIDs = append(clientIDs, presence.clientID)
	}
	return clientIDs
}

// post delivers job in the background and reports the result to done.
func (n *pushNotifier) post(job pushJob, done func(string)) {
	n.inflight.Add(1)
	go func() {
		defer n.inflight.Done()
		n.posts <- struct{}{}
		defer func() { <-n.posts }()
		result := n.deliver(job)
		if done != nil {
			done(result)
		}
	}()
}

// sendTest posts a test event to one device and waits for the outcome.
func (n *pushNotifier) sendTest(deviceID string, session string) string {
	devices, salt := n.store.snapshot()
	var device *pushDeviceRecord
	for _, candidate := range pushDevicesByID(devices) {
		if candidate.DeviceID == deviceID {
			device = &candidate
			break
		}
	}
	if device == nil {
		return pushResultNotRegistered
	}
	now := n.now()
	n.mu.Lock()
	refused := n.admitLocked(pushCoalesceKey{deviceID: deviceID, kind: pushKindTest}, now, false)
	n.mu.Unlock()
	if refused != "" {
		return refused
	}
	// A test opens the host, not a window, so the payload names neither.
	job, err := buildPushJob(*device, salt, "", "", pushKindTest, now)
	if err != nil {
		return pushResultFailed
	}
	job.collapse = pushCollapseKey(salt, deviceID, session, "test")
	// The app is waiting on the answer, so a test gets one attempt.
	return n.deliverWithRetries(job, nil)
}

func buildPushJob(
	device pushDeviceRecord,
	salt []byte,
	session string,
	windowID string,
	kind string,
	now time.Time,
) (pushJob, error) {
	publicKey, err := parsePushPublicKey(device.PublicKey)
	if err != nil {
		return pushJob{}, err
	}
	plaintext, err := json.Marshal(struct {
		V         int    `json:"v"`
		HostRef   string `json:"hostRef"`
		Window    string `json:"window"`
		SessionID string `json:"sessionId"`
		Kind      string `json:"kind"`
		TS        int64  `json:"ts"`
	}{1, device.HostRef, windowID, session, kind, now.Unix()})
	if err != nil {
		return pushJob{}, err
	}
	payload, err := encryptPushPayload(publicKey, plaintext)
	if err != nil {
		return pushJob{}, err
	}
	return pushJob{
		deviceID: device.DeviceID,
		ticket:   device.Ticket,
		kind:     kind,
		collapse: pushCollapseKey(salt, device.DeviceID, session, windowID),
		payload:  payload,
	}, nil
}

// deliver posts a job with retries and applies the function's answer.
func (n *pushNotifier) deliver(job pushJob) string {
	return n.deliverWithRetries(job, pushRetryDelays)
}

func (n *pushNotifier) deliverWithRetries(job pushJob, retryDelays []time.Duration) string {
	body, err := json.Marshal(map[string]string{
		"ticket":   job.ticket,
		"kind":     job.kind,
		"collapse": job.collapse,
		"payload":  job.payload,
	})
	if err != nil {
		return pushResultFailed
	}
	for attempt := 0; ; attempt++ {
		status, retryAfter, err := n.postOnce(body)
		switch {
		case err == nil && status == http.StatusAccepted:
			return pushResultSent
		case err == nil && status == http.StatusUnauthorized:
			n.rejectTicket(job.deviceID, job.ticket, pushRejectedBadTicket)
			return pushResultBadTicket
		case err == nil && status == http.StatusGone:
			n.rejectTicket(job.deviceID, job.ticket, pushRejectedUnregistered)
			return pushResultUnregistered
		case err == nil && status == http.StatusTooManyRequests:
			n.backOff(job.deviceID, pushBudgetFor(job.kind), retryAfter)
			return pushResultRateLimited
		case err == nil && status < http.StatusInternalServerError:
			return pushResultRejected
		}
		if attempt >= len(retryDelays) {
			return pushResultFailed
		}
		n.sleep(retryDelays[attempt])
	}
}

func (n *pushNotifier) postOnce(body []byte) (int, time.Duration, error) {
	ctx, cancel := context.WithTimeout(context.Background(), pushRequestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, n.endpoint, bytes.NewReader(body))
	if err != nil {
		return 0, 0, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("User-Agent", "monkeymux/"+monkeyMuxVersion)
	response, err := n.client.Do(request)
	if err != nil {
		return 0, 0, err
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, pushResponseBodyLimit))
	var retryAfter time.Duration
	if seconds, err := strconv.Atoi(strings.TrimSpace(response.Header.Get("Retry-After"))); err == nil && seconds > 0 {
		retryAfter = time.Duration(seconds) * time.Second
	}
	return response.StatusCode, retryAfter, nil
}

func (n *pushNotifier) backOff(deviceID string, budget pushBudget, retryAfter time.Duration) {
	if retryAfter <= 0 {
		retryAfter = pushDefaultBackoff
	}
	if retryAfter > pushMaxBackoff {
		retryAfter = pushMaxBackoff
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	n.backoffUntil[pushBudgetKey{deviceID: deviceID, budget: budget}] = n.now().Add(retryAfter)
}

// isPushAlertOutput reports whether a window's output carried a bell or a
// desktop notification: OSC 9 text, OSC 777;notify, or an OSC 99 notification
// that is not a query or a close request. Shell-integration OSC 777 marks
// (precmd, preexec) and progress reports do not count.
func isPushAlertOutput(bell bool, completedOscs [][]byte) bool {
	if bell {
		return true
	}
	for _, payload := range completedOscs {
		if !isForwardableOscNotification(payload) {
			continue
		}
		code, rest, _ := strings.Cut(string(payload), ";")
		switch code {
		case "777":
			if sub, _, _ := strings.Cut(rest, ";"); sub == "notify" {
				return true
			}
		case "99":
			metadata, _, _ := strings.Cut(rest, ";")
			if !strings.Contains(metadata, "p=?") && !strings.Contains(metadata, "p=close") {
				return true
			}
		default:
			return true
		}
	}
	return false
}

// startPushLoop runs the notifier off the PTY readers: it delivers queued
// window alerts and polls native agent bridges while any device is
// registered.
func (s *muxServer) startPushLoop() {
	notifier := s.pushNotifier()
	go func() {
		ticker := time.NewTicker(pushBridgePollInterval)
		defer ticker.Stop()
		for {
			select {
			case windowID := <-notifier.alerts:
				s.raisePushEvent(windowID, pushKindAlert, "")
			case <-ticker.C:
				if s.isClosed() {
					return
				}
				s.pollPushBridges()
			}
		}
	}()
}

func (s *muxServer) pollPushBridges() {
	notifier := s.pushNotifier()
	if !notifier.store.hasDevices() {
		notifier.mu.Lock()
		clear(notifier.bridges)
		clear(notifier.delivered)
		notifier.deferred = nil
		notifier.mu.Unlock()
		return
	}
	s.flushPushDeferred()
	type target struct{ windowID, bridgeID string }
	s.mu.Lock()
	targets := make([]target, 0)
	for _, window := range s.windows {
		if !window.closed && validAcpBridgeID(window.nativeAcpBridgeID) {
			targets = append(targets, target{window.id, window.nativeAcpBridgeID})
		}
	}
	s.mu.Unlock()
	live := map[string]bool{}
	for _, target := range targets {
		live[target.bridgeID] = true
		info, err := pushBridgeStatus(target.bridgeID)
		if err != nil {
			// Keep the baseline: events while the status read failed are
			// still seen on the next successful poll.
			continue
		}
		if notifier.observeBridge(target.bridgeID, info) {
			s.raisePushEvent(target.windowID, pushKindFinished, target.bridgeID)
		}
		pendingPermission, pendingInput := pushPendingCounts(info)
		if pendingPermission {
			s.raisePushAttention(target.windowID, target.bridgeID, pushKindPermission, info.PermissionRequests, info.PushDelivered)
		}
		if pendingInput {
			s.raisePushAttention(target.windowID, target.bridgeID, pushKindInput, info.InputRequests, info.PushDelivered)
		}
	}
	notifier.mu.Lock()
	for bridgeID := range notifier.bridges {
		if !live[bridgeID] {
			delete(notifier.bridges, bridgeID)
		}
	}
	for key := range notifier.delivered {
		if !live[key.bridgeID] {
			delete(notifier.delivered, key)
		}
	}
	notifier.mu.Unlock()
}

// observeBridge compares a bridge's completed-turn counter with the last poll
// and reports whether a turn finished. The first sighting only sets the
// baseline; a restarted bridge also forgets which requests were delivered.
func (n *pushNotifier) observeBridge(bridgeID string, info acpBridgeInfo) bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	next := pushBridgeBaseline{startedAt: info.StartedAt, turns: info.CompletedTurns}
	previous, known := n.bridges[bridgeID]
	n.bridges[bridgeID] = next
	if known && previous.startedAt != next.startedAt {
		for key := range n.delivered {
			if key.bridgeID == bridgeID {
				delete(n.delivered, key)
			}
		}
		return false
	}
	return known && next.turns > previous.turns
}

// pushPendingCounts reports which kinds of request a bridge has pending. A
// bridge preserved across an upgrade from an earlier build of this branch
// reports only a combined count; then any kind it has ever asked for is
// treated as possibly pending.
func pushPendingCounts(info acpBridgeInfo) (permission bool, input bool) {
	if info.PendingPermission > 0 || info.PendingInput > 0 || info.LegacyPendingAttention == 0 {
		return info.PendingPermission > 0, info.PendingInput > 0
	}
	return info.PermissionRequests > 0, info.InputRequests > 0
}

func (n *pushNotifier) deferLocked(event pushDeferred) {
	for _, existing := range n.deferred {
		if existing.deviceID == event.deviceID && existing.windowID == event.windowID &&
			existing.kind == event.kind {
			return
		}
	}
	if len(n.deferred) >= pushEventQueueSize {
		n.deferred = n.deferred[1:]
	}
	n.deferred = append(n.deferred, event)
}

// flushPushDeferred sends deferred one-off events whose local coverage lapsed
// within pushDeferWindow, and forgets the rest once that window passes.
func (s *muxServer) flushPushDeferred() {
	notifier := s.pushNotifier()
	notifier.mu.Lock()
	if len(notifier.deferred) == 0 {
		notifier.mu.Unlock()
		return
	}
	notifier.mu.Unlock()
	devices, salt := notifier.store.snapshot()
	view := s.pushView(notifier.presenceClientIDs())
	now := notifier.now()
	byID := map[string]pushDeviceRecord{}
	for _, device := range pushDevicesByID(devices) {
		byID[device.DeviceID] = device
	}

	notifier.mu.Lock()
	due := make([]pushDeferred, 0)
	kept := notifier.deferred[:0]
	for _, event := range notifier.deferred {
		if now.Sub(event.at) > pushDeferWindow {
			continue
		}
		if notifier.coveredLocallyLocked(event.deviceID, event.kind, event.bridgeID, view, now) {
			kept = append(kept, event)
			continue
		}
		due = append(due, event)
	}
	notifier.deferred = kept
	admitted := make([]pushDeferred, 0, len(due))
	for _, event := range due {
		if _, ok := byID[event.deviceID]; !ok ||
			notifier.attendingLocked(event.deviceID, event.windowID, view, now) {
			continue
		}
		key := pushCoalesceKey{deviceID: event.deviceID, windowID: event.windowID, kind: event.kind}
		if notifier.admitLocked(key, now, true) != "" {
			continue
		}
		admitted = append(admitted, event)
	}
	notifier.mu.Unlock()

	for _, event := range admitted {
		job, err := buildPushJob(byID[event.deviceID], salt, view.session, event.windowID, event.kind, event.at)
		if err != nil {
			continue
		}
		notifier.post(job, nil)
	}
}

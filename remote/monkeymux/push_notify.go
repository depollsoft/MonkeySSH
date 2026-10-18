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
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
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
	// pushStatusAlertGrace is how long after a finished turn reached a
	// device a bell or desktop notification from that window is taken for
	// the turn's own (see alertRedundantLocked).
	pushStatusAlertGrace = 15 * time.Second
	// pushStatusWait bounds how much longer a window alert is held while a
	// status push for its window is still on its way.
	pushStatusWait = 5 * time.Second
	// pushDrainTimeout bounds how long a closing server waits for its pushes
	// in flight.
	pushDrainTimeout = 2 * time.Second
)

// pushAlertHold is how long a window alert waits before it is pushed: an
// agent that needs the user or finishes often rings first and reports its
// status in the next chunk, and that status is the better notification.
var pushAlertHold = 1500 * time.Millisecond

// Event categories a registration can ask for (push_register's events).
// Permission and input requests are "attention"; a window alert is "bell"
// when a BEL raised it and "notice" when a desktop notification (OSC 9, 777
// notify, 99) did. Test pushes are always sent.
const (
	pushEventAttention = "attention"
	pushEventFinished  = "finished"
	pushEventBell      = "bell"
	pushEventNotice    = "notice"
)

// pushEventCategories is every category, in the order records store them.
var pushEventCategories = []string{pushEventAttention, pushEventFinished, pushEventBell, pushEventNotice}

// pushAlertCategories says what raised a window alert. A window's pending
// alert can carry both.
type pushAlertCategories uint8

const (
	pushAlertBell pushAlertCategories = 1 << iota
	pushAlertNotice
	// pushAlertAny is an alert whose cause was not recorded.
	pushAlertAny = pushAlertBell | pushAlertNotice
)

// normalizePushEvents keeps the known categories of a push_register events
// list, once each and in canonical order. Nil (no list) stays nil, meaning
// every category.
func normalizePushEvents(events *[]string) *[]string {
	if events == nil {
		return nil
	}
	known := make([]string, 0, len(pushEventCategories))
	for _, category := range pushEventCategories {
		if slices.Contains(*events, category) {
			known = append(known, category)
		}
	}
	return &known
}

// wants reports whether the record asked for category. A record from an app
// that sent no events list wants everything.
func (r pushDeviceRecord) wants(category string) bool {
	return r.Events == nil || slices.Contains(*r.Events, category)
}

// wantedAlerts is the part of an alert's categories the record asked for.
func (r pushDeviceRecord) wantedAlerts(categories pushAlertCategories) pushAlertCategories {
	var wanted pushAlertCategories
	if categories&pushAlertBell != 0 && r.wants(pushEventBell) {
		wanted |= pushAlertBell
	}
	if categories&pushAlertNotice != 0 && r.wants(pushEventNotice) {
		wanted |= pushAlertNotice
	}
	return wanted
}

// wantsEvent reports whether the record asked for an event of kind; alerts
// are the categories an alert carries.
func (r pushDeviceRecord) wantsEvent(kind string, alerts pushAlertCategories) bool {
	switch kind {
	case pushKindPermission, pushKindInput:
		return r.wants(pushEventAttention)
	case pushKindFinished:
		return r.wants(pushEventFinished)
	case pushKindAlert:
		return r.wantedAlerts(alerts) != 0
	default:
		return true
	}
}

// pushRecipients keeps the registrations that want an event, one per device
// (see pushDevicesByID).
func pushRecipients(devices []pushDeviceRecord, kind string, alerts pushAlertCategories) []pushDeviceRecord {
	wanted := make([]pushDeviceRecord, 0, len(devices))
	for _, record := range devices {
		if record.wantsEvent(kind, alerts) {
			wanted = append(wanted, record)
		}
	}
	return pushDevicesByID(wanted)
}

// pushAlertEvent is a window event queued by the PTY reader: an alert with its
// categories, or, when kind is set, a program status change of that push kind.
type pushAlertEvent struct {
	windowID   string
	categories pushAlertCategories
	kind       string
}

// Results reported by push_test and push_register.
const (
	pushResultSent          = "sent"
	pushResultNotRegistered = "not_registered"
	pushResultBadTicket     = "bad_ticket"
	pushResultUnregistered  = "unregistered"
	pushResultRateLimited   = "rate_limited"
	pushResultCapped        = "capped"
	// The device was sent the same kind for the window a moment ago.
	pushResultCoalesced = "coalesced"
	pushResultFailed    = "failed"
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
	DeviceID  string `json:"deviceId,omitempty"`
	Ticket    string `json:"ticket,omitempty"`
	PublicKey string `json:"publicKey,omitempty"`
	HostRef   string `json:"hostRef,omitempty"`
	// Events lists the categories push_register asks for
	// (pushEventCategories); absent means all of them.
	Events     *[]string `json:"events,omitempty"`
	Foreground bool      `json:"foreground,omitempty"`
	// Local reports that the app is alive in the background with this attach.
	// Alerts says it raises its own bell alerts for this connection (its
	// window bar is mounted) and Notices its own desktop notifications;
	// without Notices (an older app), Alerts covers both. Bridges lists the
	// native agent bridges whose events it raises itself.
	Local   bool     `json:"local,omitempty"`
	Alerts  bool     `json:"alerts,omitempty"`
	Notices *bool    `json:"notices,omitempty"`
	Bridges []string `json:"bridges,omitempty"`
}

// pushControlResult carries push fields on a control response.
type pushControlResult struct {
	Result string `json:"result,omitempty"`
	// Events echoes, on push_registered, the categories the registration
	// will receive. Helpers before 0.1.233 ignore the request's events and
	// echo nothing, which tells the app they cannot filter.
	Events *[]string `json:"events,omitempty"`
}

// pushPresence is what one device last told this server about itself.
type pushPresence struct {
	clientID   string
	foreground bool
	local      bool
	// localBells and localNotices say the backgrounded app raises a window's
	// bell alerts and desktop notifications itself.
	localBells   bool
	localNotices bool
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
	// alerts are the alert categories the device was skipped for.
	alerts pushAlertCategories
	at     time.Time
}

// pushServerView is the server state attendance depends on, captured under
// the server mutex so the notifier never takes it.
type pushServerView struct {
	session  string
	activeID string
	attached map[string]bool
	// agents names the agent each window runs (see pushAgentName), and
	// titles each window's title (see pushWindowTitleLocked), for the
	// encrypted payload.
	agents map[string]string
	titles map[string]string
	// blocked holds, for each window whose program reports it is waiting on
	// the user (OSC 7501 blocked), the push kind of that request; finished
	// holds the windows whose program reports done or idle.
	blocked  map[string]string
	finished map[string]bool
}

// pushJob is one event addressed to one device.
type pushJob struct {
	deviceID string
	ticket   string
	kind     string
	collapse string
	payload  string
	// windowID is the window the push is for.
	windowID string
	// admittedAt is when coalescing admitted the push (see admitLocked), or
	// zero; a push that never arrives does not hold the next one back.
	admittedAt time.Time
}

// pushHeldAlert is a window alert waiting out pushAlertHold.
type pushHeldAlert struct {
	windowID   string
	categories pushAlertCategories
	at         time.Time
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
	alerts chan pushAlertEvent

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
	// held are window alerts waiting out pushAlertHold.
	held []pushHeldAlert
	// statusSent records, per device and window, the last program status
	// push that reached the device, so the event's own alert is not pushed
	// as well; statusPosting counts the status pushes per window still on
	// their way.
	statusSent    map[pushDeviceWindow]pushStatusSent
	statusPosting map[string]int
	// inflight tracks posts so tests can wait for them, and queued the window
	// events taken in but not yet raised or held.
	inflight sync.WaitGroup
	queued   sync.WaitGroup
	// stopQueue and stopPosts end the counting above once a closing server's
	// drain waits on it (see startPushDrain).
	stopQueue bool
	stopPosts bool
}

func newPushNotifier() *pushNotifier {
	endpoint := strings.TrimSpace(os.Getenv(pushEndpointEnv))
	if endpoint == "" {
		endpoint = defaultPushEndpoint
	}
	notifier := &pushNotifier{
		endpoint:      endpoint,
		client:        &http.Client{Timeout: pushRequestTimeout},
		now:           time.Now,
		sleep:         time.Sleep,
		posts:         make(chan struct{}, pushMaxConcurrentPosts),
		alerts:        make(chan pushAlertEvent, pushEventQueueSize),
		presence:      map[string]*pushPresence{},
		lastSent:      map[pushCoalesceKey]time.Time{},
		sentTimes:     map[pushBudgetKey][]time.Time{},
		backoffUntil:  map[pushBudgetKey]time.Time{},
		bridges:       map[string]pushBridgeBaseline{},
		delivered:     map[pushAttentionKey]uint64{},
		statusSent:    map[pushDeviceWindow]pushStatusSent{},
		statusPosting: map[string]int{},
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
			Events:    normalizePushEvents(push.Events),
		}
		// The session is this server's, never the app's claim: the
		// registration only receives this session's events.
		result, err := notifier.register(record, s.session)
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
		events := pushEventCategories
		if record.Events != nil {
			events = *record.Events
		}
		return controlResponse{
			ID:     request.ID,
			Type:   "push_registered",
			Status: "ok",
			Push:   &pushControlResult{Result: result, Events: &events},
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
func (n *pushNotifier) register(record pushDeviceRecord, session string) (string, error) {
	if err := validatePushRecord(record); err != nil {
		return "", err
	}
	result := pushResultRegistered
	var saltErr error
	err := n.store.mutate(func(state *pushStateFile, now time.Time) bool {
		switch pushRejectionFor(*state, record.DeviceID, record.Ticket) {
		case pushRejectedBadTicket:
			result = pushResultStaleTicket
			return false
		case pushRejectedUnregistered:
			result = pushResultTokenUnregistered
			return false
		}
		salt, err := ensurePushSalt(state)
		if err != nil {
			saltErr = err
			return false
		}
		record.SessionKey = pushSessionKey(salt, session)
		upsertPushRecord(state, record, now)
		return true
	})
	if err == nil {
		err = saltErr
	}
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
		agents:   map[string]string{},
		titles:   map[string]string{},
		blocked:  map[string]string{},
		finished: map[string]bool{},
	}
	for _, window := range s.windows {
		switch summary := window.programStatusSummaryLocked(); summary.state {
		case "blocked":
			view.blocked[window.id] = programStatusPushKind(programStatusSummary{}, summary)
		case "done", "idle":
			view.finished[window.id] = true
		}
		// The resolved tool, as the window bar shows it: the live command, else
		// what the window retains (its recorded tool, title or name).
		agent := pushAgentName(window.agentToolLocked())
		if agent != "" {
			view.agents[window.id] = agent
		}
		if title := pushWindowTitleLocked(window, agent); title != "" {
			view.titles[window.id] = title
		}
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
	presence.localBells = presence.local && report.Alerts
	notices := report.Alerts
	if report.Notices != nil {
		notices = *report.Notices
	}
	presence.localNotices = presence.local && notices
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
// bridge it is attached to. For an alert, alerts are the categories the
// device would be told about, and the app must cover each of them. The claim
// lapses after pushLocalTTL.
func (n *pushNotifier) coveredLocallyLocked(
	deviceID string,
	kind string,
	bridgeID string,
	alerts pushAlertCategories,
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
		if alerts == 0 ||
			(alerts&pushAlertBell != 0 && !presence.localBells) ||
			(alerts&pushAlertNotice != 0 && !presence.localNotices) {
			return false
		}
		return true
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
			return pushResultCoalesced
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
func (s *muxServer) notePushAlert(windowID string, categories pushAlertCategories) {
	notifier := s.pushNotifier()
	if categories == 0 || !notifier.store.mayHaveDevices() {
		return
	}
	notifier.enqueue(pushAlertEvent{windowID: windowID, categories: categories})
}

// enqueue queues event for the push loop, counted in queued until it is
// raised or held (see consumePushAlertEvent), so a closing server's drain
// waits for one the loop already took.
func (n *pushNotifier) enqueue(event pushAlertEvent) {
	n.mu.Lock()
	if n.stopQueue {
		// The server closed; its drain is already waiting.
		n.mu.Unlock()
		return
	}
	n.queued.Add(1)
	n.mu.Unlock()
	select {
	case n.alerts <- event:
	default:
		n.queued.Done()
	}
}

// consumePushAlertEvent delivers an event taken from the queue and ends its
// count in queued.
func (s *muxServer) consumePushAlertEvent(event pushAlertEvent) {
	defer s.pushNotifier().queued.Done()
	s.deliverPushAlertEvent(event)
}

// notePushProgramStatus queues the push a window's program status change calls
// for (see programStatusPushKind) without blocking the PTY reader.
func (s *muxServer) notePushProgramStatus(windowID string, kind string) {
	notifier := s.pushNotifier()
	if kind == "" || !notifier.store.mayHaveDevices() {
		return
	}
	notifier.enqueue(pushAlertEvent{windowID: windowID, kind: kind})
}

// deliverPushAlertEvent raises the push for an event the PTY reader queued. A
// status change is pushed at once; an alert waits out pushAlertHold (see
// releaseHeldPushAlerts) so a status change right after it wins.
func (s *muxServer) deliverPushAlertEvent(event pushAlertEvent) {
	if event.kind != "" {
		s.raisePush(event.windowID, event.kind, "", 0)
		return
	}
	if event.categories == 0 {
		return
	}
	notifier := s.pushNotifier()
	notifier.mu.Lock()
	defer notifier.mu.Unlock()
	for index, held := range notifier.held {
		if held.windowID == event.windowID {
			notifier.held[index].categories |= event.categories
			return
		}
	}
	if len(notifier.held) >= pushEventQueueSize {
		notifier.held = notifier.held[1:]
	}
	notifier.held = append(notifier.held, pushHeldAlert{
		windowID:   event.windowID,
		categories: event.categories,
		at:         notifier.now(),
	})
}

// releaseHeldPushAlerts pushes the held alerts whose hold has passed, and
// returns how long until the next one is due, or 0 when none is held. An
// alert whose window still has a status push on its way waits for it (up to
// pushStatusWait more), so it can give way to that status.
func (s *muxServer) releaseHeldPushAlerts() time.Duration {
	return s.releaseHeldPushAlertsAt(false)
}

// releaseHeldPushAlertsAt is releaseHeldPushAlerts; all releases every held
// alert whether or not its hold has passed.
func (s *muxServer) releaseHeldPushAlertsAt(all bool) time.Duration {
	notifier := s.pushNotifier()
	now := notifier.now()
	notifier.mu.Lock()
	due := make([]pushHeldAlert, 0, len(notifier.held))
	kept := notifier.held[:0]
	var next time.Duration
	for _, held := range notifier.held {
		wait := pushAlertHold - now.Sub(held.at)
		if wait <= 0 && notifier.statusPosting[held.windowID] > 0 {
			wait = min(pushAlertHold+pushStatusWait-now.Sub(held.at), 250*time.Millisecond)
		}
		if all || wait <= 0 {
			due = append(due, held)
			continue
		}
		kept = append(kept, held)
		if next == 0 || wait < next {
			next = wait
		}
	}
	notifier.held = kept
	// Counted in flight until raised, so a drain waits for them.
	counted := !notifier.stopPosts
	if counted {
		notifier.inflight.Add(len(due))
	}
	notifier.mu.Unlock()
	for _, held := range due {
		s.raisePushAlert(held.windowID, held.categories)
		if counted {
			notifier.inflight.Done()
		}
	}
	return next
}

// startPushDrain raises the window events still queued or held, which were
// taken in before the server closed, and returns a channel closed once the
// posts in flight finish or pushDrainTimeout passes, so a session that ends
// right after an alert still delivers it before the process exits. It runs
// beside the server's teardown, inside the time an upgrade gives the
// outgoing helper.
func (s *muxServer) startPushDrain() <-chan struct{} {
	notifier := s.pushNotifier()
	drained := make(chan struct{})
	go func() {
		defer close(drained)
		finished := make(chan struct{})
		go func() {
			defer close(finished)
			notifier.mu.Lock()
			notifier.stopQueue = true
			notifier.mu.Unlock()
			for queued := true; queued; {
				select {
				case event := <-notifier.alerts:
					s.consumePushAlertEvent(event)
				default:
					queued = false
				}
			}
			notifier.queued.Wait()
			// A held alert gives way to its window's status still on its way,
			// so let those land first.
			for deadline := time.Now().Add(pushDrainTimeout / 2); time.Now().Before(deadline); {
				notifier.mu.Lock()
				posting := false
				for _, held := range notifier.held {
					posting = posting || notifier.statusPosting[held.windowID] > 0
				}
				notifier.mu.Unlock()
				if !posting {
					break
				}
				time.Sleep(20 * time.Millisecond)
			}
			s.releaseHeldPushAlertsAt(true)
			notifier.mu.Lock()
			notifier.stopPosts = true
			notifier.mu.Unlock()
			notifier.inflight.Wait()
		}()
		select {
		case <-finished:
		case <-time.After(pushDrainTimeout):
		}
	}()
	return drained
}

// pushDeviceWindow names one device's view of one window.
type pushDeviceWindow struct {
	deviceID string
	windowID string
}

// pushStatusSent is what a device's two notification slots for a window last
// got from program status: the request (attention) kind, and when a
// finished turn arrived.
type pushStatusSent struct {
	attention   string
	attentionAt time.Time
	finishedAt  time.Time
	at          time.Time
}

// maxPushStatusSent bounds statusSent; the oldest record goes first.
const maxPushStatusSent = 256

// noteStatusSentLocked records that a status push of kind for windowID
// reached deviceID.
func (n *pushNotifier) noteStatusSentLocked(deviceID string, windowID string, kind string, now time.Time) {
	key := pushDeviceWindow{deviceID: deviceID, windowID: windowID}
	if _, ok := n.statusSent[key]; !ok && len(n.statusSent) >= maxPushStatusSent {
		var oldest pushDeviceWindow
		var oldestAt time.Time
		for candidate, sent := range n.statusSent {
			if oldestAt.IsZero() || sent.at.Before(oldestAt) {
				oldest, oldestAt = candidate, sent.at
			}
		}
		delete(n.statusSent, oldest)
	}
	sent := n.statusSent[key]
	if kind == pushKindFinished {
		sent.finishedAt = now
	} else {
		sent.attention, sent.attentionAt = kind, now
	}
	sent.at = now
	n.statusSent[key] = sent
}

// forgetStatusLocked drops what deviceID's slot for kind was last sent for
// windowID, unless a push of that kind reached it after since: a status of
// that kind the device will not hear of means an alert for the window is all
// it hears, so an earlier status no longer stands for it.
func (n *pushNotifier) forgetStatusLocked(deviceID string, windowID string, kind string, since time.Time) {
	key := pushDeviceWindow{deviceID: deviceID, windowID: windowID}
	sent, ok := n.statusSent[key]
	if !ok {
		return
	}
	switch kind {
	case pushKindFinished:
		if !sent.finishedAt.After(since) {
			sent.finishedAt = time.Time{}
		}
	case pushKindPermission, pushKindInput:
		if !sent.attentionAt.After(since) {
			sent.attention, sent.attentionAt = "", time.Time{}
		}
	default:
		return
	}
	n.statusSent[key] = sent
}

// alertRedundantLocked reports whether a window alert would only repeat a
// status that reached device for the window and still holds: the program
// waits on a request of the kind the device's request slot shows, or a turn
// finished under pushStatusAlertGrace ago and the program still reports done
// or idle. Anything else (a status the device turned off or never got, a
// program that works again or exited) leaves the alert as all the device
// hears.
func (n *pushNotifier) alertRedundantLocked(
	device pushDeviceRecord,
	windowID string,
	view pushServerView,
	now time.Time,
) bool {
	sent, ok := n.statusSent[pushDeviceWindow{deviceID: device.DeviceID, windowID: windowID}]
	if !ok {
		return false
	}
	if kind := view.blocked[windowID]; kind != "" {
		return sent.attention == kind
	}
	return view.finished[windowID] && !sent.finishedAt.IsZero() &&
		now.Sub(sent.finishedAt) < pushStatusAlertGrace
}

// programStatusPushKind is the push a terminal program's OSC 7501 status
// change calls for, or "" for none. A program that stops working with done or
// idle finished its turn; one that newly blocks needs the user, for a
// permission or, for any other kind, an answer. Neither the message nor the
// title is sent: a push carries only its kind.
func programStatusPushKind(before, after programStatusSummary) string {
	if after.state == "blocked" {
		if before.state == "blocked" && before.kind == after.kind {
			return ""
		}
		if after.kind == "permission" {
			return pushKindPermission
		}
		return pushKindInput
	}
	if before.state == "working" && (after.state == "done" || after.state == "idle") {
		return pushKindFinished
	}
	return ""
}

// programStatusPushKinds is the push each status change within one PTY read
// calls for, from before through the recorded steps to after, so the read
// boundaries do not decide which turns and requests are pushed.
func programStatusPushKinds(
	before programStatusSummary,
	steps []programStatusSummary,
	after programStatusSummary,
) []string {
	var kinds []string
	previous := before
	for _, next := range steps {
		if kind := programStatusPushKind(previous, next); kind != "" {
			kinds = append(kinds, kind)
		}
		previous = next
	}
	if kind := programStatusPushKind(previous, after); kind != "" {
		kinds = append(kinds, kind)
	}
	return kinds
}

// raisePushEvent sends a one-off event (a finished turn or a window alert) for
// windowID to every device that is not already covering it. bridgeID names
// the native agent bridge behind a finished turn. An alert raised here has no
// recorded cause and counts as both a bell and a notice; raisePushAlert
// passes the cause.
func (s *muxServer) raisePushEvent(windowID string, kind string, bridgeID string) {
	var alerts pushAlertCategories
	if kind == pushKindAlert {
		alerts = pushAlertAny
	}
	s.raisePush(windowID, kind, bridgeID, alerts)
}

// raisePushAlert sends a window alert raised by categories.
func (s *muxServer) raisePushAlert(windowID string, categories pushAlertCategories) {
	if categories == 0 {
		return
	}
	s.raisePush(windowID, pushKindAlert, "", categories)
}

func (s *muxServer) raisePush(windowID string, kind string, bridgeID string, alerts pushAlertCategories) {
	notifier := s.pushNotifier()
	devices, salt := notifier.store.snapshotFor(s.session)
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
	type admittedDevice struct {
		record pushDeviceRecord
		alerts pushAlertCategories
	}
	admitted := make([]admittedDevice, 0, len(devices))
	for _, device := range pushRecipients(devices, kind, alerts) {
		if notifier.attendingLocked(device.DeviceID, windowID, view, now) ||
			(kind == pushKindAlert && notifier.alertRedundantLocked(device, windowID, view, now)) {
			continue
		}
		wanted := device.wantedAlerts(alerts)
		if notifier.coveredLocallyLocked(device.DeviceID, kind, bridgeID, wanted, view, now) {
			notifier.deferLocked(pushDeferred{
				deviceID: device.DeviceID,
				windowID: windowID,
				bridgeID: bridgeID,
				kind:     kind,
				alerts:   wanted,
				at:       now,
			})
			continue
		}
		key := pushCoalesceKey{deviceID: device.DeviceID, windowID: windowID, kind: kind}
		switch notifier.admitLocked(key, now, true) {
		case "":
		case pushResultCoalesced:
			// The same kind reached it a moment ago and still stands.
			continue
		default:
			// Its budget refused it, so the device will not hear of it.
			notifier.forgetStatusLocked(device.DeviceID, windowID, kind, now)
			continue
		}
		admitted = append(admitted, admittedDevice{device, wanted})
	}
	notifier.mu.Unlock()

	for _, entry := range admitted {
		job, err := buildPushJob(entry.record, salt, view.session, windowID, view.agents[windowID], view.titles[windowID], kind, entry.alerts, now)
		if err != nil {
			continue
		}
		job.admittedAt = now
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
	devices, salt := notifier.store.snapshotFor(s.session)
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
	for _, device := range pushRecipients(devices, kind, 0) {
		key := pushAttentionKey{deviceID: device.DeviceID, bridgeID: bridgeID, kind: kind}
		previous := max(notifier.delivered[key], bridgeDelivered[acpPushDeliveredKey(device.DeviceID, kind)])
		if previous >= generation {
			notifier.delivered[key] = previous
			continue
		}
		if notifier.attendingLocked(device.DeviceID, windowID, view, now) ||
			notifier.coveredLocallyLocked(device.DeviceID, kind, bridgeID, 0, view, now) {
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
		job, err := buildPushJob(entry.record, salt, view.session, windowID, view.agents[windowID], view.titles[windowID], kind, 0, now)
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
	status := job.windowID != "" && job.kind != pushKindAlert && job.kind != pushKindTest
	if status {
		n.mu.Lock()
		n.statusPosting[job.windowID]++
		n.mu.Unlock()
	}
	// Once a closing server's drain waits on inflight, a later post is not
	// counted: WaitGroup.Add must not race its Wait.
	n.mu.Lock()
	counted := !n.stopPosts
	if counted {
		n.inflight.Add(1)
	}
	n.mu.Unlock()
	go func() {
		if counted {
			defer n.inflight.Done()
		}
		if status {
			defer func() {
				n.mu.Lock()
				if n.statusPosting[job.windowID]--; n.statusPosting[job.windowID] <= 0 {
					delete(n.statusPosting, job.windowID)
				}
				n.mu.Unlock()
			}()
		}
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
	devices, salt := n.store.snapshotFor(session)
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
	job, err := buildPushJob(*device, salt, "", "", "", "", pushKindTest, 0, now)
	if err != nil {
		return pushResultFailed
	}
	job.collapse = pushCollapseKey(salt, deviceID, session, "test", pushKindTest)
	// The app is waiting on the answer, so a test gets one attempt.
	return n.deliverWithRetries(job, nil)
}

// pushAgentName is a window's detected agent (the command name MonkeyMux
// tracks, such as "claude" or "cursor-agent") when it is a short lowercase
// id, so the app can name the agent in the notification it shows. It travels
// only inside the encrypted payload.
func pushAgentName(tool string) string {
	if len(tool) == 0 || len(tool) > 32 {
		return ""
	}
	for index := 0; index < len(tool); index++ {
		c := tool[index]
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '-' {
			return ""
		}
	}
	return tool
}

// pushTitleMaxRunes caps the window title a push carries.
const pushTitleMaxRunes = 64

// pushGenericTitles are window titles that say nothing about the window.
var pushGenericTitles = map[string]bool{
	"bash": true, "cmd": true, "fish": true, "login": true, "monkeymux": true,
	"powershell": true, "pwsh": true, "sh": true, "shell": true,
	"terminal": true, "tmux": true, "zsh": true,
}

// pushAgentTitleAliases are the names an agent's own window goes by beyond its
// id, which a notification that already names the agent would repeat.
var pushAgentTitleAliases = map[string][]string{
	"antigravity":  {"agy"},
	"claude":       {"claude code"},
	"cursor-agent": {"cursor agent", "cursor"},
	"muse":         {"muse code"},
}

var (
	pushHostTitlePattern = regexp.MustCompile(
		`^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+$`,
	)
	pushStatusTitlePattern = regexp.MustCompile(
		`^(idle|ready|running|thinking|waiting|working)( \(.*\))?$`,
	)
	// A shell's default title, `user@host` with an optional `: folder`.
	pushUserHostTitlePattern = regexp.MustCompile(`^[^\s@]+@[^\s:]+(:.*)?$`)
)

// pushWindowTitleLocked is the window's title as a notification names it,
// close to what the window bar shows: the agent's session title, else the
// title the program set, else the window's name, else its folder. A title
// that says nothing the notification does not already (a shell, the agent's
// own name, a host name, a path, a shell's `user@host`, a bare status word)
// is skipped. It travels only inside the encrypted payload.
func pushWindowTitleLocked(window *muxWindow, agent string) string {
	for _, candidate := range []string{
		window.agentSessionTitle,
		window.paneTitle,
		window.name,
	} {
		if title := pushTitleCandidate(candidate, agent); title != "" {
			return title
		}
	}
	return pushFolderTitle(window.cwd, agent)
}

// pushTitleCandidate cleans a title for a notification, or returns "" when it
// says nothing: control characters and runs of space collapse, and leading
// decoration such as a spinner or status glyph goes. A path or a shell's
// `user@host` title is left out.
func pushTitleCandidate(value string, agent string) string {
	fields := strings.FieldsFunc(value, func(r rune) bool {
		return unicode.IsSpace(r) || unicode.IsControl(r)
	})
	joined := strings.Join(fields, " ")
	if strings.HasPrefix(joined, "/") || strings.HasPrefix(joined, "~") ||
		pushUserHostTitlePattern.MatchString(joined) {
		return ""
	}
	title := strings.TrimLeftFunc(joined, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
	lowered := strings.ToLower(title)
	if lowered == "" ||
		pushGenericTitles[lowered] ||
		pushHostTitlePattern.MatchString(lowered) ||
		pushStatusTitlePattern.MatchString(lowered) {
		return ""
	}
	if agent != "" {
		if lowered == agent || lowered == strings.ReplaceAll(agent, "-", " ") {
			return ""
		}
		for _, alias := range pushAgentTitleAliases[agent] {
			if lowered == alias {
				return ""
			}
		}
	}
	if runes := []rune(title); len(runes) > pushTitleMaxRunes {
		title = strings.TrimRightFunc(
			string(runes[:pushTitleMaxRunes-1]), unicode.IsSpace,
		) + "…"
	}
	return title
}

// pushFolderTitle names a window by its working folder, unless that is the
// home folder or the root, which say nothing.
func pushFolderTitle(cwd string, agent string) string {
	cwd = strings.TrimSpace(cwd)
	if cwd == "" {
		return ""
	}
	clean := filepath.Clean(cwd)
	if home, err := os.UserHomeDir(); err == nil && clean == filepath.Clean(home) {
		return ""
	}
	base := filepath.Base(clean)
	if base == "." || base == string(filepath.Separator) || base == "~" {
		return ""
	}
	return pushTitleCandidate(base, agent)
}

func buildPushJob(
	device pushDeviceRecord,
	salt []byte,
	session string,
	windowID string,
	agent string,
	title string,
	kind string,
	alerts pushAlertCategories,
	now time.Time,
) (pushJob, error) {
	publicKey, err := parsePushPublicKey(device.PublicKey)
	if err != nil {
		return pushJob{}, err
	}
	// An alert says whether it was a bell, a program's notification, or
	// both, so the app can honour each of the host's switches on its own.
	var alertNames []string
	if alerts&pushAlertBell != 0 {
		alertNames = append(alertNames, pushEventBell)
	}
	if alerts&pushAlertNotice != 0 {
		alertNames = append(alertNames, pushEventNotice)
	}
	plaintext, err := json.Marshal(struct {
		V         int      `json:"v"`
		HostRef   string   `json:"hostRef"`
		Window    string   `json:"window"`
		SessionID string   `json:"sessionId"`
		Kind      string   `json:"kind"`
		Agent     string   `json:"agent,omitempty"`
		Title     string   `json:"title,omitempty"`
		Alert     []string `json:"alert,omitempty"`
		TS        int64    `json:"ts"`
	}{1, device.HostRef, windowID, session, kind, agent, title, alertNames, now.Unix()})
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
		collapse: pushCollapseKey(salt, device.DeviceID, session, windowID, kind),
		payload:  payload,
		windowID: windowID,
	}, nil
}

// deliver posts a job with retries and applies the function's answer.
func (n *pushNotifier) deliver(job pushJob) string {
	result := n.deliverWithRetries(job, pushRetryDelays)
	if result != pushResultSent && !job.admittedAt.IsZero() {
		// It never arrived, so the next event of its kind is not coalesced
		// into it, and an earlier status of its kind no longer stands for it.
		key := pushCoalesceKey{deviceID: job.deviceID, windowID: job.windowID, kind: job.kind}
		n.mu.Lock()
		if last, ok := n.lastSent[key]; ok && last.Equal(job.admittedAt) {
			delete(n.lastSent, key)
		}
		n.forgetStatusLocked(job.deviceID, job.windowID, job.kind, job.admittedAt)
		n.mu.Unlock()
	}
	return result
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
			switch job.kind {
			case pushKindPermission, pushKindInput, pushKindFinished:
				if job.windowID != "" {
					n.mu.Lock()
					n.noteStatusSentLocked(job.deviceID, job.windowID, job.kind, n.now())
					n.mu.Unlock()
				}
			}
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

// pushAlertOutputCategories reports whether a window's output carried a bell
// or a desktop notification: OSC 9 text, OSC 777;notify, or an OSC 99
// notification that is not a query or a close request. Shell-integration OSC
// 777 marks (precmd, preexec) and progress reports do not count.
func pushAlertOutputCategories(bell bool, completedOscs [][]byte) pushAlertCategories {
	var categories pushAlertCategories
	if bell {
		categories |= pushAlertBell
	}
	if isPushNoticeOutput(completedOscs) {
		categories |= pushAlertNotice
	}
	return categories
}

// isPushNoticeOutput reports whether completedOscs hold a desktop
// notification.
func isPushNoticeOutput(completedOscs [][]byte) bool {
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
		// hold fires when the earliest held alert is due; nil while none is.
		var hold <-chan time.Time
		for {
			select {
			case alert := <-notifier.alerts:
				s.consumePushAlertEvent(alert)
				if hold == nil && alert.kind == "" {
					hold = time.After(pushAlertHold)
				}
			case <-hold:
				hold = nil
				if next := s.releaseHeldPushAlerts(); next > 0 {
					hold = time.After(next)
				}
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
	if devices, _ := notifier.store.snapshotFor(s.session); len(devices) == 0 {
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
	for index, existing := range n.deferred {
		if existing.deviceID == event.deviceID && existing.windowID == event.windowID &&
			existing.kind == event.kind {
			n.deferred[index].alerts |= event.alerts
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
	devices, salt := notifier.store.snapshotFor(s.session)
	view := s.pushView(notifier.presenceClientIDs())
	now := notifier.now()
	// recipient is the registration a deferred event goes through, if the
	// device still wants it.
	recipient := func(event pushDeferred) (pushDeviceRecord, bool) {
		for _, device := range pushRecipients(devices, event.kind, event.alerts) {
			if device.DeviceID == event.deviceID {
				return device, true
			}
		}
		return pushDeviceRecord{}, false
	}

	notifier.mu.Lock()
	due := make([]pushDeferred, 0)
	kept := notifier.deferred[:0]
	for _, event := range notifier.deferred {
		if now.Sub(event.at) > pushDeferWindow {
			continue
		}
		if notifier.coveredLocallyLocked(event.deviceID, event.kind, event.bridgeID, event.alerts, view, now) {
			kept = append(kept, event)
			continue
		}
		due = append(due, event)
	}
	notifier.deferred = kept
	type admittedEvent struct {
		event  pushDeferred
		record pushDeviceRecord
	}
	admitted := make([]admittedEvent, 0, len(due))
	for _, event := range due {
		record, ok := recipient(event)
		if !ok || notifier.attendingLocked(event.deviceID, event.windowID, view, now) {
			continue
		}
		if event.kind == pushKindAlert && notifier.alertRedundantLocked(record, event.windowID, view, now) {
			continue
		}
		key := pushCoalesceKey{deviceID: event.deviceID, windowID: event.windowID, kind: event.kind}
		if notifier.admitLocked(key, now, true) != "" {
			continue
		}
		admitted = append(admitted, admittedEvent{event, record})
	}
	notifier.mu.Unlock()

	for _, entry := range admitted {
		job, err := buildPushJob(
			entry.record,
			salt,
			view.session,
			entry.event.windowID,
			view.agents[entry.event.windowID],
			view.titles[entry.event.windowID],
			entry.event.kind,
			entry.event.alerts,
			entry.event.at,
		)
		if err != nil {
			continue
		}
		job.admittedAt = now
		notifier.post(job, nil)
	}
}

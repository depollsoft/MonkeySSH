package main

import (
	"slices"
	"strings"
	"testing"
	"time"
)

// Regression tests for one notification per window and event: an agent that
// needs the user or finishes also rings the bell or posts a desktop
// notification, and those alerts must not reach the device as a second
// notification or replace the status one in the window's slot.

// writeStatus feeds one OSC 7501 report to a window and delivers what it
// queues, without moving the clock.
func (h *pushTestHarness) writeStatus(windowID string, report string) {
	h.server.handleWindowOutput(windowID, []byte(programStatusOsc(report)))
	h.deliverQueued()
}

// holdAlert queues a window alert as the PTY reader does and delivers it.
func (h *pushTestHarness) holdAlert(windowID string, categories pushAlertCategories) {
	h.server.deliverPushAlertEvent(pushAlertEvent{windowID: windowID, categories: categories})
}

// releaseHeld releases the held alerts that are due and waits for their posts.
func (h *pushTestHarness) releaseHeld() time.Duration {
	next := h.server.releaseHeldPushAlerts()
	h.notifier.inflight.Wait()
	return next
}

func TestPushAlertWhileBlockedIsNotPushed(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.addPushStatusWindow("@2", "")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.writeStatus("@2", "state=blocked:app=claude-code:kind=permission")
	// Long after the approval push, the agent rings again while it waits.
	h.clock.now = h.clock.now.Add(pushStatusAlertGrace + time.Minute)
	h.raise("@2", pushKindAlert)
	if got := h.kinds(); got != "permission" {
		t.Fatalf("pushes = %q, want only the approval", got)
	}
}

func TestPushAlertRightAfterAStatusIsNotPushed(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.addPushStatusWindow("@3", "")
	h.writeStatus("@3", "state=working:app=claude-code")
	h.writeStatus("@3", "state=done:app=claude-code")
	h.clock.now = h.clock.now.Add(5 * time.Second)
	h.raise("@3", pushKindAlert)
	if got := h.kinds(); got != "finished" {
		t.Fatalf("pushes = %q, want the finished turn alone", got)
	}
	// A later bell is a new event.
	h.clock.now = h.clock.now.Add(pushStatusAlertGrace)
	h.raise("@3", pushKindAlert)
	if got := h.kinds(); got != "finished,alert" {
		t.Fatalf("pushes = %q, want the later alert too", got)
	}
}

func TestPushHeldAlertGivesWayToTheStatusThatFollows(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.addPushStatusWindow("@2", "")
	h.writeStatus("@2", "state=working:app=claude-code")
	// The agent's bell arrives in one read, its blocked report in the next.
	h.holdAlert("@2", pushAlertBell|pushAlertNotice)
	h.writeStatus("@2", "state=blocked:app=claude-code:kind=input")
	h.clock.now = h.clock.now.Add(pushAlertHold)
	if next := h.releaseHeld(); next != 0 {
		t.Fatalf("still holding an alert, next due in %v", next)
	}
	if got := h.kinds(); got != "input" {
		t.Fatalf("pushes = %q, want the question alone", got)
	}
}

func TestPushHeldAlertIsPushedOnceItsHoldPasses(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.holdAlert("@4", pushAlertBell)
	h.holdAlert("@4", pushAlertNotice)
	if next := h.releaseHeld(); next != pushAlertHold {
		t.Fatalf("next due in %v, want %v", next, pushAlertHold)
	}
	if got := h.kinds(); got != "" {
		t.Fatalf("pushed %q before the hold passed", got)
	}
	h.clock.now = h.clock.now.Add(pushAlertHold)
	h.releaseHeld()
	requests := h.endpoint.received()
	if len(requests) != 1 || requests[0].Kind != pushKindAlert {
		t.Fatalf("pushes = %q, want one alert for both categories", h.kinds())
	}
}

// A turn that finishes and starts again within one read leaves the window's
// status as it was, so nothing else in the snapshot changes; its status event
// still reaches the clients, numbered, so a backgrounded app that claimed the
// window's status raises it.
func TestWindowStatusEventsReachClientsBetweenSnapshots(t *testing.T) {
	server := newMuxServer("test")
	control := newControlRecorder(server)
	client := newControlClient(control)
	window := &muxWindow{id: "@2", index: 1, name: "agent", lastActivity: time.Now()}
	server.windows = []*muxWindow{{id: "@1", index: 0, lastActivity: time.Now()}, window}
	server.activeID = "@1"
	server.controls[client] = struct{}{}

	server.handleWindowOutput("@2", []byte(programStatusOsc("state=working:app=claude-code")))
	broadcasts := strings.Count(control.String(), `"type":"window_updated"`)
	server.handleWindowOutput("@2", []byte(
		programStatusOsc("state=done:app=claude-code")+programStatusOsc("state=working:app=claude-code"),
	))
	if got := strings.Count(control.String(), `"type":"window_updated"`) - broadcasts; got != 1 {
		t.Fatalf("broadcasts for the finished turn = %d, want 1", got)
	}
	want := []windowStatusEvent{{Seq: 1, Kind: pushKindFinished}}
	if got := server.snapshotLocked(window).StatusEvents; !slices.Equal(got, want) {
		t.Fatalf("status events = %+v, want %+v", got, want)
	}

	// Only the latest few are kept, oldest first.
	for range maxWindowStatusEvents + 1 {
		server.handleWindowOutput("@2", []byte(
			programStatusOsc("state=blocked:app=claude-code:kind=permission")+
				programStatusOsc("state=working:app=claude-code"),
		))
	}
	got := server.snapshotLocked(window).StatusEvents
	if len(got) != maxWindowStatusEvents || got[0].Seq != 3 || got[len(got)-1].Kind != pushKindPermission {
		t.Fatalf("status events = %+v, want the latest %d", got, maxWindowStatusEvents)
	}
}

// Once the program that finished has gone, a bell in its window is someone
// else's and is pushed.
func TestPushAlertAfterTheProgramLeftIsPushed(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.addPushStatusWindow("@3", "")
	h.writeStatus("@3", "state=working:app=claude-code")
	h.writeStatus("@3", "state=done:app=claude-code")
	h.writeStatus("@3", "state=clear:app=claude-code")
	h.clock.now = h.clock.now.Add(5 * time.Second)
	h.raise("@3", pushKindAlert)
	if got := h.kinds(); got != "finished,alert" {
		t.Fatalf("pushes = %q, want the finished turn and the later alert", got)
	}
}

// Alerts still held when the server closes were taken in before its end and
// are sent, not dropped.
func TestPushHeldAlertsAreSentWhenTheServerCloses(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.holdAlert("@4", pushAlertBell)
	h.server.releaseHeldPushAlertsAt(true)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "alert" {
		t.Fatalf("pushes = %q, want the held alert", got)
	}
}

// A backgrounded app that claims program status raises the window's approval
// itself, so the host keeps the push back, and sends it only if that claim
// lapses (the app died before it could). With the approval goes no alert
// for the same window.
func TestPushClaimedStatusIsDeferredAndAlertGivesWay(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.registerEvents(t, phone, nil)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	notices := true
	h.presenceReport(t, phone, "phone-client", pushControlRequest{
		Local: true, Alerts: true, Notices: &notices, Status: true,
	})
	h.addPushStatusWindow("@2", "")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.holdAlert("@2", pushAlertBell|pushAlertNotice)
	h.writeStatus("@2", "state=blocked:app=claude-code:kind=permission")
	h.clock.now = h.clock.now.Add(pushAlertHold)
	h.releaseHeld()
	if got := h.kinds(); got != "" {
		t.Fatalf("pushed %q while the app covers the window itself", got)
	}

	// The app stops reporting; the claim lapses.
	h.clock.now = h.clock.now.Add(pushLocalTTL + time.Second)
	h.server.flushPushDeferred()
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "permission" {
		t.Fatalf("pushes after the claim lapsed = %q, want the approval alone", got)
	}
}

// Without the status claim (an app before it, or one whose window bar is
// not mounted), the host pushes program status as before.
func TestPushStatusWithoutTheClaimIsPushed(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.registerEvents(t, phone, nil)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	h.presenceReport(t, phone, "phone-client", pushControlRequest{Local: true, Alerts: true})
	h.addPushStatusWindow("@2", "")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.writeStatus("@2", "state=done:app=claude-code")
	if got := h.kinds(); got != "finished" {
		t.Fatalf("pushes = %q, want the finished turn", got)
	}
}

// An alert and a later finished turn both kept back for a covering app go
// out together once its claim lapses; the window gets the finished turn only,
// since both would land in its one slot in either order.
func TestPushDeferredFlushSendsAWindowsStatusWithoutItsAlert(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.registerEvents(t, phone, nil)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	notices := true
	h.presenceReport(t, phone, "phone-client", pushControlRequest{
		Local: true, Alerts: true, Notices: &notices, Status: true,
	})
	h.addPushStatusWindow("@3", "")
	h.writeStatus("@3", "state=working:app=claude-code")
	h.raise("@3", pushKindAlert)
	h.clock.now = h.clock.now.Add(pushStatusAlertGrace + time.Second)
	h.writeStatus("@3", "state=done:app=claude-code")
	h.clock.now = h.clock.now.Add(pushLocalTTL + time.Second)
	h.server.flushPushDeferred()
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "finished" {
		t.Fatalf("pushes = %q, want the finished turn alone", got)
	}
}

// A device that turned a status off is not sent it, so the alert for the same
// event is all it hears of it and still goes out; a device that takes the
// status gets that alone.
func TestPushAlertGivesWayOnlyToAStatusTheDeviceTakes(t *testing.T) {
	for _, test := range []struct {
		name   string
		status string
		after  time.Duration
		want   string
	}{
		{"finished", "state=done:app=claude-code", 5 * time.Second, "alert,finished"},
		{"blocked", "state=blocked:app=claude-code:kind=permission", pushStatusAlertGrace + time.Minute, "alert,permission"},
	} {
		t.Run(test.name, func(t *testing.T) {
			h := newPushTestHarness(t)
			h.registerEvents(t, newPushTestDevice(t, 1), nil)
			h.registerEvents(t, newPushTestDevice(t, 2), pushTestEvents(pushEventBell, pushEventNotice))
			h.addPushStatusWindow("@2", "")
			h.writeStatus("@2", "state=working:app=claude-code")
			h.writeStatus("@2", test.status)
			h.clock.now = h.clock.now.Add(test.after)
			h.raise("@2", pushKindAlert)
			// Device 1 takes the status alone; device 2 turned it off.
			if got, tickets := h.sortedKinds(), h.ticketsSent(); got != test.want || tickets != "1,2" {
				t.Fatalf("pushes = %q to %q, want %q to 1,2", got, tickets, test.want)
			}
		})
	}
}

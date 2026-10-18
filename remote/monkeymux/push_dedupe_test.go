package main

import (
	"net/http"
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

// releaseHeldNoWait releases the held alerts that are due, from inside a post.
func (h *pushTestHarness) releaseHeldNoWait() {
	h.server.releaseHeldPushAlerts()
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

// A second approval moments after the first is coalesced into it, so the
// device still shows "needs approval" for the window and its bell is not
// pushed over it.
func TestPushAlertForACoalescedStatusIsNotPushed(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.addPushStatusWindow("@2", "")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.writeStatus("@2", "state=blocked:app=claude-code:kind=permission")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.writeStatus("@2", "state=blocked:app=claude-code:kind=permission")
	h.raise("@2", pushKindAlert)
	if got := h.kinds(); got != "permission" {
		t.Fatalf("pushes = %q, want the first approval alone", got)
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
// are sent before close returns, so the process cannot exit first.
// A turn that finished and then asks for approval rings for the approval: a
// device that turned approvals off gets that bell rather than have it taken
// for the finished turn's.
func TestPushAlertForANewRequestIsNotTakenForTheFinishedTurn(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), pushTestEvents(pushEventFinished, pushEventBell))
	h.addPushStatusWindow("@2", "")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.writeStatus("@2", "state=done:app=claude-code")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.writeStatus("@2", "state=blocked:app=claude-code:kind=permission")
	h.clock.now = h.clock.now.Add(5 * time.Second)
	h.raise("@2", pushKindAlert)
	if got := h.kinds(); got != "finished,alert" {
		t.Fatalf("pushes = %q, want the finished turn and the approval's bell", got)
	}
}

func TestPushHeldAlertsAreSentBeforeTheServerCloses(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.holdAlert("@4", pushAlertBell)
	h.server.close()
	if got := h.kinds(); got != "alert" {
		t.Fatalf("pushes when close returned = %q, want the held alert", got)
	}
}

// A backgrounded app raises its window's bells and notifications itself;
// the host still pushes the program's status, which takes the window's slot
// on the phone.
func TestPushStatusIsPushedToAnAppCoveringAlerts(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.registerEvents(t, phone, nil)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	notices := true
	h.presenceReport(t, phone, "phone-client", pushControlRequest{
		Local: true, Alerts: true, Notices: &notices,
	})
	h.addPushStatusWindow("@2", "")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.writeStatus("@2", "state=done:app=claude-code")
	h.raise("@2", pushKindAlert)
	if got := h.kinds(); got != "finished" {
		t.Fatalf("pushes = %q, want the finished turn alone", got)
	}
}

// A native agent's finished turn and an alert both kept back for a covering
// app both go out once its claim lapses: they share the window's update slot
// on the device, and the alert is all it hears if the turn's push fails.
func TestPushDeferredFlushSendsAWindowsStatusAndAlert(t *testing.T) {
	h := newPushTestHarness(t)
	phone := newPushTestDevice(t, 1)
	h.registerEvents(t, phone, nil)
	registerTestAttachClient(t, h.server, &recordingConn{}, "phone-client", 80, 24)
	notices := true
	h.presenceReport(t, phone, "phone-client", pushControlRequest{
		Local: true, Alerts: true, Notices: &notices, Bridges: []string{pushTestBridgeID},
	})
	h.addPushStatusWindow("@3", pushTestBridgeID)
	h.raise("@3", pushKindAlert)
	h.clock.now = h.clock.now.Add(time.Second)
	h.server.raisePushEvent("@3", pushKindFinished, pushTestBridgeID)
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "" {
		t.Fatalf("pushed %q while the app covers the window itself", got)
	}
	h.clock.now = h.clock.now.Add(pushLocalTTL + time.Second)
	h.server.flushPushDeferred()
	h.notifier.inflight.Wait()
	if got := h.sortedKinds(); got != "alert,finished" {
		t.Fatalf("pushes = %q, want the finished turn and the alert", got)
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

// An approval the function did not take (429) never reached the device, so
// its bell still goes out through the routine budget.
func TestPushAlertAfterAStatusThatFailedIsPushed(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.addPushStatusWindow("@2", "")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.endpoint.mu.Lock()
	h.endpoint.statuses = []int{http.StatusTooManyRequests}
	h.endpoint.mu.Unlock()
	h.writeStatus("@2", "state=blocked:app=claude-code:kind=permission")
	h.raise("@2", pushKindAlert)
	if got := h.kinds(); got != "permission,alert" {
		t.Fatalf("requests = %q, want the refused approval and then its bell", got)
	}
}

// An approval moments after a finished turn is coalesced into the earlier
// approval still showing in the window's request slot, and its bell is not
// pushed beside it.
func TestPushBellOfACoalescedApprovalAfterAFinishedTurnIsNotPushed(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.addPushStatusWindow("@2", "")
	for _, report := range []string{
		"state=working:app=claude-code",
		"state=blocked:app=claude-code:kind=permission",
		"state=working:app=claude-code",
		"state=done:app=claude-code",
		"state=working:app=claude-code",
		"state=blocked:app=claude-code:kind=permission",
	} {
		h.writeStatus("@2", report)
		h.clock.now = h.clock.now.Add(time.Second)
	}
	h.raise("@2", pushKindAlert)
	if got := h.kinds(); got != "permission,finished" {
		t.Fatalf("pushes = %q, want the approval and the turn alone", got)
	}
}

// A bell whose window still has a status push on its way waits for it, so it
// can give way to it, but not for long.
func TestPushHeldAlertWaitsForAStatusOnItsWay(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.holdAlert("@2", pushAlertBell)
	h.notifier.mu.Lock()
	h.notifier.statusPosting["@2"] = 1
	h.notifier.mu.Unlock()
	h.clock.now = h.clock.now.Add(pushAlertHold)
	if next := h.releaseHeld(); next <= 0 {
		t.Fatalf("released the alert while its window's status was on its way")
	}
	if got := h.kinds(); got != "" {
		t.Fatalf("pushed %q while waiting", got)
	}
	h.clock.now = h.clock.now.Add(pushStatusWait)
	h.releaseHeld()
	if got := h.kinds(); got != "alert" {
		t.Fatalf("pushes = %q, want the alert once the wait ran out", got)
	}
}

// A push that never arrived does not hold the next of its kind back: the
// next approval within the coalescing window is sent.
func TestPushApprovalAfterOneThatNeverArrivedIsSent(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.addPushStatusWindow("@2", "")
	h.endpoint.mu.Lock()
	h.endpoint.statuses = []int{http.StatusBadRequest}
	h.endpoint.mu.Unlock()
	for _, report := range []string{
		"state=working:app=claude-code",
		"state=blocked:app=claude-code:kind=permission",
		"state=working:app=claude-code",
		"state=blocked:app=claude-code:kind=permission",
	} {
		h.writeStatus("@2", report)
		h.clock.now = h.clock.now.Add(time.Second)
	}
	if got := h.kinds(); got != "permission,permission" {
		t.Fatalf("requests = %q, want the refused approval and the next one", got)
	}
}

// An earlier approval that reached the device does not stand for a later one
// whose push never arrived (refused, here by a 429): the later one's bell is
// all the device hears of it, as before.
func TestPushBellOfAnApprovalThatNeverArrivedIsPushed(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.addPushStatusWindow("@2", "")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.writeStatus("@2", "state=blocked:app=claude-code:kind=permission")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.clock.now = h.clock.now.Add(10 * time.Minute)
	h.endpoint.mu.Lock()
	h.endpoint.statuses = []int{http.StatusTooManyRequests}
	h.endpoint.mu.Unlock()
	h.writeStatus("@2", "state=blocked:app=claude-code:kind=permission")
	h.raise("@2", pushKindAlert)
	if got := h.kinds(); got != "permission,permission,alert" {
		t.Fatalf("requests = %q, want both approvals and the refused one's bell", got)
	}
}

// So is one its budget refused before posting it.
func TestPushBellOfAnApprovalItsBudgetRefusedIsPushed(t *testing.T) {
	h := newPushTestHarness(t)
	device := newPushTestDevice(t, 1)
	h.registerEvents(t, device, nil)
	h.addPushStatusWindow("@2", "")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.writeStatus("@2", "state=blocked:app=claude-code:kind=permission")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.clock.now = h.clock.now.Add(10 * time.Minute)
	h.notifier.mu.Lock()
	h.notifier.backoffUntil[pushBudgetKey{deviceID: device.id, budget: pushBudgetUrgent}] =
		h.clock.now.Add(time.Hour)
	h.notifier.mu.Unlock()
	h.writeStatus("@2", "state=blocked:app=claude-code:kind=permission")
	h.raise("@2", pushKindAlert)
	if got := h.kinds(); got != "permission,alert" {
		t.Fatalf("requests = %q, want the first approval and the second one's bell", got)
	}
}

// A bell held while its window's approval is still on its way (here waiting
// to retry) waits for it, and gives way once it lands.
func TestPushHeldAlertGivesWayToAStatusStillOnItsWay(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.addPushStatusWindow("@2", "")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.holdAlert("@2", pushAlertBell)
	h.endpoint.mu.Lock()
	h.endpoint.statuses = []int{http.StatusInternalServerError}
	h.endpoint.mu.Unlock()
	h.notifier.sleep = func(time.Duration) {
		// The bell's hold passes while the approval waits to retry.
		h.clock.now = h.clock.now.Add(pushAlertHold)
		h.releaseHeldNoWait()
	}
	h.writeStatus("@2", "state=blocked:app=claude-code:kind=permission")
	h.clock.now = h.clock.now.Add(time.Second)
	h.releaseHeld()
	if got := h.kinds(); got != "permission,permission" {
		t.Fatalf("requests = %q, want the approval and its retry alone", got)
	}
}

// A bell queued just before the server closes goes out before close returns.
func TestPushQueuedAlertIsSentBeforeTheServerCloses(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.server.notePushAlert("@4", pushAlertBell)
	h.server.close()
	if got := h.kinds(); got != "alert" {
		t.Fatalf("pushes when close returned = %q, want the queued alert", got)
	}
}

// A closing server lets a status still on its way land before it releases
// the held alerts, so a bell that would only repeat it is not pushed beside
// it.
func TestPushDrainLetsAStatusOnItsWayLandBeforeItsAlert(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.addPushStatusWindow("@2", "")
	h.writeStatus("@2", "state=working:app=claude-code")
	h.holdAlert("@2", pushAlertBell)
	h.endpoint.mu.Lock()
	h.endpoint.statuses = []int{http.StatusInternalServerError}
	h.endpoint.mu.Unlock()
	retrying := make(chan struct{})
	h.notifier.sleep = func(time.Duration) {
		close(retrying)
		// The close below starts while the approval waits to retry.
		time.Sleep(200 * time.Millisecond)
	}
	go h.server.handleWindowOutput("@2", []byte(programStatusOsc("state=blocked:app=claude-code:kind=permission")))
	go func() {
		for event := range h.notifier.alerts {
			h.server.consumePushAlertEvent(event)
		}
	}()
	<-retrying
	h.server.close()
	h.notifier.inflight.Wait()
	if got := h.kinds(); got != "permission,permission" {
		t.Fatalf("requests = %q, want the approval and its retry alone", got)
	}
}

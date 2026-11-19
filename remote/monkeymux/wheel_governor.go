package main

import (
	"bytes"
	"strconv"
	"sync"
	"time"
)

type wheelAccelerationProfile struct {
	window time.Duration
	// speed is the rows the TUI moves for a report that continues a run of
	// count quick reports; the client calibrates each report to speed(0).
	speed func(count int) int
	// processSpeed, set instead of speed for a TUI whose ramp its environment
	// configures, reads speed from the window's foreground process group.
	// Returning nil leaves the window ungoverned.
	processSpeed func(processGroup int) func(count int) int
	// rowCap, when set, bounds the rows one report moves in a pane of the
	// given height, applied after speed.
	rowCap func(paneRows int) int
	// deferredReversal TUIs move nothing for the first report against the
	// previous direction, and move speed(0) rows for the next report in the
	// new direction. A single reversed report followed by one in the old
	// direction would instead read as a mechanical wheel's bounce, so the
	// governor sends every reversal as that pair.
	deferredReversal bool
	// precisionSticky, when set, is how long after a Ctrl- or Meta-wheel
	// report the TUI keeps scrolling in a precision mode: one row per frame,
	// not ramped, with the ramp reset when the mode starts. Such reports,
	// and any report less than that after the last one in the mode, pass
	// through ungoverned. The gap is counted in whole milliseconds, as the
	// TUI counts it: a report it reads as outside the mode while the governor
	// still bypasses would keep the governor bypassed for the whole drag.
	precisionSticky time.Duration
}

// wheelPrecisionModifiers are the Meta and Ctrl bits of a wheel report's
// button, in SGR and X10 alike.
const wheelPrecisionModifiers = 8 | 16

var wheelGovernorNow = time.Now

// wheelCarryExpiry bounds how long a trailing run that could still complete
// into a wheel report is held. A lone Escape is as likely a key press as the
// first byte of a split report, and without an expiry it waited for the next
// input chunk, which could then read as an Alt-modified key. Releasing a
// genuinely split report early only leaves that one event ungoverned.
const wheelCarryExpiry = 50 * time.Millisecond

// Like scheduleRestoreRedraw, this is replaceable so tests can fire timers
// synchronously without waiting for wall time.
var scheduleWheelFlush = func(delay time.Duration, action func()) {
	time.AfterFunc(delay, action)
}

type wheelGovernor struct {
	profile *wheelAccelerationProfile
	// paneRows is the pane height the TUI lays out for, refreshed before each
	// use; 0 leaves rowCap unapplied.
	paneRows int
	last     time.Time
	count    int
	// direction is the sign of the last forwarded report, 0 before the first.
	direction int
	// precisionAt is when the last report in precision mode was forwarded.
	precisionAt time.Time
	owed        int
	template    []byte
	carry       []byte
	flushGen    int
}

func (g *wheelGovernor) reset(profile *wheelAccelerationProfile) {
	*g = wheelGovernor{profile: profile, flushGen: g.flushGen + 1}
}

func (g *wheelGovernor) nextCount(now time.Time) int {
	if !g.last.IsZero() && now.Sub(g.last) < g.profile.window {
		return g.count + 1
	}
	return 0
}

func (g *wheelGovernor) cappedSpeed(count int) int {
	speed := g.profile.speed(count)
	if g.profile.rowCap != nil && g.paneRows > 0 {
		speed = min(speed, g.profile.rowCap(g.paneRows))
	}
	return speed
}

func (g *wheelGovernor) drain(now time.Time) []byte {
	var output []byte
	if g.profile == nil || len(g.template) == 0 {
		return output
	}
	for g.owed != 0 {
		direction, rows := 1, g.owed
		if rows < 0 {
			direction, rows = -1, -rows
		}
		reversal := g.profile.deferredReversal && g.direction != 0 && direction != g.direction
		count := g.nextCount(now)
		if reversal {
			count = 0
		}
		speed := g.cappedSpeed(count)
		if rows < speed {
			if count != 0 {
				break
			}
			// A TUI with a base speed above 1 moves no fewer rows than
			// speed(0), and the ramp can leave less than that owed. No
			// report can pay it exactly, so round it to the nearest report.
			if 2*rows < speed {
				g.owed = 0
				break
			}
		}
		report := g.reportInDirection(direction)
		output = append(output, report...)
		if reversal {
			output = append(output, report...)
		}
		g.count = count
		g.last = now
		g.direction = direction
		g.owed -= direction * speed
		if g.owed*direction < 0 {
			g.owed = 0
		}
	}
	return output
}

func (g *wheelGovernor) inPrecisionMode(button int, now time.Time) bool {
	if g.profile.precisionSticky <= 0 {
		return false
	}
	return button&wheelPrecisionModifiers != 0 ||
		(!g.precisionAt.IsZero() &&
			now.UnixMilli()-g.precisionAt.UnixMilli() < g.profile.precisionSticky.Milliseconds())
}

func (g *wheelGovernor) reportInDirection(direction int) []byte {
	report := append([]byte(nil), g.template...)
	_, buttonOffset, button := wheelReport(report)
	wantDown := direction > 0
	if (button&1 != 0) != wantDown {
		// SGR's last decimal digit and X10's button byte both encode
		// up/down in their low bit. Preserve every other byte.
		report[buttonOffset] ^= 1
	}
	return report
}

func (g *wheelGovernor) process(data []byte, now time.Time) []byte {
	if g.profile == nil {
		return data
	}
	if len(g.carry) > 0 {
		// A wheel report withheld mid-parse from the previous chunk; complete
		// it with this chunk's bytes so a split report is still governed.
		data = append(append([]byte(nil), g.carry...), data...)
		g.carry = g.carry[:0]
	}
	output := make([]byte, 0, len(data))
	// Tracks whether a non-wheel byte has been written while earlier wheel rows
	// are still owed. Delivering those rows later, from the flush timer, would
	// place them after input the user sent afterwards, so they are dropped
	// instead. A fresh wheel report clears the flag, since its own debt is
	// legitimately flushable until later non-wheel input arrives.
	reorder := false
	for offset := 0; offset < len(data); {
		// Hold a trailing run that could still complete into a wheel report,
		// rather than passing its prefix straight through and losing track of
		// the event when the rest arrives in the next chunk.
		if data[offset] == 0x1b {
			if prefix := wheelReportPrefixLen(data[offset:]); prefix == len(data)-offset {
				g.carry = append(g.carry[:0], data[offset:]...)
				break
			}
		}
		length, _, button := wheelReport(data[offset:])
		if length == 0 {
			if g.owed != 0 {
				reorder = true
			}
			output = append(output, data[offset])
			offset++
			continue
		}
		report := data[offset : offset+length]
		offset += length
		if button < 0 {
			if g.owed != 0 {
				reorder = true
			}
			output = append(output, report...)
			continue
		}
		reorder = false
		if g.inPrecisionMode(button, now) {
			// The TUI starts its ramp afresh on entering precision mode, and
			// rows owed from before could only be paid in it at a row each.
			g.precisionAt = now
			g.owed, g.count, g.last, g.direction = 0, 0, time.Time{}, 0
			output = append(output, report...)
			continue
		}
		// The client calibrated this report against one sent after a pause.
		rows := g.cappedSpeed(0)
		if button&1 == 0 {
			g.owed -= rows
		} else {
			g.owed += rows
		}
		g.template = append(g.template[:0], report...)
		output = append(output, g.drain(now)...)
	}
	if reorder && g.owed != 0 {
		g.owed = 0
	}
	return output
}

// takeOpaque returns any withheld wheel-report prefix followed by data
// unchanged, and abandons pending scroll debt. It is used for input that must
// reach the pty byte for byte, such as a bracketed paste, so the governor
// neither rewrites a payload that happens to contain wheel-shaped bytes nor
// lets the flush timer inject a wheel report into it.
func (g *wheelGovernor) takeOpaque(data []byte) []byte {
	if g.profile == nil {
		return data
	}
	g.owed = 0
	if len(g.carry) == 0 {
		return data
	}
	out := append(append([]byte(nil), g.carry...), data...)
	g.carry = g.carry[:0]
	return out
}

// wheelReportPrefixLen returns len(data) when the whole of data is a non-empty,
// still-incomplete prefix of an SGR or X10 wheel report, and 0 otherwise. The
// length bound keeps a malformed run from buffering without end.
func wheelReportPrefixLen(data []byte) int {
	const maxWheelReport = 32
	if len(data) == 0 || len(data) > maxWheelReport || data[0] != 0x1b {
		return 0
	}
	if len(data) == 1 { // ESC
		return 1
	}
	if data[1] != '[' {
		return 0
	}
	if len(data) == 2 { // ESC [
		return 2
	}
	switch data[2] {
	case 'M': // X10: ESC [ M then three coordinate bytes.
		if len(data) < 6 {
			return len(data)
		}
		return 0
	case '<': // SGR: ESC [ < digits and semicolons, closed by M or m.
		for i := 3; i < len(data); i++ {
			if c := data[i]; c == 'M' || c == 'm' {
				return 0 // A closed, hence complete, report.
			} else if (c < '0' || c > '9') && c != ';' {
				return 0 // Not a wheel-report body.
			}
		}
		return len(data)
	default:
		return 0
	}
}

// wheelReport recognizes whole SGR and six-byte X10 reports at the start of
// data. Non-wheel reports return button -1 but still consume their full length,
// so X10 coordinate bytes are never mistaken for the start of another report.
// An incomplete trailing report is reported by wheelReportPrefixLen and held by
// process; wheelReport itself just consumes the remaining bytes.
func wheelReport(data []byte) (length, buttonOffset, button int) {
	button = -1
	if len(data) < 3 || data[0] != 0x1b || data[1] != '[' {
		return
	}
	switch data[2] {
	case 'M':
		if len(data) < 6 {
			return len(data), 0, -1
		}
		length, buttonOffset = 6, 3
		button = int(data[3]) - 32
	case '<':
		cursor := 3
		for field := 0; field < 3; field++ {
			start := cursor
			for cursor < len(data) && data[cursor] >= '0' && data[cursor] <= '9' {
				cursor++
			}
			if cursor == len(data) {
				return len(data), 0, -1
			}
			if cursor == start {
				return 0, 0, -1
			}
			if field == 0 {
				parsed, err := strconv.Atoi(string(data[start:cursor]))
				if err != nil {
					return 0, 0, -1
				}
				button, buttonOffset = parsed, cursor-1
			}
			if field < 2 {
				if data[cursor] != ';' {
					return 0, 0, -1
				}
				cursor++
			} else {
				if data[cursor] == 'm' {
					return cursor + 1, 0, -1
				}
				if data[cursor] != 'M' {
					return 0, 0, -1
				}
				length = cursor + 1
			}
		}
	default:
		return
	}
	if base := button &^ (4 | 8 | 16); base != 64 && base != 65 {
		button = -1
	}
	return
}

func (w *muxWindow) wheelAccelerationProfileLocked() *wheelAccelerationProfile {
	if w.closed || !w.mouseTrackingActiveLocked() {
		w.processWheelProfile.forget()
		return nil
	}
	profile := agentRegistry[w.agentToolLocked()].wheelProfile
	if profile == nil || profile.processSpeed == nil {
		w.processWheelProfile.forget()
		return profile
	}
	return w.processWheelProfile.lookup(profile, w.activeForegroundPidLocked())
}

// processWheelProfile caches a registered profile resolved for one
// foreground process group. Resolving reads other processes and files, so
// it runs off the server lock: the window stays ungoverned until the result
// lands, which is normally long before a drag, as the lookup starts when the
// TUI turns mouse tracking on.
//
// The TUI's environment is fixed when it starts, so one resolution serves
// the group, and the stable pointer keeps the governor's state. On Windows
// the group is the window's shell, which outlives the TUI, so the result is
// also forgotten whenever the window stops being governed by the profile,
// as it is once the TUI turns mouse tracking off.
type processWheelProfile struct {
	mu         sync.Mutex
	generation int
	registered *wheelAccelerationProfile
	group      int
	resolved   *wheelAccelerationProfile
	// done is closed when the resolution started for the current key
	// finishes; resolving is true until then.
	done      chan struct{}
	resolving bool
	// bypassed is set once wheel input stopped waiting for the resolution
	// and reached the TUI ungoverned. The TUI's ramp and direction then
	// hold state no governor saw, so the key stays ungoverned.
	bypassed bool
}

// resolveProcessWheelProfile runs a resolution. Tests replace it to run it
// synchronously or to hold it.
var resolveProcessWheelProfile = func(resolve func()) {
	go resolve()
}

// processWheelProfileWait bounds how long wheel input waits for a pending
// resolution before it goes to the TUI ungoverned.
var processWheelProfileWait = 250 * time.Millisecond

// onWheelProfileWait, when set by a test, runs as wheel input starts waiting
// for a resolution, with s.mu still held.
var onWheelProfileWait func()

func (c *processWheelProfile) forget() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.registered != nil {
		c.generation++
		c.registered, c.group, c.resolved, c.resolving, c.bypassed = nil, 0, nil, false, false
	}
}

// pending returns a channel closed when the resolution in flight finishes,
// or nil when none is or input no longer waits for it.
func (c *processWheelProfile) pending() <-chan struct{} {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.resolving || c.bypassed {
		return nil
	}
	return c.done
}

// bypassPending records that wheel input stopped waiting for the resolution
// in flight, whichever key it is for, and went to the TUI ungoverned.
func (c *processWheelProfile) bypassPending() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.resolving {
		c.bypassed = true
	}
}

func (c *processWheelProfile) lookup(profile *wheelAccelerationProfile, group int) *wheelAccelerationProfile {
	c.mu.Lock()
	if c.registered == profile && c.group == group {
		defer c.mu.Unlock()
		if c.bypassed {
			return nil
		}
		return c.resolved
	}
	c.generation++
	generation := c.generation
	done := make(chan struct{})
	c.registered, c.group, c.resolved = profile, group, nil
	c.done, c.resolving, c.bypassed = done, true, false
	c.mu.Unlock()
	resolveProcessWheelProfile(func() {
		var resolved *wheelAccelerationProfile
		if speed := profile.processSpeed(group); speed != nil {
			copied := *profile
			copied.speed, copied.processSpeed = speed, nil
			resolved = &copied
		}
		c.mu.Lock()
		defer c.mu.Unlock()
		if c.generation == generation {
			c.resolved, c.resolving = resolved, false
		}
		close(done)
	})
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.generation != generation || c.bypassed {
		return nil
	}
	return c.resolved
}

// awaitWheelProfileLocked returns the window's wheel profile for data. Wheel
// reports the TUI received ungoverned would advance its ramp and direction
// where a governor started afterwards cannot see them, so while a profile is
// still being resolved, wheel input waits for it, off s.mu (still holding
// the window's inputMu, which queues the window's later input behind it).
// Called with s.mu held; it returns with s.mu held, and false when the
// window went away while it waited.
func (s *muxServer) awaitWheelProfileLocked(window *muxWindow, data []byte) (*wheelAccelerationProfile, bool) {
	profile := window.wheelAccelerationProfileLocked()
	if profile != nil || !mayHoldWheelReport(data) {
		return profile, true
	}
	deadline := time.NewTimer(processWheelProfileWait)
	defer deadline.Stop()
	for {
		pending := window.processWheelProfile.pending()
		if pending == nil {
			return profile, true
		}
		if onWheelProfileWait != nil {
			onWheelProfileWait()
		}
		s.mu.Unlock()
		expired := false
		select {
		case <-pending:
		case <-deadline.C:
			expired = true
		}
		s.mu.Lock()
		if s.windowByIDLocked(window.id) != window || window.closed {
			return nil, false
		}
		// The key may have changed while waiting, starting another
		// resolution; input that gives up goes through ungoverned, so
		// whichever one is now in flight is bypassed.
		profile = window.wheelAccelerationProfileLocked()
		if profile == nil && expired {
			window.processWheelProfile.bypassPending()
		}
		if profile != nil || expired {
			return profile, true
		}
	}
}

// mayHoldWheelReport reports whether data may hold an SGR or X10 mouse
// report, or ends with what may be the start of one split across writes, as
// a lone ESC or ESC [ may be. Waiting for the profile lets the governor carry
// that start, so the rest of the report is governed with it.
func mayHoldWheelReport(data []byte) bool {
	if bytes.Contains(data, []byte("\x1b[<")) || bytes.Contains(data, []byte("\x1b[M")) {
		return true
	}
	last := bytes.LastIndexByte(data, 0x1b)
	return last >= 0 && wheelReportPrefixLen(data[last:]) == len(data)-last
}

func (w *muxWindow) resetWheelGovernorIfInactiveLocked() {
	if w.wheelAccelerationProfileLocked() != w.wheelGovernor.profile {
		w.wheelGovernor.reset(nil)
	}
}

// Called with s.mu and inputMu held. The returned function must run after both
// locks are released, allowing injected schedulers to invoke it synchronously.
func (s *muxServer) prepareWheelFlushLocked(window *muxWindow) func() {
	g := &window.wheelGovernor
	g.flushGen++
	if g.profile == nil || (g.owed == 0 && len(g.carry) == 0) {
		return nil
	}
	generation := g.flushGen
	delay := g.profile.window + 50*time.Millisecond
	if len(g.carry) > 0 {
		delay = wheelCarryExpiry
	}
	return func() {
		scheduleWheelFlush(delay, func() {
			s.flushWheelGovernor(window, generation)
		})
	}
}

func (s *muxServer) flushWheelGovernor(window *muxWindow, generation int) {
	window.inputMu.Lock()
	var scheduleFlush func()
	defer func() {
		window.inputMu.Unlock()
		if scheduleFlush != nil {
			scheduleFlush()
		}
	}()
	s.mu.Lock()
	if s.windowByIDLocked(window.id) != window || window.closed {
		s.mu.Unlock()
		return
	}
	g := &window.wheelGovernor
	if g.flushGen != generation {
		s.mu.Unlock()
		return
	}
	// A held prefix nothing completed is ordinary input; it goes to the pty
	// as it is, never back through report detection.
	held := g.carry
	g.carry = nil
	window.resetWheelGovernorIfInactiveLocked()
	var data []byte
	if g.profile != nil {
		g.paneRows = window.screenHeight
		data = g.drain(wheelGovernorNow())
	}
	if len(held) > 0 {
		data = append(data, held...)
		// Rows still owed would land after that input.
		g.owed = 0
	}
	scheduleFlush = s.prepareWheelFlushLocked(window)
	win32InputMode := window.win32InputMode
	s.mu.Unlock()
	if len(data) != 0 {
		if win32InputMode {
			data = encodeTerminalInputForWin32InputMode(data)
			data = encodeTerminalResponsesForWin32InputMode(data)
		}
		_, _ = window.pty.Write(data)
	}
}

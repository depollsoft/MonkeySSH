package main

import (
	"strconv"
	"time"
)

type wheelAccelerationProfile struct {
	window time.Duration
	speed  func(count int) int
}

var wheelAccelerationProfiles = map[string]*wheelAccelerationProfile{
	"antigravity": {
		window: 150 * time.Millisecond,
		speed: func(count int) int {
			// Integer square root, bounded by the TUI's maximum speed.
			speed := 1
			for speed < 12 && speed*speed <= count {
				speed++
			}
			return speed
		},
	},
}

var wheelGovernorNow = time.Now

// Like scheduleRestoreRedraw, this is replaceable so tests can fire timers
// synchronously without waiting for wall time.
var scheduleWheelFlush = func(delay time.Duration, action func()) {
	time.AfterFunc(delay, action)
}

type wheelGovernor struct {
	profile  *wheelAccelerationProfile
	last     time.Time
	count    int
	owed     int
	template []byte
	carry    []byte
	flushGen int
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

func (g *wheelGovernor) predictedSpeed(now time.Time) int {
	return g.profile.speed(g.nextCount(now))
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
		speed := g.predictedSpeed(now)
		if rows < speed {
			break
		}
		report := append([]byte(nil), g.template...)
		_, buttonOffset, button := wheelReport(report)
		wantDown := direction > 0
		if (button&1 != 0) != wantDown {
			// SGR's last decimal digit and X10's button byte both encode
			// up/down in their low bit. Preserve every other byte.
			report[buttonOffset] ^= 1
		}
		output = append(output, report...)
		g.count = g.nextCount(now)
		g.last = now
		g.owed -= direction * speed
	}
	return output
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
		if button&1 == 0 {
			g.owed--
		} else {
			g.owed++
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
		return nil
	}
	return wheelAccelerationProfiles[w.agentToolLocked()]
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
	if g.profile == nil || g.owed == 0 {
		return nil
	}
	generation := g.flushGen
	delay := g.profile.window + 50*time.Millisecond
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
	window.resetWheelGovernorIfInactiveLocked()
	g := &window.wheelGovernor
	if g.profile == nil || g.flushGen != generation {
		s.mu.Unlock()
		return
	}
	data := g.drain(wheelGovernorNow())
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

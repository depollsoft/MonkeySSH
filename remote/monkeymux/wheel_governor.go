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
	output := make([]byte, 0, len(data))
	for offset := 0; offset < len(data); {
		length, _, button := wheelReport(data[offset:])
		if length == 0 {
			output = append(output, data[offset])
			offset++
			continue
		}
		report := data[offset : offset+length]
		offset += length
		if button < 0 {
			output = append(output, report...)
			continue
		}
		if button&1 == 0 {
			g.owed--
		} else {
			g.owed++
		}
		g.template = append(g.template[:0], report...)
		output = append(output, g.drain(now)...)
	}
	return output
}

// wheelReport recognizes whole SGR and six-byte X10 reports at the start of
// data. Non-wheel reports return button -1 but still consume their full length,
// so X10 coordinate bytes are never mistaken for the start of another report.
// Incomplete reports consume the remaining bytes verbatim; there is no carry.
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

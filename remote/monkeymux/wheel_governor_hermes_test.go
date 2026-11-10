package main

import (
	"bytes"
	"fmt"
	"math"
	"math/rand"
	"strings"
	"testing"
	"time"
)

// hermesTestTUI ports the Hermes Ink TUI's native wheel handling
// (ui-tui/src/lib/wheelAccel.ts, nativeStep, base speed 1) independently of
// the governor's speed table, including the bounce detection the governor
// must never trigger.
type hermesTestTUI struct {
	timeMs      int64
	mult        float64
	dir         int
	pendingFlip bool
	wheelMode   bool
	burstCount  int
	rows        int
	// enteredWheelMode records that a report ever switched the TUI into
	// the mechanical-wheel mode, which moves up to 15 rows per report.
	enteredWheelMode bool
}

func newHermesTestTUI() *hermesTestTUI {
	return &hermesTestTUI{mult: 1}
}

func (tui *hermesTestTUI) step(dir int, now int64) int {
	if tui.wheelMode && now-tui.timeMs > 1500 {
		tui.wheelMode = false
		tui.burstCount = 0
		tui.mult = 1
	}
	if tui.pendingFlip {
		tui.pendingFlip = false
		if dir != tui.dir || now-tui.timeMs > 200 {
			tui.dir = dir
			tui.timeMs = now
			tui.mult = 1
			return int(math.Floor(tui.mult))
		}
		tui.wheelMode = true
		tui.enteredWheelMode = true
	}
	gap := now - tui.timeMs
	if dir != tui.dir && tui.dir != 0 {
		tui.pendingFlip = true
		tui.timeMs = now
		return 0
	}
	tui.dir = dir
	tui.timeMs = now
	if tui.wheelMode {
		if gap < 5 {
			tui.burstCount++
			if tui.burstCount >= 5 {
				tui.wheelMode = false
				tui.burstCount = 0
				tui.mult = 1
			} else {
				return 1
			}
		} else {
			tui.burstCount = 0
		}
	}
	if tui.wheelMode {
		m := math.Pow(0.5, float64(gap)/150)
		next := 1 + (tui.mult-1)*m + 15*m
		tui.mult = math.Min(15, math.Min(next, tui.mult+3))
		return int(math.Floor(tui.mult))
	}
	if gap > 40 {
		tui.mult = 1
	} else {
		tui.mult = math.Min(6, tui.mult+0.3)
	}
	return int(math.Floor(tui.mult))
}

func (tui *hermesTestTUI) receive(t *testing.T, data []byte, now time.Time) {
	t.Helper()
	for len(data) != 0 {
		direction := 0
		switch {
		case bytes.HasPrefix(data, []byte(wheelUp)):
			direction = -1
			data = data[len(wheelUp):]
		case bytes.HasPrefix(data, []byte(wheelDown)):
			direction = 1
			data = data[len(wheelDown):]
		default:
			t.Fatalf("unexpected forwarded bytes: %q", data)
		}
		tui.rows += direction * tui.step(direction, now.UnixMilli())
	}
}

func hermesWheelProfile() *wheelAccelerationProfile {
	return agentRegistry["hermes"].wheelProfile
}

func TestHermesWheelSpeedMatchesTUI(t *testing.T) {
	tui := newHermesTestTUI()
	now := time.Unix(100, 0).UnixMilli()
	for count := 0; count < 40; count++ {
		if got, want := hermesWheelSpeed(count), tui.step(1, now); got != want {
			t.Fatalf("count %d: speed %d, TUI moved %d", count, got, want)
		}
	}
}

func TestHermesTUIAcceleratesUngovernedDrag(t *testing.T) {
	tui := newHermesTestTUI()
	now := time.Unix(100, 0)
	for i := 0; i < 60; i++ {
		tui.receive(t, []byte(wheelDown), now)
		now = now.Add(16 * time.Millisecond)
	}
	if tui.rows <= 120 {
		t.Fatalf("an ungoverned 60-report drag moved %d rows; the model no longer accelerates", tui.rows)
	}
}

func TestWheelGovernorHermesRowConservation(t *testing.T) {
	// batch is how many reports the client writes per frame; it sends up to
	// six while a fast drag is behind.
	for _, batch := range []int{1, 3, 6} {
		for _, reports := range []int{20, 2000} {
			for _, interval := range []time.Duration{0, 16 * time.Millisecond, 30 * time.Millisecond, 45 * time.Millisecond} {
				t.Run(fmt.Sprintf("%d/%d/%v", batch, reports, interval), func(t *testing.T) {
					testWheelGovernorHermesRowConservation(t, batch, reports, interval)
				})
			}
		}
	}
}

func testWheelGovernorHermesRowConservation(t *testing.T, batch, reports int, interval time.Duration) {
	g := wheelGovernor{profile: hermesWheelProfile()}
	tui := newHermesTestTUI()
	now := time.Unix(100, 0)
	for sent := 0; sent < reports; sent += batch {
		tui.receive(t, g.process([]byte(strings.Repeat(wheelDown, batch)), now), now)
		if tui.rows > sent+batch || tui.rows+g.owed != sent+batch {
			t.Fatalf("after %d reports: moved=%d owed=%d", sent+batch, tui.rows, g.owed)
		}
		now = now.Add(interval)
	}
	settleHermesWheelGovernor(t, &g, tui, now)
	if want := (reports + batch - 1) / batch * batch; tui.rows != want {
		t.Fatalf("moved %d rows, want %d", tui.rows, want)
	}
	if tui.enteredWheelMode {
		t.Fatal("governed reports switched Hermes into wheel mode")
	}
}

func settleHermesWheelGovernor(t *testing.T, g *wheelGovernor, tui *hermesTestTUI, now time.Time) {
	t.Helper()
	for flushes := 0; g.owed != 0; flushes++ {
		if flushes > 12 {
			t.Fatal("flush failed to settle debt")
		}
		now = now.Add(g.profile.window + 50*time.Millisecond)
		tui.receive(t, g.drain(now), now)
	}
}

func TestWheelGovernorHermesReversalSendsPair(t *testing.T) {
	g := wheelGovernor{profile: hermesWheelProfile()}
	tui := newHermesTestTUI()
	now := time.Unix(100, 0)
	tui.receive(t, g.process([]byte(wheelDown+wheelDown), now), now)
	now = now.Add(16 * time.Millisecond)
	got := g.process([]byte(wheelUp), now)
	if string(got) != wheelUp+wheelUp {
		t.Fatalf("reversal output=%q, want two up reports", got)
	}
	tui.receive(t, got, now)
	if tui.rows != 1 || g.owed != 0 || g.count != 0 {
		t.Fatalf("after reversal: moved=%d owed=%d count=%d, want 1, 0 and 0", tui.rows, g.owed, g.count)
	}
	// A report in the same direction is a single report again.
	now = now.Add(16 * time.Millisecond)
	if got := g.process([]byte(wheelUp), now); string(got) != wheelUp {
		t.Fatalf("second up output=%q, want one report", got)
	}
}

func TestWheelGovernorHermesJitteredDrag(t *testing.T) {
	// A finger drag that wobbles: mostly one direction, with reversals in
	// the same frame and across frames, at varying frame gaps.
	for seed := int64(1); seed <= 50; seed++ {
		t.Run(fmt.Sprint(seed), func(t *testing.T) {
			random := rand.New(rand.NewSource(seed))
			g := wheelGovernor{profile: hermesWheelProfile()}
			tui := newHermesTestTUI()
			now := time.Unix(100, 0)
			requested := 0
			direction := 1
			for frame := 0; frame < 400; frame++ {
				var chunk []byte
				for report := random.Intn(7); report > 0; report-- {
					if random.Intn(8) == 0 {
						direction = -direction
					}
					if direction > 0 {
						chunk = append(chunk, wheelDown...)
					} else {
						chunk = append(chunk, wheelUp...)
					}
					requested += direction
				}
				tui.receive(t, g.process(chunk, now), now)
				if tui.rows+g.owed != requested {
					t.Fatalf("frame %d: moved=%d owed=%d, requested %d", frame, tui.rows, g.owed, requested)
				}
				now = now.Add(time.Duration(8+random.Intn(60)) * time.Millisecond)
			}
			settleHermesWheelGovernor(t, &g, tui, now)
			if tui.rows != requested {
				t.Fatalf("moved %d rows, requested %d", tui.rows, requested)
			}
			if tui.enteredWheelMode {
				t.Fatal("governed reports switched Hermes into wheel mode")
			}
		})
	}
}

func TestWriteWindowWheelGovernorHermes(t *testing.T) {
	clock := installWheelTestClock(t)
	server, _, pty := newWheelTestWindow("hermes", true)
	window := server.windows[0]
	// Hermes moves 1, 1, 1, 1 and then 2 rows, so seven quick reports send
	// five and hold the seventh row until the ramp has reset.
	if err := server.writeWindowData(window.id, []byte(strings.Repeat(wheelUp, 7)), false, false); err != nil {
		t.Fatal(err)
	}
	if got := pty.String(); got != strings.Repeat(wheelUp, 5) || window.wheelGovernor.owed != -1 {
		t.Fatalf("PTY input=%q owed=%d, want five reports and one row owed", got, window.wheelGovernor.owed)
	}
	if len(clock.timers) != 1 || clock.timers[0].due.Sub(clock.now) != 91*time.Millisecond {
		t.Fatal("want one flush once Hermes's 41ms ramp window and 50ms have passed")
	}
	clock.now = clock.timers[0].due
	clock.timers[0].action()
	if got := pty.String(); got != strings.Repeat(wheelUp, 6) || window.wheelGovernor.owed != 0 {
		t.Fatalf("after flush PTY=%q owed=%d", got, window.wheelGovernor.owed)
	}
}

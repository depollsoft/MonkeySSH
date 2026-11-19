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
// (ui-tui/src/lib/wheelAccel.ts, nativeStep) independently of the governor's
// speed table, including the bounce detection the governor must never
// trigger.
type hermesTestTUI struct {
	base        float64
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
	// Precision mode (ui-tui/src/lib/precisionWheel.ts).
	precisionActive     bool
	precisionDir        int
	precisionLastEvent  int64
	precisionLastScroll int64
}

const (
	// Ctrl-wheel reports, which put Hermes in precision mode.
	ctrlWheelUp   = "\x1b[<80;12;34M"
	ctrlWheelDown = "\x1b[<81;12;34M"
)

// precisionStep mirrors computePrecisionWheelStep and its caller: it returns
// the rows a report moves in precision mode, or false outside it.
func (tui *hermesTestTUI) precisionStep(dir int, modifier bool, now int64) (int, bool) {
	if !modifier && now-tui.precisionLastEvent >= 80 {
		tui.precisionActive = false
		return 0, false
	}
	if !tui.precisionActive {
		// Entering precision mode discards the accelerated wheel state.
		*tui = hermesTestTUI{
			base: tui.base, mult: tui.base, rows: tui.rows, enteredWheelMode: tui.enteredWheelMode,
			precisionDir: tui.precisionDir, precisionLastScroll: tui.precisionLastScroll,
		}
	}
	tui.precisionActive = true
	tui.precisionLastEvent = now
	if dir == tui.precisionDir && now-tui.precisionLastScroll < 16 {
		return 0, true
	}
	tui.precisionDir = dir
	tui.precisionLastScroll = now
	return 1, true
}

func newHermesTestTUI(base float64) *hermesTestTUI {
	return &hermesTestTUI{base: base, mult: base}
}

func (tui *hermesTestTUI) step(dir int, now int64) int {
	if tui.wheelMode && now-tui.timeMs > 1500 {
		tui.wheelMode = false
		tui.burstCount = 0
		tui.mult = tui.base
	}
	if tui.pendingFlip {
		tui.pendingFlip = false
		if dir != tui.dir || now-tui.timeMs > 200 {
			tui.dir = dir
			tui.timeMs = now
			tui.mult = tui.base
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
				tui.mult = tui.base
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
		tui.mult = math.Min(math.Max(15, tui.base*2), math.Min(next, tui.mult+3))
		return int(math.Floor(tui.mult))
	}
	if gap > 40 {
		tui.mult = tui.base
	} else {
		tui.mult = math.Min(math.Max(6, tui.base*2), tui.mult+0.3)
	}
	return int(math.Floor(tui.mult))
}

func (tui *hermesTestTUI) receive(t *testing.T, data []byte, now time.Time) {
	t.Helper()
	for len(data) != 0 {
		direction, modifier := 0, false
		for _, report := range []struct {
			bytes     string
			direction int
			modifier  bool
		}{{wheelUp, -1, false}, {wheelDown, 1, false}, {ctrlWheelUp, -1, true}, {ctrlWheelDown, 1, true}} {
			if bytes.HasPrefix(data, []byte(report.bytes)) {
				direction, modifier = report.direction, report.modifier
				data = data[len(report.bytes):]
				break
			}
		}
		if direction == 0 {
			t.Fatalf("unexpected forwarded bytes: %q", data)
		}
		if rows, precision := tui.precisionStep(direction, modifier, now.UnixMilli()); precision {
			tui.rows += direction * rows
			continue
		}
		tui.rows += direction * tui.step(direction, now.UnixMilli())
	}
}

// hermesTestBases are base speeds a user can set: the default, a fraction,
// one past Hermes's maximum multiplier of 6, and the cap of 20.
var hermesTestBases = []float64{1, 1.5, 3, 7, 20}

// hermesWheelProfile resolves the registered Hermes profile for a base speed,
// as wheelAccelerationProfileLocked does for a window.
func hermesWheelProfile(base float64) *wheelAccelerationProfile {
	profile := *agentRegistry["hermes"].wheelProfile
	profile.speed, profile.processSpeed = hermesWheelSpeed(base), nil
	return &profile
}

func TestHermesWheelSpeedMatchesTUI(t *testing.T) {
	for _, base := range hermesTestBases {
		speed := hermesWheelSpeed(base)
		tui := newHermesTestTUI(base)
		now := time.Unix(100, 0).UnixMilli()
		for count := 0; count < 100; count++ {
			if got, want := speed(count), tui.step(1, now); got != want {
				t.Fatalf("base %v, count %d: speed %d, TUI moved %d", base, count, got, want)
			}
		}
	}
	if got := hermesWheelSteps(1); fmt.Sprint(got) != "[1 1 1 1 2 2 2 3 3 3 3 4 4 4 5 5 5 6]" {
		t.Fatalf("base 1 steps = %v", got)
	}
	if hermesWheelSpeed(0.5) != nil {
		t.Fatal("a base below 1 is governed")
	}
}

func TestHermesTUIAcceleratesUngovernedDrag(t *testing.T) {
	tui := newHermesTestTUI(1)
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
	for _, base := range hermesTestBases {
		for _, batch := range []int{1, 3, 6} {
			for _, reports := range []int{20, 2000} {
				for _, interval := range []time.Duration{0, 16 * time.Millisecond, 30 * time.Millisecond, 45 * time.Millisecond} {
					t.Run(fmt.Sprintf("%v/%d/%d/%v", base, batch, reports, interval), func(t *testing.T) {
						testWheelGovernorHermesRowConservation(t, base, batch, reports, interval)
					})
				}
			}
		}
	}
}

func testWheelGovernorHermesRowConservation(t *testing.T, base float64, batch, reports int, interval time.Duration) {
	g := wheelGovernor{profile: hermesWheelProfile(base)}
	tui := newHermesTestTUI(base)
	// The client calibrates each report to the rows one moves after a pause.
	perReport := int(base)
	now := time.Unix(100, 0)
	for sent := 0; sent < reports; sent += batch {
		requested := (sent + batch) * perReport
		tui.receive(t, g.process([]byte(strings.Repeat(wheelDown, batch)), now), now)
		if tui.rows > requested || tui.rows+g.owed != requested {
			t.Fatalf("after %d reports: moved=%d owed=%d, requested %d", sent+batch, tui.rows, g.owed, requested)
		}
		now = now.Add(interval)
	}
	settleHermesWheelGovernor(t, &g, tui, now)
	// The ramp can leave less than one paused report's rows owed, which the
	// flush rounds to the nearest report.
	want := (reports + batch - 1) / batch * batch * perReport
	if miss := tui.rows - want; miss < -perReport/2 || miss > perReport/2 {
		t.Fatalf("moved %d rows, want %d±%d", tui.rows, want, perReport/2)
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
	g := wheelGovernor{profile: hermesWheelProfile(1)}
	tui := newHermesTestTUI(1)
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
	// the same frame and across frames, at varying frame gaps. With a base
	// below 2 every row is paid exactly.
	for seed := int64(1); seed <= 50; seed++ {
		base := hermesTestBases[int(seed)%len(hermesTestBases)]
		t.Run(fmt.Sprint(seed), func(t *testing.T) {
			random := rand.New(rand.NewSource(seed))
			g := wheelGovernor{profile: hermesWheelProfile(base)}
			tui := newHermesTestTUI(base)
			now := time.Unix(100, 0)
			requested := 0
			direction := 1
			// Each drain rounds at most once, by at most half a paused report.
			perReport := int(base)
			roundingBound := perReport / 2
			miss := 0
			for frame := 0; frame < 400; frame++ {
				var chunk []byte
				reports := random.Intn(7)
				for report := reports; report > 0; report-- {
					if random.Intn(8) == 0 {
						direction = -direction
					}
					if direction > 0 {
						chunk = append(chunk, wheelDown...)
					} else {
						chunk = append(chunk, wheelUp...)
					}
					requested += direction * int(base)
				}
				tui.receive(t, g.process(chunk, now), now)
				next := tui.rows + g.owed - requested
				if change := next - miss; change < -reports*roundingBound || change > reports*roundingBound {
					t.Fatalf("frame %d: moved=%d owed=%d, requested %d, earlier miss %d", frame, tui.rows, g.owed, requested, miss)
				}
				miss = next
				now = now.Add(time.Duration(8+random.Intn(60)) * time.Millisecond)
			}
			settleHermesWheelGovernor(t, &g, tui, now)
			if final := tui.rows - requested - miss; final < -roundingBound || final > roundingBound {
				t.Fatalf("moved %d rows, requested %d with %d already missed", tui.rows, requested, miss)
			}
			if tui.enteredWheelMode {
				t.Fatal("governed reports switched Hermes into wheel mode")
			}
		})
	}
}

func installHermesTestEnvironment(t *testing.T, environment ...string) *int {
	t.Helper()
	original := hermesTUIEnvironmentForGroup
	t.Cleanup(func() { hermesTUIEnvironmentForGroup = original })
	lookups := 0
	hermesTUIEnvironmentForGroup = func(group int) []string {
		lookups++
		return environment
	}
	return &lookups
}

func TestWriteWindowWheelGovernorHermes(t *testing.T) {
	clock := installWheelTestClock(t)
	installHermesTestEnvironment(t)
	server, window, pty := newWheelTestWindow("hermes", true)
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

func TestWriteWindowWheelGovernorHermesScrollSpeed(t *testing.T) {
	installWheelTestClock(t)
	lookups := installHermesTestEnvironment(t, "HERMES_TUI_SCROLL_SPEED=3")
	server, window, pty := newWheelTestWindow("hermes", true)
	// From a base of 3 Hermes moves 3, 3, 3, 3 and then 4 rows, and each
	// calibrated report asks for 3, so five reports owe 15 rows: four
	// reports move 12 and the 3 left are short of the next report's 4.
	if err := server.writeWindowData(window.id, []byte(strings.Repeat(wheelDown, 5)), false, false); err != nil {
		t.Fatal(err)
	}
	if got := pty.String(); got != strings.Repeat(wheelDown, 4) || window.wheelGovernor.owed != 3 {
		t.Fatalf("PTY input=%q owed=%d, want four reports and 3 rows owed", got, window.wheelGovernor.owed)
	}
	if err := server.writeWindowData(window.id, []byte(wheelDown), false, false); err != nil {
		t.Fatal(err)
	}
	if *lookups != 1 {
		t.Fatalf("environment read %d times, want once per process group", *lookups)
	}
	// Another process group that has turned on mouse tracking.
	window.foregroundPid, window.mouseTrackingProcessID = 200, 200
	if err := server.writeWindowData(window.id, []byte(wheelDown), false, false); err != nil {
		t.Fatal(err)
	}
	if *lookups != 2 {
		t.Fatalf("environment read %d times after the process group changed, want 2", *lookups)
	}
}

func TestWriteWindowWheelGovernorHermesSlowScrollSpeed(t *testing.T) {
	installWheelTestClock(t)
	installHermesTestEnvironment(t, "HERMES_TUI_SCROLL_SPEED=0.5")
	server, window, pty := newWheelTestWindow("hermes", true)
	data := strings.Repeat(wheelUp, 7)
	if err := server.writeWindowData(window.id, []byte(data), false, false); err != nil {
		t.Fatal(err)
	}
	if got := pty.String(); got != data {
		t.Fatalf("PTY input=%q, want the reports ungoverned", got)
	}
}

func TestHermesScrollSpeedBase(t *testing.T) {
	for _, test := range []struct {
		environment []string
		want        float64
	}{
		{nil, 1},
		{[]string{"HERMES_TUI_SCROLL_SPEED=3"}, 3},
		{[]string{"CLAUDE_CODE_SCROLL_SPEED=2"}, 2},
		{[]string{"CLAUDE_CODE_SCROLL_SPEED=2", "HERMES_TUI_SCROLL_SPEED=4"}, 4},
		// Set but empty still shadows the fallback, as `??` does.
		{[]string{"HERMES_TUI_SCROLL_SPEED=", "CLAUDE_CODE_SCROLL_SPEED=2"}, 1},
		{[]string{"HERMES_TUI_SCROLL_SPEED=3", "HERMES_TUI_SCROLL_SPEED=5"}, 3},
		{[]string{"HERMES_TUI_SCROLL_SPEED= \t2.5rows"}, 2.5},
		{[]string{"HERMES_TUI_SCROLL_SPEED=.5"}, 0.5},
		{[]string{"HERMES_TUI_SCROLL_SPEED=1e1"}, 10},
		{[]string{"HERMES_TUI_SCROLL_SPEED=50"}, 20},
		{[]string{"HERMES_TUI_SCROLL_SPEED=0x10"}, 1},
		{[]string{"HERMES_TUI_SCROLL_SPEED=-2"}, 1},
		{[]string{"HERMES_TUI_SCROLL_SPEED=0"}, 1},
		{[]string{"HERMES_TUI_SCROLL_SPEED=Infinity"}, 1},
		{[]string{"HERMES_TUI_SCROLL_SPEED=1e400"}, 1},
		{[]string{"HERMES_TUI_SCROLL_SPEED=fast"}, 1},
		{[]string{"HERMES_TUI_SCROLL_SPEED_X=3"}, 1},
	} {
		if got := hermesScrollSpeedBase(test.environment); got != test.want {
			t.Errorf("%q: base %v, want %v", test.environment, got, test.want)
		}
	}
}

func TestWheelGovernorHermesPrecisionMode(t *testing.T) {
	for _, base := range hermesTestBases {
		t.Run(fmt.Sprint(base), func(t *testing.T) {
			g := wheelGovernor{profile: hermesWheelProfile(base)}
			tui := newHermesTestTUI(base)
			now := time.Unix(100, 0)
			send := func(report string, count int, passThrough bool) {
				t.Helper()
				for i := 0; i < count; i++ {
					got := g.process([]byte(report), now)
					if passThrough && string(got) != report {
						t.Fatalf("report %q forwarded as %q, want it unchanged", report, got)
					}
					tui.receive(t, got, now)
					now = now.Add(16 * time.Millisecond)
				}
			}
			// A governed drag, then Ctrl-wheel reports, then plain reports
			// that arrive while Hermes is still in precision mode.
			send(wheelDown, 6, false)
			send(ctrlWheelDown, 3, true)
			send(wheelDown, 4, true)
			if g.owed != 0 || g.count != 0 || !g.last.IsZero() {
				t.Fatalf("precision mode left owed=%d count=%d last=%v", g.owed, g.count, g.last)
			}
			// Once precision mode ends, a drag is governed from a fresh ramp.
			now = now.Add(100 * time.Millisecond)
			before := tui.rows
			send(wheelDown, 30, false)
			settleHermesWheelGovernor(t, &g, tui, now)
			// As in the row conservation test, the flush rounds what the
			// ramp leaves to the nearest report.
			want, bound := 30*int(base), int(base)/2
			if miss := tui.rows - before - want; miss < -bound || miss > bound {
				t.Fatalf("drag after precision mode moved %d rows, want %d±%d", tui.rows-before, want, bound)
			}
			if tui.enteredWheelMode {
				t.Fatal("governed reports switched Hermes into wheel mode")
			}
		})
	}
}

// On Windows a window's process group is its shell, which outlives the TUI,
// so a later Hermes run there must read its own settings.
func TestWheelGovernorHermesRereadsSpeedForNextRun(t *testing.T) {
	installWheelTestClock(t)
	speed := "HERMES_TUI_SCROLL_SPEED=0.5"
	original := hermesTUIEnvironmentForGroup
	t.Cleanup(func() { hermesTUIEnvironmentForGroup = original })
	lookups := 0
	hermesTUIEnvironmentForGroup = func(int) []string {
		lookups++
		return []string{speed}
	}
	server, window, pty := newWheelTestWindow("hermes", true)
	write := func(data string) {
		t.Helper()
		if err := server.writeWindowData(window.id, []byte(data), false, false); err != nil {
			t.Fatal(err)
		}
	}
	write(strings.Repeat(wheelDown, 6))
	if got := pty.String(); got != strings.Repeat(wheelDown, 6) {
		t.Fatalf("PTY input=%q, want a base below 1 ungoverned", got)
	}
	// Hermes exits, turning mouse tracking off, and the next run in the same
	// shell has a base of 3.
	window.observeTerminalModesLocked([]byte("\x1b[?1002l\x1b[?1006l"))
	window.resetWheelGovernorIfInactiveLocked()
	speed = "HERMES_TUI_SCROLL_SPEED=3"
	window.observeTerminalModesLocked([]byte("\x1b[?1002h\x1b[?1006h"))
	before := len(pty.String())
	write(strings.Repeat(wheelDown, 5))
	if got := pty.String()[before:]; got != strings.Repeat(wheelDown, 4) || lookups != 2 {
		t.Fatalf("next run: PTY input=%q after %d lookups, want four reports from base 3 after 2", got, lookups)
	}
}

// Hermes leaves precision mode once a report comes 80 whole milliseconds or
// more after the last one in it. A governor still bypassing there would stay
// bypassed for a whole drag Hermes then ramps, and a reversal could switch
// Hermes into wheel mode.
func TestWheelGovernorHermesPrecisionBoundary(t *testing.T) {
	for _, test := range []struct {
		name     string
		gap      time.Duration
		reversal bool
		governed bool
	}{
		{name: "79ms", gap: 79 * time.Millisecond},
		{name: "79.9ms", gap: 79*time.Millisecond + 900*time.Microsecond},
		{name: "80ms", gap: 80 * time.Millisecond, governed: true},
		{name: "80ms reversal", gap: 80 * time.Millisecond, reversal: true, governed: true},
		{name: "81ms", gap: 81 * time.Millisecond, governed: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			g := wheelGovernor{profile: hermesWheelProfile(1)}
			tui := newHermesTestTUI(1)
			now := time.UnixMilli(100_000)
			tui.receive(t, g.process([]byte(ctrlWheelDown), now), now)
			now = now.Add(test.gap)
			before := tui.rows
			report := wheelDown
			if test.reversal {
				report = wheelUp
			}
			for i := 0; i < 40; i++ {
				tui.receive(t, g.process([]byte(report), now), now)
				now = now.Add(16 * time.Millisecond)
			}
			settleHermesWheelGovernor(t, &g, tui, now)
			moved := tui.rows - before
			if test.reversal {
				moved = -moved
			}
			if test.governed && moved != 40 {
				t.Fatalf("drag after leaving precision mode moved %d rows, want 40", moved)
			}
			if !test.governed && moved > 40 {
				t.Fatalf("drag in precision mode moved %d rows, more than the 40 asked for", moved)
			}
			if tui.enteredWheelMode {
				t.Fatal("reports switched Hermes into wheel mode")
			}
		})
	}
}

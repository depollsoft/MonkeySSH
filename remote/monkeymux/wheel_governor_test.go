package main

import (
	"bytes"
	"fmt"
	"math"
	"strings"
	"testing"
	"time"
)

const (
	wheelUp   = "\x1b[<64;12;34M"
	wheelDown = "\x1b[<65;12;34M"
)

func TestWheelGovernorSlowReports(t *testing.T) {
	for _, gap := range []time.Duration{150 * time.Millisecond, time.Second} {
		g := wheelGovernor{profile: wheelAccelerationProfiles["antigravity"]}
		now := time.Unix(100, 0)
		for i := 0; i < 20; i++ {
			report := []byte(wheelUp)
			if i%2 != 0 {
				report = []byte(wheelDown)
			}
			if got := g.process(report, now); !bytes.Equal(got, report) {
				t.Fatalf("gap %v, report %d = %q, want %q", gap, i, got, report)
			}
			if g.owed != 0 || g.count != 0 {
				t.Fatalf("gap %v, report %d: owed=%d count=%d", gap, i, g.owed, g.count)
			}
			now = now.Add(gap)
		}
	}
}

func TestWheelGovernorSixReportBurst(t *testing.T) {
	g := wheelGovernor{profile: wheelAccelerationProfiles["antigravity"]}
	now := time.Unix(100, 0)
	if got := string(g.process([]byte(strings.Repeat(wheelUp, 6)), now)); got != strings.Repeat(wheelUp, 3) {
		t.Fatalf("burst = %q, want three reports", got)
	}
	if g.owed != -1 || g.count != 2 || g.last != now {
		t.Fatalf("after burst: owed=%d count=%d last=%v", g.owed, g.count, g.last)
	}
	if got := string(g.drain(now.Add(200 * time.Millisecond))); got != wheelUp {
		t.Fatalf("flush = %q, want one report", got)
	}
	if g.owed != 0 || g.count != 0 {
		t.Fatalf("after flush: owed=%d count=%d", g.owed, g.count)
	}
}

// Simulate the disassembled TUI independently of the governor's predictor and
// parser, counting the actual signed rows moved by each forwarded SGR report.
type wheelTestTUI struct {
	last  time.Time
	count int
	rows  int
}

func (tui *wheelTestTUI) receive(t *testing.T, data []byte, now time.Time) {
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
		if now.Sub(tui.last) < 150*time.Millisecond {
			tui.count++
		} else {
			tui.count = 0
		}
		tui.last = now
		tui.rows += direction * min(int(math.Sqrt(float64(tui.count)))+1, 12)
	}
}

func TestWheelGovernorRowConservation(t *testing.T) {
	for _, reports := range []int{20, 2000} {
		for _, interval := range []time.Duration{0, 16 * time.Millisecond} {
			t.Run(fmt.Sprintf("%d/%v", reports, interval), func(t *testing.T) {
				g := wheelGovernor{profile: wheelAccelerationProfiles["antigravity"]}
				tui := wheelTestTUI{}
				now := time.Unix(100, 0)
				for i := 0; i < reports; i++ {
					tui.receive(t, g.process([]byte(wheelDown), now), now)
					if tui.rows > i+1 || tui.rows+g.owed != i+1 {
						t.Fatalf("report %d: moved=%d owed=%d", i+1, tui.rows, g.owed)
					}
					now = now.Add(interval)
				}
				for flushes := 0; g.owed != 0; flushes++ {
					if flushes > 12 {
						t.Fatal("flush failed to settle debt")
					}
					now = now.Add(200 * time.Millisecond)
					tui.receive(t, g.drain(now), now)
				}
				if tui.rows != reports {
					t.Fatalf("moved %d rows, want %d", tui.rows, reports)
				}
			})
		}
	}
}

func TestWheelGovernorDirectionCancellation(t *testing.T) {
	g := wheelGovernor{profile: wheelAccelerationProfiles["antigravity"]}
	now := time.Unix(100, 0)
	g.process([]byte(wheelUp+wheelUp), now)
	if g.owed != -1 {
		t.Fatalf("owed=%d, want -1", g.owed)
	}
	if got := g.process([]byte(wheelDown), now); len(got) != 0 || g.owed != 0 {
		t.Fatalf("reversal output=%q owed=%d, want empty and zero", got, g.owed)
	}
	if got := g.process([]byte(wheelDown+wheelDown), now); string(got) != wheelDown || g.count != 1 {
		t.Fatalf("down output=%q count=%d, want one report and shared count 1", got, g.count)
	}
}

func TestWheelGovernorPassthroughOrder(t *testing.T) {
	const other = "keys\x1b[A\x1b[<66;1;2M\x1b[<67;1;2M\x1b[<0;1;2M\x1b[<32;1;2M\x1b[<64;1;2m\x1b[<96;1;2M"
	g := wheelGovernor{profile: wheelAccelerationProfiles["antigravity"]}
	now := time.Unix(100, 0)
	data := []byte("a" + wheelUp + "b" + wheelUp + other + wheelUp + "z")
	want := "a" + wheelUp + "b" + other + wheelUp + "z"
	if got := string(g.process(data, now)); got != want {
		t.Fatalf("output=%q, want %q", got, want)
	}
	if g.count != 1 || g.owed != 0 {
		t.Fatalf("non-wheel input changed ramp: count=%d owed=%d", g.count, g.owed)
	}
	if got := string((&wheelGovernor{}).process(data, now)); got != string(data) {
		t.Fatalf("nil profile output=%q, want unchanged input", got)
	}
}

func TestWheelGovernorEncodingsAndModifiers(t *testing.T) {
	for _, x10 := range []bool{false, true} {
		for modifiers := 0; modifiers < 32; modifiers += 4 {
			t.Run(fmt.Sprintf("X10=%v/modifiers=%d", x10, modifiers), func(t *testing.T) {
				var up, down string
				if x10 {
					up = string([]byte{27, '[', 'M', byte(32 + 64 + modifiers), 200, 255})
					down = string([]byte{27, '[', 'M', byte(32 + 65 + modifiers), 200, 255})
				} else {
					up = fmt.Sprintf("\x1b[<00%d;0012;0034M", 64+modifiers)
					down = fmt.Sprintf("\x1b[<00%d;0012;0034M", 65+modifiers)
				}
				g := wheelGovernor{profile: wheelAccelerationProfiles["antigravity"]}
				now := time.Unix(100, 0)
				if got := string(g.process([]byte(strings.Repeat(up, 6)), now)); got != strings.Repeat(up, 3) {
					t.Fatalf("burst=%q, want three up reports", got)
				}
				if got := string(g.drain(now.Add(200 * time.Millisecond))); got != up {
					t.Fatalf("flush=%q, want %q", got, up)
				}
				// Residual debt can have the opposite direction to the last
				// report after a reversal during a high-speed burst.
				g.owed = 1
				if got := string(g.drain(now.Add(time.Second))); got != down {
					t.Fatalf("synthesized down=%q, want %q", got, down)
				}
				g.template = []byte(down)
				g.owed = -1
				if got := string(g.drain(now.Add(2 * time.Second))); got != up {
					t.Fatalf("synthesized up=%q, want %q", got, up)
				}
			})
		}
	}
}

func TestWheelGovernorUnrecognizedReports(t *testing.T) {
	// Complete reports that are not a governed wheel event, plus malformed SGR
	// that will never complete into one. All pass through byte for byte and
	// leave the governor untouched, including its carry buffer.
	for _, data := range []string{
		"\x1b[M" + string([]byte{32 + 66, 27, '['}),
		"\x1b[M" + string([]byte{32 + 67, 200, 255}),
		"\x1b[M" + string([]byte{32, 40, 50}),
		"\x1b[M" + string([]byte{32 + 32, 40, 50}),
		"\x1b[<999999999999999999999999;1;2M", "\x1b[<64;;2M",
		"\x1b[A", "\x1bOP",
	} {
		g := wheelGovernor{profile: wheelAccelerationProfiles["antigravity"]}
		if got := string(g.process([]byte(data), time.Unix(100, 0))); got != data {
			t.Errorf("input=%q output=%q", data, got)
		}
		if g.owed != 0 || !g.last.IsZero() || len(g.carry) != 0 {
			t.Errorf("non-wheel report changed state: %+v", g)
		}
	}
}

func TestWheelGovernorCarriesIncompletePrefix(t *testing.T) {
	// A trailing run that could still become a wheel report is withheld, not
	// emitted, so the event is not lost when its tail arrives next chunk.
	for _, prefix := range []string{
		"\x1b", "\x1b[", "\x1b[<", "\x1b[<64;", "\x1b[<64;12;34",
		"\x1b[M", "\x1b[M`", "\x1b[M`x",
	} {
		g := wheelGovernor{profile: wheelAccelerationProfiles["antigravity"]}
		if got := string(g.process([]byte("ab"+prefix), time.Unix(100, 0))); got != "ab" {
			t.Errorf("prefix=%q output=%q, want leading bytes only", prefix, got)
		}
		if string(g.carry) != prefix {
			t.Errorf("prefix=%q carry=%q, want held", prefix, g.carry)
		}
		if g.owed != 0 {
			t.Errorf("prefix=%q accumulated debt: %d", prefix, g.owed)
		}
	}
}

func TestWheelGovernorSplitReportAcrossChunks(t *testing.T) {
	now := time.Unix(100, 0)
	// One wheel-up split into two reads is reassembled and governed, not lost.
	g := wheelGovernor{profile: wheelAccelerationProfiles["antigravity"]}
	if got := string(g.process([]byte("\x1b[<64;12"), now)); got != "" {
		t.Fatalf("held half output=%q, want empty", got)
	}
	if got := string(g.process([]byte(";34M"), now)); got != wheelUp {
		t.Fatalf("completed output=%q, want one wheel report", got)
	}
	if g.owed != 0 {
		t.Fatalf("owed=%d, want 0", g.owed)
	}
	// Split at the very first byte, and drive the TUI to confirm it moves
	// exactly one row rather than leaving acceleration active for the event.
	g.reset(wheelAccelerationProfiles["antigravity"])
	tui := wheelTestTUI{}
	tui.receive(t, g.process([]byte("\x1b"), now), now)
	tui.receive(t, g.process([]byte("[<64;12;34M"), now), now)
	if tui.rows != -1 || g.owed != 0 { // One wheel-up moves one row up.
		t.Fatalf("rows=%d owed=%d, want -1 and 0", tui.rows, g.owed)
	}
}

func TestWheelGovernorDropsReorderedDebt(t *testing.T) {
	g := wheelGovernor{profile: wheelAccelerationProfiles["antigravity"]}
	now := time.Unix(100, 0)
	// A fast pair leaves one row owed for the flush.
	g.process([]byte(wheelUp+wheelUp), now)
	if g.owed == 0 {
		t.Fatal("expected pending debt after a fast pair")
	}
	// A keystroke before the flush drops that debt so no wheel report is
	// written after the keystroke.
	if got := string(g.process([]byte("\r"), now.Add(10*time.Millisecond))); got != "\r" {
		t.Fatalf("keystroke output=%q", got)
	}
	if g.owed != 0 {
		t.Fatalf("owed=%d after keystroke, want 0", g.owed)
	}
	if got := string(g.drain(now.Add(time.Second))); got != "" {
		t.Fatalf("flush wrote %q after keystroke, want nothing", got)
	}
}

func TestWheelGovernorTakeOpaque(t *testing.T) {
	g := wheelGovernor{profile: wheelAccelerationProfiles["antigravity"]}
	now := time.Unix(100, 0)
	g.process([]byte(wheelUp+wheelUp+"\x1b[<64;1"), now)
	if g.owed == 0 || len(g.carry) == 0 {
		t.Fatalf("setup: owed=%d carry=%q", g.owed, g.carry)
	}
	paste := "\x1b[200~" + wheelUp + "text\x1b[201~"
	if got := string(g.takeOpaque([]byte(paste))); got != "\x1b[<64;1"+paste {
		t.Fatalf("opaque output=%q", got)
	}
	if g.owed != 0 || len(g.carry) != 0 {
		t.Fatalf("opaque left state: owed=%d carry=%q", g.owed, g.carry)
	}
}

func TestWheelReportPrefixLen(t *testing.T) {
	for _, c := range []struct {
		data string
		want int
	}{
		{"\x1b", 1}, {"\x1b[", 2}, {"\x1b[<", 3}, {"\x1b[<64;12", 8},
		{"\x1b[M", 3}, {"\x1b[M`", 4}, {"\x1b[M`x", 5},
		{"", 0}, {"\x1b[A", 0}, {"\x1bO", 0}, {"\x1b[2", 0},
		{wheelUp, 0}, {"\x1b[M`xy", 0}, {"\x1b[<64;1;2m", 0},
		{"\x1b[<" + strings.Repeat("9", 40), 0}, // Over the length bound.
	} {
		if got := wheelReportPrefixLen([]byte(c.data)); got != c.want {
			t.Errorf("wheelReportPrefixLen(%q)=%d, want %d", c.data, got, c.want)
		}
	}
}

func TestWriteWindowWheelGovernorPasteOpaque(t *testing.T) {
	clock := installWheelTestClock(t)
	server, window, pty := newWheelTestWindow("agy", true)
	if err := server.writeWindowData(window.id, []byte(strings.Repeat(wheelUp, 6)), false, false); err != nil {
		t.Fatal(err)
	}
	if window.wheelGovernor.owed == 0 || len(clock.timers) == 0 {
		t.Fatal("setup expected pending debt and a scheduled flush")
	}
	pty.Reset()
	paste := "\x1b[200~" + wheelUp + "hello\x1b[201~"
	if err := server.writeWindowData(window.id, []byte(paste), true, false); err != nil {
		t.Fatal(err)
	}
	if got := pty.String(); got != paste {
		t.Fatalf("paste PTY=%q, want verbatim", got)
	}
	if window.wheelGovernor.owed != 0 {
		t.Fatalf("owed=%d after paste, want 0", window.wheelGovernor.owed)
	}
	pty.Reset()
	for _, tm := range clock.timers {
		clock.now = tm.due
		tm.action()
	}
	if got := pty.String(); got != "" {
		t.Fatalf("a flush wrote %q after paste, want nothing", got)
	}
}

type wheelTestTimer struct {
	due    time.Time
	action func()
}

type wheelTestClock struct {
	now    time.Time
	timers []wheelTestTimer
}

func installWheelTestClock(t *testing.T) *wheelTestClock {
	t.Helper()
	clock := &wheelTestClock{now: time.Unix(100, 0)}
	originalNow, originalSchedule := wheelGovernorNow, scheduleWheelFlush
	originalForeground := foregroundProcessGroupForWindow
	t.Cleanup(func() {
		wheelGovernorNow, scheduleWheelFlush = originalNow, originalSchedule
		foregroundProcessGroupForWindow = originalForeground
	})
	foregroundProcessGroupForWindow = func(window *muxWindow) int { return window.foregroundPid }
	wheelGovernorNow = func() time.Time { return clock.now }
	scheduleWheelFlush = func(delay time.Duration, action func()) {
		if delay != 200*time.Millisecond {
			t.Errorf("flush delay=%v, want 200ms", delay)
		}
		clock.timers = append(clock.timers, wheelTestTimer{clock.now.Add(delay), action})
	}
	return clock
}

func newWheelTestWindow(tool string, mouse bool) (*muxServer, *muxWindow, *recordingPty) {
	pty := &recordingPty{}
	window := &muxWindow{id: "@1", pty: pty, foregroundPid: 100, foregroundCommand: tool}
	if mouse {
		window.observeTerminalModesLocked([]byte("\x1b[?1002h\x1b[?1006h"))
	}
	server := newMuxServer("test")
	server.windows, server.activeID = []*muxWindow{window}, window.id
	return server, window, pty
}

func TestWriteWindowWheelGovernorGating(t *testing.T) {
	for _, test := range []struct {
		name, tool                       string
		mouse, response, win32, governed bool
	}{
		{name: "antigravity", tool: "agy", mouse: true, governed: true},
		{name: "claude", tool: "claude", mouse: true},
		{name: "no mouse", tool: "agy"},
		{name: "response", tool: "agy", mouse: true, response: true},
		{name: "win32", tool: "agy", mouse: true, win32: true, governed: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			clock := installWheelTestClock(t)
			server, window, pty := newWheelTestWindow(test.tool, test.mouse)
			window.win32InputMode = test.win32
			data := strings.Repeat(wheelUp, 6)
			if err := server.writeWindowData(window.id, []byte(data), false, test.response); err != nil {
				t.Fatal(err)
			}
			want := data
			if test.governed {
				want = strings.Repeat(wheelUp, 3)
			}
			if got := pty.String(); got != want {
				t.Fatalf("PTY input=%q, want %q", got, want)
			}
			if !test.governed {
				if len(clock.timers) != 0 || window.wheelGovernor.owed != 0 {
					t.Fatal("bypassed input scheduled a flush or accumulated debt")
				}
				return
			}
			if len(clock.timers) != 1 {
				t.Fatalf("timers=%d, want 1", len(clock.timers))
			}
			clock.now = clock.timers[0].due
			clock.timers[0].action()
			if got := pty.String(); got != strings.Repeat(wheelUp, 4) || window.wheelGovernor.owed != 0 {
				t.Fatalf("after flush PTY=%q owed=%d", got, window.wheelGovernor.owed)
			}
		})
	}
}

func TestWheelGovernorFlushInvalidation(t *testing.T) {
	for _, change := range []string{"closed", "retired", "replaced", "stale", "agent", "mouse1000", "mouse1002", "mouse1003", "owner", "cancelled"} {
		t.Run(change, func(t *testing.T) {
			clock := installWheelTestClock(t)
			server, window, pty := newWheelTestWindow("agy", true)
			if strings.HasPrefix(change, "mouse") {
				window.observeTerminalModesLocked([]byte("\x1b[?1002l\x1b[?" + strings.TrimPrefix(change, "mouse") + "h"))
			}
			if err := server.writeWindowInput(window.id, []byte(wheelUp+wheelUp), false); err != nil {
				t.Fatal(err)
			}
			if len(clock.timers) != 1 || window.wheelGovernor.owed != -1 {
				t.Fatal("expected one pending row and timer")
			}
			server.mu.Lock()
			switch change {
			case "closed":
				window.closed = true
			case "retired":
				server.retireWindowLocked(window)
			case "replaced":
				server.windows = []*muxWindow{{id: window.id, pty: pty, foregroundCommand: "agy"}}
			case "agent":
				window.foregroundCommand = "claude"
			case "owner":
				window.foregroundPid = 200
			default:
				if strings.HasPrefix(change, "mouse") {
					window.observeTerminalModesLocked([]byte("\x1b[?" + strings.TrimPrefix(change, "mouse") + "l"))
					if g := &window.wheelGovernor; g.owed != 0 || g.count != 0 || !g.last.IsZero() {
						t.Fatalf("mouse disable did not reset governor: %+v", g)
					}
				}
			}
			server.mu.Unlock()
			if change == "stale" || change == "cancelled" {
				data := "x"
				if change == "cancelled" {
					data = wheelDown
				}
				if err := server.writeWindowInput(window.id, []byte(data), false); err != nil {
					t.Fatal(err)
				}
			}
			before := pty.String()
			clock.now = clock.timers[0].due
			clock.timers[0].action()
			if got := pty.String(); got != before {
				t.Fatalf("invalidated flush wrote %q", got[len(before):])
			}
			if change == "stale" {
				// A keystroke arriving before the flush drops the pending row,
				// so no wheel report lands after it, and schedules no
				// replacement; the earlier timer is left stale and, fired
				// above, wrote nothing.
				if window.wheelGovernor.owed != 0 || len(clock.timers) != 1 {
					t.Fatalf("keystroke debt handling: owed=%d timers=%d",
						window.wheelGovernor.owed, len(clock.timers))
				}
			}
		})
	}
}

func TestWriteWindowWheelGovernorRowConservation(t *testing.T) {
	clock := installWheelTestClock(t)
	server, window, pty := newWheelTestWindow("agy", true)
	tui := wheelTestTUI{}
	read := 0
	receive := func() {
		output := pty.String()
		tui.receive(t, []byte(output[read:]), clock.now)
		read = len(output)
	}
	for i := 0; i < 20; i++ {
		if err := server.writeWindowInput(window.id, []byte(wheelDown), false); err != nil {
			t.Fatal(err)
		}
		receive()
		clock.now = clock.now.Add(16 * time.Millisecond)
	}
	initialTimers := len(clock.timers)
	for i := 0; i < len(clock.timers); i++ {
		if i > initialTimers+12 {
			t.Fatal("flush failed to settle debt")
		}
		timer := clock.timers[i]
		if timer.due.After(clock.now) {
			clock.now = timer.due
		}
		timer.action()
		receive()
	}
	if tui.rows != 20 || window.wheelGovernor.owed != 0 {
		t.Fatalf("after flushes: moved=%d owed=%d, want 20 and 0", tui.rows, window.wheelGovernor.owed)
	}
}

func TestWheelGovernorFlushRearmsSynchronously(t *testing.T) {
	clock := installWheelTestClock(t)
	server, window, pty := newWheelTestWindow("agy", true)
	// Advance the injected clock and fire inline to catch scheduling while
	// holding either lock. Eleven residual rows require multiple flushes.
	flushes := 0
	scheduleWheelFlush = func(delay time.Duration, action func()) {
		flushes++
		if flushes > 12 {
			t.Fatal("flush failed to settle debt")
		}
		clock.now = clock.now.Add(delay)
		action()
	}
	window.wheelGovernor = wheelGovernor{
		profile: wheelAccelerationProfiles["antigravity"],
		last:    clock.now, count: 121, owed: 11, template: []byte(wheelUp),
	}
	server.mu.Lock()
	window.inputMu.Lock()
	schedule := server.prepareWheelFlushLocked(window)
	window.inputMu.Unlock()
	server.mu.Unlock()
	if schedule != nil {
		schedule()
	}
	if flushes < 2 || window.wheelGovernor.owed != 0 {
		t.Fatalf("flushes=%d owed=%d, want multiple flushes and zero debt", flushes, window.wheelGovernor.owed)
	}
	if !strings.HasPrefix(pty.String(), wheelDown) {
		t.Fatalf("flush lost debt direction: %q", pty.String())
	}
}

func TestWheelGovernorResponsePreservesPendingFlush(t *testing.T) {
	clock := installWheelTestClock(t)
	server, window, pty := newWheelTestWindow("agy", true)
	if err := server.writeWindowInput(window.id, []byte(wheelUp+wheelUp), false); err != nil {
		t.Fatal(err)
	}
	generation := window.wheelGovernor.flushGen
	if err := server.writeWindow(window.id, []byte(wheelDown)); err != nil {
		t.Fatal(err)
	}
	if g := &window.wheelGovernor; g.owed != -1 || g.count != 0 || g.flushGen != generation {
		t.Fatalf("response changed governor state: %+v", g)
	}
	clock.now = clock.timers[0].due
	clock.timers[0].action()
	if got := pty.String(); got != wheelUp+wheelDown+wheelUp {
		t.Fatalf("response and flush PTY=%q", got)
	}
}

func TestWheelGovernorResetsBeforeMouseTrackingResumes(t *testing.T) {
	clock := installWheelTestClock(t)
	server, window, pty := newWheelTestWindow("agy", true)
	if err := server.writeWindowInput(window.id, []byte(strings.Repeat(wheelUp, 6)), false); err != nil {
		t.Fatal(err)
	}
	server.mu.Lock()
	window.observeTerminalModesLocked([]byte("\x1b[?1002l\x1b[?1002h"))
	server.mu.Unlock()
	if err := server.writeWindowInput(window.id, []byte(wheelDown), false); err != nil {
		t.Fatal(err)
	}
	want := strings.Repeat(wheelUp, 3) + wheelDown
	clock.now = clock.timers[0].due
	clock.timers[0].action()
	if got := pty.String(); got != want || window.wheelGovernor.count != 0 || window.wheelGovernor.owed != 0 {
		t.Fatalf("resumed PTY=%q, count=%d owed=%d", got, window.wheelGovernor.count, window.wheelGovernor.owed)
	}
}

func TestWheelGovernorsArePerWindow(t *testing.T) {
	clock := installWheelTestClock(t)
	server, first, firstPty := newWheelTestWindow("agy", true)
	_, second, secondPty := newWheelTestWindow("agy", true)
	second.id = "@2"
	server.windows = append(server.windows, second)
	for _, window := range []*muxWindow{first, second} {
		if err := server.writeWindowInput(window.id, []byte(wheelUp+wheelUp), false); err != nil {
			t.Fatal(err)
		}
	}
	if len(clock.timers) != 2 || firstPty.String() != wheelUp || secondPty.String() != wheelUp {
		t.Fatal("windows did not independently forward their first report")
	}
	clock.now = clock.timers[0].due
	clock.timers[0].action()
	if firstPty.String() != wheelUp+wheelUp || secondPty.String() != wheelUp || second.wheelGovernor.owed != -1 {
		t.Fatal("first window's flush disturbed second window")
	}
	clock.timers[1].action()
	if secondPty.String() != wheelUp+wheelUp || second.wheelGovernor.owed != 0 {
		t.Fatal("second window did not flush its own debt")
	}
}

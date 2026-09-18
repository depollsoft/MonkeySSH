package main

import (
	"bytes"
	"fmt"
	"os"
	"runtime"
	"strings"
	"testing"
)

func benchTranscript(n int) []byte {
	var b bytes.Buffer
	for b.Len() < n {
		fmt.Fprintf(&b, "\x1b[2m⏺\x1b[22m line %d: the quick brown fox jumps over the lazy dog \x1b[38;2;10;20;30m─────\x1b[0m 漢字\r\n", b.Len())
	}
	return b.Bytes()
}

func benchTUIFrames(width, height, n int) []byte {
	var b bytes.Buffer
	for _, f := range inkLikeFrames(width, height, true) {
		b.Write(f)
	}
	for tick := 0; b.Len() < n; tick++ {
		fmt.Fprintf(&b, "\x1b[?2026h\x1b[%d;1H\x1b[2K\x1b[38;2;255;193;7m✻ Working… (%d)\x1b[0m\x1b[%d;1H\x1b[2K\x1b[48;2;20;20;20m  status %d %s\x1b[0m\x1b[%d;3H\x1b[?2026l", height-5, tick, height, tick, strings.Repeat("·", 30), height-2)
	}
	return b.Bytes()
}

func BenchmarkVTScreenWriteTranscript(b *testing.B) {
	data := benchTranscript(1 << 20)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		s := newTerminalScreen(80, 24)
		s.Write(data)
	}
}

func BenchmarkVTScreenWriteTUI(b *testing.B) {
	data := benchTUIFrames(80, 24, 1<<20)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		s := newTerminalScreen(80, 24)
		s.Write(data)
	}
}

func BenchmarkVTScreenWritePlainCat(b *testing.B) {
	data := bytes.Repeat([]byte(strings.Repeat("x", 79)+"\r\n"), 1<<20/81)
	b.SetBytes(int64(len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		s := newTerminalScreen(80, 24)
		s.Write(data)
	}
}

func BenchmarkVTScreenRenderFrame(b *testing.B) {
	s := newTerminalScreen(80, 24)
	s.Write(benchTUIFrames(80, 24, 64<<10))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = s.RenderFrame()
	}
}

func BenchmarkVTScreenClone(b *testing.B) {
	s := newTerminalScreen(80, 24)
	s.Write(benchTranscript(2 << 20))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = s.Clone()
	}
}

// TestVTScreenMemoryProbe reports the heap cost of a window with a full
// scrollback; run with MONKEYMUX_VT_MEMPROBE=1 -v.
func TestVTScreenMemoryProbe(t *testing.T) {
	if os.Getenv("MONKEYMUX_VT_MEMPROBE") == "" {
		t.Skip("MONKEYMUX_VT_MEMPROBE not set")
	}
	for _, size := range [][2]int{{80, 24}, {200, 50}} {
		var before, after runtime.MemStats
		runtime.GC()
		runtime.ReadMemStats(&before)
		screens := make([]*terminalScreen, 20)
		for i := range screens {
			s := newTerminalScreen(size[0], size[1])
			s.Write(benchTranscript(2 << 20))
			screens[i] = s
		}
		runtime.GC()
		runtime.ReadMemStats(&after)
		per := (after.HeapAlloc - before.HeapAlloc) / uint64(len(screens))
		t.Logf("%dx%d window with full 1000-line scrollback: %.2f MB heap each", size[0], size[1], float64(per)/1e6)
		runtime.KeepAlive(screens)
	}
}

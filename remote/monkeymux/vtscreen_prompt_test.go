package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

type semanticParityCase struct {
	Name  string `json:"name"`
	Size  [2]int `json:"size"`
	Steps []struct {
		Write  string  `json:"write"`
		Resize *[2]int `json:"resize"`
	} `json:"steps"`
	Expect []string `json:"expect"`
	// A case with a Frame is a window the client attaches to after the
	// first ReplayAfter steps: Frame is the replay the model sends then.
	ReplayAfter int    `json:"replayAfter"`
	Frame       string `json:"frame"`
}

// dumpSemanticPrompt is dumpSemanticPrompt in
// third_party/xterm/test/src/core/semantic_prompt_parity_test.dart.
func dumpSemanticPrompt(s *terminalScreen) []string {
	var out []string
	row := func(cells []vtCell, wrapped bool, prompt uint8) string {
		mark := map[uint8]string{vtPromptNone: "-", vtPromptPrimary: "P", vtPromptContinuation: "C", vtPromptSecondary: "S"}[prompt]
		wrap := " "
		if wrapped {
			wrap = "+"
		}
		var text, content strings.Builder
		for x := 0; x < vtTrimmedLength(cells, s.width); x++ {
			if cells[x].width == 0 {
				continue
			}
			r := cells[x].r
			if r == 0 {
				r = ' '
			}
			text.WriteRune(r)
			content.WriteByte("oip"[cells[x].sem])
		}
		return mark + wrap + "|" + text.String() + "|" + content.String()
	}
	if !s.altActive {
		var decoder vtLineDecoder
		for i := range s.scrollback.len() {
			line := s.scrollback.at(i)
			out = append(out, row(line.decode(&decoder, s.width), line.wrapped, line.prompt))
		}
	}
	g := s.grid()
	for r, cells := range g.rows {
		out = append(out, row(cells, g.wrapped[r], g.prompt[r]))
	}
	st := s.semantic()
	eol := ""
	if st.eolInput {
		eol = " eol"
	}
	cl := map[uint8]string{
		vtCursorKeysNone:          "-",
		vtCursorKeysLine:          "line",
		vtCursorKeysMultiple:      "multiple",
		vtCursorKeysVertical:      "conservativeVertical",
		vtCursorKeysSmartVertical: "smartVertical",
	}[st.cursorKeys]
	aid := st.aid
	if aid == "" {
		aid = "-"
	}
	out = append(out, fmt.Sprintf("cursor %d,%d %c%s click=%d cl=%s special=%t redraw=%t aid=%s",
		g.cursorCol, g.cursorRow, "oip"[st.content], eol, st.clickEvents, cl, st.specialKey, !st.noRedraw, aid))
	return out
}

func runSemanticParitySteps(s *terminalScreen, c semanticParityCase, from, to int) {
	for _, step := range c.Steps[from:to] {
		if step.Write != "" {
			s.Write([]byte(step.Write))
		}
		if step.Resize != nil {
			s.Resize(step.Resize[0], step.Resize[1])
		}
	}
}

func runSemanticParityCase(c semanticParityCase) *terminalScreen {
	s := newTerminalScreen(c.Size[0], c.Size[1])
	runSemanticParitySteps(s, c, 0, len(c.Steps))
	return s
}

// TestSemanticPromptParityWithClient runs the cases the client's
// semantic_prompt_parity_test.dart runs and expects the same marks, cell
// contents, scrollback and prompt state.
func TestSemanticPromptParityWithClient(t *testing.T) {
	data, err := os.ReadFile("testdata/semantic_prompt_parity.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []semanticParityCase
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			got := dumpSemanticPrompt(runSemanticParityCase(c))
			if strings.Join(got, "\n") != strings.Join(c.Expect, "\n") {
				t.Fatalf("model differs from the client\n got:\n%s\nwant:\n%s",
					strings.Join(got, "\n"), strings.Join(c.Expect, "\n"))
			}
			if c.Frame == "" {
				return
			}
			// The client in this case was painted from the model's frame.
			s := newTerminalScreen(c.Size[0], c.Size[1])
			runSemanticParitySteps(s, c, 0, c.ReplayAfter)
			if frame := activeWindowReplayPrefix + string(s.RenderFrame()); frame != c.Frame {
				t.Fatalf("the frame changed; record it again in the fixture:\n%q", frame)
			}
			replica := newTerminalScreen(c.Size[0], c.Size[1])
			replica.Write([]byte(c.Frame))
			runSemanticParitySteps(replica, c, c.ReplayAfter, len(c.Steps))
			if got := dumpSemanticPrompt(replica); strings.Join(got, "\n") != strings.Join(c.Expect, "\n") {
				t.Fatalf("a model painted from the frame differs\n got:\n%s\nwant:\n%s",
					strings.Join(got, "\n"), strings.Join(c.Expect, "\n"))
			}
		})
	}
}

func osc133(body string) string { return "\x1b]133;" + body + "\x07" }

func TestSemanticPromptReadsLongOptions(t *testing.T) {
	s := newTerminalScreen(40, 4)
	aid := strings.Repeat("x", 100)
	s.Write([]byte(osc133("A;aid=" + aid + ";click_events=2;cl=v;special_key=1;redraw=last")))
	st := s.semantic()
	if st.aid != aid || st.clickEvents != 2 || st.cursorKeys != vtCursorKeysVertical || !st.specialKey || st.noRedraw {
		t.Fatalf("options = %+v", *st)
	}
	// An over-long payload keeps what fits, and the mark still applies.
	s.Write([]byte("\r\n" + osc133("A;aid="+strings.Repeat("y", 2*vtSemanticOSCLimit)+";cl=line")))
	if st.cursorKeys != vtCursorKeysNone || s.main.prompt[1] != vtPromptPrimary {
		t.Fatalf("truncated mark: %+v, rows %v", *st, s.main.prompt)
	}
}

// replayFrame paints s's frame onto a fresh model the way an attaching client
// receives it: after the replay prefix, which ends with CSI 3 J.
func replayFrame(s *terminalScreen) *terminalScreen {
	width, height := s.Size()
	replica := newTerminalScreen(width, height)
	replica.Write([]byte("\x1b[?6l\x1b[r\x1b[0m" + terminalAllScreensClearSequence))
	replica.Write(s.RenderFrame())
	return replica
}

func TestRenderFrameReemitsTheCurrentPromptMarks(t *testing.T) {
	cases := []struct {
		name   string
		size   [2]int
		output string
	}{
		{"single line", [2]int{20, 5}, osc133("A;cl=line;aid=9") + "$ " + osc133("B") + "ls -la\x1b[3D"},
		{"empty input", [2]int{20, 5}, osc133("A;click_events=1") + "$ " + osc133("B")},
		{"wrapped and secondary prompt", [2]int{8, 6}, osc133("A;cl=m") + "$ " + osc133("B") + "abcdefghij\r\n" +
			osc133("P;k=s") + "> " + osc133("B") + "kl"},
		{"input ending with its line", [2]int{20, 5}, osc133("A") + "$ " + osc133("I") + "x"},
		{"after output in the scrollback", [2]int{12, 3}, "1\r\n2\r\n3\r\n4\r\n" + osc133("A;special_key=1;click_events=1") +
			"$ " + osc133("B") + "echo"},
		// A newline inside a prompt continues it; only k=s starts a secondary
		// prompt, which relative click events count rows from.
		{"two-line prompt", [2]int{20, 5}, osc133("A;click_events=2") + "top\r\n$ " + osc133("B") + "abc"},
		{"two-line prompt, second line k=s", [2]int{20, 5}, osc133("A;click_events=2") + "top\r\n" +
			osc133("P;k=s") + "$ " + osc133("B") + "abc"},
		{"two-line prompt, last line A;k=s", [2]int{20, 5}, osc133("A;click_events=2") + "top\r\n" +
			osc133("A;k=s") + "$ " + osc133("B") + "abc"},
		{"continuation prompt k=c", [2]int{20, 5}, osc133("A;cl=m") + "$ " + osc133("B") + "a\r\n" +
			osc133("P;k=c") + "> " + osc133("B") + "b"},
		{"wrapped two-line prompt", [2]int{6, 6}, osc133("A;click_events=2") + "topline!\r\n$ " + osc133("B") +
			"abcdefgh"},
		{"wrapped secondary prompt", [2]int{6, 6}, osc133("A;click_events=2") + "top\r\n" + osc133("P;k=s") +
			"$ " + osc133("B") + "abcdefgh"},
		{"secondary prompt from the scrollback", [2]int{6, 3}, osc133("A;click_events=2") + "top\r\n" +
			osc133("P;k=s") + "$ " + osc133("B") + "abcdefghijklmnop"},
		{"secondary prompt first on the screen", [2]int{20, 3}, osc133("A;click_events=2") + "top\r\n" +
			osc133("P;k=s") + "$ " + osc133("B") + "a\x1b[H\x1b[1J\x1b[2;3H"},
		// The frame reprints the last glyph of the scrollback to wrap onto
		// the screen, and that glyph is prompt text.
		{"prompt text wrapping from the scrollback", [2]int{10, 3}, osc133("A;click_events=2") + "topline!!!x\r\n$ " +
			osc133("B") + "abcdefghijkl"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newTerminalScreen(c.size[0], c.size[1])
			s.Write([]byte(osc133("C") + "out\r\n" + osc133("D;0") + c.output))
			want := dumpSemanticPrompt(s)
			got := dumpSemanticPrompt(replayFrame(s))
			if strings.Join(got, "\n") != strings.Join(want, "\n") {
				t.Fatalf("frame lost the prompt\n got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
		})
	}
}

// A prompt row that scrolled into the scrollback and came back with a taller
// screen keeps its input, so a frame still marks it as input.
func TestRenderFrameKeepsInputRestoredFromScrollback(t *testing.T) {
	s := newTerminalScreen(10, 2)
	s.Write([]byte(osc133("A;cl=line") + "$ " + osc133("B") + "abcdefghijklmnopqrstuv"))
	s.Resize(10, 4)
	if got := s.main.rows[0][2].sem; got != vtSemInput {
		t.Fatalf("restored row cell content = %d, want input", got)
	}
	want := dumpSemanticPrompt(s)
	got := dumpSemanticPrompt(replayFrame(s))
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("frame lost the restored input\n got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestRenderFrameEmitsNoMarksOutsideAPrompt(t *testing.T) {
	s := newTerminalScreen(20, 5)
	s.Write([]byte(osc133("A;cl=line") + "$ " + osc133("B") + "sleep 9\r\n" + osc133("C") + "running"))
	if frame := string(s.RenderFrame()); strings.Contains(frame, "\x1b]133") {
		t.Fatalf("frame of a running command carries marks: %q", frame)
	}
	alt := newTerminalScreen(20, 5)
	alt.Write([]byte(osc133("A") + "$ " + osc133("B") + "\x1b[?1049h" + osc133("A") + "> " + osc133("B")))
	if frame := string(alt.RenderFrame()); strings.Contains(frame, "\x1b]133") {
		t.Fatalf("alternate screen frame carries marks: %q", frame)
	}
}

func TestSemanticPromptCloneAndReset(t *testing.T) {
	s := newTerminalScreen(20, 4)
	s.Write([]byte(osc133("A;cl=line") + "$ " + osc133("B") + "x"))
	c := s.Clone()
	s.Write([]byte("\x1bc"))
	if s.main.prompt[0] != vtPromptNone || s.semantic().cursorKeys != vtCursorKeysNone || s.semantic().content != vtSemOutput {
		t.Fatalf("RIS kept the prompt: %v %+v", s.main.prompt, *s.semantic())
	}
	if c.main.prompt[0] != vtPromptPrimary || c.semantic().cursorKeys != vtCursorKeysLine || c.main.rows[0][2].sem != vtSemInput {
		t.Fatalf("clone lost the prompt: %v %+v", c.main.prompt, *c.semantic())
	}
}

// TestSemanticPromptMarksReachAttachedClients checks that a window's OSC 133
// and 633 marks, options included, reach attached clients in live output and
// survive the replay filter, while the window's model applies them.
func TestSemanticPromptMarksReachAttachedClients(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{{id: "@1", index: 0, lastActivity: time.Now()}}
	server.activeID = "@1"
	conn := &recordingConn{}
	registerTestAttachClient(t, server, conn, "client", 80, 24)

	output := osc133("A;click_events=1;cl=line;special_key=1;redraw=0;aid=42") + "$ " + osc133("B") +
		"ls\r\n" + osc133("C;cmdline_url=ls") + "out\r\n" + osc133("D;0") +
		"\x1b]633;A\x07$ \x1b]633;B\x07"
	// A mark split across reads still arrives whole.
	server.handleWindowOutput("@1", []byte(output[:12]))
	server.handleWindowOutput("@1", []byte(output[12:]))
	waitForRecordedOutput(t, conn, output)

	if replay := string(stripTerminalQueriesFromReplay([]byte(output))); replay != output {
		t.Fatalf("replay filter changed the marks: %q", replay)
	}
	server.mu.Lock()
	screen := server.windows[0].screenLocked()
	prompt, content := screen.main.prompt[2], screen.semMain.content
	server.mu.Unlock()
	if prompt != vtPromptPrimary || content != vtSemInput {
		t.Fatalf("model prompt row %d, content %d", prompt, content)
	}
}

// The cursor can be in a prompt or its input on a row the model does not
// mark, after the prompt row was deleted under it or erased above it, or
// when VS Code marked the content alone. A frame must leave the row
// unmarked on the client and still carry the content and the options in
// force, whatever prompt the client showed before. (A frame carries the
// marks of the prompt the cursor is at only, so these cases keep no other.)
func TestRenderFrameLeavesUnmarkedPromptRowsUnmarked(t *testing.T) {
	cases := []struct {
		name   string
		size   [2]int
		output string
	}{
		{"continuation deleted under the cursor", [2]int{20, 5},
			osc133("P;k=s") + "\x1b[M" + "text" + "\x1b[H\x1b[J"},
		{"prompt deleted under the cursor", [2]int{20, 5},
			"out\r\n" + osc133("A;cl=line;click_events=1") + "$ \x1b[M" + "abc"},
		{"prompt erased above the cursor", [2]int{20, 5},
			osc133("A;cl=m") + "$ " + osc133("B") + "ls\x1b[4;3H\x1b[1J" + "x"},
		{"cursor above a continuation", [2]int{20, 5},
			"\r\n\r\n" + osc133("P;k=s") + "> " + osc133("B") + "x\x1b[3;1H"},
		{"VS Code input alone", [2]int{20, 5}, "$ \x1b]633;B\x07ls"},
		{"VS Code prompt alone", [2]int{20, 5}, "\x1b]633;H\x07$ "},
		{"ED 1 at a continuation", [2]int{20, 5},
			osc133("A;special_key=1") + "$ " + osc133("B") + "ls\r\nmore\x1b[1J"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newTerminalScreen(c.size[0], c.size[1])
			s.Write([]byte(osc133("C") + "out\r\n" + osc133("D;0") + c.output))
			want := strings.Join(dumpSemanticPrompt(s), "\n")
			for _, before := range []string{"", osc133("A;cl=w;click_events=2;aid=old") + "$ "} {
				replica := newTerminalScreen(c.size[0], c.size[1])
				replica.Write([]byte(before + "\x1b[?6l\x1b[r\x1b[0m" + terminalAllScreensClearSequence))
				replica.Write(s.RenderFrame())
				if got := strings.Join(dumpSemanticPrompt(replica), "\n"); got != want {
					t.Fatalf("painted after %q:\n%s\nwant:\n%s", before, got, want)
				}
			}
		})
	}
}

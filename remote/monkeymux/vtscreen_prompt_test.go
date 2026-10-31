package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
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
			if frame := replaySequence(s); frame != c.Frame {
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

// replaySequence is the replay that paints s on an attaching client, as
// buildWindowReplay builds it: the prefix, which ends with CSI 3 J, the main
// screen behind an alternate-screen application and the alternate screen
// entered again, then the frame.
func replaySequence(s *terminalScreen) string {
	replay := activeWindowReplayPrefix + string(s.RenderMainScreen())
	if s.altActive {
		replay += "\x1b[?1049h"
	}
	return replay + string(s.RenderFrame())
}

// replayFrame paints s's replay onto a fresh model the way an attaching client
// receives it.
func replayFrame(s *terminalScreen) *terminalScreen {
	width, height := s.Size()
	replica := newTerminalScreen(width, height)
	replica.Write([]byte(replaySequence(s)))
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
		// The frame reprints the glyph before a pending wrap to restore it,
		// for the cursor and for a saved cursor, and that glyph is prompt.
		{"prompt text before the cursor's pending wrap", [2]int{5, 3}, osc133("A;cl=line") + "ABCDE" + osc133("B")},
		{"prompt text before a saved pending wrap", [2]int{5, 4}, osc133("A;cl=line") + "ABCDE\x1b7" +
			osc133("B") + "\x1b[2;3H"},
		{"input before a saved pending wrap", [2]int{5, 4}, osc133("A;cl=line") + "$ " + osc133("B") + "abc\x1b7" +
			"\x1b[2;2H" + osc133("P;k=i")},
		// Output cells inside the prompt stay output, wherever they are.
		{"output between input", [2]int{20, 5}, osc133("A;cl=line") + "$ " + osc133("B") + "ab" +
			osc133("D") + "X" + osc133("B") + "cd"},
		{"output before a VS Code prompt", [2]int{20, 5}, "out\x1b]633;A\x07$ \x1b]633;B\x07ls"},
		{"output then prompt text", [2]int{20, 5}, osc133("A;cl=line") + "$ " + osc133("D") + "o" +
			"\x1b]633;H\x07%" + osc133("B") + "x"},
		{"output starting a wrapped row", [2]int{5, 4}, osc133("A;cl=m") + "$ " + osc133("B") + "abcd\r" +
			osc133("D") + "X" + osc133("B") + "yz"},
		{"output in the scrollback part", [2]int{6, 2}, osc133("A;cl=m") + "$ " + osc133("B") + "ab" +
			osc133("D") + "X" + osc133("B") + "cdefghijk"},
		{"output ending the scrollback part", [2]int{6, 2}, osc133("A;cl=m") + "$ " + osc133("B") + "ab" +
			osc133("D") + "XY" + osc133("B") + "cdefghijk"},
		{"output ending a scrollback line", [2]int{6, 3}, osc133("A;cl=m") + "$ " + osc133("B") + "ab" +
			osc133("D") + "XY" + osc133("B") + "c\r\n" + osc133("P;k=c") + "> " + osc133("B") + "d\r\n\r\n\r\n" +
			osc133("P;k=c") + "> " + osc133("B") + "e"},
		{"output before the cursor's pending wrap", [2]int{5, 3}, osc133("A;cl=line") + "$ " + osc133("D") +
			"xyz" + osc133("B")},
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

// A frame carries the marks and cell contents of every prompt in what it
// paints, the earlier ones too, on either screen, and the options and exit
// status in force, so a client painted from it keeps what the model keeps.
func TestRenderFrameCarriesEveryPrompt(t *testing.T) {
	shell := osc133("A;cl=line;click_events=1") + "$ " + osc133("B") + "ls\r\n" + osc133("C") + "out\r\n" +
		osc133("D;0") + osc133("A;cl=line;click_events=1") + "$ " + osc133("B") + "false\r\n" + osc133("C") +
		osc133("D;1") + osc133("A;cl=m") + "top\r\n" + osc133("P;k=s") + "> " + osc133("B") + "abcdefgh"
	cases := []struct {
		name   string
		size   [2]int
		output string
	}{
		{"running command", [2]int{20, 5}, osc133("A;cl=line") + "$ " + osc133("B") + "sleep 9\r\n" + osc133("C") + "running"},
		{"earlier prompts on the screen", [2]int{20, 9}, shell},
		{"earlier prompts in the scrollback", [2]int{6, 3}, shell},
		{"earlier prompts in the scrollback of a one-row screen", [2]int{6, 1}, shell},
		{"prompt ended by its exit status", [2]int{20, 5}, osc133("A") + "$ " + osc133("B") + "x\r\n" + osc133("C") + osc133("D;2")},
		{"alternate screen", [2]int{20, 5}, osc133("A;cl=line") + "$ " + osc133("B") + "vi\x1b[?1049h" + osc133("A;cl=m") + "> " + osc133("B") + "x"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newTerminalScreen(c.size[0], c.size[1])
			s.Write([]byte(c.output))
			want := dumpSemanticPrompt(s)
			replica := replayFrame(s)
			if got := dumpSemanticPrompt(replica); strings.Join(got, "\n") != strings.Join(want, "\n") {
				t.Fatalf("frame lost marks\n got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
			if got, want := replica.shell, s.shell; got != want {
				t.Fatalf("shell state %+v, want %+v", got, want)
			}
			if s.altActive {
				replica.Write([]byte("\x1b[?1049l"))
				s.Write([]byte("\x1b[?1049l"))
				if got, want := dumpSemanticPrompt(replica), dumpSemanticPrompt(s); strings.Join(got, "\n") != strings.Join(want, "\n") {
					t.Fatalf("main screen behind the frame lost marks\n got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
				}
			}
		})
	}
}

// A frame carries C, which the app reads as a command running and marks at
// the cursor, only where a command's output begins: on the row after its
// prompt's input, on the screen or in the scrollback, before the first output
// when the prompt is above what the frame replays, and not at all for a
// prompt whose command ended, a screen without shell integration or the
// alternate screen a running program shows.
func TestRenderFrameMarksOnlyWhatTheModelMarks(t *testing.T) {
	s := newTerminalScreen(20, 5)
	s.Write([]byte(osc133("A;cl=line") + "$ " + osc133("B") + "sleep 9\r\n" + osc133("C") + "running"))
	frame := string(s.RenderFrame())
	if !strings.Contains(frame, "\x1b[2;1H"+osc133("C")+"running") || strings.Count(frame, osc133("C")) != 1 {
		t.Fatalf("frame does not start the command on its output row: %q", frame)
	}
	if status, _ := shellStatusAfter(t, []byte(frame), "prompt", ""); status != "running" {
		t.Fatalf("after the frame the app shows %s, want running", status)
	}

	history := newTerminalScreen(20, 1)
	history.Write([]byte(osc133("A;cl=line") + "$ " + osc133("B") + "sleep 9\r\n" + osc133("C") + "line\r\nmore"))
	frame = string(history.RenderFrame())
	if !strings.Contains(frame, "\r\n"+osc133("C")+"line") || strings.Count(frame, osc133("C")) != 1 {
		t.Fatalf("frame does not start the command on its scrollback line: %q", frame)
	}

	scrolled := newTerminalScreen(20, 2)
	scrolled.Write([]byte(osc133("A;cl=line") + "$ " + osc133("B") + "yes\r\n" + osc133("C") +
		strings.Repeat("y\r\n", vtScrollbackLimit+5)))
	frame = string(scrolled.RenderFrame())
	if !strings.HasPrefix(frame[strings.Index(frame, "\x1b]133;A"):], osc133("A;cl=line")+"\x1b[2J\x1b[3J"+osc133("C")) ||
		strings.Count(frame, osc133("C")) != 1 {
		t.Fatalf("frame of a scrolled-out prompt does not start the command first: %q", frame)
	}
	if status, _ := shellStatusAfter(t, []byte(frame), "prompt", "3"); status != "running" {
		t.Fatalf("after the frame the app shows %s, want running", status)
	}

	ended := newTerminalScreen(20, 5)
	ended.Write([]byte(osc133("A") + "$ " + osc133("B") + "x\r\n" + osc133("C") + "out\r\n" + osc133("D;0") + osc133("A") + "$ "))
	frame = string(ended.RenderFrame())
	if !strings.Contains(frame, "\x1b[2;1H"+osc133("C")+"out") || strings.Count(frame, osc133("C")) != 1 {
		t.Fatalf("frame does not mark the earlier command: %q", frame)
	}
	if status, exit := shellStatusAfter(t, []byte(frame), "running", ""); status != "prompt" || exit != "0" {
		t.Fatalf("after the frame the app shows %s %q, want prompt 0", status, exit)
	}

	alt := newTerminalScreen(20, 5)
	alt.Write([]byte(osc133("A") + "$ " + osc133("B") + "vi\r\n" + osc133("C") + "\x1b[?1049hediting"))
	if frame := string(alt.RenderFrame()); strings.Contains(frame, "\x1b]133") {
		t.Fatalf("alternate screen frame carries marks: %q", frame)
	}
	if frame := string(alt.RenderMainScreen()); !strings.Contains(frame, "\x1b[2;1H"+osc133("C")) {
		t.Fatalf("main screen behind the program does not start its command: %q", frame)
	}

	plain := newTerminalScreen(20, 5)
	plain.Write([]byte("$ ls\r\nout\r\n$ "))
	if frame := string(plain.RenderFrame()); strings.Contains(frame, "\x1b]133") || strings.Contains(frame, "\x1b]633") {
		t.Fatalf("frame of a plain screen carries marks: %q", frame)
	}
}

// The model keeps the exit status of the last D, as the app does, and a frame
// ends with it where the app reads the status it ends with: a prompt keeps the
// status, input clears it.
func TestRenderFrameEndsWithTheExitStatus(t *testing.T) {
	s := newTerminalScreen(20, 5)
	s.Write([]byte(osc133("A") + "$ " + osc133("B") + "false\r\n" + osc133("C") + osc133("D;1") + osc133("A") + "$ "))
	if s.shell.exit != "1" {
		t.Fatalf("exit = %q", s.shell.exit)
	}
	status, exit := shellStatusAfter(t, s.RenderFrame(), "editing", "")
	if status != "prompt" || exit != "1" {
		t.Fatalf("after the frame the app shows %s %q, want prompt 1", status, exit)
	}
	s.Write([]byte(osc133("B") + "x"))
	if status, exit := shellStatusAfter(t, s.RenderFrame(), "prompt", "7"); status != "editing" || exit != "" {
		t.Fatalf("after the frame the app shows %s %q, want editing", status, exit)
	}
	// C clears the status, as the app does; a D without one, or with one
	// that is not a number, keeps what there is.
	s.Write([]byte("\r\n" + osc133("C") + osc133("D") + osc133("D;x") + osc133("A") + "$ "))
	if s.shell.exit != "" || s.shell.status != vtShellPrompt {
		t.Fatalf("after C and D without a status: %+v", s.shell)
	}
	s.Write([]byte("\x1b]633;D;0\x07"))
	if s.shell.exit != "0" {
		t.Fatalf("exit = %q after VS Code's D", s.shell.exit)
	}
	if status, exit := shellStatusAfter(t, s.RenderFrame(), "editing", ""); status != "prompt" || exit != "0" {
		t.Fatalf("after the frame the app shows %s %q, want prompt 0", status, exit)
	}
	s.Write([]byte(osc133("B") + "sleep\r\n" + osc133("C")))
	if s.shell != (vtShellState{status: vtShellRunning}) {
		t.Fatalf("after C: %+v", s.shell)
	}
	if status, exit := shellStatusAfter(t, s.RenderFrame(), "prompt", "4"); status != "running" || exit != "" {
		t.Fatalf("after the frame the app shows %s %q, want running", status, exit)
	}
}

// shellStatusAfter reads frame as applyTerminalShellIntegrationOsc in the
// app does, from status and exit: A and D show the prompt, D with a number
// sets the exit status, B and I show the command being edited and clear it,
// C a command running.
func shellStatusAfter(t *testing.T, frame []byte, status, exit string) (string, string) {
	t.Helper()
	for _, part := range strings.Split(string(frame), "\x1b]")[1:] {
		payload, _, ok := strings.Cut(part, "\x07")
		if !ok || !isSemanticPromptOSC([]byte(payload)) {
			continue
		}
		args := strings.Split(payload[4:], ";")
		switch args[0] {
		case "A":
			status = "prompt"
		case "B", "I":
			status, exit = "editing", ""
		case "C":
			status, exit = "running", ""
		case "D":
			status = "prompt"
			if len(args) > 1 {
				if _, err := strconv.Atoi(args[1]); err == nil {
					exit = args[1]
				}
			}
		}
	}
	return status, exit
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
// force, whatever prompt the client showed before.
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

// A command whose C arrived on its input row, with no newline before it,
// starts there: at the first output cell after the input on that row, or at
// the cursor when nothing follows, and never with a D after its C, so the
// app reads a program started that way as running rather than at a prompt.
func TestRenderFrameStartsACommandOnItsInputRow(t *testing.T) {
	cases := []struct {
		name, output, want string
	}{
		{"output on the input row", osc133("A") + "$ " + osc133("B") + "vi" + osc133("C") + "out", "vi" + osc133("C") + "out"},
		{"nothing after the input", osc133("A") + "$ " + osc133("B") + "vi" + osc133("C"), "\x1b[1;5H" + osc133("C")},
		{"alternate screen program", osc133("A") + "$ " + osc133("B") + "vi" + osc133("C") + "\x1b[?1049hTUI", "\x1b[1;5H" + osc133("C")},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newTerminalScreen(20, 5)
			s.Write([]byte(c.output))
			replay := replaySequence(s)
			if status, _ := shellStatusAfter(t, []byte(replay), "prompt", "0"); status != "running" {
				t.Fatalf("after the replay the app shows %s, want running: %q", status, replay)
			}
			if !strings.Contains(replay, c.want) || strings.Count(replay, osc133("C")) != 1 {
				t.Fatalf("the command does not start on its input row: %q", replay)
			}
			want := dumpSemanticPrompt(s)
			if got := dumpSemanticPrompt(replayFrame(s)); strings.Join(got, "\n") != strings.Join(want, "\n") {
				t.Fatalf("frame lost marks\n got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
		})
	}
}

// Earlier commands' Cs do not count for the running command: it gets its own
// C after its input however many commands the replay shows before it, on the
// screen and in the scrollback.
func TestRenderFrameStartsTheRunningCommandAfterEarlierOnes(t *testing.T) {
	earlier := ""
	for i := range 4 {
		earlier += osc133("A;cl=line") + "$ " + osc133("B") + "echo x\r\n" + osc133("C") + "x\r\n" + osc133("D;"+string(rune('0'+i)))
	}
	cases := []struct {
		name, output, want string
		height             int
	}{
		{"program on its input row", earlier + osc133("A;cl=line") + "$ " + osc133("B") + "vi" + osc133("C") + "\x1b[?1049hTUI",
			"\x1b[6;5H" + osc133("C"), 6},
		{"program on its input row, earlier commands in the scrollback", earlier + osc133("A;cl=line") + "$ " + osc133("B") + "vi" + osc133("C") + "\x1b[?1049hTUI",
			"\x1b[3;5H" + osc133("C"), 3},
		{"output on the input row", earlier + osc133("A;cl=line") + "$ " + osc133("B") + "cat" + osc133("C") + "out",
			"cat" + osc133("C") + "out", 4},
		{"prompt above the replay", earlier + osc133("A;cl=line") + "$ " + osc133("B") + "yes\r\n" + osc133("C") + strings.Repeat("y\r\n", vtScrollbackLimit+5),
			"\x1b[2J\x1b[3J" + osc133("C"), 3},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newTerminalScreen(20, c.height)
			s.Write([]byte(c.output))
			replay := replaySequence(s)
			if status, exit := shellStatusAfter(t, []byte(replay), "prompt", "9"); status != "running" || exit != "" {
				t.Fatalf("after the replay the app shows %s %q, want running: %q", status, exit, replay)
			}
			if !strings.Contains(replay, c.want) {
				t.Fatalf("the running command does not start after its input: %q", replay)
			}
			if got, want := dumpSemanticPrompt(replayFrame(s)), dumpSemanticPrompt(s); strings.Join(got, "\n") != strings.Join(want, "\n") {
				t.Fatalf("frame lost marks\n got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
		})
	}
}

// A running command whose cursor a program moved back onto its input row,
// deferring a wrap: C again on that row would add a command mark there, so
// the glyph the cursor waits after is printed again as output, the one cell
// the client classifies apart from the model.
func TestRenderFrameKeepsTheCommandMarkWithTheCursorOnItsInput(t *testing.T) {
	s := newTerminalScreen(10, 5)
	s.Write([]byte(osc133("A") + "$ " + osc133("B") + "abcdefgh\x1b7\r\n" + osc133("C") + "out\x1b8"))
	replay := replaySequence(s)
	if status, _ := shellStatusAfter(t, []byte(replay), "prompt", "0"); status != "running" {
		t.Fatalf("after the replay the app shows %s, want running: %q", status, replay)
	}
	if strings.Count(replay, osc133("C")) != strings.Count(replay, "\x1b[2;1H"+osc133("C")) {
		t.Fatalf("a C lands off the command's row: %q", replay)
	}
	want := dumpSemanticPrompt(s)
	want[0] = strings.TrimSuffix(want[0], "i") + "o"
	if got := dumpSemanticPrompt(replayFrame(s)); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("frame lost marks\n got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

// However the frame paints the running command's screen, the app ends at
// running: when the command's output overwrote its whole prompt row, which
// keeps the row's mark, and when a glyph printed again as input restores a
// saved cursor's deferred wrap after the command's C, which then comes again
// where it was (at mark), so the app adds no command mark on another row.
func TestRenderFrameKeepsTheCommandRunning(t *testing.T) {
	cases := []struct {
		name, output, mark string
	}{
		{"output over its prompt row", osc133("A") + "$ " + osc133("B") + "app" + osc133("C") + "\rloading...", ""},
		{"saved cursor deferring a wrap on input", osc133("A") + "$ " + osc133("B") + "abcdefgh\x1b7\r\n" + osc133("C") + "out",
			"\x1b[2;1H"},
		{"saved cursor deferring a wrap on input, cursor rows below", osc133("A") + "$ " + osc133("B") + "abcdefgh\x1b7\r\n" +
			osc133("C") + "out\r\nmore", "\x1b[2;1H"},
		// The C goes after the input, not at the cursor: in column 0 it
		// would end the row's mark.
		{"program homing the cursor onto its prompt row", osc133("A;cl=line") + "$ " + osc133("B") + "cmd" + osc133("C") +
			"\r\n\x1b[H", "\x1b[1;6H"},
		{"program erasing its prompt from home", osc133("A;cl=line") + "$ " + osc133("B") + "cmd" + osc133("C") +
			"\r\n\x1b[H\x1b[J", "\x1b[1;2H"},
		// A glyph printed again as prompt text changes no status, but D
		// would end the prompt content.
		{"saved cursor deferring a wrap on prompt text", osc133("A") + "1234567890\x1b7" + osc133("B") + "cmd\r\n" +
			osc133("C") + "out", "\x1b[3;1H"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newTerminalScreen(10, 5)
			s.Write([]byte(c.output))
			replay := replaySequence(s)
			if status, _ := shellStatusAfter(t, []byte(replay), "prompt", "0"); status != "running" {
				t.Fatalf("after the replay the app shows %s, want running: %q", status, replay)
			}
			if c.mark != "" && strings.Count(replay, osc133("C")) != strings.Count(replay, c.mark+osc133("C")) {
				t.Fatalf("a C lands off the command's row: %q", replay)
			}
			if got, want := dumpSemanticPrompt(replayFrame(s)), dumpSemanticPrompt(s); strings.Join(got, "\n") != strings.Join(want, "\n") {
				t.Fatalf("frame lost marks\n got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
		})
	}
}

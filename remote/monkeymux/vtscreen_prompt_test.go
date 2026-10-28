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
}

// dumpSemanticPrompt is dumpSemanticPrompt in
// third_party/xterm/test/src/core/semantic_prompt_parity_test.dart.
func dumpSemanticPrompt(s *terminalScreen) []string {
	var out []string
	row := func(cells []vtCell, wrapped bool, prompt uint8, withContent bool) string {
		mark := map[uint8]string{vtPromptNone: "-", vtPromptPrimary: "P", vtPromptContinuation: "C"}[prompt]
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
		if !withContent {
			return mark + wrap + "|" + text.String()
		}
		return mark + wrap + "|" + text.String() + "|" + content.String()
	}
	if !s.altActive {
		var decoder vtLineDecoder
		for i := range s.scrollback.len() {
			line := s.scrollback.at(i)
			out = append(out, row(decoder.decode(line.text, s.width), line.wrapped, line.prompt, false))
		}
	}
	g := s.grid()
	for r, cells := range g.rows {
		out = append(out, row(cells, g.wrapped[r], g.prompt[r], true))
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

func runSemanticParityCase(c semanticParityCase) *terminalScreen {
	s := newTerminalScreen(c.Size[0], c.Size[1])
	for _, step := range c.Steps {
		if step.Write != "" {
			s.Write([]byte(step.Write))
		}
		if step.Resize != nil {
			s.Resize(step.Resize[0], step.Resize[1])
		}
	}
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

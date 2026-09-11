package main

import (
	"bytes"
	"errors"
	"testing"
	"time"
)

func TestEncodeTerminalResponsesForWin32InputMode(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  string
	}{
		{name: "plain text passes through", input: "hello\r", want: "hello\r"},
		{
			name:  "csi passes through",
			input: "\x1b[I\x1b[?997;2n",
			want:  "\x1b[I\x1b[?997;2n",
		},
		{
			name:  "osc with bel is encoded",
			input: "\x1b]11;?\x07",
			want: "\x1b[0;0;27;1;0;1_\x1b[0;0;93;1;0;1_\x1b[0;0;49;1;0;1_" +
				"\x1b[0;0;49;1;0;1_\x1b[0;0;59;1;0;1_\x1b[0;0;63;1;0;1_" +
				"\x1b[0;0;7;1;0;1_",
		},
		{
			name:  "osc with st is encoded",
			input: "\x1b]11;?\x1b\\",
			want: "\x1b[0;0;27;1;0;1_\x1b[0;0;93;1;0;1_\x1b[0;0;49;1;0;1_" +
				"\x1b[0;0;49;1;0;1_\x1b[0;0;59;1;0;1_\x1b[0;0;63;1;0;1_" +
				"\x1b[0;0;27;1;0;1_\x1b[0;0;92;1;0;1_",
		},
		{
			name:  "dcs is encoded",
			input: "\x1bP>|mux\x1b\\",
			want: "\x1b[0;0;27;1;0;1_\x1b[0;0;80;1;0;1_\x1b[0;0;62;1;0;1_" +
				"\x1b[0;0;124;1;0;1_\x1b[0;0;109;1;0;1_\x1b[0;0;117;1;0;1_" +
				"\x1b[0;0;120;1;0;1_\x1b[0;0;27;1;0;1_\x1b[0;0;92;1;0;1_",
		},
		{
			name:  "mixed output only encodes the osc portion",
			input: "a\x1b]10;rgb:aaaa/bbbb/cccc\x07\x1b[Ib",
			want: "a" + win32EncodeSequence("\x1b]10;rgb:aaaa/bbbb/cccc\x07") +
				"\x1b[Ib",
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			got := string(encodeTerminalResponsesForWin32InputMode(
				[]byte(testCase.input),
			))
			if got != testCase.want {
				t.Fatalf(
					"encodeTerminalResponsesForWin32InputMode(%q) = %q, want %q",
					testCase.input,
					got,
					testCase.want,
				)
			}
		})
	}
}

func win32EncodeSequence(sequence string) string {
	var buffer bytes.Buffer
	writeWin32InputModeKeyEvents(&buffer, []byte(sequence))
	return buffer.String()
}

func TestEncodeTerminalInputForWin32InputMode(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "bare escape becomes a key event",
			input: "\x1b",
			want:  "\x1b[27;1;27;1;0;1_\x1b[27;1;27;0;0;1_",
		},
		{name: "empty input passes through", input: "", want: ""},
		{name: "cursor key passes through", input: "\x1b[A", want: "\x1b[A"},
		{
			name:  "modified cursor key passes through",
			input: "\x1b[1;5C",
			want:  "\x1b[1;5C",
		},
		{name: "alt chord passes through", input: "\x1bb", want: "\x1bb"},
		{name: "double escape passes through", input: "\x1b\x1b", want: "\x1b\x1b"},
		{name: "ctrl-c passes through", input: "\x03", want: "\x03"},
		{name: "plain text passes through", input: "esc", want: "esc"},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			got := string(encodeTerminalInputForWin32InputMode(
				[]byte(testCase.input),
			))
			if got != testCase.want {
				t.Fatalf(
					"encodeTerminalInputForWin32InputMode(%q) = %q, want %q",
					testCase.input,
					got,
					testCase.want,
				)
			}
		})
	}
}

func TestEncodeBracketedPasteInputForWin32InputMode(t *testing.T) {
	input := "\x1b[200~hello\x1b[?62;4c\x1b[201~"
	want := win32InputModeEscapeCharacterEvent + "[200~hello" +
		win32InputModeEscapeCharacterEvent + "[?62;4c" +
		win32InputModeEscapeCharacterEvent + "[201~"
	got := string(encodeBracketedPasteInputForWin32InputMode([]byte(input)))
	if got != want {
		t.Fatalf(
			"encodeBracketedPasteInputForWin32InputMode(%q) = %q, want %q",
			input,
			got,
			want,
		)
	}
}

func TestStripWin32InputModeRequests(t *testing.T) {
	cases := []struct {
		name      string
		prev      string
		data      string
		wantOut   string
		wantCarry string
	}{
		{
			name:    "strips enable request",
			data:    "\x1b[?9001h",
			wantOut: "",
		},
		{
			name:    "strips disable request",
			data:    "\x1b[?9001l",
			wantOut: "",
		},
		{
			name:    "keeps other private modes",
			data:    "\x1b[?9001h\x1b[?1004h\x1b[?25l",
			wantOut: "\x1b[?1004h\x1b[?25l",
		},
		{
			name:    "leaves cursor key untouched",
			data:    "\x1b[Aecho\r",
			wantOut: "\x1b[Aecho\r",
		},
		{
			name:    "leaves title osc untouched",
			data:    "\x1b]0;title\x07",
			wantOut: "\x1b]0;title\x07",
		},
		{
			name:    "strips request between output",
			data:    "before\x1b[?9001hafter",
			wantOut: "beforeafter",
		},
		{
			name:      "buffers split request prefix",
			data:      "text\x1b[?90",
			wantOut:   "text",
			wantCarry: "\x1b[?90",
		},
		{
			name:    "completes split request from carry",
			prev:    "\x1b[?90",
			data:    "01h\x1b[A",
			wantOut: "\x1b[A",
		},
		{
			name:    "flushes non-request escape prefix",
			prev:    "\x1b[?90",
			data:    "0m done",
			wantOut: "\x1b[?900m done",
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			out, carry := stripWin32InputModeRequests(
				[]byte(testCase.prev),
				[]byte(testCase.data),
			)
			if string(out) != testCase.wantOut {
				t.Fatalf("out = %q, want %q", out, testCase.wantOut)
			}
			if string(carry) != testCase.wantCarry {
				t.Fatalf("carry = %q, want %q", carry, testCase.wantCarry)
			}
		})
	}
}

func TestWin32InputModeRequestStripperWriteHandlesSplitAcrossWrites(t *testing.T) {
	var sink bytes.Buffer
	stripper := newWin32InputModeRequestStripper(&sink)
	// A win32-input-mode request split across two writes must still be removed
	// so the ConPTY hosting the attach process never sees it.
	if _, err := stripper.Write([]byte("prompt\x1b[?90")); err != nil {
		t.Fatalf("first write: %v", err)
	}
	if _, err := stripper.Write([]byte("01h\x1b[A")); err != nil {
		t.Fatalf("second write: %v", err)
	}
	if got := sink.String(); got != "prompt\x1b[A" {
		t.Fatalf("stripped output = %q, want %q", got, "prompt\x1b[A")
	}
}

func TestWin32InputModeRequestStripperFlushEmitsUnterminatedCarry(t *testing.T) {
	var sink bytes.Buffer
	stripper := newWin32InputModeRequestStripper(&sink)
	// A chunk ending on a partial request prefix is buffered, not emitted...
	if _, err := stripper.Write([]byte("tail\x1b[?90")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if got := sink.String(); got != "tail" {
		t.Fatalf("pre-flush output = %q, want %q", got, "tail")
	}
	// ...but if the stream ends there, Flush must not drop those bytes.
	if err := stripper.Flush(); err != nil {
		t.Fatalf("flush: %v", err)
	}
	if got := sink.String(); got != "tail\x1b[?90" {
		t.Fatalf("post-flush output = %q, want %q", got, "tail\x1b[?90")
	}
	// Flush is idempotent once the carry is drained.
	if err := stripper.Flush(); err != nil {
		t.Fatalf("second flush: %v", err)
	}
	if got := sink.String(); got != "tail\x1b[?90" {
		t.Fatalf("double-flush output = %q, want unchanged %q", got, "tail\x1b[?90")
	}
}

func TestSplitBracketedPasteActionsStayClassified(t *testing.T) {
	client := &attachClient{}

	first := client.routeInput([]byte("abc\x1b[20"))
	if len(first.actions) != 1 ||
		!first.actions[0].userInput ||
		!bytes.Equal(first.actions[0].data, []byte("abc")) ||
		first.actions[0].bracketedPaste {
		t.Fatalf("partial paste start routing = %#v", first)
	}

	second := client.routeInput([]byte("0~hello\x1b[201~"))
	want := []byte("\x1b[200~hello\x1b[201~")
	if len(second.actions) != 1 ||
		!second.actions[0].userInput ||
		!second.actions[0].bracketedPaste ||
		!bytes.Equal(second.actions[0].data, want) {
		t.Fatalf("completed paste routing = %#v, want %q", second, want)
	}
}

func TestEscapeImmediatelyBeforePastePreservesActionOrder(t *testing.T) {
	client := &attachClient{}
	input := []byte("\x1b\x1b[200~hello\x1b[201~x")

	routing := client.routeInput(input)
	if len(routing.actions) != 3 ||
		!routing.actions[0].userInput ||
		!routing.actions[1].userInput ||
		!routing.actions[2].userInput ||
		routing.actions[0].bracketedPaste ||
		!bytes.Equal(routing.actions[0].data, []byte{0x1b}) ||
		!routing.actions[1].bracketedPaste ||
		!bytes.Equal(
			routing.actions[1].data,
			[]byte("\x1b[200~hello\x1b[201~"),
		) ||
		routing.actions[2].bracketedPaste ||
		!bytes.Equal(routing.actions[2].data, []byte("x")) {
		t.Fatalf("escape + paste routing = %#v", routing)
	}
}

func TestAmbiguousPasteStartFlushesAsOrdinaryInput(t *testing.T) {
	passthrough := make(chan []byte, 1)
	claims := make(chan uint64, 1)
	client := &attachClient{
		inputPassthrough: func(data []byte) {
			passthrough <- append([]byte(nil), data...)
		},
		focusSequenceSnapshot: func() uint64 {
			return 42
		},
		focusClaim: func(sequence uint64) {
			claims <- sequence
		},
	}

	routing := client.routeInput([]byte{0x1b})
	if len(routing.actions) != 0 {
		t.Fatalf("ambiguous escape routing = %#v", routing)
	}
	select {
	case data := <-passthrough:
		if !bytes.Equal(data, []byte{0x1b}) {
			t.Fatalf("flushed input = %q, want ESC", data)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for ambiguous ESC flush")
	}
	select {
	case sequence := <-claims:
		if sequence != 42 {
			t.Fatalf("focus sequence = %d, want 42", sequence)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for focus claim")
	}
}

func TestLateSplitPasteStartAfterTimeoutStaysOrdinary(t *testing.T) {
	flushed := make(chan []byte, 1)
	client := &attachClient{
		inputPassthrough: func(data []byte) {
			flushed <- append([]byte(nil), data...)
		},
	}

	if routing := client.routeInput([]byte{0x1b}); len(routing.actions) != 0 {
		t.Fatalf("ambiguous escape routing = %#v", routing)
	}
	select {
	case data := <-flushed:
		if !bytes.Equal(data, []byte{0x1b}) {
			t.Fatalf("flushed prefix = %q, want ESC", data)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for paste prefix flush")
	}

	routing := client.routeInput([]byte("[200~hello\x1b[201~"))
	if len(routing.actions) != 1 ||
		routing.actions[0].bracketedPaste ||
		!bytes.Equal(
			routing.actions[0].data,
			[]byte("[200~hello\x1b[201~"),
		) {
		t.Fatalf("late split ordinary routing = %#v", routing)
	}
}

func TestInjectInputControlPreservesBracketedPaste(t *testing.T) {
	const paste = "\x1b[200~/tmp/image.png\x1b[201~ "
	for _, test := range []struct {
		name  string
		win32 bool
		want  string
	}{
		{"raw", false, paste},
		{"win32", true, string(encodeBracketedPasteInputForWin32InputMode([]byte(paste)))},
	} {
		t.Run(test.name, func(t *testing.T) {
			pty := &recordingPty{}
			window := &muxWindow{id: "@1", pty: pty, win32InputMode: test.win32}
			server := newMuxServer("test")
			server.windows = []*muxWindow{window}
			server.activeID = window.id
			server.handleControlRequest(&controlClient{}, controlMessage{
				Type: "inject_input", WindowID: window.id, Data: paste, BracketedPaste: true,
			})
			if got := pty.String(); got != test.want {
				t.Fatalf("injected PTY input = %q, want %q", got, test.want)
			}
		})
	}
}

func TestWriteWindowBareEscape(t *testing.T) {
	for _, test := range []struct {
		name  string
		win32 bool
		want  string
	}{
		{"raw", false, "\x1b"},
		{"win32", true, "\x1b[27;1;27;1;0;1_\x1b[27;1;27;0;0;1_"},
	} {
		t.Run(test.name, func(t *testing.T) {
			pty := &recordingPty{}
			window := &muxWindow{id: "@1", pty: pty, win32InputMode: test.win32}
			server := newMuxServer("test")
			server.windows = []*muxWindow{window}
			server.activeID = window.id
			if err := server.writeWindow(window.id, []byte("\x1b")); err != nil {
				t.Fatal(err)
			}
			if got := pty.String(); got != test.want {
				t.Fatalf("PTY input = %q, want %q", got, test.want)
			}
		})
	}
}

type consoleModeRecordingPty struct {
	recordingPty
	vtInput bool
	modeErr error
	probes  int
}

func (p *consoleModeRecordingPty) virtualTerminalInputEnabled() (bool, error) {
	p.probes++
	return p.vtInput, p.modeErr
}

func TestConsoleInputModeChangesAndProbeFailure(t *testing.T) {
	pty := &consoleModeRecordingPty{}
	window := &muxWindow{id: "@1", pty: pty, win32InputMode: true}
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	const reply = "\x1b]11;rgb:0000/0000/0000\x07"
	for _, state := range []struct {
		vt  bool
		err error
	}{
		{false, nil}, {true, nil}, {false, nil}, {false, errors.New("probe failed")},
	} {
		pty.vtInput, pty.modeErr = state.vt, state.err
		if err := server.writeWindow(window.id, []byte(reply)); err != nil {
			t.Fatal(err)
		}
	}
	want := win32EncodeSequence(reply) + win32EncodeSequence(reply)
	if pty.String() != want || pty.probes != 4 {
		t.Fatalf("input %q, probes %d; want %q and 4", pty.String(), pty.probes, want)
	}
	for _, key := range []string{"x", "\r", "\x1b", "\x1b[A"} {
		if err := server.writeWindow(window.id, []byte(key)); err != nil {
			t.Fatal(err)
		}
	}
	if pty.probes != 4 {
		t.Fatal("ordinary keys must not launch console probes")
	}
}
func TestConsoleReaderInputPolicy(t *testing.T) {
	const reply = "\x1b]11;rgb:0d0d/1a1a/2020\x1b\\"
	const paste = "\x1b[200~hello\x1b[201~"
	for _, test := range []struct {
		name, reader, input, want string
		win32, paste              bool
	}{
		{"native paste", "native", paste, string((&nativeConsolePasteFilter{}).encode([]byte(paste))), true, true},
		{"split paste escape", "native", "\x1b", "", true, true},
		{"native reply", "native", reply, "", true, false},
		{"native DCS reply", "native", "\x1bP>|MonkeySSH\x1b\\", "", true, false},
		{"mixed text and replies", "native", "a" + reply + "b", "ab", true, false},
		{"pasted reply is user content", "native", "\x1b[200~" + reply + "\x1b[201~", string((&nativeConsolePasteFilter{}).encode([]byte(reply))), true, true},
		{"native Escape", "native", "\x1b", win32InputModeEscapeKeyEvents, true, false},
		{"native arrow", "native", "\x1b[A", "\x1b[A", true, false},
		{"native Return", "native", "\r", "\r", true, false},
		{"Unix reply", "native", reply, reply, false, false},
		{"Unix paste", "native", paste, paste, false, true},
		{"Windows VT reader reply", "vt", reply, win32EncodeSequence(reply), true, false},
		{"Windows VT reader paste", "vt", paste, string(encodeBracketedPasteInputForWin32InputMode([]byte(paste))), true, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			pty := &consoleModeRecordingPty{vtInput: test.reader == "vt"}
			window := &muxWindow{id: "@1", pty: pty, win32InputMode: test.win32}
			server := newMuxServer("test")
			server.windows = []*muxWindow{window}
			var err error
			if test.paste {
				err = server.writeWindowInput(window.id, []byte(test.input), true)
			} else {
				err = server.writeWindow(window.id, []byte(test.input))
			}
			if err != nil {
				t.Fatal(err)
			}
			if got := pty.String(); got != test.want {
				t.Fatalf("PTY input = %q, want %q", got, test.want)
			}
		})
	}
}

func TestNativeConsolePasteFilterAcrossEverySplit(t *testing.T) {
	for _, test := range []struct{ name, input, want string }{
		{"plain", "\x1b[200~hello\x1b[201~ ", "hello "},
		{"unicode", "\x1b[200~héllo 🐒\x1b[201~", "héllo 🐒"},
		{"8-bit framing", "\x9b200~hello\x9b201~", "hello"},
		{"unicode continuation is not framing", "\x1b[200~\xc2\x9b201~text\x1b[201~", "\xc2\x9b201~text"},
		{"multiple pastes", "\x1b[200~one\x1b[201~\x1b[200~two\x1b[201~", "onetwo"},
		{"nested start is content", "\x1b[200~\x1b[200~hello\x1b[201~", "\x1b[200~hello"},
		{"control payload", "\x1b[200~a\r\nb\x1b]11;rgb:0000/0000/0000\x07\x1b[201~", "a\r\nb\x1b]11;rgb:0000/0000/0000\x07"},
	} {
		t.Run(test.name, func(t *testing.T) {
			for split := 0; split <= len(test.input); split++ {
				filter := &nativeConsolePasteFilter{}
				got := append(filter.filter([]byte(test.input[:split])), filter.filter([]byte(test.input[split:]))...)
				if string(got) != test.want || len(filter.carry) != 0 || filter.inPaste {
					t.Fatalf("split %d: output %q, carry %q, inPaste %v; want %q", split, got, filter.carry, filter.inPaste, test.want)
				}
			}
			filter := &nativeConsolePasteFilter{}
			var got []byte
			for _, value := range []byte(test.input) {
				got = append(got, filter.filter([]byte{value})...)
			}
			if string(got) != test.want || len(filter.carry) != 0 || filter.inPaste {
				t.Fatalf("byte-by-byte output %q, carry %q, inPaste %v; want %q", got, filter.carry, filter.inPaste, test.want)
			}
		})
	}
}

func TestNativePasteCharacterEventsPreserveRepeatsAndSplitUnicode(t *testing.T) {
	const input = "\x1b[200~aa🐒\r\n\t\x1b[201~"
	const up = "\x1b[0;0;0;0;0;1_"
	const want = "\x1b[0;0;97;1;0;1_" + up + "\x1b[0;0;97;1;0;1_" + up +
		"\x1b[0;0;55357;1;0;1_" + up + "\x1b[0;0;56338;1;0;1_" + up +
		"\x1b[13;0;13;1;0;1_\x1b[13;0;0;0;0;1_" +
		"\x1b[9;0;9;1;0;1_\x1b[9;0;0;0;0;1_"
	for split := 0; split <= len(input); split++ {
		encoder := &nativeConsolePasteFilter{}
		got := append(encoder.encode([]byte(input[:split])), encoder.encode([]byte(input[split:]))...)
		if string(got) != want {
			t.Fatalf("split %d: events %q, want %q", split, got, want)
		}
	}
	encoder := &nativeConsolePasteFilter{}
	var got []byte
	for _, value := range []byte(input) {
		got = append(got, encoder.encode([]byte{value})...)
	}
	if string(got) != want {
		t.Fatalf("byte-by-byte events %q, want %q", got, want)
	}
}

func TestNativePasteChunksUseOneModeQuery(t *testing.T) {
	pty := &consoleModeRecordingPty{}
	window := &muxWindow{id: "@1", pty: pty, win32InputMode: true}
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	const paste = "\x1b[200~hello\x1b[201~"
	for _, value := range []byte(paste) {
		if err := server.writeWindowInput(window.id, []byte{value}, true); err != nil {
			t.Fatal(err)
		}
		// A transient query failure must not change an in-flight paste's mode.
		pty.modeErr = errors.New("probe unavailable")
	}
	if pty.probes != 1 {
		t.Fatalf("split paste used %d mode queries, want 1", pty.probes)
	}
	if want := string((&nativeConsolePasteFilter{}).encode([]byte(paste))); pty.String() != want {
		t.Fatalf("split paste input %q, want %q", pty.String(), want)
	}
}

func TestNativeConsoleRoutedResponseForms(t *testing.T) {
	for _, reply := range []string{
		"\x1b]11;rgb:ff/ff/ff\a", "\x1b]11;rgb:ff/ff/ff\x9c",
		"\x9d11;rgb:ff/ff/ff\x1b\\", "\x9d11;rgb:ff/ff/ff\x9c",
		"\x1bP!|00000000\x9c", "\x90!|00000000\x1b\\", "\x90!|00000000\x9c",
	} {
		for split := 0; split <= len(reply); split++ {
			pty := &consoleModeRecordingPty{}
			window := &muxWindow{id: "@1", pty: pty, win32InputMode: true}
			server := newMuxServer("test")
			server.windows = []*muxWindow{window}
			client := &attachClient{}
			client.expectTerminalResponses(window.id, 1)
			responses := 0
			for _, fragment := range []string{reply[:split], reply[split:]} {
				for _, action := range client.routeInput([]byte(fragment)).actions {
					if action.userInput {
						t.Fatalf("reply %q split %d routed as input", reply, split)
					}
					responses++
					if err := server.writeWindow(action.windowID, action.data); err != nil {
						t.Fatal(err)
					}
				}
			}
			if responses == 0 || pty.String() != "" || pty.probes != 1 {
				t.Fatalf("reply %q split %d: responses %d, input %q, probes %d", reply, split, responses, pty.String(), pty.probes)
			}
		}
	}
}

func TestNativeConsoleStreamingResponsePreservesUserInput(t *testing.T) {
	for _, framing := range [][2]string{{"\x1b]52;c;", "\x1b\\"}, {"\x9d52;c;", "\x9c"}, {"\x90!|", "\x1b\\"}} {
		pty := &consoleModeRecordingPty{}
		window := &muxWindow{id: "@1", pty: pty, win32InputMode: true}
		server := newMuxServer("test")
		server.windows = []*muxWindow{window}
		client := &attachClient{}
		client.expectTerminalResponses(window.id, 1)
		route := func(data []byte) {
			for _, action := range client.routeInput(data).actions {
				var err error
				if action.userInput {
					err = server.writeWindowInput(window.id, action.data, action.bracketedPaste)
				} else {
					err = server.writeWindow(action.windowID, action.data)
				}
				if err != nil {
					t.Fatal(err)
				}
			}
		}
		route(append([]byte(framing[0]), bytes.Repeat([]byte("A"), terminalResponseCarryLimitBytes+1)...))
		if window.nativeResponse.kind == 0 || pty.String() != "" {
			t.Fatal("streamed prefix was not suppressed")
		}
		if err := server.writeWindowInput(window.id, []byte("key"), false); err != nil {
			t.Fatal(err)
		}
		route([]byte("\x1b[200~paste\x1b[201~"))
		pty.modeErr = errors.New("probe unavailable during response")
		// UTF-8 continuation bytes resembling ST must not end suppression.
		for _, fragment := range []string{"tail\xc2", "\x9cmore", framing[1][:1], framing[1][1:]} {
			route([]byte(fragment))
		}
		route([]byte("after"))
		want := "key" + string((&nativeConsolePasteFilter{}).encode([]byte("paste"))) + "after"
		if pty.String() != want || window.nativeResponse.kind != 0 || pty.probes != 2 {
			t.Fatalf("input %q, state %#v, probes %d; want %q and 2 probes", pty.String(), window.nativeResponse, pty.probes, want)
		}
	}
}

func TestNativeResponseFilterPreservesSplitUTF8(t *testing.T) {
	const text = "\xc2\x9dtext\xc2\x90text\xc2\x9c"
	for split := 0; split <= len(text); split++ {
		pty := &consoleModeRecordingPty{}
		window := &muxWindow{id: "@1", pty: pty, win32InputMode: true}
		server := newMuxServer("test")
		server.windows = []*muxWindow{window}
		for _, part := range []string{text[:split], text[split:]} {
			if err := server.writeWindow(window.id, []byte(part)); err != nil {
				t.Fatal(err)
			}
		}
		if pty.String() != text || pty.probes != 0 {
			t.Fatalf("split %d: input %q, probes %d", split, pty.String(), pty.probes)
		}
	}
}

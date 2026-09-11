package main

import (
	"bufio"
	"io"
	"strings"
	"testing"
	"time"
)

// xtversionQuery is XTVERSION (CSI > q); da1Query is primary device attributes
// (CSI c). Agents such as Copilot CLI emit these at startup and gate richer
// rendering on the terminal's answers.
const (
	xtversionQuery = "\x1b[>q"
	da1Query       = "\x1b[c"
)

// capabilityHintFixture is the wire-format hint MonkeySSH sends on attach: the
// static replies its terminal gives for XTVERSION and the device attribute /
// status queries agents emit at startup.
const capabilityHintFixture = "da1\x1f\x1b[?62;22c" +
	"\x1e" + "da2\x1f\x1b[>1;0;0c" +
	"\x1e" + "da3\x1f\x1bP!|00000000\x1b\\" +
	"\x1e" + "xtversion\x1f\x1bP>|kitty(0.32.0)\x1b\\" +
	"\x1e" + "dsr\x1f\x1b[0n"

// Keep the terminal attached until queued writes have been observed. An empty
// reader disconnects immediately and races the asynchronous query flush.
func startCapabilityTestAttach(t *testing.T, server *muxServer, hello controlMessage) (*recordingConn, func()) {
	t.Helper()
	input, writer := io.Pipe()
	attach := &recordingConn{}
	done := make(chan struct{})
	go func() {
		defer close(done)
		server.handleAttach(attach, bufio.NewReader(input), hello)
	}()
	return attach, func() {
		_ = writer.Close()
		defer input.Close()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("attach handler did not stop after disconnect")
		}
	}
}

func TestXtversionClassifiedAsReplayUnsafeQuery(t *testing.T) {
	cases := []struct {
		name     string
		sequence string
		want     bool
	}{
		{"xtversion", xtversionQuery, true},
		{"da1", da1Query, true},
		{"da2", "\x1b[>0c", true},
		{"c1 da1", string([]byte{0x9b, 'c'}), true},
		{"dsr cursor position", "\x1b[6n", true},
		{"decscusr cursor style is not a query", "\x1b[2 q", false},
		{"sgr is not a query", "\x1b[0m", false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isReplayUnsafeCsiQuery([]byte(tc.sequence)); got != tc.want {
				t.Fatalf("isReplayUnsafeCsiQuery(%q) = %v, want %v", tc.sequence, got, tc.want)
			}
		})
	}
}

func TestC1CapabilityQueryBufferedWhileDetached(t *testing.T) {
	window := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	query := []byte{0x9b, 'c'}

	window.appendPendingTerminalQueriesLocked(query, nil, nil)

	if got := string(window.pendingTerminalQueries); got != string(query) {
		t.Fatalf("pending C1 query = %q, want %q", got, query)
	}
}

// TestPendingCapabilityQueriesDeliveredOnAttach reproduces the upgrade-restore
// race: an agent window is relaunched and emits its startup capability queries
// while no client is attached. Foreground-redraw windows do not replay history,
// so the queries must be re-delivered to the terminal when it attaches.
func TestPendingCapabilityQueriesDeliveredOnAttach(t *testing.T) {
	server := newMuxServer("cap-attach")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	// Detached: the relaunched agent queries the terminal before the client
	// reattaches, so attachConn is still nil.
	server.handleWindowOutput("@1", []byte(xtversionQuery+da1Query))

	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != xtversionQuery+da1Query {
		t.Fatalf("pending queries = %q, want XTVERSION+DA1 buffered while detached", pending)
	}

	restore := stubForegroundResize(t)
	defer restore()

	attach, detach := startCapabilityTestAttach(t, server, controlMessage{Width: 80, Height: 24})
	defer detach()

	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		got := attach.String()
		if strings.Contains(got, xtversionQuery) && strings.Contains(got, da1Query) {
			break
		}
		time.Sleep(time.Millisecond)
	}
	got := attach.String()
	if !strings.Contains(got, xtversionQuery) || !strings.Contains(got, da1Query) {
		t.Fatalf(
			"attach output = %q, want XTVERSION+DA1 delivered to terminal",
			got,
		)
	}

	remaining := -1
	for time.Now().Before(deadline) {
		server.mu.Lock()
		remaining = len(window.pendingTerminalQueries) +
			len(window.pendingTerminalQueriesInFlight)
		server.mu.Unlock()
		if remaining == 0 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if remaining != 0 {
		t.Fatalf("pending queries not cleared after flush: %d bytes remain", remaining)
	}
}

// TestPendingCapabilityQueriesDeliveredOnWindowSwitch covers a restored agent
// window that starts in the background: its startup queries are buffered and
// re-delivered when the user switches to it.
func TestPendingCapabilityQueriesDeliveredOnWindowSwitch(t *testing.T) {
	server := newMuxServer("cap-switch")
	background := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "copilot",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		background,
	}
	server.activeID = "@1"
	attach := &recordingConn{}
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	// Background window: not active, so its queries are not forwarded.
	server.handleWindowOutput("@2", []byte(xtversionQuery+da1Query))

	server.mu.Lock()
	pending := string(background.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != xtversionQuery+da1Query {
		t.Fatalf("pending queries = %q, want XTVERSION+DA1 buffered while backgrounded", pending)
	}

	restore := stubForegroundResize(t)
	defer restore()

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	waitForTestAttachWrites(t, server)
	got := attach.String()
	if !strings.Contains(got, xtversionQuery) || !strings.Contains(got, da1Query) {
		t.Fatalf("switch output = %q, want XTVERSION+DA1 delivered to terminal", got)
	}

	waitForPendingQueryState(t, server, background, "", "")
	server.mu.Lock()
	remaining := len(background.pendingTerminalQueries)
	server.mu.Unlock()
	if remaining != 0 {
		t.Fatalf("pending queries not cleared after switch: %d bytes remain", remaining)
	}
}

// TestCapabilityQueriesNotBufferedWhenTerminalAttached verifies that when a
// terminal is already showing the window, its queries are forwarded live (and
// answered by that terminal), not buffered as pending.
func TestCapabilityQueriesNotBufferedWhenTerminalAttached(t *testing.T) {
	server := newMuxServer("cap-live")
	window := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	attach := &recordingConn{}
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	server.handleWindowOutput("@1", []byte(xtversionQuery+da1Query))

	server.mu.Lock()
	pending := len(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != 0 {
		t.Fatalf("queries buffered while terminal attached: %d bytes", pending)
	}
	waitForTestAttachWrites(t, server)
	if got := attach.String(); !strings.Contains(got, xtversionQuery) {
		t.Fatalf("attach output = %q, want live-forwarded query", got)
	}
}

// TestPendingCapabilityQuerySplitAcrossReads verifies a query sequence split
// across pty reads is reassembled via the carry buffer.
func TestPendingCapabilityQuerySplitAcrossReads(t *testing.T) {
	server := newMuxServer("cap-split")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.handleWindowOutput("@1", []byte("\x1b[>"))
	server.handleWindowOutput("@1", []byte("q"))

	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != xtversionQuery {
		t.Fatalf("pending queries = %q, want reassembled XTVERSION", pending)
	}
}

func TestDetachedTerminalCapabilityResponses(t *testing.T) {
	const cursorPositionQuery = "\x1b[6n"
	const kittyGraphicsQuery = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"
	const decrqmQuery = "\x1b[?2026$p"
	for _, tt := range []struct {
		name           string
		session        string
		tool           string
		capabilityHint string
		themeHint      string
		chunks         []string
		wantOutput     string
		wantPending    string
	}{
		{
			"capability hint answers queries while detached", "cap-hint-detached",
			"copilot", capabilityHintFixture, "",
			[]string{xtversionQuery + da1Query}, "\x1bP>|kitty(0.32.0)\x1b\\\x1b[?62;22c", "",
		},
		{
			"stateful query stays buffered without agent tool", "cap-hint-stateful",
			"", capabilityHintFixture, "",
			[]string{cursorPositionQuery}, "", cursorPositionQuery,
		},
		{
			"fence waits behind unanswered probe", "cap-hint-fence",
			"copilot", capabilityHintFixture, "",
			[]string{kittyGraphicsQuery + da1Query}, "", kittyGraphicsQuery + da1Query,
		},
		{
			"fence waits after probe earlier in chunk", "cap-hint-order",
			"copilot", capabilityHintFixture, "",
			[]string{xtversionQuery + decrqmQuery + da1Query}, "\x1bP>|kitty(0.32.0)\x1b\\", decrqmQuery + da1Query,
		},
		{
			"fence waits behind probe split across reads", "cap-hint-split-fence",
			"copilot", capabilityHintFixture, "",
			[]string{"\x1b[?2026", "$p" + da1Query}, "", "\x1b[?2026$p" + da1Query,
		},
		{
			"terminal version answered behind unanswered probe", "cap-hint-version",
			"copilot", capabilityHintFixture, "",
			[]string{kittyGraphicsQuery + xtversionQuery + da1Query}, "\x1bP>|kitty(0.32.0)\x1b\\", kittyGraphicsQuery + da1Query,
		},
		{
			"theme hint answers color scheme while detached", "theme-hint-detached",
			"copilot", capabilityHintFixture, themeHintFixture,
			[]string{colorSchemeQuery}, "\x1b[?997;1n", "",
		},
		{
			"color scheme answered behind buffered probe", "theme-hint-behind-probe",
			"copilot", "", themeHintFixture,
			[]string{cursorPositionQuery + colorSchemeQuery}, "\x1b[?997;1n", cursorPositionQuery,
		},
		{
			"color scheme buffered without theme hint", "theme-hint-missing",
			"copilot", "", "",
			[]string{colorSchemeQuery}, "", colorSchemeQuery,
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			server := newMuxServer(tt.session)
			pty := &recordingPty{}
			window := &muxWindow{
				id: "@1", index: 0, agentTool: tt.tool, pty: pty, lastActivity: time.Now(),
			}
			server.windows = []*muxWindow{window}
			server.activeID = "@1"
			server.capabilityHint = []byte(tt.capabilityHint)
			server.themeHint = []byte(tt.themeHint)

			for _, chunk := range tt.chunks {
				server.handleWindowOutput("@1", []byte(chunk))
			}

			if got := pty.String(); got != tt.wantOutput {
				t.Fatalf("window pty got = %q, want %q", got, tt.wantOutput)
			}
			server.mu.Lock()
			pending := string(window.pendingTerminalQueries)
			server.mu.Unlock()
			if pending != tt.wantPending {
				t.Fatalf("pending queries = %q, want %q", pending, tt.wantPending)
			}
		})
	}
}

// TestCapabilityHintAnswersBackgroundWindowQueries covers a restored agent
// window that starts behind the active one: the daemon answers its probes on
// its own pty without disturbing the window the user is looking at.
func TestCapabilityHintAnswersBackgroundWindowQueries(t *testing.T) {
	server := newMuxServer("cap-hint-background")
	pty := &recordingPty{}
	background := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "copilot",
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		background,
	}
	server.activeID = "@1"
	attach := &recordingConn{}
	client := registerTestAttachClient(t, server, attach, "primary", server.width, server.height)
	client.capabilityHint = []byte(capabilityHintFixture)

	server.handleWindowOutput("@2", []byte(xtversionQuery))

	if got := pty.String(); got != "\x1bP>|kitty(0.32.0)\x1b\\" {
		t.Fatalf("background pty got = %q, want the XTVERSION reply", got)
	}
	waitForTestAttachWrites(t, server)
	if got := attach.String(); got != "" {
		t.Fatalf("attach output = %q, want nothing for a background window", got)
	}
}

// TestCapabilityHintIsNotBorrowedFromAnotherClient pins the hint to the client
// that sent it. A client that declares no capabilities — an older helper, or a
// plain terminal running `monkeymux attach` — must not have the previous
// client's terminal identity advertised to its windows.
func TestCapabilityHintIsNotBorrowedFromAnotherClient(t *testing.T) {
	server := newMuxServer("cap-hint-client")
	pty := &recordingPty{}
	background := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "copilot",
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		background,
	}
	server.activeID = "@1"
	// The session was started by a client that declared its capabilities, but
	// the client attached now did not.
	server.capabilityHint = []byte(capabilityHintFixture)
	conn := &recordingConn{}
	registerTestAttachClient(t, server, conn, "primary", server.width, server.height)

	server.handleWindowOutput("@2", []byte(xtversionQuery))

	if got := pty.String(); got != "" {
		t.Fatalf("window pty got = %q, want no reply for a hintless client", got)
	}
	server.mu.Lock()
	pending := string(background.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != xtversionQuery {
		t.Fatalf("pending queries = %q, want the probe buffered for replay", pending)
	}
}

// TestCapabilityHintAnswerBurstIsBounded guards the pty write path: output
// replayed into a background window (ANSI art, a terminal recording) can carry
// thousands of device attribute queries, and an unbounded synthetic reply burst
// would block the window's reader goroutine on a child that is not draining its
// input.
func TestCapabilityHintAnswerBurstIsBounded(t *testing.T) {
	server := newMuxServer("cap-hint-burst")
	pty := &recordingPty{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.capabilityHint = []byte(capabilityHintFixture)

	server.handleWindowOutput(
		"@1",
		[]byte(strings.Repeat(da1Query, 4096)),
	)

	if got := len(pty.String()); got > pendingTerminalQueryLimitBytes {
		t.Fatalf(
			"wrote %d reply bytes to the pty, want at most %d",
			got,
			pendingTerminalQueryLimitBytes,
		)
	}
	server.mu.Lock()
	pending := len(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending > pendingTerminalQueryLimitBytes {
		t.Fatalf("buffered %d bytes, want at most %d", pending, pendingTerminalQueryLimitBytes)
	}

	// The buffer is now full, so later chunks must not resume answering fences.
	before := len(pty.String())
	server.handleWindowOutput("@1", []byte(da1Query))
	if got := len(pty.String()); got != before {
		t.Fatalf("wrote %d more reply bytes after the buffer filled", got-before)
	}
}

// TestCapabilityHintVersionAnswersAreBoundedAcrossChunks verifies the XTVERSION
// exemption from the fence gate is still bounded per window: it is never gated
// by the pending buffer, so only the running answer budget keeps a stream of
// XTVERSION queries in unwatched output from flooding the child's stdin.
func TestCapabilityHintVersionAnswersAreBoundedAcrossChunks(t *testing.T) {
	server := newMuxServer("cap-hint-version-burst")
	pty := &recordingPty{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.capabilityHint = []byte(capabilityHintFixture)

	for chunk := 0; chunk < 64; chunk++ {
		server.handleWindowOutput("@1", []byte(strings.Repeat(xtversionQuery, 64)))
	}

	if got := len(pty.String()); got > pendingTerminalQueryLimitBytes {
		t.Fatalf(
			"wrote %d reply bytes across chunks, want at most %d",
			got,
			pendingTerminalQueryLimitBytes,
		)
	}
	if got := len(pty.String()); got == 0 {
		t.Fatal("wrote no replies at all, want the budget spent on real answers")
	}
}

// TestCapabilityAnswerBudgetResetsWhenWindowIsShown pins the budget reset to
// window visibility rather than to output: a window whose budget was spent
// while unwatched must be able to answer probes again after the user visits it,
// even if it produced nothing while it was on screen.
func TestCapabilityAnswerBudgetResetsWhenWindowIsShown(t *testing.T) {
	restore := stubForegroundResize(t)
	defer restore()

	server := newMuxServer("cap-hint-budget-reset")
	pty := &recordingPty{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.capabilityHint = []byte(capabilityHintFixture)

	// Spend the budget while no terminal is attached.
	server.handleWindowOutput("@1", []byte(strings.Repeat(xtversionQuery, 4096)))
	spent := len(pty.String())
	if spent == 0 || spent > pendingTerminalQueryLimitBytes {
		t.Fatalf("spent %d reply bytes, want a bounded non-zero burst", spent)
	}
	server.handleWindowOutput("@1", []byte(xtversionQuery))
	if got := len(pty.String()); got != spent {
		t.Fatalf("answered %d more bytes with the budget spent", got-spent)
	}

	// A terminal attaches and shows the window without it producing output.
	attach := &recordingConn{}
	server.handleAttach(
		attach,
		bufio.NewReader(strings.NewReader("")),
		controlMessage{Width: 80, Height: 24},
	)

	server.mu.Lock()
	remaining := window.capabilityAnswerBytes
	server.mu.Unlock()
	if remaining != 0 {
		t.Fatalf("budget = %d after the window was shown, want a reset", remaining)
	}
}

func TestCapabilityQueryKeyMapsStaticQueries(t *testing.T) {
	cases := []struct {
		name     string
		sequence string
		want     string
	}{
		{"da1", da1Query, capabilityHintKeyPrimaryDeviceAttributes},
		{"da1 zero", "\x1b[0c", capabilityHintKeyPrimaryDeviceAttributes},
		{
			"c1 da1",
			string([]byte{0x9b, 'c'}),
			capabilityHintKeyPrimaryDeviceAttributes,
		},
		{"da2", "\x1b[>0c", capabilityHintKeySecondaryDeviceAttributes},
		{"da3", "\x1b[=c", capabilityHintKeyTertiaryDeviceAttributes},
		{"xtversion", xtversionQuery, capabilityHintKeyTerminalVersion},
		{"dsr status", "\x1b[5n", capabilityHintKeyDeviceStatus},
		{"cursor position", "\x1b[6n", ""},
		{"decrqm", "\x1b[?2026$p", ""},
		{"kitty keyboard", "\x1b[?u", ""},
		{"window size", "\x1b[14t", ""},
		{"decscusr", "\x1b[2 q", ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := capabilityQueryKey([]byte(tc.sequence)); got != tc.want {
				t.Fatalf(
					"capabilityQueryKey(%q) = %q, want %q",
					tc.sequence,
					got,
					tc.want,
				)
			}
		})
	}
}

func TestCapabilityHintResponseMapParsesRecords(t *testing.T) {
	responses := capabilityHintResponseMap([]byte(capabilityHintFixture))
	if got := string(responses[capabilityHintKeyTerminalVersion]); got !=
		"\x1bP>|kitty(0.32.0)\x1b\\" {
		t.Fatalf("xtversion reply = %q", got)
	}
	if got := string(responses[capabilityHintKeyDeviceStatus]); got != "\x1b[0n" {
		t.Fatalf("dsr reply = %q", got)
	}
	if got := len(responses); got != 5 {
		t.Fatalf("parsed %d replies, want 5", got)
	}
	if capabilityHintResponseMap(nil) != nil {
		t.Fatal("empty hint should parse to no replies")
	}
	if capabilityHintResponseMap([]byte("garbage")) != nil {
		t.Fatal("record without a field separator should be ignored")
	}
}

// stubForegroundResize replaces the foreground-resize hooks with no-ops so tests
// that drive the redraw path do not issue real syscalls, returning a restore
// function.
func stubForegroundResize(t *testing.T) func() {
	t.Helper()
	originalSignal := signalForegroundResize
	originalSimulate := simulateForegroundResize
	originalProcessGroup := foregroundProcessGroupForWindow
	signalForegroundResize = func(int) {}
	simulateForegroundResize = func(*muxWindow, int, int) {}
	foregroundProcessGroupForWindow = func(*muxWindow) int { return 0 }
	return func() {
		signalForegroundResize = originalSignal
		simulateForegroundResize = originalSimulate
		foregroundProcessGroupForWindow = originalProcessGroup
	}
}

// themeHintFixture is the wire-format theme hint MonkeySSH sends on attach: the
// colour-scheme mode report for the client's current theme followed by the OSC
// colour replies the daemon answers palette queries from.
const themeHintFixture = "\x1b[?997;1n" +
	"\x1b]10;rgb:d7d7/e7e7/e3e3\x1b\\" +
	"\x1b]11;rgb:0d0d/1a1a/2020\x1b\\"

// colorSchemeQuery is the DEC colour-scheme status query (CSI ? 996 n). Agents
// such as Copilot CLI emit it at startup to pick a light or dark theme.
const colorSchemeQuery = "\x1b[?996n"

// TestColorSchemeQueryForwardedLiveWhenTerminalAttached verifies the live path
// is untouched: a terminal showing the window answers the query itself with its
// current theme, so the daemon must not short circuit it from a cached hint.
func TestColorSchemeQueryForwardedLiveWhenTerminalAttached(t *testing.T) {
	server := newMuxServer("theme-hint-live")
	pty := &recordingPty{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	attach := &recordingConn{}
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)
	server.themeHint = []byte(themeHintFixture)

	server.handleWindowOutput("@1", []byte(colorSchemeQuery))

	if got := pty.String(); got != "" {
		t.Fatalf("window pty got = %q, want no synthesized answer", got)
	}
	waitForTestAttachWrites(t, server)
	if got := attach.String(); !strings.Contains(got, colorSchemeQuery) {
		t.Fatalf("attach output = %q, want the live-forwarded query", got)
	}
	server.mu.Lock()
	pending := len(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != 0 {
		t.Fatalf("queries buffered while terminal attached: %d bytes", pending)
	}
}

// TestIsTerminalColorSchemeQuery covers the sequence matcher, including the C1
// form and the neighbouring DSR queries it must not claim.
func TestIsTerminalColorSchemeQuery(t *testing.T) {
	cases := []struct {
		name     string
		sequence string
		want     bool
	}{
		{"csi form", colorSchemeQuery, true},
		{"c1 form", string([]byte{0x9b}) + "?996n", true},
		{"colour scheme report is not a query", "\x1b[?997;1n", false},
		{"cursor position dsr", "\x1b[6n", false},
		{"private cursor position dsr", "\x1b[?6n", false},
		{"other private dsr", "\x1b[?9960n", false},
		{"not a dsr final byte", "\x1b[?996c", false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isTerminalColorSchemeQuery([]byte(tc.sequence)); got != tc.want {
				t.Fatalf(
					"isTerminalColorSchemeQuery(%q) = %v, want %v",
					tc.sequence,
					got,
					tc.want,
				)
			}
		})
	}
}

// TestBufferedColorSchemeQueryDroppedOnFlush covers a session the daemon had no
// theme hint for when the query was emitted — one started outside MonkeySSH, or
// by a client that declared no theme. The query is buffered, and by the time a
// terminal attaches its reply can no longer be timely: it reaches the window pty
// as input, so a shell now sitting at the prompt would echo it as literal
// `^[[?997;1n` text. Drop it on flush and replay only the rest.
func TestBufferedColorSchemeQueryDroppedOnFlush(t *testing.T) {
	server := newMuxServer("theme-hint-late")
	pty := &recordingPty{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	// No theme hint cached yet, so the query has to be buffered.
	server.handleWindowOutput("@1", []byte(colorSchemeQuery+da1Query))

	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != colorSchemeQuery+da1Query {
		t.Fatalf("pending queries = %q, want both queries buffered", pending)
	}

	restore := stubForegroundResize(t)
	defer restore()

	attach, detach := startCapabilityTestAttach(t, server, controlMessage{Width: 80, Height: 24, Data: themeHintFixture})
	defer detach()

	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(attach.String(), da1Query) {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if got := attach.String(); !strings.Contains(got, da1Query) {
		t.Fatalf("attach output = %q, want DA1 still replayed to the terminal", got)
	}
	if got := attach.String(); strings.Contains(got, colorSchemeQuery) {
		t.Fatalf("attach output = %q, want the stale colour-scheme query dropped", got)
	}
	if got := pty.String(); strings.Contains(got, "\x1b[?997;1n") {
		t.Fatalf("window pty got = %q, want no late colour-scheme report", got)
	}
}

// TestDropColorSchemeQueries covers the flush-time filter directly, including a
// buffer that holds nothing else and one whose tail is a partial sequence.
func TestDropColorSchemeQueries(t *testing.T) {
	cases := []struct {
		name    string
		pending string
		want    string
	}{
		{
			name:    "keeps other queries in order",
			pending: xtversionQuery + colorSchemeQuery + da1Query + colorSchemeQuery,
			want:    xtversionQuery + da1Query,
		},
		{"drops a colour-scheme only buffer", colorSchemeQuery, ""},
		{"keeps a buffer with no colour-scheme query", da1Query, da1Query},
		{"preserves a partial trailing sequence", colorSchemeQuery + "\x1b[>", "\x1b[>"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := string(dropColorSchemeQueries([]byte(tc.pending)))
			if got != tc.want {
				t.Fatalf("dropColorSchemeQueries(%q) = %q, want %q", tc.pending, got, tc.want)
			}
		})
	}
}

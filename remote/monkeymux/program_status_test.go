package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func programStatusOsc(body string) string {
	return "\x1b]7501;" + body + "\x1b\\"
}

func programStatusText(text string) string {
	return base64.StdEncoding.EncodeToString([]byte(text))
}

func TestParseProgramStatusBody(t *testing.T) {
	longMsg := base64.RawStdEncoding.EncodeToString([]byte(strings.Repeat("m", 2049)))
	for _, test := range []struct {
		name   string
		body   string
		ok     bool
		id     string
		record programStatusRecord
	}{
		{
			name:   "root working report",
			body:   "state=working:app=claude-code",
			ok:     true,
			record: programStatusRecord{state: "working", app: "claude-code", progress: -1},
		},
		{
			name: "blocked report keeps kind and decodes msg",
			body: "state=blocked:app=claude-code:kind=permission:msg=" +
				programStatusText("approve Bash: touch probe2.txt"),
			ok: true,
			record: programStatusRecord{
				state: "blocked", kind: "permission", app: "claude-code",
				msg: "approve Bash: touch probe2.txt", progress: -1,
			},
		},
		{
			name:   "child record with title and progress",
			body:   "state=working:id=build/test:progress=40:title=" + programStatusText("Unit tests"),
			ok:     true,
			id:     "build/test",
			record: programStatusRecord{state: "working", title: "Unit tests", progress: 40},
		},
		{
			name:   "whitespace around keys and values is stripped",
			body:   " state = done : app = brew ",
			ok:     true,
			record: programStatusRecord{state: "done", app: "brew", progress: -1},
		},
		{
			name:   "last repeated key wins",
			body:   "state=working:state=done",
			ok:     true,
			record: programStatusRecord{state: "done", progress: -1},
		},
		{
			name:   "malformed pairs and unknown keys are skipped",
			body:   "garbage:=x:state=idle:Upper=1:future=yes:app=a!b",
			ok:     true,
			record: programStatusRecord{state: "idle", progress: -1},
		},
		{
			name:   "kind only applies to blocked",
			body:   "state=working:kind=permission",
			ok:     true,
			record: programStatusRecord{state: "working", progress: -1},
		},
		{
			name:   "unknown kind is absent",
			body:   "state=blocked:kind=coffee",
			ok:     true,
			record: programStatusRecord{state: "blocked", progress: -1},
		},
		{
			name:   "progress only applies to working and blocked",
			body:   "state=done:progress=50",
			ok:     true,
			record: programStatusRecord{state: "done", progress: -1},
		},
		{
			name:   "out of range progress is absent",
			body:   "state=working:progress=101",
			ok:     true,
			record: programStatusRecord{state: "working", progress: -1},
		},
		{
			name:   "signed progress is absent",
			body:   "state=working:progress=+5",
			ok:     true,
			record: programStatusRecord{state: "working", progress: -1},
		},
		{
			name:   "unpadded base64 is accepted",
			body:   "state=done:msg=aGk",
			ok:     true,
			record: programStatusRecord{state: "done", msg: "hi", progress: -1},
		},
		{
			name:   "bidirectional overrides are removed",
			body:   "state=done:msg=" + programStatusText("a\u202eb\u2066c"),
			ok:     true,
			record: programStatusRecord{state: "done", msg: "abc", progress: -1},
		},
		{name: "missing state", body: "app=claude-code"},
		{name: "unknown state", body: "state=sleeping"},
		{name: "invalid id", body: "state=working:id=a//b"},
		{name: "malformed id never falls back to root", body: "state=working:id=a!b"},
		{name: "id deeper than eight levels", body: "state=working:id=a/b/c/d/e/f/g/h/i"},
		{name: "id segment over 32 bytes", body: "state=working:id=" + strings.Repeat("s", 33)},
		{name: "key over 16 bytes", body: "state=working:abcdefghijklmnopq=1"},
		{name: "app over 32 bytes", body: "state=working:app=" + strings.Repeat("a", 33)},
		{name: "invalid base64", body: "state=done:msg=a===:"},
		{name: "padding on a full quantum", body: "state=done:msg=aGkh="},
		{name: "control character in msg", body: "state=done:msg=" + programStatusText("a\nb")},
		{name: "C1 control in title", body: "state=done:title=" + programStatusText("a\u0085b")},
		{name: "invalid UTF-8", body: "state=done:msg=" + base64.StdEncoding.EncodeToString([]byte{0xff})},
		{name: "msg over the decoded limit", body: "state=done:msg=" + longMsg},
		{name: "sequence over 4096 bytes", body: "state=done:" + strings.Repeat("x", 4096)},
	} {
		t.Run(test.name, func(t *testing.T) {
			id, record, query, ok := parseProgramStatusBody(test.body)
			if query {
				t.Fatal("report parsed as a query")
			}
			if ok != test.ok {
				t.Fatalf("ok = %v, want %v (record %#v)", ok, test.ok, record)
			}
			if !ok {
				return
			}
			if id != test.id || record != test.record {
				t.Fatalf("parsed (%q, %#v), want (%q, %#v)", id, record, test.id, test.record)
			}
		})
	}
}

func TestParseProgramStatusQuery(t *testing.T) {
	if _, _, query, ok := parseProgramStatusBody("?"); !query || !ok {
		t.Fatalf("query = %v, ok = %v; want a feature-detection query", query, ok)
	}
	if !isProgramStatusQueryPayload([]byte("7501;?")) {
		t.Fatal("OSC 7501 query payload not recognised")
	}
	if isProgramStatusQueryPayload([]byte("7501;state=idle")) {
		t.Fatal("OSC 7501 report treated as a query")
	}
	if !isReplayUnsafeOscQuery([]byte("7501;?")) {
		t.Fatal("a replayed OSC 7501 query would be answered twice")
	}
}

func TestProgramStatusReportsReplaceTheirRecord(t *testing.T) {
	window := &muxWindow{}
	window.observeTerminalMetadataLocked([]byte(programStatusOsc(
		"state=working:app=deploy:progress=10:msg=" + programStatusText("pushing"),
	)))
	window.observeTerminalMetadataLocked([]byte(programStatusOsc("state=working")))

	summary := window.programStatusSummaryLocked()
	if summary != (programStatusSummary{state: "working", progress: -1}) {
		t.Fatalf("summary = %#v, want omitted keys gone", summary)
	}
}

func TestProgramStatusChildrenInheritAppAndClearWithParent(t *testing.T) {
	window := &muxWindow{}
	window.observeTerminalMetadataLocked([]byte(
		programStatusOsc("state=working:app=deploy") +
			programStatusOsc("state=working:id=us-east:progress=40:title="+programStatusText("us-east")) +
			programStatusOsc("state=blocked:id=eu-west:kind=permission:msg="+programStatusText("approve prod")) +
			programStatusOsc("state=working:id=eu-west/canary"),
	))

	summary := window.programStatusSummaryLocked()
	if summary.state != "blocked" || summary.kind != "permission" ||
		summary.app != "deploy" || summary.msg != "approve prod" {
		t.Fatalf("summary = %#v, want the blocked child with the root's app", summary)
	}

	window.observeTerminalMetadataLocked([]byte(programStatusOsc("state=clear:id=eu-west")))
	if _, ok := window.programStatus["eu-west/canary"]; ok {
		t.Fatal("clearing a record kept its descendant")
	}
	summary = window.programStatusSummaryLocked()
	if summary.state != "working" || summary.progress != -1 || summary.title != "" {
		t.Fatalf("summary = %#v, want the root over an equally urgent child", summary)
	}

	window.observeTerminalMetadataLocked([]byte(programStatusOsc("state=clear")))
	if len(window.programStatus) != 0 {
		t.Fatalf("records after a root clear = %v, want none", window.programStatus)
	}
	if window.programStatusSummaryLocked().snapshot() != nil {
		t.Fatal("a window without records published a status")
	}
}

func TestProgramStatusEvictsLeastRecentlyUpdatedRecord(t *testing.T) {
	window := &muxWindow{}
	for index := 0; index <= programStatusMaxRecords; index++ {
		window.observeTerminalMetadataLocked([]byte(programStatusOsc(
			fmt.Sprintf("state=working:id=task%d", index),
		)))
		if index == 1 {
			// Touch task0 so task1 becomes the oldest.
			window.observeTerminalMetadataLocked([]byte(programStatusOsc("state=working:id=task0")))
		}
	}
	if len(window.programStatus) != programStatusMaxRecords {
		t.Fatalf("records = %d, want %d", len(window.programStatus), programStatusMaxRecords)
	}
	if _, ok := window.programStatus["task1"]; ok {
		t.Fatal("least recently updated record was not evicted")
	}
	if _, ok := window.programStatus["task0"]; !ok {
		t.Fatal("recently updated record was evicted")
	}
}

func TestProgramStatusPromptAndResetEndRecords(t *testing.T) {
	window := &muxWindow{}
	window.observeTerminalMetadataLocked([]byte(
		programStatusOsc("state=working") +
			programStatusOsc("state=blocked:id=a") +
			programStatusOsc("state=idle:id=b") +
			programStatusOsc("state=done:id=c") +
			programStatusOsc("state=error:id=d"),
	))

	window.observeTerminalMetadataLocked([]byte("\x1b]133;A;redraw=0\x07"))
	if len(window.programStatus) != 2 ||
		window.programStatus["c"] == nil || window.programStatus["d"] == nil {
		t.Fatalf("records after a prompt = %v, want only done and error", window.programStatus)
	}

	window.observeTerminalMetadataLocked([]byte("\x1b]133;B\x07"))
	if len(window.programStatus) != 2 {
		t.Fatal("a non-prompt OSC 133 mark ended records")
	}

	window.observeTerminalMetadataLocked([]byte(programStatusOsc("state=working:id=e") + "\x1b]633;A\x07"))
	if _, ok := window.programStatus["e"]; ok {
		t.Fatal("a VS Code OSC 633 prompt kept a working record")
	}

	window.observeTerminalMetadataLocked([]byte("\x1bc"))
	if len(window.programStatus) != 0 {
		t.Fatalf("records after RIS = %v, want none", window.programStatus)
	}
}

// RIS, prompts and reports apply in the order they were written, also when
// they share one read.
func TestProgramStatusResetAppliesInByteOrder(t *testing.T) {
	server := newMuxServer("program-status-ris")
	window := &muxWindow{id: "@1", name: "sh", lastActivity: time.Now()}
	server.windows = []*muxWindow{window}

	server.handleWindowOutput("@1", []byte(programStatusOsc("state=blocked:kind=permission")+"\x1bc"))
	if summary := window.programStatusSummaryLocked(); summary.state != "" {
		t.Fatalf("status after a report then RIS = %#v, want none", summary)
	}

	server.handleWindowOutput("@1", []byte("\x1bc"+programStatusOsc("state=working")))
	if summary := window.programStatusSummaryLocked(); summary.state != "working" {
		t.Fatalf("status after RIS then a report = %#v, want working", summary)
	}

	server.handleWindowOutput("@1", []byte("\x1b"))
	server.handleWindowOutput("@1", []byte("c"))
	if summary := window.programStatusSummaryLocked(); summary.state != "" {
		t.Fatalf("status after a split RIS = %#v, want none", summary)
	}
}

func TestProgramStatusEndsWhenItsSenderExits(t *testing.T) {
	originalForeground := foregroundProcessGroupForWindow
	originalExited := programStatusOwnerExited
	t.Cleanup(func() {
		foregroundProcessGroupForWindow = originalForeground
		programStatusOwnerExited = originalExited
	})
	foreground := 100
	foregroundProcessGroupForWindow = func(*muxWindow) int { return foreground }
	exited := map[int]bool{}
	programStatusOwnerExited = func(pgrp int) bool { return exited[pgrp] }

	server := newMuxServer("program-status-exit")
	control := newControlRecorder(server)
	server.controls[newControlClient(control)] = struct{}{}
	window := &muxWindow{id: "@1", name: "zsh", lastActivity: time.Now()}
	server.windows = []*muxWindow{window}

	server.handleWindowOutput("@1", []byte(
		programStatusOsc("state=working:app=claude-code")+programStatusOsc("state=done:id=old"),
	))
	foreground = 200
	server.handleWindowOutput("@1", []byte(programStatusOsc("state=working:id=helper")))
	_ = control.String() // drain the reports' own broadcasts
	control.Reset()

	server.dropExitedProgramStatus()
	if control.String() != "" {
		t.Fatal("broadcast while every sender is alive")
	}

	exited[100] = true
	server.dropExitedProgramStatus()
	server.mu.Lock()
	_, rootKept := window.programStatus[""]
	_, doneKept := window.programStatus["old"]
	_, helperKept := window.programStatus["helper"]
	server.mu.Unlock()
	if rootKept || !doneKept || !helperKept {
		t.Fatalf("records = %v, want the exited sender's working record dropped", window.programStatus)
	}
	if got := strings.Count(control.String(), `"type":"window_updated"`); got != 1 {
		t.Fatalf("window updates = %d, want 1", got)
	}
}

func TestProgramStatusQueryIsAnsweredByMonkeyMux(t *testing.T) {
	server := newMuxServer("program-status-query")
	pty := &recordingPty{}
	window := &muxWindow{id: "@1", name: "claude", pty: pty, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	attach := &recordingConn{}
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	server.handleWindowOutput("@1", []byte("\x1b]7501;?\x1b\\"+da1Query))
	waitForWindowReplies(t, window)
	waitForTestAttachWrites(t, server)

	if got := pty.String(); got != string(programStatusQueryReply) {
		t.Fatalf("pty got %q, want the OSC 7501 reply", got)
	}
	if got := attach.String(); strings.Contains(got, "7501") || !strings.Contains(got, da1Query) {
		t.Fatalf("attach output = %q, want the device-attributes query without OSC 7501", got)
	}
}

// MonkeyMux answers exactly the queries it strips: one split across reads is
// answered once, and a C1-introduced one it leaves in the stream is left for
// the attached terminal to answer.
func TestProgramStatusQueryIsAnsweredOnlyWhenStripped(t *testing.T) {
	server := newMuxServer("program-status-query-split")
	pty := &recordingPty{}
	window := &muxWindow{id: "@1", name: "claude", pty: pty, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	attach := &recordingConn{}
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	server.handleWindowOutput("@1", []byte("\x1b]7501"))
	server.handleWindowOutput("@1", []byte(";?\x1b\\"))
	waitForWindowReplies(t, window)
	if got := pty.String(); got != string(programStatusQueryReply) {
		t.Fatalf("pty got %q, want one reply to the split query", got)
	}

	pty.Reset()
	c1Query := "\x9d7501;?\x9c"
	server.handleWindowOutput("@1", []byte(c1Query))
	waitForWindowReplies(t, window)
	waitForTestAttachWrites(t, server)
	if got := pty.String(); got != "" {
		t.Fatalf("pty got %q, want no reply to a query left in the stream", got)
	}
	if got := attach.String(); !strings.Contains(got, c1Query) || strings.Contains(got, "\x1b]7501") {
		t.Fatalf("attach output = %q, want only the C1 query forwarded", got)
	}
}

// Claude Code sends OSC 7501 detection right before a device-attributes query
// and treats that query's answer arriving first as "unsupported". In a window
// no terminal is showing, the device-attributes answer comes from the
// client's capability hint, so the OSC 7501 reply must be queued ahead of it.
func TestProgramStatusReplyPrecedesDeviceAttributesInBackgroundWindow(t *testing.T) {
	server := newMuxServer("program-status-background")
	pty := &recordingPty{}
	background := &muxWindow{id: "@2", index: 1, name: "claude", pty: pty, lastActivity: time.Now()}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		background,
	}
	server.activeID = "@1"
	client := registerTestAttachClient(t, server, &recordingConn{}, "primary", server.width, server.height)
	client.capabilityHint = []byte(capabilityHintFixture)

	server.handleWindowOutput("@2", []byte(xtversionQuery+"\x1b]7501;?\x07"+da1Query))
	waitForWindowReplies(t, background)

	got := pty.String()
	replyAt := strings.Index(got, string(programStatusQueryReply))
	deviceAttributesAt := strings.Index(got, "\x1b[?62;22c")
	if replyAt < 0 || deviceAttributesAt < 0 || replyAt > deviceAttributesAt {
		t.Fatalf("pty got %q, want the OSC 7501 reply before the DA1 reply", got)
	}
}

// The states Claude Code 2.1.296 reported in a PTY that answered detection:
// idle at startup, working and done per turn, blocked on a permission prompt,
// idle once it was rejected, and clear on /exit.
func TestClaudeCodeProgramStatusSession(t *testing.T) {
	server := newMuxServer("program-status-claude")
	control := newControlRecorder(server)
	server.controls[newControlClient(control)] = struct{}{}
	window := &muxWindow{id: "@1", name: "claude", lastActivity: time.Now()}
	server.windows = []*muxWindow{window}

	steps := []struct {
		report string
		want   string
	}{
		{"state=idle:app=claude-code", `{"state":"idle","app":"claude-code"}`},
		{"state=working:app=claude-code", `{"state":"working","app":"claude-code"}`},
		{"state=done:app=claude-code", `{"state":"done","app":"claude-code"}`},
		{
			"state=blocked:app=claude-code:kind=permission:msg=" +
				programStatusText("approve Bash: touch probe2.txt"),
			`{"state":"blocked","kind":"permission","app":"claude-code","msg":"approve Bash: touch probe2.txt"}`,
		},
		{"state=idle:app=claude-code", `{"state":"idle","app":"claude-code"}`},
	}
	for _, step := range steps {
		control.Reset()
		server.handleWindowOutput("@1", []byte(programStatusOsc(step.report)))
		if !strings.Contains(control.String(), `"programStatus":`+step.want) {
			t.Fatalf("after %q broadcast = %s, want programStatus %s", step.report, control.String(), step.want)
		}
	}

	control.Reset()
	server.handleWindowOutput("@1", []byte(programStatusOsc("state=clear")))
	if strings.Contains(control.String(), `"programStatus"`) ||
		!strings.Contains(control.String(), `"type":"window_updated"`) {
		t.Fatalf("clear broadcast = %s, want an update without programStatus", control.String())
	}
}

func TestProgramStatusSnapshotJSON(t *testing.T) {
	window := &muxWindow{}
	window.observeTerminalMetadataLocked([]byte(programStatusOsc("state=working:progress=0")))
	encoded, err := json.Marshal(window.programStatusSummaryLocked().snapshot())
	if err != nil {
		t.Fatal(err)
	}
	if string(encoded) != `{"state":"working","progress":0}` {
		t.Fatalf("snapshot = %s, want zero progress kept", encoded)
	}
}

func TestRestoreHistoryDropsProgramStatus(t *testing.T) {
	history := []byte("before" + programStatusOsc("state=working:app=claude-code") +
		"\x1b]7501;state=done\x07after")
	if got := string(stripTerminalProgressFromRestoreHistory(history)); got != "beforeafter" {
		t.Fatalf("restored history = %q, want OSC 7501 reports removed", got)
	}
}

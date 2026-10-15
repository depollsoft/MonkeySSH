package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestProgramStatusPushKind(t *testing.T) {
	status := func(state, kind string) programStatusSummary {
		return programStatusSummary{state: state, kind: kind}
	}
	cases := []struct {
		name          string
		before, after programStatusSummary
		want          string
	}{
		{"turn ends done", status("working", ""), status("done", ""), pushKindFinished},
		{"turn ends idle", status("working", ""), status("idle", ""), pushKindFinished},
		{"permission prompt", status("working", ""), status("blocked", "permission"), pushKindPermission},
		{"question", status("working", ""), status("blocked", "question"), pushKindInput},
		{"sign-in", status("idle", ""), status("blocked", "auth"), pushKindInput},
		{"blocked without a kind", status("working", ""), status("blocked", ""), pushKindInput},
		{"another kind of block", status("blocked", "permission"), status("blocked", "question"), pushKindInput},
		{"same block again", status("blocked", "permission"), status("blocked", "permission"), ""},
		{"rejected prompt", status("blocked", "permission"), status("idle", ""), ""},
		{"startup", status("", ""), status("idle", ""), ""},
		{"turn starts", status("done", ""), status("working", ""), ""},
		{"error", status("working", ""), status("error", ""), ""},
		{"exit", status("working", ""), status("", ""), ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := programStatusPushKind(tc.before, tc.after); got != tc.want {
				t.Fatalf("push = %q, want %q", got, tc.want)
			}
		})
	}
}

// addPushStatusWindow adds a window that is not the active one.
func (h *pushTestHarness) addPushStatusWindow(id string, bridgeID string) {
	h.server.mu.Lock()
	h.server.windows = append(h.server.windows, &muxWindow{
		id:                id,
		name:              "agent",
		lastActivity:      time.Now(),
		nativeAcpBridgeID: bridgeID,
	})
	h.server.mu.Unlock()
}

// reportStatus feeds OSC 7501 reports to a window one at a time, a coalescing
// window apart, and delivers the pushes each one queues.
func (h *pushTestHarness) reportStatus(windowID string, reports ...string) {
	for _, report := range reports {
		h.server.handleWindowOutput(windowID, []byte(programStatusOsc(report)))
		h.deliverQueued()
		h.clock.now = h.clock.now.Add(pushCoalesceWindow)
	}
}

// deliverQueued raises the pushes the PTY reader queued, as the push loop does.
func (h *pushTestHarness) deliverQueued() {
	for {
		select {
		case event := <-h.notifier.alerts:
			h.server.deliverPushAlertEvent(event)
		default:
			h.notifier.inflight.Wait()
			return
		}
	}
}

// A terminal agent's turns and prompts push like a native agent chat's: the
// states Claude Code reports for a turn, a permission prompt that is
// approved, and one that is rejected.
func TestPushTerminalAgentTurnsAndPrompts(t *testing.T) {
	h := newPushTestHarness(t)
	device := newPushTestDevice(t, 1)
	h.registerEvents(t, device, nil)
	h.addPushStatusWindow("@2", "")
	prompt := "state=blocked:app=claude-code:kind=permission:msg=" +
		programStatusText("approve Bash: rm -rf secret-dir")
	h.reportStatus("@2",
		"state=idle:app=claude-code",
		"state=working:app=claude-code",
		"state=done:app=claude-code",
		"state=working:app=claude-code",
		prompt,
		"state=working:app=claude-code",
		"state=done:app=claude-code",
		prompt,
		"state=idle:app=claude-code",
	)
	if got := h.kinds(); got != "finished,permission,finished,permission" {
		t.Fatalf("pushes = %q, want two finished turns and two prompts in order", got)
	}
	for _, request := range h.endpoint.received() {
		payload := string(openPushPayloadForTest(t, device.private, request.Payload))
		if strings.Contains(payload, "rm -rf") || strings.Contains(payload, "approve") ||
			strings.Contains(payload, "claude-code") {
			t.Fatalf("payload %s carries the program's report", payload)
		}
	}
}

// A read carrying several reports pushes each change, so a quick turn whose
// working and done arrive together still pushes, and so does a prompt that
// replaces an answered one within the same read.
func TestPushTerminalAgentStatusWithinOneRead(t *testing.T) {
	h := newPushTestHarness(t)
	device := newPushTestDevice(t, 1)
	h.registerEvents(t, device, nil)
	h.addPushStatusWindow("@2", "")
	prompt := "state=blocked:app=claude-code:kind=permission"
	h.reportStatus("@2", "state=idle:app=claude-code")
	read := func(reports ...string) {
		var chunk strings.Builder
		for _, report := range reports {
			chunk.WriteString(programStatusOsc(report))
		}
		h.server.handleWindowOutput("@2", []byte(chunk.String()))
		h.deliverQueued()
		h.clock.now = h.clock.now.Add(pushCoalesceWindow)
	}
	read("state=working:app=claude-code", "state=done:app=claude-code")
	read("state=working:app=claude-code", prompt)
	read("state=working:app=claude-code", prompt)
	// A terminal reset (RIS) clears the prompt, so one that follows it in the
	// same read is new.
	h.server.handleWindowOutput("@2", []byte("\x1bc"+programStatusOsc(prompt)))
	h.deliverQueued()
	if got := h.kinds(); got != "finished,permission,permission,permission" {
		t.Fatalf("pushes = %q, want the turn and all three prompts", got)
	}
}

func TestPushTerminalAgentFollowsTheHostsEvents(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), pushTestEvents(pushEventAttention))
	h.addPushStatusWindow("@2", "")
	h.reportStatus("@2",
		"state=working",
		"state=done",
		"state=working",
		"state=blocked:kind=question",
	)
	if got := h.kinds(); got != "input" {
		t.Fatalf("pushes = %q, want only the question", got)
	}
}

// A native agent window's turns are pushed from its bridge, so its own
// status reports do not push again.
func TestPushNativeAgentWindowStatusIsNotPushedTwice(t *testing.T) {
	h := newPushTestHarness(t)
	h.registerEvents(t, newPushTestDevice(t, 1), nil)
	h.addPushStatusWindow("@2", pushTestBridgeID)
	h.reportStatus("@2", "state=working", "state=done", "state=blocked:kind=permission")
	if got := h.kinds(); got != "" {
		t.Fatalf("pushes = %q, want none from a native agent window's status", got)
	}
}

// The payload names the window's agent so the app can say who finished. It
// is sent only when it is a short lowercase id.
func TestPushPayloadNamesTheWindowsAgent(t *testing.T) {
	cases := []struct {
		tool string
		want string
	}{
		{"claude", "claude"},
		{"name:claude", "claude"},
		{"cursor-agent", "cursor-agent"},
		{"", ""},
		{"Claude Code", ""},
		{strings.Repeat("a", 33), ""},
	}
	for _, tc := range cases {
		t.Run(tc.tool, func(t *testing.T) {
			h := newPushTestHarness(t)
			device := newPushTestDevice(t, 1)
			h.registerEvents(t, device, nil)
			h.addPushStatusWindow("@2", "")
			h.server.mu.Lock()
			window := h.server.windows[len(h.server.windows)-1]
			// "name:" puts the tool only in the window's name, as a window
			// opened as `claude` without a recorded tool is.
			if name, ok := strings.CutPrefix(tc.tool, "name:"); ok {
				window.name = name
			} else {
				window.agentTool = tc.tool
			}
			h.server.mu.Unlock()
			h.reportStatus("@2", "state=working", "state=done")
			requests := h.endpoint.received()
			if len(requests) != 1 {
				t.Fatalf("pushes = %d, want 1", len(requests))
			}
			var event struct {
				Agent *string `json:"agent"`
			}
			if err := json.Unmarshal(openPushPayloadForTest(t, device.private, requests[0].Payload), &event); err != nil {
				t.Fatal(err)
			}
			got := ""
			if event.Agent != nil {
				got = *event.Agent
				if got == "" {
					t.Fatal("payload carries an empty agent")
				}
			}
			if got != tc.want {
				t.Fatalf("agent = %q, want %q", got, tc.want)
			}
		})
	}
}

// A push names the window as the window bar does, skipping titles that say
// nothing the notification does not already.
func TestPushWindowTitle(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	project := filepath.Join(home, "src", "monkeyssh")
	type titles struct{ session, pane, name, cwd string }
	cases := []struct {
		name   string
		window titles
		agent  string
		want   string
	}{
		{"agent session title first", titles{session: "Fix login bug", pane: "✳ Other", name: "claude"}, "claude", "Fix login bug"},
		{"program title without its spinner", titles{pane: "⠂ Fix login bug", name: "claude"}, "claude", "Fix login bug"},
		{"window name", titles{pane: "zsh", name: "build"}, "", "build"},
		{"agent's own name skipped for the folder", titles{pane: "Claude Code", name: "claude", cwd: project}, "claude", "monkeyssh"},
		{"host name and status words skipped", titles{pane: "build-box.local", name: "working", cwd: project}, "", "monkeyssh"},
		{"home folder says nothing", titles{name: "bash", cwd: home}, "", ""},
		{"shell titles and paths skipped", titles{pane: "dev@build-box: ~/src", name: "~/src/monkeyssh", cwd: project}, "", "monkeyssh"},
		{"a path inside a title is kept", titles{pane: "✳ Fix src/auth.ts"}, "claude", "Fix src/auth.ts"},
		{"control characters collapse", titles{name: "deploy\x1b[31m\n  prod"}, "", "deploy [31m prod"},
		{"long titles are cut", titles{name: strings.Repeat("a", 80)}, "", strings.Repeat("a", 63) + "…"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			window := &muxWindow{
				agentSessionTitle: tc.window.session,
				paneTitle:         tc.window.pane,
				name:              tc.window.name,
				cwd:               tc.window.cwd,
			}
			if got := pushWindowTitleLocked(window, tc.agent); got != tc.want {
				t.Fatalf("title = %q, want %q", got, tc.want)
			}
		})
	}
}

// The title travels in the encrypted payload.
func TestPushPayloadNamesTheWindowsTitle(t *testing.T) {
	h := newPushTestHarness(t)
	device := newPushTestDevice(t, 1)
	h.registerEvents(t, device, nil)
	h.addPushStatusWindow("@2", "")
	h.server.mu.Lock()
	h.server.windows[len(h.server.windows)-1].paneTitle = "✳ Fix login bug"
	h.server.mu.Unlock()
	h.reportStatus("@2", "state=working", "state=done")
	requests := h.endpoint.received()
	if len(requests) != 1 {
		t.Fatalf("pushes = %d, want 1", len(requests))
	}
	var event struct {
		Title string `json:"title"`
	}
	if err := json.Unmarshal(openPushPayloadForTest(t, device.private, requests[0].Payload), &event); err != nil {
		t.Fatal(err)
	}
	if event.Title != "Fix login bug" {
		t.Fatalf("title = %q, want the window's title", event.Title)
	}
	if strings.Contains(requests[0].Payload, "login") {
		t.Fatal("the title is readable outside the encrypted payload")
	}
}

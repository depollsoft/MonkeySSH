//go:build !windows

package main

import (
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRefreshProcessMetadataPublishesPiSessionTitle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	appendPiTitleTestRecords(t, path,
		piTitleTestHeader,
		`{"type":"message","message":{"role":"user","content":"Fix the window bar"}}`+"\n",
	)
	window := &muxWindow{
		id:                 "@1",
		name:               "pi",
		command:            "pi",
		agentTool:          "pi",
		agentToolConfirmed: true,
		agentSessionID:     "01a0f9cd-03d9-75cd-9ffa-8b89ede923c4",
		agentSessionPath:   path,
		lastActivity:       time.Now(),
	}
	_, server := newThemeQueryTestServer(t, window)
	control := &recordingConn{}
	server.controls[newControlClient(control)] = struct{}{}
	server.activeID = window.id

	server.handleWindowOutput(window.id, []byte("x"))
	if got := server.snapshotLocked(window).AgentSessionTitle; got != "Fix the window bar" {
		t.Fatalf("snapshot title = %q, want first prompt", got)
	}
	if !strings.Contains(control.String(), `"agentSessionTitle":"Fix the window bar"`) {
		t.Fatalf("window update did not carry the title: %s", control.String())
	}
}

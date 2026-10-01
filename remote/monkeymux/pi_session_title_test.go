package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const piTitleTestHeader = `{"type":"session","version":3,"id":"01a0f9cd-03d9-75cd-9ffa-8b89ede923c4","timestamp":"2026-10-01T23:29:17.785Z","cwd":"/work"}` + "\n"

func appendPiTitleTestRecords(t *testing.T, path string, records ...string) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.WriteString(strings.Join(records, "")); err != nil {
		t.Fatal(err)
	}
}

func TestPiSessionTitleScanPrefersNameOverFirstPrompt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	appendPiTitleTestRecords(t, path,
		piTitleTestHeader,
		`{"type":"model_change","provider":"openai"}`+"\n",
		`{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Give me a list\nof image files"},{"type":"image","data":"AAAA"},{"type":"text","text":"in this project"}]}}`+"\n",
		`{"type":"message","message":{"role":"user","content":"a later prompt"}}`+"\n",
	)
	var scan piSessionTitleScan
	if got := scan.title(path); got != "Give me a list of image files in this project" {
		t.Fatalf("first prompt title = %q", got)
	}

	// A record still being written is read once its newline lands.
	appendPiTitleTestRecords(t, path, `{"type":"session_info","name":"Image `)
	if got := scan.title(path); got != "Give me a list of image files in this project" {
		t.Fatalf("partial record changed the title to %q", got)
	}
	appendPiTitleTestRecords(t, path, `audit"}`+"\n")
	if got := scan.title(path); got != "Image audit" {
		t.Fatalf("named title = %q, want Image audit", got)
	}

	// An empty name clears it, as in Pi.
	appendPiTitleTestRecords(t, path, `{"type":"session_info","name":"  "}`+"\n")
	if got := scan.title(path); got != "Give me a list of image files in this project" {
		t.Fatalf("cleared name title = %q", got)
	}

	// A rewritten, shorter file is read again from the start.
	if err := os.WriteFile(path, []byte(piTitleTestHeader+
		`{"type":"message","message":{"role":"user","content":"Fresh start"}}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := scan.title(path); got != "Fresh start" {
		t.Fatalf("rewritten file title = %q, want Fresh start", got)
	}
}

func TestPiSessionTitleScanSummarizesLongPrompts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	prompt := strings.Repeat("é", 100)
	appendPiTitleTestRecords(t, path,
		piTitleTestHeader,
		`{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"not a prompt"}]}}`+"\n",
		`{"type":"message","message":{"role":"user","content":"`+prompt+`"}}`+"\n",
	)
	var scan piSessionTitleScan
	want := strings.Repeat("é", piSessionTitleMaxRunes-3) + "..."
	if got := scan.title(path); got != want {
		t.Fatalf("long prompt title = %q, want %q", got, want)
	}
}

func TestPiSessionTitleScanIgnoresFilesThatAreNotPiSessions(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "other.jsonl")
	appendPiTitleTestRecords(t, path,
		`{"type":"note"}`+"\n",
		`{"type":"session_info","name":"not a Pi session"}`+"\n",
	)
	var scan piSessionTitleScan
	if got := scan.title(path); got != "" {
		t.Fatalf("non-Pi file title = %q, want empty", got)
	}
	if got := scan.title(filepath.Join(directory, "missing.jsonl")); got != "" {
		t.Fatalf("missing file title = %q, want empty", got)
	}
}

func stubPiTitleBridgeStatus(t *testing.T, status func(string) (acpBridgeInfo, error)) {
	t.Helper()
	original := acpBridgeStatusForMetadata
	acpBridgeStatusForMetadata = status
	t.Cleanup(func() { acpBridgeStatusForMetadata = original })
}

func TestNativePiSessionPathFindsTheBridgeSessionFile(t *testing.T) {
	agentDir := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", "")
	t.Setenv("PI_CODING_AGENT_DIR", agentDir)
	cwd := filepath.Join(t.TempDir(), "project")
	bucket := filepath.Join(agentDir, "sessions", piEncodedSessionDirName(cwd))
	if err := os.MkdirAll(bucket, 0o700); err != nil {
		t.Fatal(err)
	}
	sessionID := "01a0f9cd-03d9-75cd-9ffa-8b89ede923c4"
	want := filepath.Join(bucket, "2026-10-01T23-29-17-785Z_"+sessionID+".jsonl")
	appendPiTitleTestRecords(t, want, piTitleTestHeader)
	appendPiTitleTestRecords(t, filepath.Join(bucket, "2026-10-01T22-00-00-000Z_other.jsonl"), piTitleTestHeader)
	bridgeID := "0123456789abcdef0123456789abcdef"
	reported := sessionID
	stubPiTitleBridgeStatus(t, func(id string) (acpBridgeInfo, error) {
		if id != bridgeID {
			return acpBridgeInfo{}, errors.New("unknown bridge")
		}
		return acpBridgeInfo{ID: id, SessionID: reported, Cwd: cwd}, nil
	})

	if got := nativePiSessionPath(bridgeID); got != want {
		t.Fatalf("native session path = %q, want %q", got, want)
	}
	if got := nativePiSessionPath("not-a-bridge"); got != "" {
		t.Fatalf("invalid bridge path = %q, want empty", got)
	}
	reported = "../escape"
	if got := nativePiSessionPath(bridgeID); got != "" {
		t.Fatalf("unsafe session id path = %q, want empty", got)
	}
}

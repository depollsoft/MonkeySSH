package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	// piSessionTitleMaxRunes matches the label length MonkeySSH's session
	// picker shows for a Pi session.
	piSessionTitleMaxRunes = 80
	// nativePiSessionLookupInterval bounds how often a native Pi window asks
	// its ACP bridge which session it hosts.
	nativePiSessionLookupInterval = 5 * time.Second
)

// acpBridgeStatusForMetadata is replaced in tests.
var acpBridgeStatusForMetadata = acpBridgeStatus

// piSessionTitleScan reads the label a Pi window shows in client window lists:
// the session's latest explicit name, else its first user prompt. Pi's own
// session picker, pi-acp's session/list, and MonkeySSH's session picker all
// label a Pi session this way, so the window keeps the name the session was
// opened under instead of reading "Pi".
//
// Pi only appends records, so each call reads just the bytes written since the
// previous one. A shorter file or a different path starts over.
type piSessionTitleScan struct {
	path        string
	offset      int64
	sawHeader   bool
	valid       bool
	name        string
	firstPrompt string
}

func (scan *piSessionTitleScan) title(path string) string {
	if path == "" {
		*scan = piSessionTitleScan{}
		return ""
	}
	if path != scan.path {
		*scan = piSessionTitleScan{path: path}
	}
	file, err := os.Open(path)
	if err != nil {
		*scan = piSessionTitleScan{path: path}
		return ""
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return scan.label()
	}
	if info.Size() < scan.offset {
		*scan = piSessionTitleScan{path: path}
	}
	if info.Size() == scan.offset {
		return scan.label()
	}
	if _, err := file.Seek(scan.offset, io.SeekStart); err != nil {
		return scan.label()
	}
	reader := bufio.NewReaderSize(io.LimitReader(file, info.Size()-scan.offset), 64*1024)
	for {
		line, truncated, bytesRead, readErr := readBoundedLine(
			reader,
			piSessionMetadataRecordLimitBytes,
		)
		if readErr != nil {
			break
		}
		if !truncated && bytesRead == len(line) {
			// Pi is still writing this record; read it once its newline lands.
			break
		}
		scan.offset += int64(bytesRead)
		scan.observe(line, truncated)
	}
	return scan.label()
}

func (scan *piSessionTitleScan) observe(line []byte, truncated bool) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return
	}
	if !scan.sawHeader {
		scan.sawHeader = true
		var header struct {
			Type string `json:"type"`
		}
		scan.valid = !truncated && json.Unmarshal(line, &header) == nil && header.Type == "session"
		return
	}
	// Oversized records are image or tool payloads. Most records are neither
	// a name nor the first prompt, so skip parsing them.
	if !scan.valid || truncated {
		return
	}
	wantsPrompt := scan.firstPrompt == "" && bytes.Contains(line, []byte(`"user"`))
	if !wantsPrompt && !bytes.Contains(line, []byte("session_info")) {
		return
	}
	var record struct {
		Type    string `json:"type"`
		Name    string `json:"name"`
		Message *struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		} `json:"message"`
	}
	if json.Unmarshal(line, &record) != nil {
		return
	}
	switch record.Type {
	case "session_info":
		// The latest record wins, and an empty name clears it (see
		// piLatestSessionName).
		scan.name = strings.TrimSpace(record.Name)
	case "message":
		if wantsPrompt && record.Message != nil && record.Message.Role == "user" {
			scan.firstPrompt = piUserMessageText(record.Message.Content)
		}
	}
}

func (scan *piSessionTitleScan) label() string {
	if !scan.valid {
		return ""
	}
	if scan.name != "" {
		return summarizePiSessionTitle(scan.name)
	}
	return summarizePiSessionTitle(scan.firstPrompt)
}

// piUserMessageText joins the text parts of a Pi user message the way the
// session picker does. Images and other parts are not part of the label.
func piUserMessageText(content json.RawMessage) string {
	var text string
	if json.Unmarshal(content, &text) == nil {
		return text
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(content, &parts) != nil {
		return ""
	}
	texts := make([]string, 0, len(parts))
	for _, part := range parts {
		if part.Type == "text" {
			texts = append(texts, part.Text)
		}
	}
	return strings.Join(texts, " ")
}

func summarizePiSessionTitle(text string) string {
	collapsed := []rune(strings.Join(strings.Fields(text), " "))
	if len(collapsed) <= piSessionTitleMaxRunes {
		return string(collapsed)
	}
	return string(collapsed[:piSessionTitleMaxRunes-3]) + "..."
}

// nativePiSessionPath finds the session file behind a native Pi window. Its
// ACP bridge reports pi-acp's session id, which is Pi's own session id, and Pi
// names that session's file `<timestamp>_<id>.jsonl`. By default the file sits
// in the bucket for the session's cwd; a configured session directory holds it
// directly. Both places are searched and the id must match exactly one file.
func nativePiSessionPath(bridgeID string) string {
	if !validAcpBridgeID(bridgeID) {
		return ""
	}
	info, err := acpBridgeStatusForMetadata(bridgeID)
	if err != nil {
		return ""
	}
	sessionID := strings.TrimSpace(info.SessionID)
	if !safePiSessionIDPattern.MatchString(sessionID) {
		return ""
	}
	root := piSessionRootForWorkingDirectory(info.Cwd)
	if root == "" {
		return ""
	}
	directories := []string{root}
	if bucket := piEncodedSessionDirName(info.Cwd); bucket != "" {
		directories = append(directories, filepath.Join(root, bucket))
	}
	suffix := "_" + sessionID + ".jsonl"
	match := ""
	for _, directory := range directories {
		entries, err := os.ReadDir(directory)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			if entry.IsDir() || !strings.HasSuffix(entry.Name(), suffix) {
				continue
			}
			if match != "" {
				return ""
			}
			match = filepath.Join(directory, entry.Name())
		}
	}
	return match
}

// piSessionTitle returns the label for a Pi window's session: the exact file a
// terminal window's Pi reported, or the file behind a native window's bridge.
// It serializes on the window's own lock because snapshots, terminal output,
// and the quiet-window refresh all refresh metadata.
func (w *muxWindow) piSessionTitle(sessionPath string, bridgeID string, now time.Time) string {
	w.piTitleMu.Lock()
	defer w.piTitleMu.Unlock()
	path := ""
	if bridgeID != "" {
		// Pi writes a new session's file only after its first prompt, and a
		// bridge can move to another session, so the lookup is retried.
		if w.piNativeSessionBridgeID != bridgeID ||
			now.Sub(w.piNativeSessionCheckedAt) >= nativePiSessionLookupInterval {
			w.piNativeSessionBridgeID = bridgeID
			w.piNativeSessionPath = nativePiSessionPath(bridgeID)
			w.piNativeSessionCheckedAt = now
		}
		path = w.piNativeSessionPath
	} else if filepath.IsAbs(sessionPath) &&
		strings.HasSuffix(strings.ToLower(sessionPath), ".jsonl") {
		path = filepath.Clean(sessionPath)
	}
	return w.piTitleScan.title(path)
}

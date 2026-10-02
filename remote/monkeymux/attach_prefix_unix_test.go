//go:build !windows

package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestAttachPrefixDetachesWithEnhancedKeyboardEncodings(t *testing.T) {
	for _, test := range []struct {
		name  string
		input []string
	}{
		{"kitty disambiguate", []string{"\x1b[98;5u", "d"}},
		{"kitty in one read", []string{"\x1b[98;5ud"}},
		{"kitty all keys as escapes", []string{"\x1b[98;5u", "\x1b[100u"}},
		{
			"kitty event types",
			[]string{"\x1b[98;5u", "\x1b[98;5:3u", "\x1b[57442;1:3u", "d"},
		},
		{"modifyOtherKeys", []string{"\x1b[27;5;98~", "d"}},
		{"legacy prefix with kitty command", []string{"\x02", "\x1b[100u"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			inputReader, inputWriter, err := os.Pipe()
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				_ = inputReader.Close()
				_ = inputWriter.Close()
			})
			server := newMuxServer("test")
			server.windows = []*muxWindow{
				{id: "@1", index: 0, pty: wrapPty(t, inputWriter), lastActivity: time.Now()},
			}
			server.activeID = "@1"
			client := registerTestAttachClient(t, server, &recordingConn{}, "keys", 80, 24)
			detached := false
			for _, chunk := range test.input {
				detached = server.handleAttachInput(client, []byte(chunk))
			}
			if !detached {
				t.Fatal("encoded Ctrl-B d did not detach")
			}
			select {
			case <-client.done:
			default:
				t.Fatal("encoded Ctrl-B d left the client open")
			}
		})
	}
}

func TestAttachPrefixWithKittyKeysForwardsOnlyWindowInput(t *testing.T) {
	firstReader, firstWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	secondReader, secondWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		for _, file := range []*os.File{firstReader, firstWriter, secondReader, secondWriter} {
			_ = file.Close()
		}
	})
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, pty: wrapPty(t, firstWriter), lastActivity: time.Now()},
		{id: "@2", index: 1, pty: wrapPty(t, secondWriter), lastActivity: time.Now()},
	}
	server.activeID = "@1"
	client := &attachClient{prefixEnabled: true}

	// Ordinary kitty keys pass through untouched, and the left-Ctrl press
	// reported before Ctrl-B belongs to the window. Ctrl-B, its release, and
	// the n command with its release are consumed.
	for _, chunk := range []string{
		"\x1b[99;5u",
		"\x1b[57442;5u",
		"\x1b[98;5u",
		"\x1b[98;5:3u",
		"\x1b[57442;1:3u",
		"\x1b[110u",
	} {
		if server.handleAttachInput(client, []byte(chunk)) {
			t.Fatalf("%q detached the client", chunk)
		}
	}
	if got := server.activeWindowID(); got != "@2" {
		t.Fatalf("active window = %q, want @2", got)
	}
	server.handleAttachInput(client, []byte("\x1b[110;1:3u"))
	// Ctrl-B Ctrl-B sends the key on as the terminal encoded it.
	server.handleAttachInput(client, []byte("\x1b[98;5u\x1b[98;5u\x1b[98;5:3u\x1b[98;5:3u"))
	server.handleAttachInput(client, []byte("x"))

	wantFirst := "\x1b[99;5u\x1b[57442;5u\x1b[57442;1:3u"
	if got := readPipeUntil(t, firstReader, func(output string) bool {
		return len(output) >= len(wantFirst)
	}); got != wantFirst {
		t.Fatalf("first window input = %q, want %q", got, wantFirst)
	}
	wantSecond := "\x1b[98;5u\x1b[98;5:3ux"
	if got := readPipeUntil(t, secondReader, func(output string) bool {
		return strings.HasSuffix(output, "x")
	}); got != wantSecond {
		t.Fatalf("second window input = %q, want %q", got, wantSecond)
	}
}

func TestAttachCloseConfirmationAcceptsKittyKeys(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		{id: "@2", index: 1, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	client := registerTestAttachClient(t, server, &recordingConn{}, "keys", 80, 24)

	// Shift-7 with alternate keys is &, and its release must not answer the
	// prompt before the y arrives.
	server.handleAttachInput(client, []byte("\x1b[98;5u\x1b[55:38;2u"))
	server.handleAttachInput(client, []byte("\x1b[55:38;2:3u"))
	if got := server.activeWindowID(); got != "@1" {
		t.Fatalf("window closed before confirmation: active = %q", got)
	}
	server.handleAttachInput(client, []byte("\x1b[121u"))
	if got := server.activeWindowID(); got != "@2" {
		t.Fatalf("active window after close = %q, want @2", got)
	}
}

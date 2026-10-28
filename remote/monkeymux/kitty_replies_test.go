package main

import (
	"fmt"
	"strings"
	"testing"
)

func kittyRoutedActions(routing attachInputRouting) string {
	var parts []string
	for _, action := range routing.actions {
		if action.userInput {
			parts = append(parts, fmt.Sprintf("input %q", action.data))
		} else {
			parts = append(parts, fmt.Sprintf("%s %q", action.windowID, action.data))
		}
	}
	return strings.Join(parts, "; ")
}

// TestKittyRepliesReachTheWindowThatAsked covers a graphics reply that
// arrives after the window that sent the command lost focus: it used to be
// typed into the window that had it.
func TestKittyRepliesReachTheWindowThatAsked(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	first := &muxWindow{id: "@1"}
	second := &muxWindow{id: "@2"}
	server.windows = []*muxWindow{first, second}
	server.activeID = first.id
	server.handleWindowOutput(first.id, []byte(
		"\x1b_Ga=T,i=1,f=100;AAAA\x1b\\\x1b_Ga=t,I=7,f=100;AAAA\x1b\\"+
			"\x1b_Ga=t,i=9,q=2,f=100;AAAA\x1b\\"))
	server.activeID = second.id

	client := &attachClient{kittyReplyRoutes: &server.kittyReplyRoutes}
	routing := client.routeInput([]byte(
		"\x1b_Gi=1;OK\x1b\\x\x1b_Gi=4,I=7;OK\x1b\\" +
			// Nothing asked about image 9 with replies on: dropped.
			"\x1b_Gi=9;EINVAL: invalid PNG data\x1b\\y"))
	want := `@1 "\x1b_Gi=1;OK\x1b\\"; @1 "\x1b_Gi=4,I=7;OK\x1b\\"; input "xy"`
	if got := kittyRoutedActions(routing); got != want {
		t.Fatalf("routed %s\nwant   %s", got, want)
	}
}

func TestKittyReplyCutByAReadIsHeldOnce(t *testing.T) {
	routes := &kittyReplyRoutes{}
	routes.note("@1", []byte("\x1b_Ga=p,i=3,p=1\x1b\\"))
	client := &attachClient{kittyReplyRoutes: routes}

	first := client.routeInput([]byte("a\x1b_Gi=3,p=1;EN"))
	second := client.routeInput([]byte("OENT: image not found\x1b\\b"))
	got := kittyRoutedActions(first) + " | " + kittyRoutedActions(second)
	want := `input "a" | @1 "\x1b_Gi=3,p=1;ENOENT: image not found\x1b\\"; input "b"`
	if got != want {
		t.Fatalf("routed %s\nwant   %s", got, want)
	}

	// Input that only starts like a reply is held for one read at most.
	client.routeInput([]byte("\x1b_Gx"))
	if got := kittyRoutedActions(client.routeInput([]byte("yz"))); got != `input "\x1b_Gxyz"` {
		t.Fatalf("held input routed as %s", got)
	}
}

func TestKittyRepliesAreNotCountedAsQueryReplies(t *testing.T) {
	if got := terminalQueryResponseCount(
		[]byte("\x1b_Ga=q,i=1,f=100;AAAA\x1b\\\x1b[c"),
	); got != 1 {
		t.Fatalf("expected replies = %d, want 1 (DA1 only)", got)
	}
}

func TestReplayedGraphicsCommandsAreSilenced(t *testing.T) {
	replay := string(stripTerminalQueriesFromReplay([]byte(
		"a\x1b_Ga=T,i=1,f=100;AAAA\x1b\\b" +
			"\x1b_Ga=p,i=1,p=2,q=1\x1b\\" +
			"\x1b_Ga=t,i=2,q=2;AAAA\x1b\\" +
			"\x1b_Ga=q,i=3;AAAA\x1b\\c")))
	want := "a\x1b_Ga=T,i=1,f=100,q=2;AAAA\x1b\\b" +
		"\x1b_Ga=p,i=1,p=2,q=2\x1b\\" +
		"\x1b_Ga=t,i=2,q=2;AAAA\x1b\\c"
	if replay != want {
		t.Fatalf("replay = %q\nwant     %q", replay, want)
	}
}

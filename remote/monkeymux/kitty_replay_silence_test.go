package main

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestReplayedGraphicsCommandsAreSilenced(t *testing.T) {
	replay := string(stripTerminalQueriesFromReplay([]byte(
		"a\x1b_Ga=T,I=1,f=100;AAAA\x1b\\b" +
			"\x1b_Ga=f,i=1,q=1;AAAA\x1b\\" +
			"\x1b_Ga=t,i=2,q=2;AAAA\x1b\\" +
			"\x1b_Ga=q,i=3;AAAA\x1b\\c")))
	want := "a\x1b_Ga=T,I=1,f=100,q=2;AAAA\x1b\\b" +
		"\x1b_Ga=f,i=1,q=2;AAAA\x1b\\" +
		"\x1b_Ga=t,i=2,q=2;AAAA\x1b\\c"
	if replay != want {
		t.Fatalf("replay = %q\nwant     %q", replay, want)
	}

	// The replay scanner also takes the 8-bit APC introducer and ST, which
	// keep their place around the quiet flag. The app ends a command only at
	// ESC \ and reads a raw 0x9c inside it as a replacement character, so it
	// runs the first one to the ESC \ that follows: silently.
	replay = string(stripTerminalQueriesFromReplay([]byte(
		"a\x1b_Ga=T,I=1,f=24,s=1,v=1;AAAA\x9c\x1b\\b" +
			"\x9fGa=t,i=4;AAAA\x1b\\" +
			"\x9fGa=d,i=4\x9c" +
			"\x1b_Ga=f,i=1,q=1;AAAA\x9c" +
			"\x9fGa=t,i=5,q=2\x9cc")))
	want = "a\x1b_Ga=T,I=1,f=24,s=1,v=1,q=2;AAAA\x9c\x1b\\b" +
		"\x9fGa=t,i=4,q=2;AAAA\x1b\\" +
		"\x9fGa=d,i=4,q=2\x9c" +
		"\x1b_Ga=f,i=1,q=2;AAAA\x9c" +
		"\x9fGa=t,i=5,q=2\x9cc"
	if replay != want {
		t.Fatalf("8-bit replay = %q\nwant           %q", replay, want)
	}
}

// TestBackgroundKittyQueryReplyReachesItsWindow covers a capability probe a
// window sends while in the background: it is held, sent when the user
// switches to the window, and its reply, OK or an error, goes back to that
// window as a reply rather than as typed input.
func TestBackgroundKittyQueryReplyReachesItsWindow(t *testing.T) {
	for _, reply := range []string{
		"\x1b_Gi=7;OK\x1b\\",
		"\x1b_Gi=7;EINVAL: invalid PNG data\x1b\\",
	} {
		t.Run(reply, func(t *testing.T) {
			server := newMuxServer("kitty-probe")
			background := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
			server.windows = []*muxWindow{
				{id: "@1", index: 0, lastActivity: time.Now()},
				background,
			}
			server.activeID = "@1"
			attach := &recordingConn{}
			client := registerTestAttachClient(
				t, server, attach, "primary", server.width, server.height,
			)
			probe := "\x1b_Ga=q,i=7,s=1,v=1,f=24,t=d;AAAA\x1b\\"
			server.handleWindowOutput("@2", []byte(probe))
			server.mu.Lock()
			pending := string(background.pendingTerminalQueries)
			server.mu.Unlock()
			if pending != probe {
				t.Fatalf("pending queries = %q, want the probe held", pending)
			}

			restore := stubForegroundResize(t)
			defer restore()
			if err := server.selectWindow("@2"); err != nil {
				t.Fatal(err)
			}
			waitForTestAttachWrites(t, server)
			if !strings.Contains(attach.String(), probe) {
				t.Fatalf("switch output = %q, want the probe", attach.String())
			}

			routing := client.routeInput([]byte(reply))
			var got []string
			for _, action := range routing.actions {
				got = append(got, fmt.Sprintf("%v %s %q",
					action.userInput, action.windowID, action.data))
			}
			want := fmt.Sprintf("false @2 %q", reply)
			if strings.Join(got, "; ") != want {
				t.Fatalf("reply routed as %v, want %s", got, want)
			}
		})
	}
}

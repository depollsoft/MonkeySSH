//go:build !windows

package main

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeAgent listens on a unix socket and answers each connection with name,
// standing in for the agent socket sshd creates for one connection.
func fakeAgent(t *testing.T, dir string, name string) (string, func()) {
	t.Helper()
	path := filepath.Join(dir, name)
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen %s: %v", path, err)
	}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			_, _ = conn.Write([]byte(name + "\n"))
			_ = conn.Close()
		}
	}()
	stop := func() { _ = listener.Close() }
	t.Cleanup(stop)
	return path, stop
}

func dialAgentName(t *testing.T, path string) string {
	t.Helper()
	conn, err := net.DialTimeout("unix", path, time.Second)
	if err != nil {
		t.Fatalf("dial %s: %v", path, err)
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		t.Fatalf("read from %s: %v", path, err)
	}
	return strings.TrimSpace(line)
}

func environmentValue(env []string, key string) (string, int) {
	value := ""
	count := 0
	for _, entry := range env {
		if strings.HasPrefix(entry, key+"=") {
			value = strings.TrimPrefix(entry, key+"=")
			count++
		}
	}
	return value, count
}

func TestLinkForwardedAgentFollowsTheLatestConnection(t *testing.T) {
	runtimeRoot := shortUnixSocketDir(t)
	t.Setenv("XDG_RUNTIME_DIR", runtimeRoot)
	sockets := shortUnixSocketDir(t)
	link, err := forwardedAgentLinkPath()
	if err != nil {
		t.Fatal(err)
	}

	first, stopFirst := fakeAgent(t, sockets, "first")
	t.Setenv(sshAuthSockVariable, first)
	linkForwardedAgent()
	if got := dialAgentName(t, link); got != "first" {
		t.Fatalf("link reached %q, want first", got)
	}

	// The phone reconnects: sshd removes the old socket and makes a new one.
	stopFirst()
	second, _ := fakeAgent(t, sockets, "second")
	t.Setenv(sshAuthSockVariable, second)
	linkForwardedAgent()
	if got := dialAgentName(t, link); got != "second" {
		t.Fatalf("link reached %q after reconnect, want second", got)
	}
	matches, _ := filepath.Glob(link + ".tmp-*")
	if len(matches) != 0 {
		t.Fatalf("temporary links left behind: %v", matches)
	}
}

func TestLinkForwardedAgentIgnoresUnusableSockets(t *testing.T) {
	runtimeRoot := shortUnixSocketDir(t)
	t.Setenv("XDG_RUNTIME_DIR", runtimeRoot)
	sockets := shortUnixSocketDir(t)
	link, err := forwardedAgentLinkPath()
	if err != nil {
		t.Fatal(err)
	}
	live, _ := fakeAgent(t, sockets, "live")
	t.Setenv(sshAuthSockVariable, live)
	linkForwardedAgent()

	regular := filepath.Join(sockets, "not-a-socket")
	if err := os.WriteFile(regular, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{"", "   ", filepath.Join(sockets, "missing"), regular, link} {
		t.Setenv(sshAuthSockVariable, value)
		linkForwardedAgent()
		if got := dialAgentName(t, link); got != "live" {
			t.Fatalf("SSH_AUTH_SOCK=%q repointed the link to %q", value, got)
		}
	}
}

func TestWithForwardedAgentSocketWaitsForAForwardingConnection(t *testing.T) {
	runtimeRoot := shortUnixSocketDir(t)
	t.Setenv("XDG_RUNTIME_DIR", runtimeRoot)
	sockets := shortUnixSocketDir(t)
	base := []string{"HOME=/home/dev", sshAuthSockVariable + "=/host/agent"}

	if got := withForwardedAgentSocket(base); strings.Join(got, "\n") != strings.Join(base, "\n") {
		t.Fatalf("env changed before any forwarding connection: %v", got)
	}

	agent, _ := fakeAgent(t, sockets, "phone")
	t.Setenv(sshAuthSockVariable, agent)
	linkForwardedAgent()
	link, _ := forwardedAgentLinkPath()
	value, count := environmentValue(withForwardedAgentSocket(base), sshAuthSockVariable)
	if value != link || count != 1 {
		t.Fatalf("SSH_AUTH_SOCK = %q (%d entries), want only %q", value, count, link)
	}
}

func TestWithForwardedAgentSocketIgnoresADeadLink(t *testing.T) {
	runtimeRoot := shortUnixSocketDir(t)
	t.Setenv("XDG_RUNTIME_DIR", runtimeRoot)
	sockets := shortUnixSocketDir(t)
	base := []string{"HOME=/home/dev", sshAuthSockVariable + "=/host/agent"}

	agent, stop := fakeAgent(t, sockets, "phone")
	t.Setenv(sshAuthSockVariable, agent)
	linkForwardedAgent()
	// The forwarding connection closes and sshd removes its socket.
	stop()
	_ = os.Remove(agent)

	if got := withForwardedAgentSocket(base); strings.Join(got, "\n") != strings.Join(base, "\n") {
		t.Fatalf("a dead link replaced the server's agent: %v", got)
	}
}

func TestWindowsKeepReachingTheAgentAcrossReconnects(t *testing.T) {
	setTestHomeDir(t, t.TempDir())
	t.Setenv("SHELL", "/bin/sh")
	runtimeRoot := shortUnixSocketDir(t)
	t.Setenv("XDG_RUNTIME_DIR", runtimeRoot)
	sockets := shortUnixSocketDir(t)
	output := t.TempDir()

	// The server keeps the environment of the connection that started it.
	first, stopFirst := fakeAgent(t, sockets, "first")
	t.Setenv(sshAuthSockVariable, first)
	linkForwardedAgent()
	server := newMuxServerWithSize("agent-link", 80, 24)
	t.Cleanup(server.close)

	startWindow := func(name string) string {
		path := filepath.Join(output, name)
		_, err := server.createWindow(createWindowOptions{
			args: []string{"/bin/sh", "-c", `printf %s "$SSH_AUTH_SOCK" > "$0"; sleep 2`, path},
		})
		if err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if raw, err := os.ReadFile(path); err == nil && len(raw) > 0 {
				return string(raw)
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatalf("window %s never reported SSH_AUTH_SOCK", name)
		return ""
	}

	before := startWindow("before")
	link, _ := forwardedAgentLinkPath()
	if before != link {
		t.Fatalf("window SSH_AUTH_SOCK = %q, want the stable link %q", before, link)
	}

	// Reconnect without restarting the server: only the client command that
	// carries the new connection's socket runs.
	stopFirst()
	second, _ := fakeAgent(t, sockets, "second")
	t.Setenv(sshAuthSockVariable, second)
	linkForwardedAgent()

	if got := dialAgentName(t, before); got != "second" {
		t.Fatalf("existing window's agent path reached %q, want second", got)
	}
	if after := startWindow("after"); after != link {
		t.Fatalf("new window SSH_AUTH_SOCK = %q, want %q", after, link)
	}
}

func TestOnlyConnectionClientsRepointTheAgent(t *testing.T) {
	for _, command := range []string{"attach", "a", "at", "attach-session", "new", "new-session", "control", "acp"} {
		if !commandRepointsForwardedAgent(command) {
			t.Fatalf("%s should repoint the agent link", command)
		}
	}
	for _, command := range []string{"serve", "agent-launch", "agent-identity-hook", "pi-agent", "version", "gc"} {
		if commandRepointsForwardedAgent(command) {
			t.Fatalf("%s must not repoint the agent link", command)
		}
	}
}

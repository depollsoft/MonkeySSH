//go:build !windows

package main

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
)

// sshAuthSockVariable names the agent socket that ssh(1), git and ssh-add use.
const sshAuthSockVariable = "SSH_AUTH_SOCK"

// forwardedAgentLinkName is the stable agent path MonkeyMux gives windows.
//
// sshd creates a new agent socket for every forwarding connection and deletes
// it when that connection closes, while the server and its windows outlive
// connections. Windows therefore get this symlink instead, and every client
// command from a forwarding connection repoints it at that connection's
// socket, so a window started before a reconnect still reaches the agent the
// phone is forwarding now. It is the same trick tmux users put in their
// shell profiles, done for them.
const forwardedAgentLinkName = "agent.sock"

func forwardedAgentLinkPath() (string, error) {
	dir, err := runtimeDirectory()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, forwardedAgentLinkName), nil
}

// linkForwardedAgent points the stable agent link at this process's
// SSH_AUTH_SOCK when that is a live socket other than the link itself. It is
// best effort: without a forwarded agent nothing changes, and a failure leaves
// the previous target in place.
func linkForwardedAgent() {
	target := strings.TrimSpace(os.Getenv(sshAuthSockVariable))
	if target == "" {
		return
	}
	link, err := forwardedAgentLinkPath()
	if err != nil {
		return
	}
	if absTarget, err := filepath.Abs(target); err == nil {
		target = absTarget
	}
	if target == link {
		return
	}
	info, err := os.Stat(target)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		return
	}
	if current, err := os.Readlink(link); err == nil && current == target {
		return
	}
	var suffix [6]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return
	}
	temp := link + ".tmp-" + hex.EncodeToString(suffix[:])
	if err := os.Symlink(target, temp); err != nil {
		return
	}
	// rename(2) replaces the link atomically, so a window never sees it
	// missing while it is repointed.
	if err := os.Rename(temp, link); err != nil {
		_ = os.Remove(temp)
	}
}

// withForwardedAgentSocket points SSH_AUTH_SOCK in env at the stable agent
// link while it leads to a live agent socket. Otherwise env is left alone: a
// host that never forwards, or whose last forwarding connection has closed
// and taken its socket with it, keeps whatever agent the server inherited.
func withForwardedAgentSocket(env []string) []string {
	link, err := forwardedAgentLinkPath()
	if err != nil {
		return env
	}
	linkInfo, err := os.Lstat(link)
	if err != nil || linkInfo.Mode()&os.ModeSymlink == 0 {
		return env
	}
	target, err := os.Stat(link)
	if err != nil || target.Mode()&os.ModeSocket == 0 {
		return env
	}
	prefix := sshAuthSockVariable + "="
	result := make([]string, 0, len(env)+1)
	for _, entry := range env {
		if !strings.HasPrefix(entry, prefix) {
			result = append(result, entry)
		}
	}
	return append(result, prefix+link)
}

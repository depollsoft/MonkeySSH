package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestReadWriteSessionPIDFileRoundTrip(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("pid-roundtrip-%d", time.Now().UnixNano())
	if err := writeSessionPIDFile(session, os.Getpid()); err != nil {
		t.Fatalf("writeSessionPIDFile: %v", err)
	}
	if got := readSessionPID(session); got != os.Getpid() {
		t.Fatalf("readSessionPID = %d, want %d", got, os.Getpid())
	}
	removeSessionPIDFile(session)
	if got := readSessionPID(session); got != 0 {
		t.Fatalf("readSessionPID after remove = %d, want 0", got)
	}
}

func TestRemoveSessionPIDFileKeepsOtherOwners(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("pid-other-%d", time.Now().UnixNano())
	if err := writeSessionPIDFile(session, os.Getpid()+100000); err != nil {
		t.Fatalf("writeSessionPIDFile: %v", err)
	}
	removeSessionPIDFile(session)
	if got := readSessionPID(session); got == 0 {
		t.Fatal("removeSessionPIDFile deleted another process's pid file")
	}
}

func TestAcquireSessionLockSerializesAndClearsStaleLocks(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("lock-%d", time.Now().UnixNano())
	unlock, err := acquireSessionLock(session)
	if err != nil {
		t.Fatalf("acquireSessionLock: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		secondUnlock, err := acquireSessionLock(session)
		if err != nil {
			done <- err
			return
		}
		secondUnlock()
		done <- nil
	}()

	select {
	case err := <-done:
		t.Fatalf("second lock acquired while first held: %v", err)
	case <-time.After(150 * time.Millisecond):
	}

	unlock()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("second lock after unlock: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("second lock did not acquire after unlock")
	}

	lockPath, err := sessionLockPath(session)
	if err != nil {
		t.Fatalf("sessionLockPath: %v", err)
	}
	if err := os.WriteFile(lockPath, []byte("99999999\n"), 0o600); err != nil {
		t.Fatalf("write stale lock: %v", err)
	}
	unlock, err = acquireSessionLock(session)
	if err != nil {
		t.Fatalf("acquireSessionLock with stale lock: %v", err)
	}
	unlock()
}

func TestEnsureServerRefusesToStealLivePIDWithoutSocket(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("steal-%d", time.Now().UnixNano())
	if err := writeSessionPIDFile(session, os.Getpid()); err != nil {
		t.Fatalf("writeSessionPIDFile: %v", err)
	}

	err := ensureServer(
		session,
		createWindowOptions{command: "copilot --yolo", name: "Copilot CLI"},
		serverUpdatePolicyNever,
		false,
		80,
		24,
		false,
	)
	if err == nil {
		t.Fatal("ensureServer stole a live session pid")
	}
	if !strings.Contains(err.Error(), "not accepting connections") {
		t.Fatalf("ensureServer error = %q, want not-accepting message", err)
	}

	socket, err := socketPath(session)
	if err != nil {
		t.Fatalf("socketPath: %v", err)
	}
	if _, err := os.Stat(socket); !os.IsNotExist(err) {
		t.Fatalf("socket path state = %v, want missing", err)
	}
}

func TestRemoveSocketPathIfUnchangedKeepsReboundListener(t *testing.T) {
	dir := shortUnixSocketDir(t)
	path := filepath.Join(dir, "old.sock")

	old, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen old: %v", err)
	}
	disableUnixListenerUnlink(old)
	oldIdentity, err := socketFileIdentity(path)
	if err != nil && runtime.GOOS != "windows" {
		t.Fatalf("old identity: %v", err)
	}

	_ = os.Remove(path)
	replacement, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen replacement: %v", err)
	}
	t.Cleanup(func() {
		_ = replacement.Close()
		_ = os.Remove(path)
	})
	disableUnixListenerUnlink(replacement)

	removeSocketPathIfUnchanged(path, oldIdentity)
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("outgoing close deleted the rebound socket: %v", err)
	}
	conn, err := net.DialTimeout("unix", path, 200*time.Millisecond)
	if err != nil {
		t.Fatalf("dial rebound socket: %v", err)
	}
	_ = conn.Close()
	_ = old.Close()
}

func TestRepublishSocketIfMissingRestoresUnlinkedPath(t *testing.T) {
	dir := shortUnixSocketDir(t)
	path := filepath.Join(dir, "new.sock")

	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	disableUnixListenerUnlink(listener)
	identity, err := socketFileIdentity(path)
	if err != nil && runtime.GOOS != "windows" {
		t.Fatalf("identity: %v", err)
	}

	server := newMuxServerWithSize("republish", 80, 24)
	server.listener = listener
	server.socketPath = path
	server.socketIdentity = identity
	t.Cleanup(func() {
		server.close()
	})

	accepted := make(chan net.Conn, 1)
	acceptErr := make(chan error, 1)
	go func() {
		conn, err := server.acceptConnection()
		if err != nil {
			acceptErr <- err
			return
		}
		accepted <- conn
	}()

	if err := os.Remove(path); err != nil {
		t.Fatalf("unlink: %v", err)
	}
	if !server.republishSocketIfMissing() {
		t.Fatal("republish stopped while the server was still open")
	}
	conn, err := net.DialTimeout("unix", path, 200*time.Millisecond)
	if err != nil {
		t.Fatalf("dial republished socket: %v", err)
	}
	defer conn.Close()
	select {
	case acceptedConn := <-accepted:
		_ = acceptedConn.Close()
	case err := <-acceptErr:
		t.Fatalf("accept republished socket: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("acceptConnection stayed blocked on the unlinked listener")
	}
}

func TestCloseWaitsForInFlightSocketRepublisher(t *testing.T) {
	dir := shortUnixSocketDir(t)
	path := filepath.Join(dir, "closing.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	disableUnixListenerUnlink(listener)
	identity, err := socketFileIdentity(path)
	if err != nil && runtime.GOOS != "windows" {
		t.Fatalf("identity: %v", err)
	}

	server := newMuxServerWithSize("closing-republish", 80, 24)
	server.listener = listener
	server.socketPath = path
	server.socketIdentity = identity
	if err := os.Remove(path); err != nil {
		t.Fatalf("unlink: %v", err)
	}

	entered := make(chan struct{})
	release := make(chan struct{})
	var releaseOnce sync.Once
	unblockRepublisher := func() {
		releaseOnce.Do(func() { close(release) })
	}
	server.beforeInstallRepublishedSocket = func() {
		close(entered)
		<-release
	}
	t.Cleanup(func() {
		unblockRepublisher()
		server.close()
	})

	server.socketRepublishers.Add(1)
	go func() {
		defer server.socketRepublishers.Done()
		server.republishSocketIfMissing()
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("republisher did not bind a replacement listener")
	}

	closed := make(chan struct{})
	go func() {
		server.close()
		close(closed)
	}()
	select {
	case <-closed:
		t.Fatal("close returned before the republisher finished")
	case <-time.After(150 * time.Millisecond):
	}

	unblockRepublisher()
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
		t.Fatal("close did not finish after republisher cleanup")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("republisher left socket path after close: %v", err)
	}
}

func TestWaitForServerProcessExitWaitsForLiveOwner(t *testing.T) {
	owner := pidRecord{pid: os.Getpid(), writtenAt: time.Now()}
	if waitForServerProcessExit("wait-owner", owner, 150*time.Millisecond) {
		t.Fatal("waitForServerProcessExit treated a live pid as exited")
	}
}

func TestWaitForServerProcessExitChecksOnceAtDeadline(t *testing.T) {
	owner := pidRecord{pid: 99999999, writtenAt: time.Now()}
	if !waitForServerProcessExit("wait-dead-owner", owner, 0) {
		t.Fatal("waitForServerProcessExit skipped the final ownership check")
	}
}

func TestServerExitWaitAllowsWindowWatcherShutdownMargin(t *testing.T) {
	if serverExitWaitTimeout <= windowWatcherShutdownTimeout {
		t.Fatalf(
			"server exit wait %s must exceed watcher shutdown bound %s",
			serverExitWaitTimeout,
			windowWatcherShutdownTimeout,
		)
	}
}

func TestPrepareRunningServerReplacementKeepsServerWithoutSnapshot(
	t *testing.T,
) {
	// A version-skewed server that cannot be dialed yields no restore snapshot.
	// Replacement must be refused rather than green-lighting an empty recreate
	// (the lost-windows failure mode after auto-connect attach).
	isolateTestRuntime(t)

	session := fmt.Sprintf("nosnap-%d", time.Now().UnixNano())
	outcome, err := prepareRunningServerReplacement(
		session,
		runningServerStatus{
			version: "0.0.1",
			capabilities: []string{
				"shutdown",
				"upgrade-restore-v1",
				"window-list",
			},
		},
		serverUpdatePolicyAlways,
		false,
	)
	if !errors.Is(err, errServerUpdateNoSnapshot) {
		t.Fatalf(
			"prepareRunningServerReplacement error = %v, want %v",
			err,
			errServerUpdateNoSnapshot,
		)
	}
	if outcome != nil {
		t.Fatalf("replacement = %#v, want nil when snapshot fails", outcome)
	}
}

func TestPrepareRunningServerReplacementNoopsForCurrentVersion(t *testing.T) {
	outcome, err := prepareRunningServerReplacement(
		"current",
		runningServerStatus{version: monkeyMuxVersion},
		serverUpdatePolicyAlways,
		false,
	)
	if err != nil {
		t.Fatalf("prepareRunningServerReplacement: %v", err)
	}
	if outcome != nil {
		t.Fatalf("replacement = %#v, want nil for current version", outcome)
	}
}

func TestPrepareRunningServerReplacementForceRequiresSnapshotForCurrentVersion(t *testing.T) {
	isolateTestRuntime(t)
	outcome, err := prepareRunningServerReplacement(
		fmt.Sprintf("force-nosnap-%d", time.Now().UnixNano()),
		runningServerStatus{version: monkeyMuxVersion},
		serverUpdatePolicyForce,
		false,
	)
	if !errors.Is(err, errServerUpdateNoSnapshot) || outcome != nil {
		t.Fatalf("forced replacement = (%#v, %v), want (nil, %v)", outcome, err, errServerUpdateNoSnapshot)
	}
}

func TestKeepRespondingServerBeforeReplacement(t *testing.T) {
	shutdown := &ensureServerReplacement{oldPID: pidRecord{pid: 10}}
	legacy := &ensureServerReplacement{oldPID: pidRecord{pid: 10}, legacyHandoff: true}
	native := &ensureServerReplacement{oldPID: pidRecord{pid: 10}, legacyHandoff: true, keepOldProcess: true}
	for _, test := range []struct {
		name        string
		policy      string
		version     string
		pid         int
		replacement *ensureServerReplacement
		keep        bool
		wantErr     error
	}{
		{"no replacement", serverUpdatePolicyForce, monkeyMuxVersion, 10, nil, true, nil},
		{"normal concurrent replacement", serverUpdatePolicyAlways, monkeyMuxVersion, 20, shutdown, true, nil},
		{"normal old server", serverUpdatePolicyAlways, "0.1.0", 10, legacy, false, nil},
		{"force same pid same version", serverUpdatePolicyForce, monkeyMuxVersion, 10, shutdown, false, errServerUpdateStillAlive},
		{"force same pid old version", serverUpdatePolicyForce, "0.1.0", 10, shutdown, false, errServerUpdateStillAlive},
		{"force different pid same version", serverUpdatePolicyForce, monkeyMuxVersion, 20, shutdown, true, nil},
		{"force different pid old version", serverUpdatePolicyForce, "0.1.0", 20, shutdown, true, nil},
		{"force current pid unknown", serverUpdatePolicyForce, monkeyMuxVersion, 0, shutdown, false, errServerUpdateStillAlive},
		{"force outgoing pid unknown", serverUpdatePolicyForce, monkeyMuxVersion, 20, &ensureServerReplacement{}, false, errServerUpdateStillAlive},
		{"force legacy outgoing", serverUpdatePolicyForce, monkeyMuxVersion, 10, legacy, false, nil},
		{"force legacy unknown pid", serverUpdatePolicyForce, monkeyMuxVersion, 0, legacy, false, nil},
		{"force legacy concurrent replacement", serverUpdatePolicyForce, monkeyMuxVersion, 20, legacy, true, nil},
		{"force native outgoing", serverUpdatePolicyForce, monkeyMuxVersion, 10, native, false, nil},
		{"force native concurrent replacement", serverUpdatePolicyForce, monkeyMuxVersion, 20, native, true, nil},
	} {
		t.Run(test.name, func(t *testing.T) {
			keep, err := keepRespondingServerBeforeReplacement(
				runningServerStatus{version: test.version}, pidRecord{pid: test.pid}, test.replacement, test.policy,
			)
			if keep != test.keep || !errors.Is(err, test.wantErr) {
				t.Fatalf("guard = (%t, %v), want (%t, %v)", keep, err, test.keep, test.wantErr)
			}
		})
	}
}

// startForeignProcess starts a long-lived process that is not a MonkeyMux
// helper, so tests can exercise the recycled-pid paths with a pid that really
// is alive on this host.
func startForeignProcess(t *testing.T) int {
	t.Helper()
	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		cmd = exec.Command("ping", "-n", "120", "127.0.0.1")
	} else {
		cmd = exec.Command("sleep", "120")
	}
	if err := cmd.Start(); err != nil {
		t.Skipf("cannot start helper process: %v", err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})
	return cmd.Process.Pid
}

func TestSessionServerOwnerKeepsCurrentOwner(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("owner-%d", time.Now().UnixNano())
	if err := writeSessionPIDFile(session, os.Getpid()); err != nil {
		t.Fatalf("writeSessionPIDFile: %v", err)
	}
	owner, ownership := sessionServerOwner(session)
	if owner.pid != os.Getpid() {
		t.Fatalf("owner pid = %d, want %d", owner.pid, os.Getpid())
	}
	if ownership == pidOwnershipGone {
		t.Fatal("this process reported as a departed owner")
	}
}

func TestSessionServerOwnerClearsDeadOwner(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("dead-%d", time.Now().UnixNano())
	path, err := sessionPIDPath(session)
	if err != nil {
		t.Fatalf("sessionPIDPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte("99999999\n"), 0o600); err != nil {
		t.Fatalf("write pid file: %v", err)
	}
	if owner, ownership := sessionServerOwner(session); ownership != pidOwnershipGone {
		t.Fatalf("ownership = %v (pid %d), want %v for a dead process", ownership, owner.pid, pidOwnershipGone)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("pid file state = %v, want removed", err)
	}
}

// A pid file that outlives its server (SIGKILL, crash, host reboot) must not
// permanently block the session once the operating system hands that pid to an
// unrelated process. Otherwise every attach falls back to a login shell with
// "is running (pid N) but not accepting connections".
func TestSessionServerOwnerClearsRecycledPID(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("recycled-%d", time.Now().UnixNano())
	path, err := sessionPIDPath(session)
	if err != nil {
		t.Fatalf("sessionPIDPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(recycledPIDFileContents()), 0o600); err != nil {
		t.Fatalf("write pid file: %v", err)
	}
	agePIDFileBeforeThisProcess(t, path)
	if owner, ownership := sessionServerOwner(session); ownership != pidOwnershipGone {
		t.Fatalf("ownership = %v (pid %d), want %v for a recycled pid", ownership, owner.pid, pidOwnershipGone)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("pid file state = %v, want removed", err)
	}
	// ensureServer consults exactly this result, so a gone owner is what lets
	// it start instead of reporting "not accepting connections" forever.
	if owner, ownership := sessionServerOwner(session); ownership != pidOwnershipGone ||
		owner.pid != 0 {
		t.Fatalf(
			"second resolve = %v (pid %d), want %v with no owner",
			ownership,
			owner.pid,
			pidOwnershipGone,
		)
	}
}

// Pid files written before identities were recorded carry only a number, so a
// recycled pid is detected by checking the running process image instead.
func TestSessionServerOwnerClearsLegacyForeignPID(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("legacy-%d", time.Now().UnixNano())
	path, err := sessionPIDPath(session)
	if err != nil {
		t.Fatalf("sessionPIDPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	foreign := startForeignProcess(t)
	contents := fmt.Sprintf("%d\n", foreign)
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("write pid file: %v", err)
	}
	if owner, ownership := sessionServerOwner(session); ownership != pidOwnershipGone {
		t.Fatalf("ownership = %v (pid %d), want %v for a foreign process", ownership, owner.pid, pidOwnershipGone)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("pid file state = %v, want removed", err)
	}
}

func TestAcquireSessionLockClearsLockHeldByRecycledPID(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("lock-recycled-%d", time.Now().UnixNano())
	path, err := sessionLockPath(session)
	if err != nil {
		t.Fatalf("sessionLockPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(recycledPIDFileContents()), 0o600); err != nil {
		t.Fatalf("write lock file: %v", err)
	}
	agePIDFileBeforeThisProcess(t, path)

	unlock, err := acquireSessionLock(session)
	if err != nil {
		t.Fatalf("acquireSessionLock with recycled pid lock: %v", err)
	}
	unlock()
}

func TestAcquireSessionLockClearsAbandonedUnparseableLock(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("lock-corrupt-%d", time.Now().UnixNano())
	path, err := sessionLockPath(session)
	if err != nil {
		t.Fatalf("sessionLockPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatalf("write lock file: %v", err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	unlock, err := acquireSessionLock(session)
	if err != nil {
		t.Fatalf("acquireSessionLock with abandoned lock: %v", err)
	}
	unlock()
}

func TestGCKeepsPIDAndLockFilesOfLiveOwners(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("gc-%d", time.Now().UnixNano())
	if err := writeSessionPIDFile(session, os.Getpid()); err != nil {
		t.Fatalf("writeSessionPIDFile: %v", err)
	}
	pidPath, err := sessionPIDPath(session)
	if err != nil {
		t.Fatalf("sessionPIDPath: %v", err)
	}

	dead := fmt.Sprintf("gc-dead-%d", time.Now().UnixNano())
	deadPath, err := sessionPIDPath(dead)
	if err != nil {
		t.Fatalf("sessionPIDPath: %v", err)
	}
	if err := os.WriteFile(deadPath, []byte("99999999\n"), 0o600); err != nil {
		t.Fatalf("write dead pid file: %v", err)
	}

	gcCommand()

	if _, err := os.Stat(pidPath); err != nil {
		t.Fatalf("gc removed the pid file of a live owner: %v", err)
	}
	if _, err := os.Stat(deadPath); !os.IsNotExist(err) {
		t.Fatalf("gc kept a dead pid file: %v", err)
	}
}

func TestGCSocketFailures(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", shortUnixSocketDir(t))
	dir, err := runtimeDirectory()
	if err != nil {
		t.Fatal(err)
	}
	for _, live := range []bool{true, false} {
		path := filepath.Join(dir, fmt.Sprintf("monkeymux-%t.sock", live))
		listener, err := net.Listen("unix", path)
		if err != nil {
			t.Fatal(err)
		}
		disableUnixListenerUnlink(listener)
		t.Cleanup(func() { _ = listener.Close() })
		if !live {
			_ = listener.Close()
		}
		gcCommand()
		_, err = os.Stat(path)
		if live && err != nil {
			t.Fatalf("gc removed a live socket: %v", err)
		}
		if !live && !os.IsNotExist(err) {
			t.Fatalf("gc kept an abandoned socket: %v", err)
		}
	}
	t.Run("unconfirmed failure", func(t *testing.T) {
		if runtime.GOOS == "windows" {
			t.Skip("Windows reports symlink loops as connection refused, a confirmed stale-socket error")
		}
		path := filepath.Join(dir, "monkeymux-loop.sock")
		if err := os.Symlink(path, path); err != nil {
			t.Skipf("symlink unavailable: %v", err)
		}
		gcCommand()
		if _, err := os.Lstat(path); err != nil {
			t.Fatalf("gc removed a path after an unconfirmed failure: %v", err)
		}
	})
}

func TestGCKeepsInFlightRestoreSnapshots(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("restore-gc-%d", time.Now().UnixNano())
	fresh, err := writeRestoreFile(session, &serverRestore{})
	if err != nil {
		t.Fatalf("writeRestoreFile: %v", err)
	}
	abandoned, err := writeRestoreFile(session, &serverRestore{})
	if err != nil {
		t.Fatalf("writeRestoreFile: %v", err)
	}
	if fresh == abandoned {
		t.Fatalf("writeRestoreFile reused in-flight snapshot path %q", fresh)
	}
	old := time.Now().Add(-2 * abandonedRestoreFileAge)
	if err := os.Chtimes(abandoned, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	gcCommand()

	if _, err := os.Stat(fresh); err != nil {
		t.Fatalf("gc removed an in-flight restore snapshot: %v", err)
	}
	if _, err := os.Stat(abandoned); !os.IsNotExist(err) {
		t.Fatalf("gc kept an abandoned restore snapshot: %v", err)
	}
}

// recycledPIDFileContents names this process, which is alive but is not the
// process that wrote the file in the scenario under test.
func recycledPIDFileContents() string {
	return fmt.Sprintf("%d\n", os.Getpid())
}

// agePIDFileBeforeThisProcess backdates a session file so it predates the
// process it names. That is what a recycled pid looks like: the file was
// written by a server that has since died, and the pid now belongs to a
// process that started later.
func agePIDFileBeforeThisProcess(t *testing.T, path string) {
	t.Helper()
	old := time.Now().Add(-24 * time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
}

// Reclaiming a stale session file must not be able to unlink a file that
// another helper has already taken over, or two helpers would hold the same
// session lock at once and could both start a server for it.
func TestAcquireSessionLockIsExclusiveUnderContention(t *testing.T) {
	for _, test := range []struct {
		name, contents string
		aged           bool
	}{
		{"stale PID", "99999999\n", false},
		{"abandoned lock", "   \n", true},
	} {
		t.Run(test.name, func(t *testing.T) {
			isolateTestRuntime(t)

			session := fmt.Sprintf("lock-race-%d", time.Now().UnixNano())
			path, err := sessionLockPath(session)
			if err != nil {
				t.Fatalf("sessionLockPath: %v", err)
			}
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				t.Fatalf("mkdir: %v", err)
			}
			if err := os.WriteFile(path, []byte(test.contents), 0o600); err != nil {
				t.Fatalf("write stale lock: %v", err)
			}

			if test.aged {
				old := time.Now().Add(-time.Hour)
				if err := os.Chtimes(path, old, old); err != nil {
					t.Fatal(err)
				}
			}

			const (
				contenders = 4
				rounds     = 3
			)
			var (
				mu        sync.Mutex
				held      int
				conflicts int
				wg        sync.WaitGroup
			)
			start := make(chan struct{})
			for i := 0; i < contenders; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					<-start
					for r := 0; r < rounds; r++ {
						unlock, err := acquireSessionLock(session)
						if err != nil {
							t.Errorf("acquireSessionLock: %v", err)
							return
						}
						mu.Lock()
						held++
						if held > 1 {
							conflicts++
						}
						mu.Unlock()
						// Yield while counted so overlapping acquisitions are observable.
						time.Sleep(time.Millisecond)
						mu.Lock()
						held--
						mu.Unlock()
						unlock()
					}
				}()
			}
			close(start)
			wg.Wait()

			mu.Lock()
			defer mu.Unlock()
			if conflicts > 0 {
				t.Fatalf("session lock was held by more than one holder %d times", conflicts)
			}
		})
	}
}

func TestAcquireSessionLockUnlockDoesNotDeleteAnotherSameProcessHolder(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("lock-same-pid-%d", time.Now().UnixNano())
	firstUnlock, err := acquireSessionLock(session)
	if err != nil {
		t.Fatalf("first acquireSessionLock: %v", err)
	}

	secondAcquired := make(chan func(), 1)
	secondErr := make(chan error, 1)
	go func() {
		unlock, err := acquireSessionLock(session)
		if err != nil {
			secondErr <- err
			return
		}
		secondAcquired <- unlock
	}()

	select {
	case <-secondAcquired:
		t.Fatal("second lock acquired while first held")
	case err := <-secondErr:
		t.Fatalf("second lock failed while waiting: %v", err)
	case <-time.After(150 * time.Millisecond):
	}

	firstUnlock()
	var secondUnlock func()
	select {
	case secondUnlock = <-secondAcquired:
	case err := <-secondErr:
		t.Fatalf("second lock after first unlock: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("second lock did not acquire after first unlock")
	}

	// Calling the stale unlock again must not delete the second holder's file.
	firstUnlock()
	thirdAcquired := make(chan func(), 1)
	thirdErr := make(chan error, 1)
	go func() {
		unlock, err := acquireSessionLock(session)
		if err != nil {
			thirdErr <- err
			return
		}
		thirdAcquired <- unlock
	}()
	select {
	case unlock := <-thirdAcquired:
		unlock()
		t.Fatal("stale first unlock deleted the second holder's lock")
	case err := <-thirdErr:
		t.Fatalf("third lock failed while waiting: %v", err)
	case <-time.After(150 * time.Millisecond):
	}

	secondUnlock()
	select {
	case unlock := <-thirdAcquired:
		unlock()
	case err := <-thirdErr:
		t.Fatalf("third lock after second unlock: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("third lock did not acquire after second unlock")
	}
}

// A lock file is installed already populated, so a contender can never observe
// an empty one and mistake a live holder for the residue of a crash.
func TestInstallSessionLockFileIsNeverEmpty(t *testing.T) {
	isolateTestRuntime(t)

	session := fmt.Sprintf("lock-install-%d", time.Now().UnixNano())
	path, err := sessionLockPath(session)
	if err != nil {
		t.Fatalf("sessionLockPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	installed, acquired, err := installSessionLockFile(path)
	if err != nil || !acquired {
		t.Fatalf("installSessionLockFile = %#v, %v, %v; want record, true, nil", installed, acquired, err)
	}
	record, err := readPIDRecord(path)
	if err != nil {
		t.Fatalf("lock file is not parseable immediately after install: %v", err)
	}
	if record.pid != os.Getpid() {
		t.Fatalf("lock pid = %d, want %d", record.pid, os.Getpid())
	}
	if installed.pid != record.pid || !installed.writtenAt.Equal(record.writtenAt) {
		t.Fatalf("installed = %#v, want %#v", installed, record)
	}

	// A second install must not take a held lock.
	_, acquired, err = installSessionLockFile(path)
	if err != nil {
		t.Fatalf("installSessionLockFile: %v", err)
	}
	if acquired {
		t.Fatal("installSessionLockFile took a lock that was already held")
	}

	// No staging residue may be left behind in the run directory.
	matches, err := filepath.Glob(filepath.Join(filepath.Dir(path), "*.staging"))
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	if len(matches) != 0 {
		t.Fatalf("staging files left behind: %v", matches)
	}
}

// clearAbandonedPIDFile must not delete a file that became valid while it was
// being considered.
func TestClearAbandonedPIDFileKeepsRepopulatedFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "monkeymux-test.lock")

	if err := os.WriteFile(path, []byte("not a pid\n"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
	if !clearAbandonedPIDFile(path) {
		t.Fatal("an aged unparseable file was not reclaimed")
	}

	if err := os.WriteFile(path, []byte("1234\n"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
	if clearAbandonedPIDFile(path) {
		t.Fatal("a valid record was deleted as abandoned")
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("valid record removed: %v", err)
	}
}

func TestReadPIDRecordReportsFileTimestamp(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "monkeymux-test.pid")
	if err := os.WriteFile(path, []byte("4321\n"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	stamp := time.Now().Add(-90 * time.Minute).Truncate(time.Second)
	if err := os.Chtimes(path, stamp, stamp); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
	record, err := readPIDRecord(path)
	if err != nil {
		t.Fatalf("readPIDRecord: %v", err)
	}
	if record.pid != 4321 {
		t.Fatalf("pid = %d, want 4321", record.pid)
	}
	if !record.writtenAt.Equal(stamp) {
		t.Fatalf("writtenAt = %s, want %s", record.writtenAt, stamp)
	}
}

func TestProcessImageMatching(t *testing.T) {
	// The helper installs under ~/.monkeyssh, so the install path contains the
	// name of the session from the original bug report. Ownership must come
	// from the --session value, never from a substring of the command line.
	const install = "/home/u/.monkeyssh/bin/monkeymux/0.1.144/linux-amd64/monkeymux"
	cases := []struct {
		image   string
		monkey  bool
		session string
		serves  bool
	}{
		{install + " serve --session MonkeySSH", true, "MonkeySSH", true},
		// The session token is authoritative and survives any name. It is
		// emitted before the name so a name cannot shadow it.
		{install + " serve --session-token " + sessionToken("MonkeySSH") + " --session MonkeySSH", true, "MonkeySSH", true},
		{install + " serve --session-token " + sessionToken("agents") + " --session agents", true, "MonkeySSH", false},
		// A name that itself looks like flags is unambiguous with a token.
		{install + " serve --session-token " + sessionToken("Work --foo") + " --session Work --foo", true, "Work", false},
		{install + " serve --session-token " + sessionToken("Work --foo") + " --session Work --foo", true, "Work --foo", true},
		// A name that embeds another session's token must not shadow the real
		// one, which is why the real token is emitted first.
		{
			install + " serve --session-token " + sessionToken("agents") +
				" --session agents --session-token " + sessionToken("Work"),
			true,
			"Work",
			false,
		},
		{
			install + " serve --session-token " + sessionToken("agents") +
				" --session agents --session-token " + sessionToken("Work"),
			true,
			"agents",
			true,
		},
		{install + " serve --session=MonkeySSH", true, "MonkeySSH", true},
		{install + " serve -session MonkeySSH", true, "MonkeySSH", true},
		// Another session's server, on a path that contains "monkeyssh".
		{install + " serve --session agents", true, "MonkeySSH", false},
		{install + " serve --session Work2", true, "Work", false},
		{install + " serve --session Work", true, "Work2", false},
		// Session names are case-sensitive; they hash to different sockets.
		{install + " serve --session work", true, "Work", false},
		// A session name containing spaces survives command line flattening.
		{install + " serve --session My Session --width 80", true, "My Session", true},
		{install + " serve --session My Session --width 80", true, "My", false},
		// An attach or other subcommand is not a server for the session.
		{install + " attach --session MonkeySSH", true, "MonkeySSH", false},
		{install, true, "MonkeySSH", false},
		{"/usr/bin/monkeymux.exe serve --session Work", true, "Work", true},
		{"/usr/bin/vim /home/u/.monkeyssh/bin/monkeymux/notes.txt", false, "Work", false},
		{"/usr/bin/grep -r monkeymux serve --session Work /etc", false, "Work", false},
		{"/bin/sleep 120", false, "Work", false},
		// A home directory containing spaces flattens into the command line;
		// failing to recognise the helper here would steal a live session.
		{"/Users/Jane Doe/.monkeyssh/bin/monkeymux/0.1.144/darwin-arm64/monkeymux serve --session MonkeySSH", true, "MonkeySSH", true},
		{"/Users/Jane Doe/.monkeyssh/bin/monkeymux/0.1.144/darwin-arm64/monkeymux serve --session agents", true, "MonkeySSH", false},
		{"/Users/Jane Doe/bin/monkeymux", true, "MonkeySSH", false},
		{"/Users/Jane Doe/bin/notes.txt serve --session MonkeySSH", false, "MonkeySSH", false},
		{"", false, "Work", false},
	}
	for _, tc := range cases {
		if got := processImageIsMonkeyMux(tc.image); got != tc.monkey {
			t.Errorf("processImageIsMonkeyMux(%q) = %v, want %v", tc.image, got, tc.monkey)
		}
		if got := processImageServesSession(tc.image, tc.session); got != tc.serves {
			t.Errorf(
				"processImageServesSession(%q, %q) = %v, want %v",
				tc.image,
				tc.session,
				got,
				tc.serves,
			)
		}
	}
}

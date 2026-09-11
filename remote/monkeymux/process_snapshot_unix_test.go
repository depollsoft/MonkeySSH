//go:build !windows

package main

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"
)

// A process that has exited but has not been reaped by its parent still
// answers kill(pid, 0). Treating that zombie as a live server would keep the
// session locked out for as long as the parent lives.
func TestInspectProcessReportsZombieAsNotRunning(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "exit 0")
	if err := cmd.Start(); err != nil {
		t.Skipf("cannot start helper process: %v", err)
	}
	pid := cmd.Process.Pid
	// Keep the child unreaped until ownership assertions finish.
	t.Cleanup(func() {
		_ = cmd.Wait()
	})

	deadline := time.Now().Add(3 * time.Second)
	for {
		snapshot := inspectProcess(pid)
		if snapshot.known && !snapshot.running {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("process %d never reported as exited: %#v", pid, inspectProcess(pid))
		}
		time.Sleep(25 * time.Millisecond)
	}

	if !processIDAlive(pid) {
		t.Skip("the zombie was reaped before ownership could be checked")
	}
	record := pidRecord{pid: pid, writtenAt: time.Now()}
	if got := pidRecordOwnership(record, ""); got != pidOwnershipGone {
		t.Fatalf("ownership of a zombie = %v, want %v", got, pidOwnershipGone)
	}
}

// The recorded start time must describe the process, not the timezone the
// caller happened to inherit, or the same process would look like a different
// one to an SSH session that forwarded a different TZ.
func TestInspectProcessStartTimeIsTimezoneIndependent(t *testing.T) {
	t.Setenv("TZ", "UTC")
	utc := inspectProcess(os.Getpid())
	t.Setenv("TZ", "Asia/Tokyo")
	tokyo := inspectProcess(os.Getpid())

	if !utc.known || !tokyo.known {
		t.Skip("this host cannot inspect its own process")
	}
	if utc.started.IsZero() || tokyo.started.IsZero() {
		t.Skip("this host does not report process start times")
	}
	if !utc.started.Equal(tokyo.started) {
		t.Fatalf("start time changed with TZ: %s vs %s", utc.started, tokyo.started)
	}
}

func TestInspectProcessReportsSelfAsRunningMonkeyMux(t *testing.T) {
	snapshot := inspectProcess(os.Getpid())
	if !snapshot.known {
		t.Skip("this host cannot inspect its own process")
	}
	if !snapshot.running {
		t.Fatal("this process reported as not running")
	}
	if snapshot.image == "" {
		t.Skip("this host does not report process images")
	}
	if !processImageIsMonkeyMux(snapshot.image) {
		t.Fatalf("own image %q not recognised as the helper", snapshot.image)
	}
}

func TestParseProcessStartTimeAcceptsCLocaleOutput(t *testing.T) {
	// Padded and unpadded day-of-month, as ps prints them under LC_ALL=C.
	for _, value := range []string{
		"Sat Aug  8 23:15:36 2026",
		"Mon Jan 12 04:05:06 2026",
	} {
		if parseProcessStartTime(value).IsZero() {
			t.Fatalf("could not parse ps lstart value %q", value)
		}
	}
	if got := parseProcessStartTime("not a date"); !got.IsZero() {
		t.Fatalf("parsed nonsense as %s, want the zero time", got)
	}
}

func TestUserHZTicksToDuration(t *testing.T) {
	cases := map[int64]time.Duration{
		0:      0,
		1:      10 * time.Millisecond,
		100:    time.Second,
		360050: 3600*time.Second + 500*time.Millisecond,
	}
	for ticks, want := range cases {
		if got := userHZTicksToDuration(ticks); got != want {
			t.Fatalf("userHZTicksToDuration(%d) = %s, want %s", ticks, got, want)
		}
	}
	// A multi-year uptime must not overflow the intermediate multiplication.
	const fiveYears = int64(5 * 365 * 24 * 60 * 60 * 100)
	if got := userHZTicksToDuration(fiveYears); got <= 0 {
		t.Fatalf("userHZTicksToDuration(%d) = %s, want a positive duration", fiveYears, got)
	}
}

func TestPidRecordOwnershipRejectsProcessStartedAfterTheRecord(t *testing.T) {
	snapshot := inspectProcess(os.Getpid())
	if !snapshot.known || snapshot.started.IsZero() {
		t.Skip("this host does not report process start times")
	}
	record := pidRecord{
		pid:       os.Getpid(),
		writtenAt: snapshot.started.Add(-time.Hour),
	}
	if got := pidRecordOwnership(record, ""); got != pidOwnershipGone {
		t.Fatalf("ownership = %v, want %v for a record older than the process", got, pidOwnershipGone)
	}

	current := pidRecord{pid: os.Getpid(), writtenAt: time.Now()}
	if got := pidRecordOwnership(current, ""); got == pidOwnershipGone {
		t.Fatalf("ownership = %v, want a live or unknown owner for this process", got)
	}
}

func TestPidRecordOwnershipRejectsForeignProcess(t *testing.T) {
	cmd := exec.Command("sleep", "120")
	if err := cmd.Start(); err != nil {
		t.Skipf("cannot start helper process: %v", err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})

	record := pidRecord{pid: cmd.Process.Pid, writtenAt: time.Now()}
	snapshot := inspectProcess(record.pid)
	if !snapshot.known || snapshot.image == "" {
		t.Skip("this host does not report process images")
	}
	if got := pidRecordOwnership(record, ""); got != pidOwnershipGone {
		t.Fatalf("ownership of %q = %v, want %v", snapshot.image, got, pidOwnershipGone)
	}
}

func TestInspectProcessHandlesUnknownPID(t *testing.T) {
	// A pid that cannot exist must never be reported as a running owner.
	snapshot := inspectProcess(0)
	if snapshot.running {
		t.Fatalf("pid 0 reported as running: %#v", snapshot)
	}
	if got := pidRecordOwnership(pidRecord{pid: 0}, ""); got != pidOwnershipGone {
		t.Fatalf("ownership of pid 0 = %v, want %v", got, pidOwnershipGone)
	}
}

// kill(pid, 0) reports EPERM for a live process owned by another user. Reading
// that as "gone" would let a helper reclaim a session another user's server
// still owns.
func TestProcessIDAliveTreatsPermissionDeniedAsAlive(t *testing.T) {
	// pid 1 always exists and is owned by root, so an unprivileged test run
	// exercises the EPERM path and a privileged one still succeeds outright.
	if !processIDAlive(1) {
		t.Fatal("pid 1 reported as not alive")
	}
	if err := syscall.Kill(1, 0); err == nil {
		t.Log("running privileged; EPERM path not exercised")
	} else if !errors.Is(err, syscall.EPERM) {
		t.Skipf("pid 1 is not signal-protected on this host: %v", err)
	}
}

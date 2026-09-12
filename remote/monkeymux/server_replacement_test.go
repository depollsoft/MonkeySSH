package main

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func TestStopServerForReplacement(t *testing.T) {
	for _, tc := range []struct {
		name         string
		exits        []bool
		wantForced   bool
		wantErr      error
		wantCalls    string
		canTerminate bool
	}{
		{"graceful exit", []bool{true}, false, nil, "wait", true},
		{"forced exit", []bool{false, true}, true, nil, "wait,terminate,reap,wait", true},
		{"still alive", []bool{false, false}, true, errServerUpdateStillAlive, "wait,terminate,reap,wait", true},
		{"unknown ownership", []bool{false}, false, errServerUpdateStillAlive, "wait,terminate", false},
		{"termination failed", []bool{false}, false, errServerUpdateStillAlive, "wait,terminate", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls []string
			waits := 0
			forced, err := stopServerForReplacement(
				func(timeout time.Duration) bool {
					t.Helper()
					wantTimeout := serverExitWaitTimeout
					if waits > 0 {
						wantTimeout = serverForcedExitWaitTimeout
					}
					if timeout != wantTimeout {
						t.Fatalf("wait timeout = %s, want %s", timeout, wantTimeout)
					}
					if waits >= len(tc.exits) {
						t.Fatal("unexpected extra exit wait")
					}
					calls = append(calls, "wait")
					result := tc.exits[waits]
					waits++
					return result
				},
				func() bool { calls = append(calls, "terminate"); return tc.canTerminate },
				func() { calls = append(calls, "reap") },
			)
			if forced != tc.wantForced || !errors.Is(err, tc.wantErr) {
				t.Fatalf("stop = (%v, %v), want (%v, %v)", forced, err, tc.wantForced, tc.wantErr)
			}
			if got := strings.Join(calls, ","); got != tc.wantCalls {
				t.Fatalf("calls = %s, want %s", got, tc.wantCalls)
			}
		})
	}
}

func TestTerminateConfirmedServerRechecksFailedSignal(t *testing.T) {
	for _, tc := range []struct {
		name           string
		before, after  pidOwnership
		signaled, want bool
		calls          string
	}{
		{"already gone", pidOwnershipGone, pidOwnershipGone, false, true, "check"},
		{"unknown owner", pidOwnershipUnknown, pidOwnershipGone, false, false, "check"},
		{"signal delivered", pidOwnershipLive, pidOwnershipLive, true, true, "check,signal"},
		{"exited before signal", pidOwnershipLive, pidOwnershipGone, false, allowExitAfterFailedTermination, "check,signal,check"},
		{"signal failed while live", pidOwnershipLive, pidOwnershipLive, false, false, "check,signal,check"},
		{"signal failed then unknown", pidOwnershipLive, pidOwnershipUnknown, false, false, "check,signal,check"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if !allowExitAfterFailedTermination && !tc.signaled && tc.before == pidOwnershipLive {
				tc.calls = "check,signal"
			}
			var calls []string
			got := terminateConfirmedServer(func() pidOwnership {
				calls = append(calls, "check")
				if len(calls) == 1 {
					return tc.before
				}
				return tc.after
			}, func() bool {
				calls = append(calls, "signal")
				return tc.signaled
			})
			if got != tc.want || strings.Join(calls, ",") != tc.calls {
				t.Fatalf("termination confirmed = %v, calls = %v; want %v, %s", got, calls, tc.want, tc.calls)
			}
		})
	}
}

func TestConfirmedServerProcessRejectsReusedOrUnknownIdentity(t *testing.T) {
	original := processSnapshot{known: true, running: true, started: time.Unix(100, 1000)}
	for _, tc := range []struct {
		name      string
		current   processSnapshot
		ownership pidOwnership
		want      bool
	}{
		{"same process", original, pidOwnershipLive, true},
		{"recycled in same second", processSnapshot{known: true, running: true, started: time.Unix(100, 2000)}, pidOwnershipLive, false},
		{"unknown identity", processSnapshot{}, pidOwnershipLive, false},
		{"unknown owner", original, pidOwnershipUnknown, false},
		{"gone owner", original, pidOwnershipGone, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			current, ownership := original, pidOwnershipLive
			stillOwner := confirmedServerProcessWithQueries(func() processSnapshot { return current }, func() pidOwnership { return ownership })
			current, ownership = tc.current, tc.ownership
			if got := stillOwner(); got != tc.want {
				t.Fatalf("still owner = %v, want %v", got, tc.want)
			}
		})
	}
}

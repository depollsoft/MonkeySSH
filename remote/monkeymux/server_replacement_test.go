package main

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func TestStopServerForReplacement(t *testing.T) {
	for _, tc := range []struct {
		name       string
		exits      []bool
		wantForced bool
		wantErr    error
		wantCalls  string
	}{
		{"graceful exit", []bool{true}, false, nil, "wait"},
		{"forced exit", []bool{false, true}, true, nil, "wait,terminate,reap,wait"},
		{"still alive", []bool{false, false}, true, errServerUpdateStillAlive, "wait,terminate,reap,wait"},
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
				func() { calls = append(calls, "terminate") },
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

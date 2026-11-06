package main

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestRefreshAllProcessMetadataRefreshesWindowsConcurrently(t *testing.T) {
	for _, windowCount := range []int{6, 3 * maxConcurrentMetadataRefreshes} {
		t.Run(fmt.Sprintf("%d windows", windowCount), func(t *testing.T) {
			server := newMuxServer("test")
			for index := 0; index < windowCount; index++ {
				server.windows = append(server.windows, &muxWindow{id: fmt.Sprintf("@%d", index+1), index: index})
			}
			previous := refreshWindowProcessMetadata
			t.Cleanup(func() { refreshWindowProcessMetadata = previous })

			// Each fake refresh waits until as many refreshes as may run at once
			// have started. Refreshing one window after another never fills
			// that, so each would wait out the deadline with one in flight.
			expected := min(windowCount, maxConcurrentMetadataRefreshes)
			var mu sync.Mutex
			refreshed := map[string]int{}
			inFlight, maxInFlight, started := 0, 0, 0
			allStarted := make(chan struct{})
			refreshWindowProcessMetadata = func(_ *muxServer, windowID string) {
				mu.Lock()
				refreshed[windowID]++
				inFlight++
				maxInFlight = max(maxInFlight, inFlight)
				started++
				if started == expected {
					close(allStarted)
				}
				mu.Unlock()
				select {
				case <-allStarted:
				case <-time.After(200 * time.Millisecond):
				}
				time.Sleep(5 * time.Millisecond)
				mu.Lock()
				inFlight--
				mu.Unlock()
			}

			server.refreshAllProcessMetadata()

			mu.Lock()
			defer mu.Unlock()
			if maxInFlight != expected {
				t.Fatalf("at most %d refreshes ran at once, want %d", maxInFlight, expected)
			}
			if len(refreshed) != windowCount {
				t.Fatalf("refreshed %d windows, want %d", len(refreshed), windowCount)
			}
			for windowID, count := range refreshed {
				if count != 1 {
					t.Fatalf("window %s refreshed %d times", windowID, count)
				}
			}
		})
	}
}

package main

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestAcpTrimReplayKeepsPendingAndNewestEvents(t *testing.T) {
	for _, test := range []struct {
		name    string
		weights []int
		pending map[int]bool
		want    []uint64
	}{
		{"oldest", []int{20, 20, 20}, nil, []uint64{2, 3}},
		{"pinned gaps", []int{10, 15, 10, 15, 10}, map[int]bool{0: true, 2: true}, []uint64{1, 3, 5}},
		{"batch below ceiling", []int{5, 5, 5, 5, 5, 5, 5, 6}, map[int]bool{0: true}, []uint64{1, 4, 5, 6, 7, 8}},
		{"only pending", []int{30, 30}, map[int]bool{0: true, 1: true}, []uint64{1, 2}},
		{"one oversized", []int{1, 50}, nil, []uint64{2}},
	} {
		t.Run(test.name, func(t *testing.T) {
			bridge := newTestAcpBridge()
			for i, weight := range test.weights {
				event := acpReplayEvent{
					message: acpWireMessage{Sequence: uint64(i + 1), Data: json.RawMessage(`{"result":{}}`)},
					bytes:   weight * 1024 * 1024,
				}
				if test.pending[i] {
					event.pendingID = "permission"
					event.clientRequest = true
					bridge.pendingReplayEvents++
					bridge.pendingReplayBytes += event.bytes
				}
				bridge.replay = append(bridge.replay, event)
				bridge.replayBytes += event.bytes
			}
			pendingEvents, pendingBytes := bridge.pendingReplayEvents, bridge.pendingReplayBytes
			storage := bridge.replay
			bridge.trimReplayLocked()
			if test.name == "oldest" || test.name == "one oversized" {
				removed := len(storage) - len(bridge.replay)
				if &bridge.replay[0] != &storage[removed] {
					t.Error("prefix eviction moved retained events")
				}
				for _, event := range storage[:removed] {
					if !reflect.DeepEqual(event, acpReplayEvent{}) {
						t.Error("evicted prefix retains payloads")
					}
				}
			}
			var got []uint64
			bytes := 0
			for _, event := range bridge.replay {
				got = append(got, event.message.Sequence)
				bytes += event.bytes
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Errorf("retained sequences = %v, want %v", got, test.want)
			}
			if bridge.replayBytes != bytes || bridge.pendingReplayEvents != pendingEvents || bridge.pendingReplayBytes != pendingBytes {
				t.Error("replay accounting changed incorrectly")
			}
			for _, event := range bridge.replay[len(bridge.replay):cap(bridge.replay)] {
				if !reflect.DeepEqual(event, acpReplayEvent{}) {
					t.Error("unused replay capacity retains evicted payloads")
				}
			}
		})
	}
}

func TestAcpTrimReplayDoesNotAllocatePerEviction(t *testing.T) {
	bridge := newTestAcpBridge()
	seed := []acpReplayEvent{
		{bytes: acpReplayMaxBytes / 2},
		{bytes: acpReplayMaxBytes / 2, pendingID: "permission"},
		{bytes: acpReplayMaxBytes / 2},
	}
	storage := make([]acpReplayEvent, len(seed))
	allocations := testing.AllocsPerRun(100, func() {
		copy(storage, seed)
		bridge.replay = storage
		bridge.replayBytes = 3 * (acpReplayMaxBytes / 2)
		bridge.trimReplayLocked()
	})
	if allocations != 0 {
		t.Errorf("allocations per eviction = %g, want zero", allocations)
	}
}

func BenchmarkAcpReplayFullBufferStreaming(b *testing.B) {
	for _, pinned := range []bool{false, true} {
		name := "unpinned"
		if pinned {
			name = "pinned"
		}
		b.Run(name, func(b *testing.B) {
			bridge := newTestAcpBridge()
			message := acpWireMessage{Type: "output", Data: json.RawMessage(`{"delta":"x"}`)}
			retained := acpReplayMaxBytes / (len(message.Data) + acpReplayEventOverheadBytes)
			for i := 0; i < retained; i++ {
				pendingID := ""
				if pinned && i == 0 {
					pendingID = "permission"
				}
				bridge.appendReplayLocked(message, pendingID)
			}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				bridge.appendReplayLocked(message, "")
			}
		})
	}
}

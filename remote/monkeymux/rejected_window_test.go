package main

import (
	"reflect"
	"testing"
)

// Embedding leaves unused methods out of the fake. The cleanup contract is
// deliberately narrower than the normal watched-window lifecycle.
type rejectedCleanupProcess struct {
	muxProcess
	events *[]string
}

func (p rejectedCleanupProcess) Kill() { *p.events = append(*p.events, "kill") }
func (p rejectedCleanupProcess) Wait() error {
	*p.events = append(*p.events, "wait")
	return nil
}

type rejectedCleanupPty struct {
	muxPty
	events *[]string
}

func (p rejectedCleanupPty) Close() error {
	*p.events = append(*p.events, "close")
	return nil
}

func TestRejectedWindowKillsBeforeReaping(t *testing.T) {
	var events []string
	cleanupRejectedWindow(rejectedCleanupPty{events: &events}, rejectedCleanupProcess{events: &events})
	if want := []string{"kill", "close", "wait"}; !reflect.DeepEqual(events, want) {
		t.Fatalf("cleanup order = %v, want %v", events, want)
	}
}

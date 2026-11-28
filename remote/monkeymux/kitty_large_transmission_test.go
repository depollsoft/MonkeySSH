package main

import (
	"bytes"
	"fmt"
	"reflect"
	"testing"
)

func TestKittyRetentionAcceptsMultipartImageLargerThanLegacyPendingCap(
	t *testing.T,
) {
	const (
		imageID          = "11532700"
		payloadBytes     = 3 * 1024 * 1024
		kittyPayloadSize = 4096
	)
	window := &muxWindow{}
	payload := bytes.Repeat([]byte{'A'}, payloadBytes)

	for offset := 0; offset < len(payload); offset += kittyPayloadSize {
		end := offset + kittyPayloadSize
		if end > len(payload) {
			end = len(payload)
		}
		more := 1
		control := "m=1"
		if end == len(payload) {
			more = 0
			control = "m=0"
		}
		if offset == 0 {
			control = fmt.Sprintf(
				"a=t,U=1,i=%s,c=22,r=24,f=100,q=2,m=%d",
				imageID,
				more,
			)
		}
		chunk := append([]byte("\x1b_G"+control+";"), payload[offset:end]...)
		chunk = append(chunk, '\x1b', '\\')
		window.observeKittyGraphicsLocked(chunk)
	}

	retained := window.kittyImages[imageID]
	if len(retained) <= payloadBytes {
		t.Fatalf(
			"retained transmission = %d bytes, want more than %d payload bytes",
			len(retained),
			payloadBytes,
		)
	}
	if len(window.kittyGraphicsPending) != 0 {
		t.Fatalf(
			"completed transmission left %d pending bytes",
			len(window.kittyGraphicsPending),
		)
	}

	replayed, served := window.kittyImageTransmissionsForLocked([]string{imageID})
	if len(replayed) != len(retained) {
		t.Fatalf(
			"requested replay = %d bytes, want retained %d",
			len(replayed),
			len(retained),
		)
	}
	if !reflect.DeepEqual(served, []string{imageID}) {
		t.Fatalf("served ids = %#v, want [%s]", served, imageID)
	}
}

func TestKittyPendingMultipartSurvivesArbitraryPTYReadBoundaries(t *testing.T) {
	t.Parallel()
	const (
		imageID          = "11532700"
		payloadBytes     = 3 * 1024 * 1024
		kittyPayloadSize = 4096
		ptyReadSize      = 32749
	)
	payload := bytes.Repeat([]byte{'B'}, payloadBytes)
	var stream []byte
	for offset := 0; offset < len(payload); offset += kittyPayloadSize {
		end := offset + kittyPayloadSize
		if end > len(payload) {
			end = len(payload)
		}
		more := 1
		control := "m=1"
		if end == len(payload) {
			more = 0
			control = "m=0"
		}
		if offset == 0 {
			control = fmt.Sprintf(
				"a=t,U=1,i=%s,c=22,r=24,f=100,q=2,m=%d",
				imageID,
				more,
			)
		}
		stream = append(stream, "\x1b_G"+control+";"...)
		stream = append(stream, payload[offset:end]...)
		stream = append(stream, '\x1b', '\\')
	}

	window := &muxWindow{}
	for offset := 0; offset < len(stream); offset += ptyReadSize {
		end := offset + ptyReadSize
		if end > len(stream) {
			end = len(stream)
		}
		window.observeKittyGraphicsLocked(stream[offset:end])
	}

	if got := len(window.kittyImages[imageID]); got != len(stream) {
		t.Fatalf("retained transmission = %d bytes, want %d", got, len(stream))
	}
	if len(window.kittyGraphicsPending) != 0 ||
		window.kittyGraphicsPendingScan != 0 ||
		window.kittyGraphicsPendingTerm != 0 {
		t.Fatalf(
			"completed transmission left pending=%d scan=%d term=%d",
			len(window.kittyGraphicsPending),
			window.kittyGraphicsPendingScan,
			window.kittyGraphicsPendingTerm,
		)
	}
}

func TestClearKittyGraphicsPendingReleasesIncompleteImage(t *testing.T) {
	t.Parallel()
	window := &muxWindow{}
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=t,U=1,i=9,f=100,m=1;PARTIAL\x1b\\"),
	)
	if len(window.kittyGraphicsPending) == 0 {
		t.Fatal("incomplete image did not create pending state")
	}

	window.clearKittyGraphicsPendingLocked()

	if len(window.kittyGraphicsPending) != 0 ||
		window.kittyGraphicsPendingScan != 0 ||
		window.kittyGraphicsPendingTerm != 0 {
		t.Fatalf(
			"clear left pending=%d scan=%d term=%d",
			len(window.kittyGraphicsPending),
			window.kittyGraphicsPendingScan,
			window.kittyGraphicsPendingTerm,
		)
	}
}

func TestKittyPendingMalformedRootResyncsToLaterImage(t *testing.T) {
	t.Parallel()
	window := &muxWindow{}
	stream := []byte(
		"\x1b_Ga=t,U=1,i=1,f=100,m=1;ABCD\x1b\\" +
			"not-a-continuation" +
			"\x1b_Ga=t,U=1,i=2,f=100,m=0;EFGH\x1b\\",
	)

	window.observeKittyGraphicsLocked(stream)

	if _, retained := window.kittyImages["1"]; retained {
		t.Fatal("malformed unfinished image 1 was retained")
	}
	if _, retained := window.kittyImages["2"]; !retained {
		t.Fatal("valid image 2 after malformed multipart root was not retained")
	}
}

func TestKittyPendingUnterminatedAPCAdvancesTerminatorScan(t *testing.T) {
	t.Parallel()
	window := &muxWindow{}
	const readSize = 32 * 1024
	stream := append(
		[]byte("\x1b_Ga=t,U=1,i=1,f=100,m=1;"),
		bytes.Repeat([]byte{'A'}, 3*1024*1024)...,
	)
	for offset := 0; offset < len(stream); offset += readSize {
		end := offset + readSize
		if end > len(stream) {
			end = len(stream)
		}
		window.observeKittyGraphicsLocked(stream[offset:end])
	}

	if got := len(window.kittyGraphicsPending); got != len(stream) {
		t.Fatalf("pending bytes = %d, want %d", got, len(stream))
	}
	if window.kittyGraphicsPendingTerm < len(stream)-readSize-1 {
		t.Fatalf(
			"terminator scan = %d, want near end of %d-byte buffer",
			window.kittyGraphicsPendingTerm,
			len(stream),
		)
	}
}

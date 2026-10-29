package main

import (
	"errors"
	"io"
	"sync"
	"time"
)

const (
	// attachOutputBufferLimitBytes bounds the server output an attach client
	// holds while its terminal is not accepting writes. It matches the server's
	// own per-client queue limit, past which the server drops a client anyway.
	attachOutputBufferLimitBytes = attachWriteQueueLimitBytes
	// attachOutputQueryWait is how long a terminal query may wait in the relay
	// before it stops reading ahead. The server takes a reply that comes later
	// than terminalResponseFocusGrace for typed input, and a stalled client is
	// dropped attachWriteTimeout after its socket fills.
	attachOutputQueryWait = terminalResponseFocusGrace - attachWriteTimeout
	// attachQueryScanCarryLimitBytes bounds the unfinished control string kept
	// between reads. Queries are short; a longer string is an image or a title.
	attachQueryScanCarryLimitBytes = 4096
)

// relayAttachOutput copies server output to the local terminal through a
// buffer, so the session socket keeps draining while a terminal write waits.
//
// Over SSH that write waits whenever the channel stalls: a phone moving
// between networks, or a jump host on a slow link. A plain copy then stops
// reading the socket, and the server drops a client whose socket refuses
// output for attachWriteTimeout, so a stall of about a second ended the
// attach. Reading pauses while limit bytes are waiting to be written.
//
// It also pauses once a terminal query has waited queryWait without reaching
// the terminal. The server counts a query as delivered when the socket takes
// it, and routes a reply that comes after its grace period to the pane as
// typed input. Reading ahead past such a query would only keep the attach
// alive for the reply to arrive too late, so the server's write timeout
// applies again, as it did before the relay.
//
// It returns nil once src reports io.EOF and everything read before it has
// been written, and otherwise the first read or write error.
func relayAttachOutput(
	dst io.Writer,
	src io.Reader,
	limit int,
	queryWait time.Duration,
) error {
	var (
		mu      sync.Mutex
		changed = sync.NewCond(&mu)
		pending []byte
		// held counts pending plus the chunk the writer is writing.
		held    int
		readErr error
		// writeFailed stops the reader once nothing will drain the buffer.
		writeFailed bool
		// pendingQueryAt is when the first query in pending was read, and
		// writingQueryAt the same for the chunk being written; zero for none.
		pendingQueryAt time.Time
		writingQueryAt time.Time
	)
	queryOverdue := func() bool {
		oldest := writingQueryAt
		if oldest.IsZero() {
			oldest = pendingQueryAt
		}
		return !oldest.IsZero() && time.Since(oldest) >= queryWait
	}
	go func() {
		buf := make([]byte, attachWriteChunkBytes)
		var queries attachQueryScanner
		for {
			n, err := src.Read(buf)
			query := queries.scan(buf[:n])
			mu.Lock()
			pending = append(pending, buf[:n]...)
			held += n
			if query && pendingQueryAt.IsZero() {
				pendingQueryAt = time.Now()
			}
			readErr = err
			changed.Broadcast()
			for err == nil && !writeFailed && (held >= limit || queryOverdue()) {
				changed.Wait()
			}
			stop := err != nil || writeFailed
			mu.Unlock()
			if stop {
				return
			}
		}
	}()
	for {
		mu.Lock()
		for len(pending) == 0 && readErr == nil {
			changed.Wait()
		}
		chunk := pending
		pending = nil
		writingQueryAt = pendingQueryAt
		pendingQueryAt = time.Time{}
		err := readErr
		mu.Unlock()
		if len(chunk) == 0 {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		if _, writeErr := dst.Write(chunk); writeErr != nil {
			mu.Lock()
			writeFailed = true
			changed.Broadcast()
			mu.Unlock()
			return writeErr
		}
		mu.Lock()
		held -= len(chunk)
		writingQueryAt = time.Time{}
		changed.Broadcast()
		mu.Unlock()
	}
}

// attachQueryScanner reports whether attach output, read in arbitrary pieces,
// holds a terminal query, counting the queries the server expects replies to.
type attachQueryScanner struct {
	// carry is an unfinished control string from the previous piece.
	carry []byte
}

func (s *attachQueryScanner) scan(piece []byte) bool {
	data := piece
	leadingUtf8Prefix := 0
	if len(s.carry) > 0 {
		data = append(s.carry, piece...)
		s.carry = nil
	} else {
		// Continuation bytes that end a character the previous piece began.
		for leadingUtf8Prefix < len(data) &&
			data[leadingUtf8Prefix]&0xc0 == 0x80 {
			leadingUtf8Prefix++
		}
	}
	found := false
	for index := 0; index < len(data); {
		end, query, incomplete, recognized :=
			terminalQuerySequenceAtWithUtf8Prefix(data, index, leadingUtf8Prefix)
		if incomplete {
			if len(data)-index <= attachQueryScanCarryLimitBytes {
				s.carry = append([]byte(nil), data[index:]...)
			}
			break
		}
		if !recognized {
			index++
			continue
		}
		found = found || query
		index = end
	}
	return found
}

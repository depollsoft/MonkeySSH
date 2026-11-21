package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"slices"
	"sync"
	"sync/atomic"
	"time"
)

const (
	// attachOutputDeliveryCapability marks a server that takes attach_delivered
	// reports and starts a query's reply grace when the client's terminal has
	// been written the query, not when the attach socket took it.
	attachOutputDeliveryCapability = "attach-output-delivery"
	// attachDeliveredRequest is the control request that carries a report.
	attachDeliveredRequest = "attach_delivered"
	// attachOutputBufferLimitBytes bounds the server output an attach client
	// holds while its terminal is not accepting writes. It matches the server's
	// own per-client queue limit, past which the server drops a client anyway.
	attachOutputBufferLimitBytes = attachWriteQueueLimitBytes
)

// relayAttachOutput copies server output to the local terminal through a
// buffer of up to limit bytes. It writes the output in pieces of at most
// attachWriteChunkBytes and, when delivered is set, calls it after each piece
// with the number of output bytes the terminal has been written.
//
// A limit above one piece keeps the session socket draining while a terminal
// write waits. Over SSH that write waits whenever the channel stalls (a phone
// moving between networks, a jump host on a slow link), and the server drops
// a client whose socket refuses output for attachWriteTimeout. Reading ahead
// also lets the socket take a query long before the terminal sees it, so it
// needs a server that times the query's reply from the delivered reports
// (attach-output-delivery). Without one, limit is 1 and this copies the way
// io.Copy does, reading only once everything read has been written.
//
// It returns nil once src reports io.EOF and everything read before it has
// been written, and otherwise the first read or write error.
func relayAttachOutput(
	dst io.Writer,
	src io.Reader,
	limit int,
	delivered func(uint64),
) error {
	var (
		mu      sync.Mutex
		changed = sync.NewCond(&mu)
		pending []byte
		// held counts pending plus the piece the writer is writing.
		held    int
		readErr error
		// writeFailed stops the reader once nothing will drain the buffer.
		writeFailed bool
	)
	go func() {
		buf := make([]byte, attachWriteChunkBytes)
		for {
			n, err := src.Read(buf)
			mu.Lock()
			pending = append(pending, buf[:n]...)
			held += n
			readErr = err
			changed.Broadcast()
			for err == nil && held >= limit && !writeFailed {
				changed.Wait()
			}
			stop := err != nil || writeFailed
			mu.Unlock()
			if stop {
				return
			}
		}
	}()
	var written uint64
	for {
		mu.Lock()
		for len(pending) == 0 && readErr == nil {
			changed.Wait()
		}
		size := min(len(pending), attachWriteChunkBytes)
		// The reader appends past the end of pending, never into this piece.
		piece := pending[:size:size]
		pending = pending[size:]
		if len(pending) == 0 {
			pending = nil
		}
		err := readErr
		mu.Unlock()
		if size == 0 {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		if _, writeErr := dst.Write(piece); writeErr != nil {
			mu.Lock()
			writeFailed = true
			changed.Broadcast()
			mu.Unlock()
			return writeErr
		}
		written += uint64(size)
		if delivered != nil {
			delivered(written)
		}
		mu.Lock()
		held -= size
		changed.Broadcast()
		mu.Unlock()
	}
}

// attachDeliveryReporter sends a server attach_delivered reports for one
// attach connection over a control connection of its own. Reports coalesce:
// each one carries the latest offset, sent as soon as the previous one is
// written.
type attachDeliveryReporter struct {
	token     string
	session   string
	conn      net.Conn
	encoder   *json.Encoder
	delivered atomic.Uint64
	pending   chan struct{}
	// failed closes when the control connection ends before close, after
	// which the server would wait for reports forever.
	failed    chan struct{}
	failOnce  sync.Once
	done      chan struct{}
	closeOnce sync.Once
}

// openAttachDeliveryReporter connects a reporter, or returns nil when the
// server does not take reports or cannot be reached.
func openAttachDeliveryReporter(session string) *attachDeliveryReporter {
	conn, err := dialSession(session)
	if err != nil {
		return nil
	}
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))
	encoder := json.NewEncoder(conn)
	decoder := json.NewDecoder(conn)
	var hello controlResponse
	if encoder.Encode(controlMessage{Role: "control", Session: session}) != nil ||
		decoder.Decode(&hello) != nil ||
		!slices.Contains(hello.Capabilities, attachOutputDeliveryCapability) {
		_ = conn.Close()
		return nil
	}
	_ = conn.SetDeadline(time.Time{})
	token := make([]byte, 16)
	if _, err := rand.Read(token); err != nil {
		_ = conn.Close()
		return nil
	}
	reporter := &attachDeliveryReporter{
		token:   hex.EncodeToString(token),
		session: session,
		conn:    conn,
		encoder: encoder,
		pending: make(chan struct{}, 1),
		failed:  make(chan struct{}),
		done:    make(chan struct{}),
	}
	// The server also sends every control client its window changes; nothing
	// here needs them, but they must be read, and the connection ending
	// before close means no report sent since has arrived.
	go func() {
		for {
			var discard json.RawMessage
			if decoder.Decode(&discard) != nil {
				reporter.fail()
				return
			}
		}
	}()
	go reporter.run()
	return reporter
}

func (r *attachDeliveryReporter) run() {
	for {
		select {
		case <-r.pending:
		case <-r.done:
			return
		}
		if err := r.encoder.Encode(controlMessage{
			Type:        attachDeliveredRequest,
			Session:     r.session,
			AttachToken: r.token,
			Delivered:   r.delivered.Load(),
		}); err != nil {
			r.fail()
			return
		}
	}
}

func (r *attachDeliveryReporter) fail() {
	select {
	case <-r.done:
		// Closed on purpose: the attach is over.
	default:
		r.failOnce.Do(func() { close(r.failed) })
	}
}

// report records that the terminal has been written offset bytes.
func (r *attachDeliveryReporter) report(offset uint64) {
	r.delivered.Store(offset)
	select {
	case r.pending <- struct{}{}:
	default:
	}
}

// closeAttachInput ends the input the client sends on an attach connection
// while leaving its output to be read to the end.
func closeAttachInput(conn net.Conn) {
	if halfCloser, ok := conn.(interface{ CloseWrite() error }); ok {
		_ = halfCloser.CloseWrite()
		return
	}
	_ = conn.Close()
}

func (r *attachDeliveryReporter) close() {
	r.closeOnce.Do(func() {
		close(r.done)
		_ = r.conn.Close()
	})
}

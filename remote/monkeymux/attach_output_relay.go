package main

import (
	"errors"
	"io"
	"sync"
)

// attachOutputBufferLimitBytes bounds the server output an attach client holds
// while its terminal is not accepting writes. It matches the server's own
// per-client queue limit, past which the server drops a client anyway.
const attachOutputBufferLimitBytes = attachWriteQueueLimitBytes

// relayAttachOutput copies server output to the local terminal through a
// buffer, so the session socket keeps draining while a terminal write waits.
//
// Over SSH that write waits whenever the channel stalls: a phone moving
// between networks, or a jump host on a slow link. A plain copy then stops
// reading the socket, and the server drops a client whose socket refuses
// output for attachWriteTimeout, so a stall of about a second ended the
// attach. Reading pauses only while limit bytes are waiting to be written.
//
// It returns nil once src reports io.EOF and everything read before it has
// been written, and otherwise the first read or write error.
func relayAttachOutput(dst io.Writer, src io.Reader, limit int) error {
	var (
		mu      sync.Mutex
		changed = sync.NewCond(&mu)
		pending []byte
		// held counts pending plus the chunk the writer is writing.
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
	for {
		mu.Lock()
		for len(pending) == 0 && readErr == nil {
			changed.Wait()
		}
		chunk := pending
		pending = nil
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
		changed.Broadcast()
		mu.Unlock()
	}
}

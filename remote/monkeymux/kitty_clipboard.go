package main

import (
	"bytes"
	"encoding/hex"
	"net"
	"strings"
	"sync/atomic"
	"time"
)

// The kitty clipboard protocol (OSC 5522) lets a program read and write the
// system clipboard with MIME types: https://sw.kovidgoyal.net/kitty/clipboard/
//
// MonkeyMux forwards a window's requests to the attached client that answers
// them and routes the replies back to that window, whatever window is on
// screen by then. It gives each forwarded request an id naming its window
// (the spec's multiplexer id), and takes replies carrying such an id out of
// the client's input. A request the client cannot see, because its window is
// in the background, no client is attached, or the attached client does not
// speak the protocol, is answered EBUSY at once so the program is not left
// waiting. Paste events (private mode 5522) carry no id and reach the window
// on screen as ordinary input.
//
// A write is a sequence of packets the client keeps as one open transaction,
// so only one window's write can be open there at a time. The window that
// starts a write takes that slot; a window that loses it, or that leaves the
// screen mid-write, is answered EBUSY and the rest of its packets are dropped.

const (
	kittyClipboardOscCode = "5522"
	kittyPasteEventsMode  = "5522"

	// kittyClipboardWindowTagPrefix starts the id MonkeyMux gives a forwarded
	// request: the prefix, the window id in hex, then "." and the program's
	// own id when it sent one.
	kittyClipboardWindowTagPrefix = "mmx"

	// capabilityHintKeyKittyClipboard is present in the capability hint of a
	// client that answers OSC 5522.
	capabilityHintKeyKittyClipboard = "osc5522"

	// kittyClipboardReplyLimitBytes bounds a reply held while it is split
	// across reads of a client's input. A data packet carries at most 4 KiB
	// before base64, about 5.5 KiB on the wire.
	kittyClipboardReplyLimitBytes = 64 << 10

	// kittyClipboardRepliesOwedGrace is how long after a request is forwarded,
	// or a reply passes through, the client is assumed to be sending replies.
	// Only then is an input read that ends in a partial `ESC ] 5522 ;` held
	// back, since outside it a lone trailing ESC is the Escape key.
	kittyClipboardRepliesOwedGrace = 5 * time.Second

	// kittyClipboardAmbiguousCarryTimeout releases input held back because
	// it could have been the start of a reply but was not continued.
	kittyClipboardAmbiguousCarryTimeout = time.Second
)

var (
	kittyClipboardOscIntroducer   = []byte("\x1b]" + kittyClipboardOscCode + ";")
	kittyClipboardPasteStartInput = []byte("\x1b[200~")
	kittyClipboardPasteEndInput   = []byte("\x1b[201~")
)

type kittyClipboardWriteState uint8

const (
	kittyClipboardWriteNone kittyClipboardWriteState = iota
	// kittyClipboardWriteForwarding: the window's write is open on the
	// clients, which hold it as their one open transaction.
	kittyClipboardWriteForwarding
	// kittyClipboardWriteRejected: the window was answered EBUSY and its
	// remaining write packets are dropped until it starts another write.
	kittyClipboardWriteRejected
)

// kittyClipboardRoute is where a window's clipboard requests can go while
// handleWindowOutput applies one of its reads.
type kittyClipboardRoute struct {
	onScreen bool
	primary  net.Conn
	client   *attachClient
}

func (r kittyClipboardRoute) forwarding() bool {
	return r.onScreen && r.client != nil && r.client.answersKittyClipboard()
}

// kittyClipboardWindowState is a window's clipboard protocol state. Guarded
// by the server's mu.
type kittyClipboardWindowState struct {
	route        kittyClipboardRoute
	write        kittyClipboardWriteState
	writeID      string
	writePrimary net.Conn
	// replies collects the answers MonkeyMux gives itself while a read is
	// applied, queued to the window afterwards.
	replies []byte
	// forwarded notes that a request went to the client, which now owes a
	// reply.
	forwarded bool
}

// kittyClipboardInputState holds a client's input that may be the start of
// a reply split across reads. Guarded by the client's inputDispatchMu.
type kittyClipboardInputState struct {
	owedUntil  *atomic.Int64
	carry      []byte
	generation uint64
}

func isKittyClipboardOscPayload(payload []byte) bool {
	return bytes.HasPrefix(payload, []byte(kittyClipboardOscCode+";"))
}

// isKittyClipboardOscSequence reports whether sequence is a complete OSC 5522
// control string in its 7-bit or C1 form.
func isKittyClipboardOscSequence(sequence []byte) bool {
	switch {
	case len(sequence) >= 2 && sequence[0] == '\x1b' && sequence[1] == ']':
		return isKittyClipboardOscPayload(sequence[2:])
	case len(sequence) >= 1 && sequence[0] == 0x9d:
		return isKittyClipboardOscPayload(sequence[1:])
	}
	return false
}

func (c *attachClient) answersKittyClipboard() bool {
	if c == nil {
		return false
	}
	for _, record := range bytes.Split(
		c.capabilityHint,
		[]byte{capabilityHintRecordSeparator},
	) {
		key, _, found := bytes.Cut(record, []byte{capabilityHintFieldSeparator})
		if found && string(bytes.TrimSpace(key)) == capabilityHintKeyKittyClipboard {
			return true
		}
	}
	return false
}

// kittyClipboardRouteLocked reports where window's requests can go for the
// read being applied: to the primary attached client while the window is on
// screen and that client speaks the protocol. Requires s.mu.
func (s *muxServer) kittyClipboardRouteLocked(window *muxWindow) kittyClipboardRoute {
	if window == nil || !window.terminalOutputForwarding {
		return kittyClipboardRoute{}
	}
	return kittyClipboardRoute{
		onScreen: true,
		primary:  s.attachConn,
		client:   s.attachClients[s.attachConn],
	}
}

// kittyClipboardMetadata is the part of an OSC 5522 packet's metadata
// MonkeyMux acts on. records keeps every record, in order, for rewriting.
type kittyClipboardMetadata struct {
	records []string
	op      string
	id      string
	idIndex int
	hasMime bool
}

// parseKittyClipboardMetadata splits a packet's metadata into its colon
// separated key=value records. It fails, as kitty does, when a record has no
// '='.
func parseKittyClipboardMetadata(raw string) (kittyClipboardMetadata, bool) {
	metadata := kittyClipboardMetadata{
		records: strings.Split(raw, ":"),
		idIndex: -1,
	}
	for index, record := range metadata.records {
		key, value, found := strings.Cut(record, "=")
		if !found {
			return kittyClipboardMetadata{}, false
		}
		switch key {
		case "type":
			metadata.op = value
		case "id":
			metadata.id = value
			metadata.idIndex = index
		case "mime":
			metadata.hasMime = value != ""
		}
	}
	return metadata, true
}

// withID returns the metadata with its id record set to id, or removed when
// id is empty.
func (m kittyClipboardMetadata) withID(id string) string {
	records := make([]string, 0, len(m.records)+1)
	for index, record := range m.records {
		if index == m.idIndex {
			continue
		}
		records = append(records, record)
	}
	if id != "" {
		records = append(records, "id="+id)
	}
	return strings.Join(records, ":")
}

// sanitizeKittyClipboardID keeps the characters the spec allows in an id,
// [a-zA-Z0-9-_+.], leaving room for the window tag in kitty's 512 limit.
func sanitizeKittyClipboardID(id string) string {
	var builder strings.Builder
	for index := 0; index < len(id) && builder.Len() < 480; index++ {
		character := id[index]
		switch {
		case character >= 'a' && character <= 'z',
			character >= 'A' && character <= 'Z',
			character >= '0' && character <= '9',
			character == '-', character == '_', character == '+', character == '.':
			builder.WriteByte(character)
		}
	}
	return builder.String()
}

func kittyClipboardWindowTag(windowID string, id string) string {
	tag := kittyClipboardWindowTagPrefix + hex.EncodeToString([]byte(windowID))
	if id != "" {
		tag += "." + id
	}
	return tag
}

// untagKittyClipboardID splits an id MonkeyMux gave a request into its window
// and the program's own id.
func untagKittyClipboardID(tag string) (windowID string, id string, ok bool) {
	rest, found := strings.CutPrefix(tag, kittyClipboardWindowTagPrefix)
	if !found {
		return "", "", false
	}
	encoded, id, _ := strings.Cut(rest, ".")
	decoded, err := hex.DecodeString(encoded)
	if err != nil || len(decoded) == 0 {
		return "", "", false
	}
	return string(decoded), id, true
}

func kittyClipboardStatusReply(op string, status string, id string) []byte {
	reply := "\x1b]" + kittyClipboardOscCode + ";type=" + op + ":status=" + status
	if id != "" {
		reply += ":id=" + id
	}
	return []byte(reply + "\x1b\\")
}

// forwardKittyClipboardLocked decides what the attached client receives for
// one OSC 5522 packet of this window: the packet with its id tagged, the
// packet unchanged, or nothing when MonkeyMux answers it itself. terminator
// is the packet's string terminator. Requires the server's mu.
func (w *muxWindow) forwardKittyClipboardLocked(payload []byte, terminator []byte) []byte {
	state := &w.kittyClipboard
	forwarding := state.route.forwarding()
	body := string(payload[len(kittyClipboardOscCode)+1:])
	rawMetadata, data, hasData := strings.Cut(body, ";")
	metadata, ok := parseKittyClipboardMetadata(rawMetadata)
	unchanged := func() []byte {
		packet := make([]byte, 0, len(payload)+len(terminator)+2)
		packet = append(packet, "\x1b]"...)
		packet = append(packet, payload...)
		return append(packet, terminator...)
	}
	tagged := func() []byte {
		packet := "\x1b]" + kittyClipboardOscCode + ";" +
			metadata.withID(kittyClipboardWindowTag(w.id, sanitizeKittyClipboardID(metadata.id)))
		if hasData {
			packet += ";" + data
		}
		return append([]byte(packet), terminator...)
	}
	reject := func(op string, id string) {
		state.replies = append(state.replies, kittyClipboardStatusReply(op, "EBUSY", id)...)
	}
	if !ok {
		// A terminal drops malformed metadata without a reply.
		if forwarding {
			return unchanged()
		}
		return nil
	}
	commit := metadata.op == "wdata" && !metadata.hasMime
	switch metadata.op {
	case "read":
		if !forwarding {
			reject("read", sanitizeKittyClipboardID(metadata.id))
			return nil
		}
		state.forwarded = true
		return tagged()
	case "write":
		state.writeID = sanitizeKittyClipboardID(metadata.id)
		if !forwarding {
			state.write = kittyClipboardWriteRejected
			reject("write", state.writeID)
			return nil
		}
		state.write = kittyClipboardWriteForwarding
		state.writePrimary = state.route.primary
		state.forwarded = true
		return tagged()
	case "wdata", "walias":
		switch state.write {
		case kittyClipboardWriteForwarding:
			if forwarding && state.route.primary == state.writePrimary {
				if commit {
					state.write = kittyClipboardWriteNone
					state.forwarded = true
				}
				return unchanged()
			}
			state.write = kittyClipboardWriteRejected
			reject("write", state.writeID)
		}
		if commit {
			state.write = kittyClipboardWriteNone
		}
		// Data outside a forwarded write is dropped, as a terminal ignores
		// write packets after an error or without an open write.
		return nil
	default:
		if forwarding {
			return unchanged()
		}
		return nil
	}
}

// settleKittyClipboardOutputLocked applies what forwardKittyClipboardLocked
// recorded for one read of window. A write that is open on the clients but
// whose window left the screen, or whose client stopped being primary, can
// no longer complete, and is answered EBUSY even if this read carried none
// of its packets: a packet too large for the output scan passes through it
// unseen, so it must not be forwarded later with a gap before it. A window
// that opens a write takes the clients' only slot from any other window.
// Returns the replies MonkeyMux owes window itself. Requires s.mu.
func (s *muxServer) settleKittyClipboardOutputLocked(window *muxWindow, now time.Time) []byte {
	state := &window.kittyClipboard
	if state.write == kittyClipboardWriteForwarding &&
		(!state.route.forwarding() || state.route.primary != state.writePrimary) {
		state.write = kittyClipboardWriteRejected
		state.replies = append(state.replies, kittyClipboardStatusReply("write", "EBUSY", state.writeID)...)
	}
	if state.write == kittyClipboardWriteForwarding {
		if owner := s.kittyClipboardWriteWindow; owner != "" && owner != window.id {
			if other := s.windowByIDLocked(owner); other != nil &&
				other.kittyClipboard.write == kittyClipboardWriteForwarding {
				other.kittyClipboard.write = kittyClipboardWriteRejected
				s.queueWindowReply(
					other,
					kittyClipboardStatusReply("write", "EBUSY", other.kittyClipboard.writeID),
				)
			}
		}
		s.kittyClipboardWriteWindow = window.id
	} else if s.kittyClipboardWriteWindow == window.id {
		s.kittyClipboardWriteWindow = ""
	}
	if state.forwarded {
		s.noteKittyClipboardRepliesOwed(now)
	}
	replies := state.replies
	state.replies = nil
	state.forwarded = false
	state.route = kittyClipboardRoute{}
	return replies
}

func (s *muxServer) noteKittyClipboardRepliesOwed(now time.Time) {
	noteKittyClipboardRepliesOwed(&s.kittyClipboardRepliesOwedUntil, now)
}

func noteKittyClipboardRepliesOwed(owedUntil *atomic.Int64, now time.Time) {
	if owedUntil == nil {
		return
	}
	until := now.Add(kittyClipboardRepliesOwedGrace).UnixNano()
	for {
		current := owedUntil.Load()
		if current >= until || owedUntil.CompareAndSwap(current, until) {
			return
		}
	}
}

// untagKittyClipboardReply returns the window a reply is addressed to and the
// reply's payload with the program's own id restored.
func untagKittyClipboardReply(payload []byte) (string, []byte, bool) {
	if !isKittyClipboardOscPayload(payload) {
		return "", nil, false
	}
	body := string(payload[len(kittyClipboardOscCode)+1:])
	rawMetadata, data, hasData := strings.Cut(body, ";")
	metadata, ok := parseKittyClipboardMetadata(rawMetadata)
	if !ok || metadata.idIndex < 0 {
		return "", nil, false
	}
	windowID, id, ok := untagKittyClipboardID(metadata.id)
	if !ok {
		return "", nil, false
	}
	restored := kittyClipboardOscCode + ";" + metadata.withID(id)
	if hasData {
		restored += ";" + data
	}
	return windowID, []byte(restored), true
}

// splitKittyClipboardRepliesLocked takes the OSC 5522 replies addressed to a
// window out of a read of this client's input. It returns the rest of the
// input, for the usual routing, and one action per reply. Pasted text is
// never taken as a reply.
//
// A reply split across reads is held back until it is complete. So is a read
// ending in a bare prefix of `ESC ] 5522 ;` while replies are owed, released
// after kittyClipboardAmbiguousCarryTimeout if nothing completes it.
// Requires inputDispatchMu.
func (c *attachClient) splitKittyClipboardRepliesLocked(
	data []byte,
	now time.Time,
) ([]byte, []attachInputAction) {
	state := &c.kittyClipboardInput
	if len(state.carry) > 0 {
		data = append(append([]byte(nil), state.carry...), data...)
		state.carry = nil
		state.generation++
	}
	if bytes.IndexByte(data, '\x1b') < 0 {
		return data, nil
	}
	owed := state.owedUntil != nil && now.UnixNano() < state.owedUntil.Load()
	c.activityMu.Lock()
	inPaste := c.inputBracketedPasteActive
	c.activityMu.Unlock()

	var input []byte
	var replies []attachInputAction
	copyStart := 0
	holdStart := -1
	ambiguous := false
	for index := 0; index < len(data); index++ {
		if data[index] != '\x1b' {
			continue
		}
		rest := data[index:]
		switch {
		case bytes.HasPrefix(rest, kittyClipboardPasteStartInput):
			inPaste = true
			index += len(kittyClipboardPasteStartInput) - 1
			continue
		case bytes.HasPrefix(rest, kittyClipboardPasteEndInput):
			inPaste = false
			index += len(kittyClipboardPasteEndInput) - 1
			continue
		case inPaste:
			continue
		}
		if len(rest) < len(kittyClipboardOscIntroducer) {
			if owed && bytes.HasPrefix(kittyClipboardOscIntroducer, rest) {
				holdStart = index
				ambiguous = true
				break
			}
			continue
		}
		if !bytes.HasPrefix(rest, kittyClipboardOscIntroducer) {
			continue
		}
		payloadEnd, terminatorLength, complete := findOscTerminator(rest[2:])
		if !complete {
			if len(rest) <= kittyClipboardReplyLimitBytes {
				holdStart = index
				break
			}
			continue
		}
		sequenceLength := 2 + payloadEnd + terminatorLength
		windowID, restored, addressed := untagKittyClipboardReply(rest[2 : 2+payloadEnd])
		if addressed {
			input = append(input, data[copyStart:index]...)
			reply := make([]byte, 0, len(restored)+terminatorLength+2)
			reply = append(reply, "\x1b]"...)
			reply = append(reply, restored...)
			reply = append(reply, rest[2+payloadEnd:sequenceLength]...)
			replies = append(replies, attachInputAction{
				kittyClipboardReply: true,
				windowID:            windowID,
				data:                reply,
			})
			copyStart = index + sequenceLength
			noteKittyClipboardRepliesOwed(state.owedUntil, now)
		}
		index += sequenceLength - 1
	}
	end := len(data)
	if holdStart >= 0 {
		end = holdStart
		state.carry = append([]byte(nil), data[holdStart:]...)
		state.generation++
		if ambiguous {
			c.scheduleKittyClipboardCarryFlushLocked()
		}
	}
	if replies == nil && holdStart < 0 {
		return data, nil
	}
	input = append(input, data[copyStart:end]...)
	return input, replies
}

func (c *attachClient) scheduleKittyClipboardCarryFlushLocked() {
	generation := c.kittyClipboardInput.generation
	time.AfterFunc(kittyClipboardAmbiguousCarryTimeout, func() {
		c.flushKittyClipboardCarry(generation)
	})
}

// flushKittyClipboardCarry releases input held back as a possible reply that
// was never completed, routing it as it would have been.
func (c *attachClient) flushKittyClipboardCarry(generation uint64) {
	c.inputDispatchMu.Lock()
	defer c.inputDispatchMu.Unlock()
	state := &c.kittyClipboardInput
	if state.generation != generation || len(state.carry) == 0 {
		return
	}
	data := state.carry
	state.carry = nil
	state.generation++
	select {
	case <-c.done:
		return
	default:
	}
	routing := c.routeInput(data)
	if routing.claimsFocus && c.focusClaim != nil && c.focusSequenceSnapshot != nil {
		c.focusClaim(c.focusSequenceSnapshot())
	}
	c.enqueueInputActions(routing.actions)
}

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

	// kittyClipboardPacketLimitBytes bounds one OSC 5522 packet held whole
	// while it is split across reads, in a window's output or a client's
	// input. A data packet carries at most 4 KiB before base64, about 5.5 KiB
	// on the wire with its metadata; the rest is headroom. A window's packet
	// past this is dropped rather than forwarded unchecked.
	kittyClipboardPacketLimitBytes = 64 << 10

	// kittyClipboardRepliesOwedGrace is how long after a request is forwarded,
	// or a reply passes through, the client is assumed to be sending replies.
	// Only then is an input read that ends in a partial `ESC ] 5522 ;` held
	// back, since outside it a lone trailing ESC is the Escape key.
	kittyClipboardRepliesOwedGrace = 5 * time.Second

	// kittyClipboardAmbiguousCarryTimeout releases input held back because
	// it could have been the start of a reply but was not continued.
	kittyClipboardAmbiguousCarryTimeout = time.Second
)

var kittyClipboardOscIntroducer = []byte("\x1b]" + kittyClipboardOscCode + ";")

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
	// claimedWrite notes that a write was opened on the clients, replacing
	// any other window's open write there, even if this read also ended it.
	claimedWrite bool
	// discarding drops the rest of a packet too large to hold whole, up to
	// its terminator; discardEscape notes a read that ended on the ESC that
	// may start that terminator.
	discarding    bool
	discardEscape bool
}

// kittyClipboardInputState holds a client's input that may be the start of
// a reply split across reads. Guarded by the client's inputDispatchMu.
type kittyClipboardInputState struct {
	owedUntil  *atomic.Int64
	carry      []byte
	generation uint64
	// pasteActive tracks bracketed paste in the client's input as it arrives,
	// and pasteMarkerCarry the start of a paste marker a read ended in, so a
	// marker split across reads still opens or closes the paste.
	pasteActive      bool
	pasteMarkerCarry []byte
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
// read being applied: to the attached client the read is forwarded to while
// the window is on screen and that client speaks the protocol. That is the
// primary client, unless a query split across reads is still open: the read
// then goes to the client that received the query's start, as
// handleWindowOutput sends it, so every packet goes where the rest of the
// read goes. Requires s.mu.
func (s *muxServer) kittyClipboardRouteLocked(window *muxWindow) kittyClipboardRoute {
	if window == nil || !window.terminalOutputForwarding {
		return kittyClipboardRoute{}
	}
	primary := s.attachConn
	if len(window.secondaryQueryCarry) > 0 &&
		s.isAttachConnectionLocked(window.secondaryQueryPrimary) {
		primary = window.secondaryQueryPrimary
	}
	return kittyClipboardRoute{
		onScreen: true,
		primary:  primary,
		client:   s.attachClients[primary],
	}
}

// attachPartialOscLimitBytes is how much of an OSC split across reads the
// live stream holds back. An OSC 5522 packet is held whole, so its routing
// (tagging, rejection, primary-only delivery) applies to all of it rather
// than to whatever arrived in the read that completed it.
func attachPartialOscLimitBytes(partial []byte) int {
	if bytes.HasPrefix(partial, kittyClipboardOscIntroducer) {
		return kittyClipboardPacketLimitBytes
	}
	return oscBufferLimitBytes
}

// kittyClipboardOscCancelled reports whether a window's OSC 5522 packet,
// given its payload so far, is abandoned before any terminator, as the
// screen model's parser abandons it, and where ordinary output resumes:
// after a CAN or SUB, which end the string, or at an ESC that does not start
// ST, which starts the next sequence. It reports false for any other OSC.
func kittyClipboardOscCancelled(payload []byte) (resume int, cancelled bool) {
	if !isKittyClipboardOscPayload(payload) {
		return 0, false
	}
	for index := 0; index < len(payload); index++ {
		switch payload[index] {
		case '\a':
			return 0, false
		case 0x9c:
			if !isUtf8ContinuationAt(payload, index) {
				return 0, false
			}
		case 0x18, 0x1a:
			return index + 1, true
		case '\x1b':
			if index+1 >= len(payload) || payload[index+1] == '\\' {
				return 0, false
			}
			return index, true
		}
	}
	return 0, false
}

// discardKittyClipboardOscLocked drops a window's OSC 5522 packet that
// outgrew kittyClipboardPacketLimitBytes before its terminator arrived,
// given the packet's payload so far, which kittyClipboardOscCancelled found
// not cancelled. The write it belongs to cannot complete on the client any
// more and is answered EFBIG. Reports false for any other OSC. Requires the
// server's mu.
func (w *muxWindow) discardKittyClipboardOscLocked(payload []byte) bool {
	if !isKittyClipboardOscPayload(payload) {
		return false
	}
	state := &w.kittyClipboard
	state.discarding = true
	// A read can end on the ESC of the packet's own ST, which the next read
	// completes.
	state.discardEscape = payload[len(payload)-1] == '\x1b'
	body := payload[len(kittyClipboardOscCode)+1:]
	rawMetadata, _, _ := bytes.Cut(body, []byte(";"))
	metadata, ok := parseKittyClipboardMetadata(string(rawMetadata))
	if !ok {
		return true
	}
	switch metadata.op {
	case "write":
		state.writeID = sanitizeKittyClipboardID(metadata.id)
		state.write = kittyClipboardWriteRejected
	case "wdata", "walias":
		if state.write != kittyClipboardWriteForwarding {
			return true
		}
		state.write = kittyClipboardWriteRejected
	default:
		// A read has no error status for a malformed request.
		return true
	}
	state.replies = append(
		state.replies,
		kittyClipboardStatusReply("write", "EFBIG", state.writeID)...,
	)
	return true
}

// skipDiscardedKittyClipboardOscLocked removes from a window's next output
// the rest of a packet discardKittyClipboardOscLocked dropped. Requires the
// server's mu.
func (w *muxWindow) skipDiscardedKittyClipboardOscLocked(chunk []byte) []byte {
	state := &w.kittyClipboard
	if !state.discarding {
		return chunk
	}
	if state.discardEscape {
		state.discardEscape = false
		state.discarding = false
		if len(chunk) > 0 && chunk[0] == '\\' {
			return chunk[1:]
		}
		// The ESC started something else, which also ends the string: give
		// it back.
		return append([]byte{'\x1b'}, chunk...)
	}
	for index := 0; index < len(chunk); index++ {
		switch chunk[index] {
		case '\a', 0x18, 0x1a:
			// BEL ends the string; CAN and SUB cancel it.
			state.discarding = false
			return chunk[index+1:]
		case 0x9c:
			if !isUtf8ContinuationAt(chunk, index) {
				state.discarding = false
				return chunk[index+1:]
			}
		case '\x1b':
			if index+1 >= len(chunk) {
				state.discardEscape = true
				return nil
			}
			state.discarding = false
			if chunk[index+1] == '\\' {
				return chunk[index+2:]
			}
			return chunk[index:]
		}
	}
	return nil
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
		state.claimedWrite = true
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
// of its packets, so the rest of it is never forwarded with a gap before
// it. A window that opens a write takes the clients' only slot from any
// other window, which is answered EBUSY, even when the new write also ends
// in the same read. Returns the replies MonkeyMux owes window itself.
// Requires s.mu.
func (s *muxServer) settleKittyClipboardOutputLocked(window *muxWindow, now time.Time) []byte {
	state := &window.kittyClipboard
	if state.write == kittyClipboardWriteForwarding &&
		(!state.route.forwarding() || state.route.primary != state.writePrimary) {
		state.write = kittyClipboardWriteRejected
		state.replies = append(state.replies, kittyClipboardStatusReply("write", "EBUSY", state.writeID)...)
	}
	if state.claimedWrite {
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
	}
	if state.write != kittyClipboardWriteForwarding &&
		s.kittyClipboardWriteWindow == window.id {
		s.kittyClipboardWriteWindow = ""
	}
	if state.forwarded {
		s.noteKittyClipboardRepliesOwed(now)
	}
	replies := state.replies
	state.replies = nil
	state.forwarded = false
	state.claimedWrite = false
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
	c.activityMu.Lock()
	leadingUtf8Prefix := leadingUtf8ContinuationPrefix(data, c.inputUtf8Remaining)
	c.activityMu.Unlock()
	pasted := state.pastedRangesLocked(data, leadingUtf8Prefix)
	if carried := len(state.carry); carried > 0 {
		data = append(append([]byte(nil), state.carry...), data...)
		state.carry = nil
		state.generation++
		for index := range pasted {
			pasted[index][0] += carried
			pasted[index][1] += carried
		}
	}
	if bytes.IndexByte(data, '\x1b') < 0 {
		return data, nil
	}
	owed := state.owedUntil != nil && now.UnixNano() < state.owedUntil.Load()
	inPaste := func(index int) bool {
		for len(pasted) > 0 && pasted[0][1] <= index {
			pasted = pasted[1:]
		}
		return len(pasted) > 0 && pasted[0][0] <= index
	}

	var input []byte
	var replies []attachInputAction
	copyStart := 0
	holdStart := -1
	ambiguous := false
	for index := 0; index < len(data); index++ {
		if data[index] != '\x1b' {
			continue
		}
		if inPaste(index) {
			continue
		}
		rest := data[index:]
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
			if len(rest) <= kittyClipboardPacketLimitBytes {
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

// pastedRangesLocked advances the bracketed paste tracking over one read of
// a client's input and returns the [start, end) ranges of data that are
// pasted text, markers included. It matches the markers as the input routing
// does, 7-bit and C1, and remembers a marker split at the end of the read.
// Requires inputDispatchMu.
func (state *kittyClipboardInputState) pastedRangesLocked(
	data []byte,
	leadingUtf8Prefix int,
) [][2]int {
	scan := data
	offset := 0
	if carried := len(state.pasteMarkerCarry); carried > 0 {
		scan = append(append([]byte(nil), state.pasteMarkerCarry...), data...)
		offset = carried
		leadingUtf8Prefix = 0
	}
	var ranges [][2]int
	active := state.pasteActive
	regionStart := 0
	for position := 0; position <= len(scan); {
		prefix := max(0, leadingUtf8Prefix-position)
		if !active {
			start := bracketedPasteStart(scan[position:], prefix)
			if start.index < 0 {
				break
			}
			regionStart = position + start.index
			position += start.index + start.length
			active = true
			continue
		}
		end := bracketedPasteEnd(scan[position:], prefix)
		if end.index < 0 {
			ranges = append(ranges, [2]int{regionStart, len(scan)})
			break
		}
		position += end.index + end.length
		ranges = append(ranges, [2]int{regionStart, position})
		active = false
	}
	state.pasteActive = active
	sevenBit, eightBit := bracketedPasteStart7Bit, bracketedPasteStart8Bit
	if active {
		sevenBit, eightBit = bracketedPasteEnd7Bit, bracketedPasteEnd8Bit
	}
	suffix := bracketedPasteMarkerSuffixLength(scan, sevenBit, eightBit, leadingUtf8Prefix)
	state.pasteMarkerCarry = append(state.pasteMarkerCarry[:0], scan[len(scan)-suffix:]...)

	shifted := ranges[:0]
	for _, pastedRange := range ranges {
		pastedRange[0] = max(0, pastedRange[0]-offset)
		pastedRange[1] -= offset
		if pastedRange[1] > pastedRange[0] {
			shifted = append(shifted, pastedRange)
		}
	}
	return shifted
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

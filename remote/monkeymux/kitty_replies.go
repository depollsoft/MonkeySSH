package main

import (
	"bytes"
	"strconv"
	"sync"
)

// Kitty graphics replies, routed to the window that asked.
//
// The client answers a graphics command that names an image id (i=) or
// number (I=) with OK or an error, unless q= silences it. Whether it answers
// depends on the outcome (q=1 silences only OK, a=a answers only errors), so
// these replies cannot be counted ahead like other query replies. Every reply
// names the image instead, so MonkeyMux remembers which window last sent a
// command for each image and hands the reply to that window. A reply nothing
// claims is dropped: it is never typed into whatever window is active.

// maxKittyReplyRoutes bounds the images remembered across windows.
const maxKittyReplyRoutes = 512

// maxKittyReplyCarryBytes bounds a reply held while the rest of it arrives.
const maxKittyReplyCarryBytes = 256

// kittyReplyRoutes maps an image id or number to the window that last sent a
// graphics command naming it to the client.
type kittyReplyRoutes struct {
	mu     sync.Mutex
	window map[string]string
	order  []string
}

// note records the windows the graphics commands in data come from: data is
// output windowID is sending to the client.
func (r *kittyReplyRoutes) note(windowID string, data []byte) {
	if r == nil || windowID == "" || !bytes.Contains(data, []byte("\x1b_G")) {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	for index := 0; ; {
		start := bytes.Index(data[index:], []byte("\x1b_G"))
		if start < 0 {
			return
		}
		start += index + 3
		end := start
		for end < len(data) && data[end] != ';' && data[end] != '\x1b' &&
			data[end] != '\a' {
			end++
		}
		if end >= len(data) {
			return // the keys run past this chunk
		}
		index = end
		args := parseKittyControl(string(data[start:end]))
		if quiet, err := strconv.Atoi(args["q"]); err == nil && quiet >= 2 {
			continue
		}
		if key := kittyReplyKey(args); key != "" {
			r.rememberLocked(key, windowID)
		}
	}
}

func (r *kittyReplyRoutes) rememberLocked(key, windowID string) {
	if r.window == nil {
		r.window = make(map[string]string)
	}
	if _, ok := r.window[key]; ok {
		for index, existing := range r.order {
			if existing == key {
				r.order = append(r.order[:index], r.order[index+1:]...)
				break
			}
		}
	}
	r.window[key] = windowID
	r.order = append(r.order, key)
	if len(r.order) > maxKittyReplyRoutes {
		delete(r.window, r.order[0])
		r.order = r.order[1:]
	}
}

// lookup returns the window a reply belongs to, "" when no window claims it.
// payload is the reply between the APC introducer and its terminator.
func (r *kittyReplyRoutes) lookup(payload []byte) string {
	if r == nil || len(payload) < 1 || payload[0] != 'G' {
		return ""
	}
	control := payload[1:]
	if separator := bytes.IndexByte(control, ';'); separator >= 0 {
		control = control[:separator]
	}
	args := parseKittyControl(string(control))
	r.mu.Lock()
	defer r.mu.Unlock()
	// A reply to an I= command names the number and the id the client
	// picked for it; the number is what the window used.
	for _, key := range []string{
		kittyReplyKey(map[string]string{"I": args["I"]}),
		kittyReplyKey(map[string]string{"i": args["i"]}),
	} {
		if windowID := r.window[key]; key != "" && windowID != "" {
			return windowID
		}
	}
	return ""
}

// kittyReplyKey names the image a command's reply will name: its number when
// it has one, otherwise its id; "" when the reply could name neither.
func kittyReplyKey(args map[string]string) string {
	if number := kittyIDValue(args["I"]); number != "" {
		return "I:" + number
	}
	if id := kittyIDValue(args["i"]); id != "" {
		return "i:" + id
	}
	return ""
}

// takeKittyRepliesLocked removes the graphics replies from client input and
// routes each to the window that sent the command it answers, dropping any
// nothing claims. A reply cut off at the end of data is held until the rest
// arrives. It returns the input left for the usual routing.
func (c *attachClient) takeKittyRepliesLocked(
	data []byte,
	result *attachInputRouting,
) []byte {
	// A reply is held across one read at most, so input that only looks like
	// the start of one is never held up for long.
	carried := len(c.kittyReplyCarry) > 0
	if carried {
		data = append(c.kittyReplyCarry, data...)
		c.kittyReplyCarry = nil
	}
	if !bytes.Contains(data, []byte("\x1b_G")) {
		return data
	}
	var out []byte
	copyStart := 0
	for index := 0; index < len(data); {
		start := bytes.Index(data[index:], []byte("\x1b_G"))
		if start < 0 {
			break
		}
		start += index
		end := bytes.Index(data[start+3:], []byte("\x1b\\"))
		if end < 0 {
			if !carried && len(data)-start <= maxKittyReplyCarryBytes &&
				kittyReplyPrefix(data[start+2:]) {
				out = append(out, data[copyStart:start]...)
				c.kittyReplyCarry = append([]byte(nil), data[start:]...)
				return out
			}
			break
		}
		end += start + 3
		payload := data[start+2 : end]
		index = end + 2
		if !isTerminalResponseKitty(payload) {
			continue
		}
		out = append(out, data[copyStart:start]...)
		copyStart = index
		if windowID := c.kittyReplyRoutes.lookup(payload); windowID != "" {
			result.addResponse(windowID, data[start:index])
		}
	}
	if copyStart == 0 {
		return data
	}
	return append(out, data[copyStart:]...)
}

// kittyReplyPrefix reports whether partial reads like the start of a reply
// ("G" and keys, then perhaps ";" and a message), worth holding for the rest.
func kittyReplyPrefix(partial []byte) bool {
	if len(partial) == 0 || partial[0] != 'G' {
		return false
	}
	for _, b := range partial[1:] {
		if b < 0x20 && b != '\x1b' {
			return false
		}
	}
	return true
}

// silencedKittyReplayCommand returns a graphics command from replayed output
// with q=2, so running it again on attach sends no reply to a program that
// already had one, or nil when seq is not a graphics command or is already
// silent.
func silencedKittyReplayCommand(seq []byte) []byte {
	if !bytes.HasPrefix(seq, []byte("\x1b_G")) ||
		!bytes.HasSuffix(seq, []byte("\x1b\\")) {
		return nil
	}
	control := seq[3 : len(seq)-2]
	if separator := bytes.IndexByte(control, ';'); separator >= 0 {
		control = control[:separator]
	}
	quiet, err := strconv.Atoi(parseKittyControl(string(control))["q"])
	if err == nil && quiet >= 2 {
		return nil
	}
	return rewriteKittyReplayCommand(seq, false)
}

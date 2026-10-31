package main

import (
	"strings"
)

// Visibility reports (DEC private mode 2033) tell a program whether anyone can
// see it: https://rockorager.dev/misc/visibility-reports/
//
// MonkeyMux is the program's terminal, so it owns the mode per window. A window
// is potentially visible while it is the active window and at least one
// attached client has not said it is hidden (client_visibility). A client that
// never says (an older app, or a terminal running `monkeymux attach`) counts as
// visible. The attached terminal never sees the mode, the `CSI ? 998 n` query
// or a DECRQM for the mode: MonkeyMux strips them from the forwarded output and
// from replays, and answers exactly what it strips, so no program gets two
// answers or a report about the wrong window.

const visibilityReportsMode = "2033"

const (
	visibilityUnreported = iota
	visibilityReportedVisible
	visibilityReportedHidden
)

// windowVisibility is a window's visibility-report state, guarded by s.mu.
type windowVisibility struct {
	// enabled mirrors mode 2033.
	enabled bool
	// reported is the state last sent while enabled, so a change is reported
	// once.
	reported int
	// potentiallyVisible is the window's visibility while its output is
	// observed; handleWindowOutput sets it before each read.
	potentiallyVisible bool
	// replies holds the reports and DECRQM answers the observed output asked
	// for, in order, until handleWindowOutput queues them.
	replies []byte
}

func visibilityReportSequence(visible bool) []byte {
	if visible {
		return []byte("\x1b[?999;1n")
	}
	return []byte("\x1b[?999;2n")
}

func visibilityReportedState(visible bool) int {
	if visible {
		return visibilityReportedVisible
	}
	return visibilityReportedHidden
}

// windowPotentiallyVisibleLocked reports whether some attached client shows
// the window and has not said it is hidden.
func (s *muxServer) windowPotentiallyVisibleLocked(window *muxWindow) bool {
	if window == nil || window.closed || window.id != s.activeID {
		return false
	}
	for _, client := range s.attachClients {
		if _, hidden := s.hiddenClientIDs[client.id]; !hidden {
			return true
		}
	}
	return false
}

// refreshWindowVisibilityLocked reports a visibility change to every window
// that has visibility reports enabled. Callers run it after the active window,
// the attached clients or a client's visibility change.
func (s *muxServer) refreshWindowVisibilityLocked() {
	for _, window := range s.windows {
		if window.closed || !window.visibility.enabled {
			continue
		}
		visible := s.windowPotentiallyVisibleLocked(window)
		state := visibilityReportedState(visible)
		if window.visibility.reported == state {
			continue
		}
		window.visibility.reported = state
		s.queueWindowReply(window, visibilityReportSequence(visible))
	}
}

// setClientHiddenLocked records whether the attach client with id says its
// view is hidden, as told over the control connection owner.
func (s *muxServer) setClientHiddenLocked(id string, hidden bool, owner *controlClient) {
	if hidden {
		if s.hiddenClientIDs == nil {
			s.hiddenClientIDs = map[string]*controlClient{}
		}
		s.hiddenClientIDs[id] = owner
	} else {
		delete(s.hiddenClientIDs, id)
	}
	s.refreshWindowVisibilityLocked()
}

// forgetClientVisibilityLocked drops a hidden flag once neither an attach
// client with id nor the control connection that set it remains, so a later
// attach under the same id starts out visible. The app sends its state once
// per control connection, so an attach that reconnects under the same id
// while that connection lives must find the flag still set.
func (s *muxServer) forgetClientVisibilityLocked(id string) {
	owner, ok := s.hiddenClientIDs[id]
	if !ok {
		return
	}
	if _, live := s.controls[owner]; live && owner != nil {
		return
	}
	for _, client := range s.attachClients {
		if client.id == id {
			return
		}
	}
	delete(s.hiddenClientIDs, id)
}

// releaseClientVisibilityLocked forgets the hidden flags control set once it
// has gone, unless an attach client still holds them.
func (s *muxServer) releaseClientVisibilityLocked(control *controlClient) {
	for id, owner := range s.hiddenClientIDs {
		if owner == control {
			s.hiddenClientIDs[id] = nil
			s.forgetClientVisibilityLocked(id)
		}
	}
}

// setVisibilityReportsLocked applies `CSI ? 2033 h/l`. Enabling reports the
// current state at once, even when the mode is already on.
func (w *muxWindow) setVisibilityReportsLocked(enabled bool) {
	w.visibility.enabled = enabled
	if !enabled {
		w.visibility.reported = visibilityUnreported
		return
	}
	w.appendVisibilityReportLocked()
}

func (w *muxWindow) appendVisibilityReportLocked() {
	visible := w.visibility.potentiallyVisible
	if w.visibility.enabled {
		w.visibility.reported = visibilityReportedState(visible)
	}
	w.visibility.replies = append(
		w.visibility.replies,
		visibilityReportSequence(visible)...,
	)
}

// observeVisibilityCsiLocked answers the visibility query and the DECRQM for
// mode 2033 in observed output. params excludes the final byte.
func (w *muxWindow) observeVisibilityCsiLocked(params string, final byte) {
	switch visibilityCsiKind(params, final) {
	case visibilityCsiQuery:
		w.appendVisibilityReportLocked()
	case visibilityCsiModeQuery:
		state := "2"
		if w.visibility.enabled {
			state = "1"
		}
		w.visibility.replies = append(
			w.visibility.replies,
			"\x1b[?"+visibilityReportsMode+";"+state+"$y"...,
		)
	}
}

func (w *muxWindow) takeVisibilityRepliesLocked() []byte {
	replies := w.visibility.replies
	w.visibility.replies = nil
	return replies
}

func (w *muxWindow) resetVisibilityReportsLocked() {
	w.visibility.enabled = false
	w.visibility.reported = visibilityUnreported
}

const (
	visibilityCsiNone = iota
	visibilityCsiQuery
	visibilityCsiModeQuery
	visibilityCsiModeChange
)

// visibilityCsiKind classifies a CSI by its parameters (with any private
// prefix and intermediates, without the final byte): the `CSI ? 998 n` query,
// a DECRQM for mode 2033, or a mode set or reset that names 2033.
func visibilityCsiKind(params string, final byte) int {
	switch final {
	case 'n':
		if normalizedCsiQueryParams(params) == "?998" {
			return visibilityCsiQuery
		}
	case 'p':
		if normalizedCsiQueryParams(params) == "?"+visibilityReportsMode+"$" {
			return visibilityCsiModeQuery
		}
	case 'h', 'l':
		if !strings.HasPrefix(params, "?") {
			return visibilityCsiNone
		}
		for _, mode := range csiModeParams(params[1:]) {
			if isVisibilityReportsMode(mode) {
				return visibilityCsiModeChange
			}
		}
	}
	return visibilityCsiNone
}

func isVisibilityReportsMode(mode string) bool {
	return strings.TrimLeft(mode, "0") == visibilityReportsMode
}

// visibilityCsiReplacement returns what the attached terminal gets in place of
// sequence, a complete CSI in 7-bit or C1 form: nothing for the query and the
// DECRQM, and a mode change without 2033 (nothing when 2033 was its only
// mode). ok is false for any other sequence.
func visibilityCsiReplacement(sequence []byte) (replacement []byte, ok bool) {
	bodyStart := 0
	switch {
	case len(sequence) >= 3 && sequence[0] == '\x1b' && sequence[1] == '[':
		bodyStart = 2
	case len(sequence) >= 2 && sequence[0] == 0x9b:
		bodyStart = 1
	default:
		return nil, false
	}
	final := sequence[len(sequence)-1]
	params := string(sequence[bodyStart : len(sequence)-1])
	switch visibilityCsiKind(params, final) {
	case visibilityCsiQuery, visibilityCsiModeQuery:
		return nil, true
	case visibilityCsiModeChange:
		var kept []string
		for _, part := range strings.Split(params[1:], ";") {
			mode, _, _ := strings.Cut(part, ":")
			if !isVisibilityReportsMode(mode) {
				kept = append(kept, part)
			}
		}
		if strings.Join(kept, "") == "" {
			return nil, true
		}
		replacement = append(replacement, sequence[:bodyStart]...)
		replacement = append(replacement, '?')
		replacement = append(replacement, strings.Join(kept, ";")...)
		return append(replacement, final), true
	}
	return nil, false
}

// visibilityCsiMayFollow reports whether partial, the start of a CSI that has
// not ended yet (ESC [ or 0x9b and what follows), could still become a
// sequence visibilityCsiReplacement changes, so the stripper holds it until
// it ends.
func visibilityCsiMayFollow(partial []byte) bool {
	body := partial[1:]
	if partial[0] == '\x1b' {
		body = partial[2:]
	}
	if len(body) == 0 {
		return true
	}
	if body[0] != '?' {
		return false
	}
	for _, b := range body[1:] {
		if (b < '0' || b > '9') && b != ';' && b != ':' && b != '$' {
			return false
		}
	}
	return true
}

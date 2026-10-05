# go-attach handoff

Two one-line edits in `remote/monkeymux/main.go` fall outside the go-attach line region
(>= ~10300) but were unavoidable to keep the tree compiling:

1. `muxWindow` struct (around line 861): deleted the field
   `redrawForwardingFallbackHistory []byte`. The redraw pause now retains only
   `redrawForwardingFallbackScreen` and renders the fallback frame lazily on resume
   (finding 1). Nothing else referenced the field.
2. Around line 10175 (attach handshake): `s.writeAttach(attach, modeReplay)` became
   `s.writeAttach(modeReplay)` after dropping the ignored `conn` parameter (finding 8).

Test files outside the named list that needed a touch: none (the
`foregroundHistoryFallbackHistoryLocked` helper used by `redraw_windows_test.go:285` now
lives in `test_helpers_test.go` with the same signature).

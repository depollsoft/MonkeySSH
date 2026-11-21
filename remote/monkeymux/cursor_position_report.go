package main

// extendedCursorPositionReport turns a cursor position report (CSI row ; col
// R) into the DECXCPR answer the app's terminal gives: CSI ? row ; col R. Like
// xterm at the VT220 level the app identifies as, it reports no page.
func extendedCursorPositionReport(report []byte) []byte {
	if len(report) < 4 || report[0] != '\x1b' || report[1] != '[' ||
		report[len(report)-1] != 'R' {
		return report
	}
	extended := make([]byte, 0, len(report)+1)
	extended = append(extended, "\x1b[?"...)
	return append(extended, report[2:]...)
}

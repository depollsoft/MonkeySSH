package main

// extendedCursorPositionReport turns a cursor position report (CSI row ; col
// R) into the DECXCPR answer the app's terminal gives: CSI ? row ; col ; 1 R,
// page 1 being its only page.
func extendedCursorPositionReport(report []byte) []byte {
	if len(report) < 4 || report[0] != '\x1b' || report[1] != '[' ||
		report[len(report)-1] != 'R' {
		return report
	}
	extended := make([]byte, 0, len(report)+3)
	extended = append(extended, "\x1b[?"...)
	extended = append(extended, report[2:len(report)-1]...)
	return append(extended, ";1R"...)
}

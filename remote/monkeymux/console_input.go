package main

// Native console readers have no paste event. Remove only the framing while
// retaining the payload, including literal control strings inside it. Holding
// incomplete markers avoids ConPTY timing out a lone ESC between input writes.
type nativeConsolePasteFilter struct {
	carry         []byte
	inPaste       bool
	utf8Remaining int
}

func (f *nativeConsolePasteFilter) filter(input []byte) []byte {
	data := append(f.carry, input...)
	f.carry = nil
	leading := leadingUtf8ContinuationPrefix(data, f.utf8Remaining)
	f.utf8Remaining = nextQueryUtf8Remaining(data, f.utf8Remaining, leading)
	var output []byte
	for len(data) > 0 {
		sevenBit, eightBit := bracketedPasteStart7Bit, bracketedPasteStart8Bit
		if f.inPaste {
			sevenBit, eightBit = bracketedPasteEnd7Bit, bracketedPasteEnd8Bit
		}
		match := matchBracketedPasteMarker(data, sevenBit, eightBit, leading)
		if match.index >= 0 {
			output = append(output, data[:match.index]...)
			consumed := match.index + match.length
			data = data[consumed:]
			leading = max(0, leading-consumed)
			f.inPaste = !f.inPaste
			continue
		}
		suffix := bracketedPasteMarkerSuffixLength(data, sevenBit, eightBit, leading)
		output = append(output, data[:len(data)-suffix]...)
		f.carry = append(f.carry, data[len(data)-suffix:]...)
		break
	}
	return output
}

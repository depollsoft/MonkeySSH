package main

import "bytes"

// stripTerminalProgressFromRestoreHistory removes task state owned by a process
// that an upgrade stopped. Do not use this on ordinary reconnect history: that
// process is still running and its progress remains valid.
func stripTerminalProgressFromRestoreHistory(data []byte) []byte {
	var output []byte
	copyStart := 0
	for index := 0; index < len(data); {
		end, _, incomplete, recognized := terminalQuerySequenceAt(data, index)
		if incomplete {
			break
		}
		if !recognized {
			index++
			continue
		}
		if isTerminalProgressOscSequence(data[index:end]) {
			if output == nil {
				output = make([]byte, 0, len(data)-(end-index))
			}
			output = append(output, data[copyStart:index]...)
			copyStart = end
		}
		index = end
	}
	if output == nil {
		return data
	}
	return append(output, data[copyStart:]...)
}

func isTerminalProgressOscSequence(sequence []byte) bool {
	payloadStart := 0
	switch {
	case bytes.HasPrefix(sequence, []byte("\x1b]")):
		payloadStart = 2
	case len(sequence) > 0 && sequence[0] == 0x9d:
		payloadStart = 1
	default:
		return false
	}
	end, _, ok := findOscTerminator(sequence[payloadStart:])
	if !ok {
		return false
	}
	code, value, ok := bytes.Cut(sequence[payloadStart:payloadStart+end], []byte(";"))
	if !ok || !bytes.Equal(code, []byte("9")) {
		return false
	}
	subcommand, _, hasState := bytes.Cut(value, []byte(";"))
	return hasState && bytes.Equal(bytes.TrimSpace(subcommand), []byte("4"))
}

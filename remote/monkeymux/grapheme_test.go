package main

import (
	"fmt"
	"hash/crc32"
	"os"
	"strconv"
	"strings"
	"testing"
)

// TestGraphemePropertyMatchesSharedTable pins graphemeProperty to the digest
// of the table scripts/generate_unicode_grapheme_tables.py generates for both
// the model and the client, whose own test checks the same digest.
func TestGraphemePropertyMatchesSharedTable(t *testing.T) {
	data, err := os.ReadFile("../../scripts/unicode_grapheme_table.crc32")
	if err != nil {
		t.Fatal(err)
	}
	digest := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		if fields := strings.Fields(line); len(fields) == 2 && !strings.HasPrefix(line, "#") {
			digest[fields[0]] = fields[1]
		}
	}
	values := make([]byte, 0x110000)
	for r := range values {
		values[r] = graphemeProperty(rune(r))
	}
	if got := fmt.Sprintf("%08x", crc32.ChecksumIEEE(values)); got != digest["crc32"] || digest["unicode"] != graphemeUnicodeVersion {
		t.Fatalf("graphemeProperty (Unicode %s, crc32 %s) differs from the shared table %v; rerun scripts/generate_unicode_grapheme_tables.py",
			graphemeUnicodeVersion, got, digest)
	}
}

// TestGraphemeBreakPassesUnicodeTests runs the Unicode break tests, which the
// client runs through its port of the same rules. Tests with controls are
// skipped: terminals never print them. Ghostty's tailoring breaks before an
// emoji modifier that does not follow an emoji modifier base, and without
// GB9c a consonant joins only a prepended mark.
func TestGraphemeBreakPassesUnicodeTests(t *testing.T) {
	data, err := os.ReadFile("testdata/grapheme_break_test.txt")
	if err != nil {
		t.Fatal(err)
	}
	tested := 0
lines:
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Fields(line)
		var runes []rune
		for i := 1; i < len(parts); i += 2 {
			value, err := strconv.ParseInt(parts[i], 16, 32)
			if err != nil {
				t.Fatalf("%q: %v", line, err)
			}
			if value < 0x20 {
				continue lines
			}
			runes = append(runes, rune(value))
		}
		tested++
		var state graphemeBreakState
		for i := 0; i+1 < len(runes); i++ {
			want := parts[2*i+2] == "÷"
			if graphemeClassOf(runes[i+1]) == graphemeEmojiModifier && graphemeClassOf(runes[i]) != graphemeEmojiModifierBase {
				want = true
			}
			if graphemeClassOf(runes[i+1]) == graphemeIncbConsonant && graphemeClassOf(runes[i]) != graphemePrepend {
				want = true
			}
			if graphemeBreak(runes[i], runes[i+1], &state) != want {
				t.Errorf("%s: pair %d broke=%v", line, i, !want)
				break
			}
		}
	}
	if tested < 500 {
		t.Fatalf("only %d tests ran", tested)
	}
}

func TestGraphemeWidthEffects(t *testing.T) {
	cases := []struct {
		previous, r rune
		want        graphemeWidthEffect
	}{
		{0x2665, emojiPresentationSelector, graphemeWide},
		{0x231A, textPresentationSelector, graphemeNarrow},
		{'1', emojiPresentationSelector, graphemeWide},
		{'a', emojiPresentationSelector, graphemeIgnore},
		// A regional indicator pairs into a flag; a spacing mark has a column.
		{0x1F1FA, 0x1F1F8, graphemeWide},
		{0x0915, 0x093F, graphemeWide},
		// Marks, joiners, modifiers and Hangul vowels and finals add nothing.
		{0x1F468, 0x0301, graphemeNoChange},
		{0x1F468, 0x200D, graphemeNoChange},
		{0x1F468, 0x1F3FD, graphemeNoChange},
		{0x1100, 0x1161, graphemeNoChange},
		{0x1100, 0x11A8, graphemeNoChange},
	}
	for _, c := range cases {
		if got := graphemeWidthEffectOf(c.previous, c.r); got != c.want {
			t.Errorf("effect(%U, %U) = %d, want %d", c.previous, c.r, got, c.want)
		}
	}
	if graphemeStartWidth(0x1F3FD) != 2 || graphemeStartWidth('A') != 1 || graphemeStartWidth(0x0301) != 0 {
		t.Fatal("start widths")
	}
}

package main

// Grapheme clustering (mode 2027) joins the code points of one user-perceived
// character into one cell, as Ghostty does. The client's xterm fork ports the
// same rules (third_party/xterm/lib/src/utils/grapheme.dart), and both run the
// Unicode break tests, so the model joins and sizes clusters as the client
// does.

const (
	textPresentationSelector  = 0xFE0E
	emojiPresentationSelector = 0xFE0F
	graphemeClassMask         = graphemeVSBase - 1
)

// graphemeBreakState is the context graphemeBreak carries from one code point
// pair to the next.
type graphemeBreakState struct {
	// base is the sequence the pair is inside, for GB11 to GB13.
	base uint8
}

const (
	graphemeBaseDefault uint8 = iota
	graphemeBasePictographic
	graphemeBaseRegionalIndicator
)

func graphemeClassOf(r rune) graphemeClass {
	return graphemeClass(graphemeProperty(r) & graphemeClassMask)
}

// graphemeBreak reports whether a grapheme cluster ends between r1 and r2,
// updating state. Call it for every consecutive pair, starting from a zero
// state at the cluster's first code point.
//
// These are Ghostty's rules (its uucode library's no-control variant): UAX
// #29 with an emoji modifier joining only an emoji modifier base, as UTS #51
// has it. Unlike Ghostty, there is no GB9c: a consonant after a virama starts
// a cluster of its own. tmux and wcwidth give each consonant its own cell, and
// a conjunct joined into one wide cell put the two out of step: tmux redraws
// the second consonant by backspacing onto that cell's right half, which
// erased the conjunct. Controls never reach a terminal's print path and count
// as other.
func graphemeBreak(r1, r2 rune, state *graphemeBreakState) bool {
	gb1 := graphemeClassOf(r1)
	gb2 := graphemeClassOf(r2)

	switch state.base {
	case graphemeBaseRegionalIndicator:
		if gb1 != graphemeRegionalIndicator || gb2 != graphemeRegionalIndicator {
			state.base = graphemeBaseDefault
		}
	case graphemeBasePictographic:
		if !graphemeContinuesEmoji(gb1) || !graphemeContinuesEmoji(gb2) {
			state.base = graphemeBaseDefault
		}
	}

	// GB6, GB7, GB8: Hangul syllable sequences.
	if gb1 == graphemeL && (gb2 == graphemeL || gb2 == graphemeV || gb2 == graphemeLv || gb2 == graphemeLvt) {
		return false
	}
	if (gb1 == graphemeLv || gb1 == graphemeV) && (gb2 == graphemeV || gb2 == graphemeT) {
		return false
	}
	if (gb1 == graphemeLvt || gb1 == graphemeT) && gb2 == graphemeT {
		return false
	}

	// GB9a, GB9b.
	if gb2 == graphemeSpacingMark || gb1 == graphemePrepend {
		return false
	}

	// GB11: emoji ZWJ sequences, and emoji modifier sequences.
	if graphemeIsPictographic(gb1) {
		if graphemeIsExtend(gb2) || gb2 == graphemeZwj {
			state.base = graphemeBasePictographic
			return false
		}
		if gb1 == graphemeEmojiModifierBase && gb2 == graphemeEmojiModifier {
			state.base = graphemeBasePictographic
			return false
		}
	} else if state.base == graphemeBasePictographic {
		if (graphemeIsExtend(gb1) || gb1 == graphemeEmojiModifier) && (graphemeIsExtend(gb2) || gb2 == graphemeZwj) {
			return false
		}
		state.base = graphemeBaseDefault
		if gb1 == graphemeZwj && graphemeIsPictographic(gb2) {
			return false
		}
	}

	// GB12, GB13: regional indicators pair up.
	if gb1 == graphemeRegionalIndicator && gb2 == graphemeRegionalIndicator {
		if state.base == graphemeBaseDefault {
			state.base = graphemeBaseRegionalIndicator
			return false
		}
		state.base = graphemeBaseDefault
		return true
	}

	// GB9, then GB999.
	return !(graphemeIsExtend(gb2) || gb2 == graphemeZwj)
}

// graphemeWidthEffect is how appending a code point changes a cluster's width.
type graphemeWidthEffect uint8

const (
	// graphemeIgnore leaves the code point out of the cluster, and the break
	// state as it was before it: an emoji variation selector after a code
	// point it does not apply to.
	graphemeIgnore graphemeWidthEffect = iota
	// graphemeNoChange appends it; the width stays.
	graphemeNoChange
	// graphemeWide appends it; the cluster takes two columns.
	graphemeWide
	// graphemeNarrow appends it; the cluster takes one column.
	graphemeNarrow
)

// graphemeWidthEffectOf is the effect of appending r to a cluster whose last
// code point is previous, once graphemeBreak has found no break between them.
// As in Ghostty, a code point that has a width of its own makes the cluster
// wide.
func graphemeWidthEffectOf(previous, r rune) graphemeWidthEffect {
	if r == emojiPresentationSelector || r == textPresentationSelector {
		if graphemeProperty(previous)&graphemeVSBase == 0 {
			return graphemeIgnore
		}
		if r == emojiPresentationSelector {
			return graphemeWide
		}
		return graphemeNarrow
	}
	if !graphemeZeroWidthInCluster(r) {
		return graphemeWide
	}
	return graphemeNoChange
}

// graphemeZeroWidthInCluster reports whether r adds no width to the cluster it
// joins: anything of width 0, emoji modifiers, Hangul medial vowels and final
// consonants, and prepended concatenation marks.
func graphemeZeroWidthInCluster(r rune) bool {
	if runeWidth(r) == 0 {
		return true
	}
	switch graphemeClassOf(r) {
	case graphemeEmojiModifier, graphemeV, graphemeT, graphemePrepend:
		return true
	}
	return false
}

// graphemeStartWidth is the columns r takes when it starts a cluster with
// clustering on: its width, except that an emoji modifier on its own is shown
// as a two-column color swatch, as in Ghostty.
func graphemeStartWidth(r rune) int {
	if graphemeClassOf(r) == graphemeEmojiModifier {
		return 2
	}
	return runeWidth(r)
}

// graphemeMayContinue reports whether r can continue a grapheme cluster,
// which keeps the rest of Latin-1, and so ASCII, off the slower path. Up to
// U+00FF only the Extended_Pictographic © and ® can, after a ZWJ. Anything
// can follow a prepended concatenation mark (GB9b); like Ghostty, a terminal
// ignores that for Latin-1.
func graphemeMayContinue(r rune) bool {
	return r > 0xFF || r == 0xA9 || r == 0xAE
}

// isEmojiVariationSelector reports VS15 and VS16, which in legacy mode only
// attach after an extended pictographic code point.
func isEmojiVariationSelector(r rune) bool {
	return r == emojiPresentationSelector || r == textPresentationSelector
}

// isExtendedPictographic reports whether r is Extended_Pictographic.
func isExtendedPictographic(r rune) bool {
	return graphemeIsPictographic(graphemeClassOf(r))
}

func graphemeIsExtend(gb graphemeClass) bool {
	return gb == graphemeZwnj || gb == graphemeIncbExtend || gb == graphemeIncbLinkerExtend
}

func graphemeIsPictographic(gb graphemeClass) bool {
	return gb == graphemeExtendedPictographic || gb == graphemeEmojiModifierBase
}

func graphemeContinuesEmoji(gb graphemeClass) bool {
	switch gb {
	case graphemeIncbExtend, graphemeIncbLinkerExtend, graphemeZwnj, graphemeZwj,
		graphemeExtendedPictographic, graphemeEmojiModifierBase, graphemeEmojiModifier:
		return true
	}
	return false
}

"""Classes and freshness of the grapheme table shared by MonkeyMux and the client.

The UCD files are not in the repository: set UCD_DIR to a directory holding
them (see scripts/generate_unicode_grapheme_tables.py) to run these tests.
"""

import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import generate_unicode_grapheme_tables as generator

UCD_DIR = os.environ.get('UCD_DIR')
C = generator.CLASS


def grapheme_break(gb1, gb2, state):
    """uucode's computeGraphemeBreakNoControl without GB9c: a terminal gives a
    consonant after a virama a cell of its own, as tmux and wcwidth do. state
    is [base]."""
    def extend(gb):
        return gb in (C['zwnj'], C['incb_extend'], C['incb_linker_extend'])

    def pictographic(gb):
        return gb in (C['extended_pictographic'], C['emoji_modifier_base'])

    joins_emoji = (C['incb_extend'], C['incb_linker_extend'], C['zwnj'], C['zwj'],
                   C['extended_pictographic'], C['emoji_modifier_base'], C['emoji_modifier'])
    if state[0] == 'ri':
        if gb1 != C['regional_indicator'] or gb2 != C['regional_indicator']:
            state[0] = 'default'
    elif state[0] == 'pict':
        if gb1 not in joins_emoji or gb2 not in joins_emoji:
            state[0] = 'default'
    if gb1 == C['l'] and gb2 in (C['l'], C['v'], C['lv'], C['lvt']):
        return False
    if gb1 in (C['lv'], C['v']) and gb2 in (C['v'], C['t']):
        return False
    if gb1 in (C['lvt'], C['t']) and gb2 == C['t']:
        return False
    if gb2 == C['spacing_mark'] or gb1 == C['prepend']:
        return False
    if pictographic(gb1):
        if extend(gb2) or gb2 == C['zwj']:
            state[0] = 'pict'
            return False
        if gb1 == C['emoji_modifier_base'] and gb2 == C['emoji_modifier']:
            state[0] = 'pict'
            return False
    elif state[0] == 'pict':
        if (extend(gb1) or gb1 == C['emoji_modifier']) and (extend(gb2) or gb2 == C['zwj']):
            return False
        state[0] = 'default'
        if gb1 == C['zwj'] and pictographic(gb2):
            return False
    if gb1 == C['regional_indicator'] and gb2 == C['regional_indicator']:
        if state[0] == 'default':
            state[0] = 'ri'
            return False
        state[0] = 'default'
        return True
    return not (extend(gb2) or gb2 == C['zwj'])


@unittest.skipUnless(UCD_DIR, 'set UCD_DIR to the Unicode data files')
class GraphemeTableTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.table = generator.property_table(Path(UCD_DIR))

    def test_classes(self):
        classes = {
            0x41: 'other', 0x0301: 'incb_extend', 0x200D: 'zwj', 0x200C: 'zwnj',
            0x1F1FA: 'regional_indicator', 0x1F468: 'emoji_modifier_base',
            0x1F3FB: 'emoji_modifier', 0x2665: 'extended_pictographic',
            0x0915: 'incb_consonant', 0x094D: 'incb_linker_extend', 0x093F: 'spacing_mark',
            0x1100: 'l', 0x1161: 'v', 0x11A8: 't', 0xAC00: 'lv', 0xAC01: 'lvt',
            0x0600: 'prepend', 0x0D: 'other', 0xFE0F: 'incb_extend',
        }
        for code_point, name in classes.items():
            with self.subTest(code_point=hex(code_point)):
                self.assertEqual(self.table[code_point] & ~generator.VS_BASE, C[name])
        for base in (0x23, 0x31, 0x2665, 0x231A):
            self.assertTrue(self.table[base] & generator.VS_BASE, hex(base))
        for other in (0x41, 0x1F468):
            self.assertFalse(self.table[other] & generator.VS_BASE, hex(other))

    def test_break_rules_pass_the_unicode_tests(self):
        """The rules both sides port, against GraphemeBreakTest.txt, with
        uucode's tailoring (an emoji modifier joins only an emoji modifier
        base) and without GB9c (a consonant joins only after a prepended
        mark). Tests with controls are skipped, as terminals never print
        them."""
        failures = []
        for line in generator.break_tests(Path(UCD_DIR)):
            parts = line.split()
            code_points = [int(part, 16) for part in parts[1::2]]
            expected = [part == '÷' for part in parts[2:-1:2]]
            if any(cp in _CONTROLS for cp in code_points):
                continue
            state = ['default']
            for i, want in enumerate(expected):
                gb1 = self.table[code_points[i]] & 0x1F
                gb2 = self.table[code_points[i + 1]] & 0x1F
                if gb2 == C['emoji_modifier'] and gb1 != C['emoji_modifier_base']:
                    want = True
                if gb2 == C['incb_consonant'] and gb1 != C['prepend']:
                    want = True
                if grapheme_break(gb1, gb2, state) != want:
                    failures.append(line)
                    break
        self.assertEqual(failures, [])

    def test_checked_in_tables_are_current(self):
        self.assertEqual(generator.main(['--check', '--ucd', UCD_DIR]), 0)


def _controls():
    """Code points of the Control, CR and LF break classes."""
    if not UCD_DIR:
        return frozenset()
    controls = set()
    for first, last, fields in generator._ranges(Path(UCD_DIR) / 'GraphemeBreakProperty.txt'):
        if fields[0] in ('Control', 'CR', 'LF'):
            controls.update(range(first, last + 1))
    return frozenset(controls)


_CONTROLS = _controls()


if __name__ == '__main__':
    unittest.main()

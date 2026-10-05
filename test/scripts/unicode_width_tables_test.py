"""Rules and freshness of the terminal width table shared by MonkeyMux and the client."""

from pathlib import Path
import sys
import unicodedata
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import generate_unicode_width_tables as generator


class WidthTableTest(unittest.TestCase):
    def test_rules_and_documented_exceptions(self):
        kitty = generator.kitty_placeholder_diacritics()
        self.assertIn(0x0305, kitty)
        widths = {
            0x41: 1, 0x00: 0, 0x1B: 0, 0x85: 0,
            0xAD: 1,  # soft hyphen stays visible
            0x0301: 0, 0x200D: 0, 0xFE0F: 0, 0x1160: 0,
            0x302A: 0,  # a combining mark wins over its East Asian width
            0x6F22: 2, 0xFF21: 2, 0x1FAE0: 2,
            0x1F1FA: 1,  # regional indicators are neutral; a flag pair takes two
            0x1F3FB: 0,  # emoji modifiers add nothing to their base
        }
        for code_point, want in widths.items():
            with self.subTest(code_point=hex(code_point)):
                self.assertEqual(generator.code_point_width(code_point, kitty), want)
        self.assertEqual(generator.code_point_width(0x41, frozenset({0x41})), 0)

    def test_ranges_list_every_width_other_than_one(self):
        self.assertEqual(generator.width_ranges(bytes([0, 0, 1, 2, 2, 0, 1, 2])),
                         [(0, 1, 0), (3, 4, 2), (5, 5, 0), (7, 7, 2)])

    @unittest.skipUnless(unicodedata.unidata_version == generator.UNICODE_VERSION,
                         f'needs unicodedata {generator.UNICODE_VERSION}')
    def test_checked_in_tables_are_current(self):
        self.assertEqual(generator.main(['--check']), 0)


if __name__ == '__main__':
    unittest.main()

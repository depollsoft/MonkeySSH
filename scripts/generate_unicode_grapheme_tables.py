#!/usr/bin/env python3
"""Generate the grapheme cluster tables shared by MonkeyMux and the client.

Grapheme clustering (mode 2027) joins the code points of one user-perceived
character into one cell, the way Ghostty does. The MonkeyMux screen model (Go)
and the xterm fork (Dart) must join and size clusters identically, or their
cells and cursors diverge, so both read one table generated here:

  remote/monkeymux/grapheme_table.go
  third_party/xterm/lib/src/utils/unicode_grapheme.dart
  scripts/unicode_grapheme_table.crc32   (checked by the Go and Dart tests)
  remote/monkeymux/testdata/grapheme_break_test.txt   (both test suites)

Each code point gets its grapheme cluster break class, split the way Ghostty's
uucode library splits it (Extended_Pictographic, emoji modifiers and their
bases, and the Indic_Conjunct_Break values each get a class of their own), and
whether it starts an emoji variation sequence. Python's unicodedata has none of
these, so they come from the Unicode Character Database files of
UNICODE_VERSION. Pass --ucd DIR holding them, flat:

  GraphemeBreakProperty.txt  GraphemeBreakTest.txt  emoji-data.txt
  emoji-variation-sequences.txt  DerivedCoreProperties.txt

or leave it out to download them from unicode.org. --check reports stale
outputs without writing them.
"""

import argparse
from pathlib import Path
import re
import sys
import tempfile
import urllib.request
import zlib

UNICODE_VERSION = '17.0.0'
ROOT = Path(__file__).resolve().parents[1]
GO_PATH = ROOT / 'remote/monkeymux/grapheme_table.go'
DART_PATH = ROOT / 'third_party/xterm/lib/src/utils/unicode_grapheme.dart'
DIGEST_PATH = ROOT / 'scripts/unicode_grapheme_table.crc32'
BREAK_TEST_PATH = ROOT / 'remote/monkeymux/testdata/grapheme_break_test.txt'
MAX_CODE_POINT = 0x10FFFF

UCD_FILES = {
    'GraphemeBreakProperty.txt': 'auxiliary/GraphemeBreakProperty.txt',
    'GraphemeBreakTest.txt': 'auxiliary/GraphemeBreakTest.txt',
    'emoji-data.txt': 'emoji/emoji-data.txt',
    'emoji-variation-sequences.txt': 'emoji/emoji-variation-sequences.txt',
    'DerivedCoreProperties.txt': 'DerivedCoreProperties.txt',
}

# Break classes, in table order. Controls, CR and LF never reach a terminal's
# print path, so they count as other, as in uucode's "no control" variant.
CLASSES = [
    'other',
    'prepend',
    'regional_indicator',
    'spacing_mark',
    'l',
    'v',
    't',
    'lv',
    'lvt',
    'zwj',
    'zwnj',
    'extended_pictographic',
    'emoji_modifier_base',
    'emoji_modifier',
    'incb_extend',
    'incb_linker_extend',
    'incb_linker_other',
    'incb_consonant',
]
CLASS = {name: index for index, name in enumerate(CLASSES)}
# Set on a code point that an emoji variation selector (U+FE0E, U+FE0F) may
# follow, per emoji-variation-sequences.txt.
VS_BASE = 0x20
assert len(CLASSES) <= VS_BASE

ZWNJ = 0x200C
ZWJ = 0x200D

_ORIGINAL_CLASSES = {
    'Prepend': 'prepend',
    'Regional_Indicator': 'regional_indicator',
    'SpacingMark': 'spacing_mark',
    'L': 'l',
    'V': 'v',
    'T': 't',
    'LV': 'lv',
    'LVT': 'lvt',
    'CR': 'other',
    'LF': 'other',
    'Control': 'other',
}


def _ranges(path, property_filter=None):
    """(first, last, fields) for every data line of a UCD file."""
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(';')]
        first, _, last = fields[0].partition('..')
        if property_filter is not None and fields[1] != property_filter:
            continue
        yield int(first, 16), int(last or first, 16), fields[1:]


def _check_version(path):
    head = path.read_text(encoding='utf-8')[:600]
    major_minor = '.'.join(UNICODE_VERSION.split('.')[:2])
    if UNICODE_VERSION not in head and f'Version: {major_minor}' not in head:
        raise SystemExit(f'{path.name} is not Unicode {UNICODE_VERSION}')


def property_table(ucd):
    """One byte per code point: its break class, plus VS_BASE."""
    for name in UCD_FILES:
        _check_version(ucd / name)
    original = ['Other'] * (MAX_CODE_POINT + 1)
    for first, last, fields in _ranges(ucd / 'GraphemeBreakProperty.txt'):
        original[first:last + 1] = [fields[0]] * (last - first + 1)
    emoji = {}
    for first, last, fields in _ranges(ucd / 'emoji-data.txt'):
        for cp in range(first, last + 1):
            emoji.setdefault(cp, set()).add(fields[0])
    incb = {}
    for first, last, fields in _ranges(ucd / 'DerivedCoreProperties.txt', 'InCB'):
        for cp in range(first, last + 1):
            incb[cp] = fields[1]
    vs_bases = set()
    for line in (ucd / 'emoji-variation-sequences.txt').read_text(encoding='utf-8').splitlines():
        line = line.split('#', 1)[0].strip()
        if line:
            vs_bases.add(int(line.split(';')[0].split()[0], 16))

    table = bytearray(MAX_CODE_POINT + 1)
    for cp in range(MAX_CODE_POINT + 1):
        props = emoji.get(cp, ())
        gcb = original[cp]
        # The same derivation, and the same sanity checks, as uucode's
        # GraphemeBreakComponent.
        if 'Emoji_Modifier' in props:
            assert gcb == 'Extend' and 'Extended_Pictographic' not in props, hex(cp)
            name = 'emoji_modifier'
        elif 'Emoji_Modifier_Base' in props:
            assert gcb == 'Other' and 'Extended_Pictographic' in props, hex(cp)
            name = 'emoji_modifier_base'
        elif 'Extended_Pictographic' in props:
            assert gcb == 'Other', hex(cp)
            name = 'extended_pictographic'
        else:
            value = incb.get(cp)
            if value is None:
                if gcb == 'Extend':
                    assert cp == ZWNJ, f'Extend {cp:X} without InCB'
                    name = 'zwnj'
                else:
                    name = _ORIGINAL_CLASSES.get(gcb, 'other')
                    assert gcb in _ORIGINAL_CLASSES or gcb == 'Other', (hex(cp), gcb)
            elif value == 'Extend':
                if cp == ZWJ:
                    assert gcb == 'ZWJ'
                    name = 'zwj'
                else:
                    assert gcb == 'Extend', hex(cp)
                    name = 'incb_extend'
            elif value == 'Linker':
                assert gcb in ('Extend', 'Other'), hex(cp)
                name = 'incb_linker_extend' if gcb == 'Extend' else 'incb_linker_other'
            elif value == 'Consonant':
                assert gcb == 'Other', hex(cp)
                name = 'incb_consonant'
            else:
                raise SystemExit(f'unknown InCB value {value} at {cp:X}')
        table[cp] = CLASS[name] | (VS_BASE if cp in vs_bases else 0)
    return bytes(table)


def value_ranges(table):
    """(first, last, value) for every run of code points whose value is not 0."""
    ranges = []
    start = None
    for cp, value in enumerate(table):
        if start is not None and value != table[start]:
            ranges.append((start, cp - 1, table[start]))
            start = None
        if start is None and value != 0:
            start = cp
    if start is not None:
        ranges.append((start, len(table) - 1, table[start]))
    return ranges


def break_tests(ucd):
    """GraphemeBreakTest.txt without its comments: one test per line."""
    lines = []
    for line in (ucd / 'GraphemeBreakTest.txt').read_text(encoding='utf-8').splitlines():
        line = line.split('#', 1)[0].strip()
        if line:
            lines.append(re.sub(r'\s+', ' ', line))
    return lines


def hex_code_point(cp):
    return f'0x{cp:04X}'


def _go_constants():
    names = []
    for index, name in enumerate(CLASSES):
        camel = ''.join(part.capitalize() for part in name.split('_'))
        names.append(f'\tgrapheme{camel}' + (' graphemeClass = iota' if index == 0 else ''))
    return '\n'.join(names)


def render_go(ranges):
    rows = []
    for i in range(0, len(ranges), 4):
        cells = ', '.join(f'{{{hex_code_point(lo)}, {hex_code_point(hi)}, 0x{v:02X}}}' for lo, hi, v in ranges[i:i + 4])
        rows.append(f'\t{cells},')
    body = '\n'.join(rows)
    return f'''// Code generated by scripts/generate_unicode_grapheme_tables.py; DO NOT EDIT.

package main

// graphemeUnicodeVersion is the Unicode release graphemeRanges was built
// from. The client's third_party/xterm/lib/src/utils/unicode_grapheme.dart is
// generated from the same table, and both sides check it against
// scripts/unicode_grapheme_table.crc32 so the screen model and the client
// join code points into the same clusters.
const graphemeUnicodeVersion = "{UNICODE_VERSION}"

// graphemeClass is a code point's grapheme cluster break class, split the way
// Ghostty's uucode library splits it.
type graphemeClass uint8

const (
{_go_constants()}
)

// graphemeVSBase is set on a code point an emoji variation selector may
// follow.
const graphemeVSBase = 0x{VS_BASE:02X}

type graphemeRange struct {{
	lo, hi rune
	value  uint8
}}

// graphemeRanges lists, in order, every code point range whose class is not
// other or that is a variation sequence base.
var graphemeRanges = []graphemeRange{{
{body}
}}

// graphemeProperty returns the class of r in the low bits, plus graphemeVSBase.
func graphemeProperty(r rune) uint8 {{
	lo, hi := 0, len(graphemeRanges)-1
	for lo <= hi {{
		mid := int(uint(lo+hi) >> 1)
		switch entry := graphemeRanges[mid]; {{
		case r < entry.lo:
			hi = mid - 1
		case r > entry.hi:
			lo = mid + 1
		default:
			return entry.value
		}}
	}}
	return 0
}}
'''


def _dart_constants():
    lines = []
    for index, name in enumerate(CLASSES):
        parts = name.split('_')
        camel = parts[0] + ''.join(part.capitalize() for part in parts[1:])
        lines.append(f'  static const {camel} = {index};')
    return '\n'.join(lines)


def render_dart(ranges):
    # The trailing comments keep dart format from putting each value on a line.
    rows = '\n'.join(
        '  ' + ' '.join(f'{hex_code_point(lo)}, {hex_code_point(hi)}, 0x{v:02X},' for lo, hi, v in ranges[i:i + 3]) + ' //'
        for i in range(0, len(ranges), 3))
    return f'''// GENERATED CODE - DO NOT MODIFY BY HAND.
// Generated by scripts/generate_unicode_grapheme_tables.py from Unicode
// {UNICODE_VERSION}. The MonkeyMux screen model's graphemeProperty
// (remote/monkeymux/grapheme_table.go) is generated from the same table, and
// both sides check it against scripts/unicode_grapheme_table.crc32 so the
// client and the model join code points into the same clusters.

import 'dart:typed_data';

/// Unicode release the grapheme table was built from.
const unicodeGraphemeVersion = '{UNICODE_VERSION}';

/// Grapheme cluster break classes, split the way Ghostty's uucode library
/// splits them.
abstract final class GraphemeClass {{
{_dart_constants()}
}}

/// Set in a [graphemeProperty] on a code point an emoji variation selector
/// may follow.
const graphemeVSBase = 0x{VS_BASE:02X};

/// Every code point range whose class is not other or that is a variation
/// sequence base, in order, as (first, last, value) triples.
const _graphemeRanges = <int>[
{rows}
];

/// Values of the Basic Multilingual Plane, indexed by code point.
final Uint8List _bmpValues = _buildBmpValues();

Uint8List _buildBmpValues() {{
  final table = Uint8List(0x10000);
  for (var i = 0; i < _graphemeRanges.length; i += 3) {{
    final first = _graphemeRanges[i];
    if (first >= 0x10000) break;
    final last =
        _graphemeRanges[i + 1] < 0x10000 ? _graphemeRanges[i + 1] : 0xFFFF;
    table.fillRange(first, last + 1, _graphemeRanges[i + 2]);
  }}
  return table;
}}

/// The [GraphemeClass] of [codePoint] in the low bits, plus [graphemeVSBase].
int graphemeProperty(int codePoint) {{
  if (codePoint < 0x10000) return _bmpValues[codePoint];
  var low = 0;
  var high = _graphemeRanges.length ~/ 3 - 1;
  while (low <= high) {{
    final mid = (low + high) >> 1;
    if (codePoint < _graphemeRanges[mid * 3]) {{
      high = mid - 1;
    }} else if (codePoint > _graphemeRanges[mid * 3 + 1]) {{
      low = mid + 1;
    }} else {{
      return _graphemeRanges[mid * 3 + 2];
    }}
  }}
  return 0;
}}
'''


def render_digest(table):
    return f'''# Generated by scripts/generate_unicode_grapheme_tables.py. Do not edit.
# CRC-32 (IEEE) of one property byte per code point, U+0000 through U+10FFFF.
unicode {UNICODE_VERSION}
crc32 {zlib.crc32(table):08x}
'''


def render_break_tests(lines):
    return (f'# GraphemeBreakTest-{UNICODE_VERSION}.txt without its comments, written by\n'
            '# scripts/generate_unicode_grapheme_tables.py. Do not edit.\n'
            '# Copyright (c) Unicode, Inc. Unicode License v3: https://www.unicode.org/license.txt\n'
            + '\n'.join(lines) + '\n')


def download(target):
    for name, path in UCD_FILES.items():
        url = f'https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/{path}'
        with urllib.request.urlopen(url) as response:
            (target / name).write_bytes(response.read())


def outputs(ucd):
    table = property_table(ucd)
    ranges = value_ranges(table)
    return {
        GO_PATH: render_go(ranges),
        DART_PATH: render_dart(ranges),
        DIGEST_PATH: render_digest(table),
        BREAK_TEST_PATH: render_break_tests(break_tests(ucd)),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--check', action='store_true', help='fail if a generated file is stale')
    parser.add_argument('--ucd', type=Path, help='directory holding the UCD files (downloaded when absent)')
    args = parser.parse_args(argv)
    with tempfile.TemporaryDirectory() as temp:
        ucd = args.ucd
        if ucd is None:
            ucd = Path(temp)
            download(ucd)
        generated = outputs(ucd)
    stale = []
    for path, text in generated.items():
        current = path.read_text(encoding='utf-8') if path.exists() else None
        if current == text:
            continue
        stale.append(path.relative_to(ROOT))
        if not args.check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding='utf-8')
    if args.check and stale:
        print('stale: ' + ', '.join(map(str, stale)), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

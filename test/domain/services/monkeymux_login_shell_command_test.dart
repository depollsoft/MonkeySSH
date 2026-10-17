// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/monkeymux_acp_bridge_service.dart';

/// Values a custom agent's label or argv may hold. Several break POSIX
/// single quoting in fish (`\'`, `\\`) or csh-family shells (`!`).
const _hostile = <String>[
  r"Goose\'; touch pwned; #",
  r'acp\\',
  ' ; touch pwned ; #',
  'a!b',
  '',
  ' padded ',
  r'$(touch pwned)',
  '`touch pwned`',
  '50%d',
  r'back\slash',
  "it's",
  'say "hi"',
  '日本語',
  '@scope/pkg@1.0.0',
  '#hash',
  '~/x',
  'plain-arg',
];

const _printArgs = r'for a do printf "<%s>" "$a"; done';

Future<String?> _which(String name) async {
  final result = await Process.run('/bin/sh', [
    '-c',
    'command -v $name || true',
  ]);
  final path = (result.stdout as String).trim();
  return path.isEmpty ? null : path;
}

void main() {
  test('user bytes never reach the login shell in plain text', () {
    final line = buildMonkeyMuxLoginShellSafeCommand([
      '/bin/sh',
      '-c',
      _printArgs,
      'argv0',
      ..._hostile,
    ]);
    expect(line, isNot(contains('touch')));
    expect(line, isNot(contains('!')));
    expect(line, isNot(contains('Goose')));
    // Every backslash is followed by a digit, so fish's single-quote escapes
    // (`\'` and `\\`) can never occur.
    expect(RegExp(r'\\[^0-7]').hasMatch(line), isFalse);
    expect(line, isNot(endsWith(r"\'")));
    expect(decodeMonkeyMuxLoginShellSafeCommand(line), [
      '/bin/sh',
      '-c',
      _printArgs,
      'argv0',
      ..._hostile,
    ]);
  });

  test('plain argv keeps the existing single-quoted form', () {
    expect(
      buildMonkeyMuxLoginShellSafeCommand(const [
        '/home/u/.monkeyssh/monkeymux',
        'acp',
        'list',
      ]),
      "'/home/u/.monkeyssh/monkeymux' 'acp' 'list'",
    );
  });

  for (final shell in [
    'sh',
    'bash',
    'zsh',
    'dash',
    'ksh',
    'tcsh',
    'csh',
    'fish',
  ]) {
    test('runs argv exactly when the login shell is $shell', () async {
      final path = await _which(shell);
      if (path == null) {
        markTestSkipped('$shell is not installed');
        return;
      }
      final dir = await Directory.systemTemp.createTemp('login-shell');
      addTearDown(() => dir.delete(recursive: true));
      final line = buildMonkeyMuxLoginShellSafeCommand([
        '/bin/sh',
        '-c',
        _printArgs,
        'argv0',
        ..._hostile,
      ]);
      // sshd runs an exec request as `$SHELL -c <line>`.
      final result = await Process.run(
        path,
        ['-c', line],
        workingDirectory: dir.path,
        environment: {'HOME': dir.path, 'PATH': '/usr/bin:/bin'},
        includeParentEnvironment: false,
      );
      expect(result.stderr, '');
      expect(result.stdout, _hostile.map((value) => '<$value>').join());
      expect(File('${dir.path}/pwned').existsSync(), isFalse);
    }, testOn: 'mac-os || linux');
  }
}

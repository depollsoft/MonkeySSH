// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/services/acp_custom_provider_host_service.dart';

String _decodeEncodedPowerShell(String command) {
  final encoded = command.split(' ').last;
  final bytes = base64.decode(encoded);
  final units = <int>[
    for (var index = 0; index + 1 < bytes.length; index += 2)
      bytes[index] | (bytes[index + 1] << 8),
  ];
  return String.fromCharCodes(units);
}

void main() {
  group('environment probe', () {
    test('rejects names that are not plain identifiers', () {
      expect(
        () => buildAcpEnvironmentProbeCommand(const [
          'X;rm -rf ~',
        ], isWindows: false),
        throwsArgumentError,
      );
      expect(
        () => buildAcpEnvironmentProbeCommand(const [], isWindows: false),
        throwsArgumentError,
      );
    });

    test('POSIX probe sources the login profile and prints names only', () {
      final command = buildAcpEnvironmentProbeCommand(const [
        'OPENAI_API_KEY',
      ], isWindows: false);
      expect(command, startsWith('/bin/sh -c '));
      expect(command, contains('. ~/.zprofile'));
      expect(command, contains('OPENAI_API_KEY'));
      expect(command, isNot(contains('printenv')));
      expect(command, isNot(contains(r'echo "$OPENAI_API_KEY"')));
    });

    test('Windows probe checks each variable with PowerShell', () {
      final script = _decodeEncodedPowerShell(
        buildAcpEnvironmentProbeCommand(const ['API_KEY'], isWindows: true),
      );
      expect(script, contains(r'[string]::IsNullOrEmpty($env:API_KEY)'));
      expect(script, contains('monkeyssh-env-unset:API_KEY'));
    });

    test('parses only requested names behind the marker', () {
      expect(
        parseAcpEnvironmentProbeOutput(
          'profile noise\n'
          'monkeyssh-env-unset:B_KEY\r\n'
          'monkeyssh-env-unset:INJECTED\n'
          'monkeyssh-env-unset:A_KEY\n',
          const ['A_KEY', 'B_KEY', 'C_KEY'],
        ),
        ['A_KEY', 'B_KEY'],
      );
    });

    test(
      'reports exported variables as set and others as unset, never values',
      () async {
        final home = await Directory.systemTemp.createTemp('acp-env-home');
        addTearDown(() => home.delete(recursive: true));
        // A profile export is visible to the agent; a plain shell variable is
        // not exported, so the agent would not see it either.
        await File('${home.path}/.profile')
            .writeAsString('export FROM_PROFILE=1\nNOT_EXPORTED=1\n');
        final command = buildAcpEnvironmentProbeCommand(const [
          'FROM_PROFILE',
          'FROM_ENVIRONMENT',
          'NOT_EXPORTED',
          'EMPTY_VALUE',
          'MISSING',
        ], isWindows: false);
        final result = await Process.run(
          '/bin/sh',
          ['-c', command],
          environment: {
            'HOME': home.path,
            // MonkeyMux runs the provider under a bash/zsh login shell.
            'SHELL': '/bin/bash',
            'PATH': '/usr/bin:/bin',
            'FROM_ENVIRONMENT': 'super-secret-value',
            'EMPTY_VALUE': '',
          },
          includeParentEnvironment: false,
        );
        final output = result.stdout as String;
        expect(output, isNot(contains('super-secret-value')));
        expect(
          parseAcpEnvironmentProbeOutput(output, const [
            'FROM_PROFILE',
            'FROM_ENVIRONMENT',
            'NOT_EXPORTED',
            'EMPTY_VALUE',
            'MISSING',
          ]),
          ['NOT_EXPORTED', 'EMPTY_VALUE', 'MISSING'],
        );
      },
      testOn: 'mac-os || linux',
    );
  });

  test('session timestamps order newest first and tolerate absence', () {
    const newer = AcpSessionInfo(
      sessionId: 'a',
      cwd: '/repo',
      updatedAt: '2026-10-09T10:00:00Z',
    );
    const older = AcpSessionInfo(
      sessionId: 'b',
      cwd: '/repo',
      updatedAt: 1700000000000,
    );
    const unknown = AcpSessionInfo(sessionId: 'c', cwd: '/repo');
    expect(
      acpSessionInfoUpdatedAt(newer).isAfter(acpSessionInfoUpdatedAt(older)),
      isTrue,
    );
    expect(acpSessionInfoUpdatedAt(unknown).millisecondsSinceEpoch, 0);
  });
}

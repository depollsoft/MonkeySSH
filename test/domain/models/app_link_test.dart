// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/app_link.dart';

AppLink _parse(String link) => parseAppLinkString(link);

Matcher _rejected(AppLinkRejection reason) => equals(RejectedAppLink(reason));

void main() {
  group('isAppLinkUri', () {
    test('accepts monkeyssh and ssh in any case', () {
      expect(isAppLinkUri(Uri.parse('monkeyssh://open?host=1')), isTrue);
      expect(isAppLinkUri(Uri.parse('MonkeySSH://open?host=1')), isTrue);
      expect(isAppLinkUri(Uri.parse('ssh://example.com')), isTrue);
    });

    test('rejects other schemes and plain routes', () {
      expect(isAppLinkUri(Uri.parse('https://example.com')), isFalse);
      expect(isAppLinkUri(Uri.parse('content://provider/doc')), isFalse);
      expect(isAppLinkUri(Uri.parse('/terminal/1')), isFalse);
    });
  });

  group('monkeyssh://open', () {
    test('parses a host id', () {
      expect(
        _parse('monkeyssh://open?host=12'),
        const OpenHostAppLink(hostId: 12),
      );
    });

    test('parses a host id and window index', () {
      expect(
        _parse('monkeyssh://open?host=3&window=2'),
        const OpenHostAppLink(hostId: 3, windowIndex: 2),
      );
    });

    test('accepts window zero', () {
      expect(
        _parse('monkeyssh://open?window=0&host=3'),
        const OpenHostAppLink(hostId: 3, windowIndex: 0),
      );
    });

    test('accepts the trailing slash the router adds', () {
      expect(
        _parse('monkeyssh://open/?host=3&window=1'),
        const OpenHostAppLink(hostId: 3, windowIndex: 1),
      );
    });

    test('accepts links written without an authority', () {
      expect(_parse('monkeyssh:open?host=3'), const OpenHostAppLink(hostId: 3));
      expect(
        _parse('monkeyssh:/open?host=3'),
        const OpenHostAppLink(hostId: 3),
      );
      expect(
        _parse('monkeyssh:///open?host=3'),
        const OpenHostAppLink(hostId: 3),
      );
    });

    test('treats scheme and action case-insensitively', () {
      expect(
        _parse('MONKEYSSH://OPEN?host=3'),
        const OpenHostAppLink(hostId: 3),
      );
    });

    test('requires a host', () {
      expect(
        _parse('monkeyssh://open?window=2'),
        _rejected(AppLinkRejection.missingParameter),
      );
      expect(
        _parse('monkeyssh://open'),
        _rejected(AppLinkRejection.missingParameter),
      );
    });

    for (final value in [
      '',
      '0',
      '-1',
      '+1',
      '01',
      '1.5',
      'abc',
      ' 1',
      '1 ',
      '0x10',
      '1e3',
      '9999999999999999999',
      'example.com',
    ]) {
      test('rejects host id "$value"', () {
        expect(
          _parse('monkeyssh://open?host=${Uri.encodeQueryComponent(value)}'),
          _rejected(AppLinkRejection.invalidParameter),
        );
      });
    }

    for (final value in ['', '-1', '01', 'one', '1.0', '1000000']) {
      test('rejects window "$value"', () {
        expect(
          _parse(
            'monkeyssh://open?host=1&window=${Uri.encodeQueryComponent(value)}',
          ),
          _rejected(AppLinkRejection.invalidParameter),
        );
      });
    }

    test('rejects duplicated parameters instead of guessing', () {
      expect(
        _parse('monkeyssh://open?host=1&host=2'),
        _rejected(AppLinkRejection.duplicateParameter),
      );
      expect(
        _parse('monkeyssh://open?host=1&window=1&window=2'),
        _rejected(AppLinkRejection.duplicateParameter),
      );
    });

    test('ignores a prompt parameter so links cannot send text', () {
      final link = _parse(
        'monkeyssh://open?host=1&prompt=${Uri.encodeQueryComponent('rm -rf /')}',
      );
      expect(link, const OpenHostAppLink(hostId: 1));
    });

    test('ignores parameters it does not use', () {
      expect(
        _parse('monkeyssh://open?host=1&utm_source=ntfy&command=whoami'),
        const OpenHostAppLink(hostId: 1),
      );
    });

    test('rejects credentials in the authority', () {
      expect(
        _parse('monkeyssh://user:secret@open?host=1'),
        _rejected(AppLinkRejection.embeddedCredentials),
      );
    });

    test('rejects a user or port in the authority', () {
      expect(
        _parse('monkeyssh://user@open?host=1'),
        _rejected(AppLinkRejection.unexpectedComponent),
      );
      expect(
        _parse('monkeyssh://open:22?host=1'),
        _rejected(AppLinkRejection.unexpectedComponent),
      );
    });

    test('rejects extra path segments', () {
      expect(
        _parse('monkeyssh://open/extra?host=1'),
        _rejected(AppLinkRejection.unexpectedComponent),
      );
      expect(
        _parse('monkeyssh:open/extra?host=1'),
        _rejected(AppLinkRejection.unexpectedComponent),
      );
    });
  });

  group('monkeyssh://chat', () {
    test('parses a host and opaque session id', () {
      expect(
        _parse('monkeyssh://chat?host=4&session=sess_01HZ-abc.def:9'),
        const OpenChatAppLink(hostId: 4, sessionId: 'sess_01HZ-abc.def:9'),
      );
    });

    test('decodes percent-encoded session ids', () {
      expect(
        _parse('monkeyssh://chat?host=4&session=a%2Fb'),
        const OpenChatAppLink(hostId: 4, sessionId: 'a/b'),
      );
    });

    test('requires both host and session', () {
      expect(
        _parse('monkeyssh://chat?host=4'),
        _rejected(AppLinkRejection.missingParameter),
      );
      expect(
        _parse('monkeyssh://chat?session=abc'),
        _rejected(AppLinkRejection.missingParameter),
      );
    });

    for (final value in ['', 'has space', 'tab\there', 'new\nline', '\u0000']) {
      test('rejects session id ${value.codeUnits}', () {
        expect(
          _parse(
            'monkeyssh://chat?host=4&session=${Uri.encodeQueryComponent(value)}',
          ),
          _rejected(AppLinkRejection.invalidParameter),
        );
      });
    }

    test('rejects an over-long session id', () {
      final id = 'a' * (maxAppLinkSessionIdLength + 1);
      expect(
        _parse('monkeyssh://chat?host=4&session=$id'),
        _rejected(AppLinkRejection.invalidParameter),
      );
    });

    test('ignores a prompt parameter', () {
      expect(
        _parse('monkeyssh://chat?host=4&session=abc&prompt=hello'),
        const OpenChatAppLink(hostId: 4, sessionId: 'abc'),
      );
    });
  });

  group('monkeyssh://preset', () {
    test('parses a preset id', () {
      expect(
        _parse('monkeyssh://preset?id=9'),
        const LaunchPresetAppLink(presetId: 9),
      );
    });

    test('requires a valid id', () {
      expect(
        _parse('monkeyssh://preset'),
        _rejected(AppLinkRejection.missingParameter),
      );
      expect(
        _parse('monkeyssh://preset?id=claude'),
        _rejected(AppLinkRejection.invalidParameter),
      );
      expect(
        _parse('monkeyssh://preset?id=1&id=2'),
        _rejected(AppLinkRejection.duplicateParameter),
      );
    });

    test('ignores command and yolo overrides', () {
      expect(
        _parse('monkeyssh://preset?id=9&yolo=0&command=sh&prompt=hi'),
        const LaunchPresetAppLink(presetId: 9),
      );
    });
  });

  group('monkeyssh:// actions', () {
    test('rejects unknown actions', () {
      expect(
        _parse('monkeyssh://run?command=ls'),
        _rejected(AppLinkRejection.unknownAction),
      );
      expect(_parse('monkeyssh://'), _rejected(AppLinkRejection.unknownAction));
      expect(_parse('monkeyssh:'), _rejected(AppLinkRejection.unknownAction));
    });
  });

  group('ssh://', () {
    test('parses a host', () {
      expect(
        _parse('ssh://example.com'),
        const SshHostAppLink(hostname: 'example.com'),
      );
    });

    test('parses a user, host and port', () {
      expect(
        _parse('ssh://deploy@build.example.com:2222'),
        const SshHostAppLink(
          hostname: 'build.example.com',
          port: 2222,
          username: 'deploy',
        ),
      );
    });

    test('parses IPv4 and IPv6 hosts', () {
      expect(
        _parse('ssh://10.0.0.5:22'),
        const SshHostAppLink(hostname: '10.0.0.5', port: 22),
      );
      expect(
        _parse('ssh://root@[2001:db8::1]:2200'),
        const SshHostAppLink(
          hostname: '2001:db8::1',
          port: 2200,
          username: 'root',
        ),
      );
    });

    test('decodes percent-encoded usernames', () {
      expect(
        _parse('ssh://first.last%2Bci@example.com'),
        const SshHostAppLink(
          hostname: 'example.com',
          username: 'first.last+ci',
        ),
      );
    });

    test('rejects an embedded password', () {
      expect(
        _parse('ssh://root:hunter2@example.com'),
        _rejected(AppLinkRejection.embeddedCredentials),
      );
      expect(
        _parse('ssh://root:@example.com'),
        _rejected(AppLinkRejection.embeddedCredentials),
      );
    });

    test('rejects connection parameters in the user part', () {
      expect(
        _parse('ssh://root;fingerprint=ssh-ed25519-abc@example.com'),
        _rejected(AppLinkRejection.invalidParameter),
      );
      expect(
        _parse('ssh://root%3Bfingerprint=ssh-ed25519-abc@example.com'),
        _rejected(AppLinkRejection.invalidParameter),
      );
    });

    test('rejects a missing host', () {
      expect(_parse('ssh://'), _rejected(AppLinkRejection.missingParameter));
      expect(
        _parse('ssh://root@'),
        _rejected(AppLinkRejection.missingParameter),
      );
    });

    test('rejects malformed hosts and ports', () {
      expect(
        _parse('ssh://-bad.example.com'),
        _rejected(AppLinkRejection.invalidParameter),
      );
      expect(
        _parse('ssh://example.com:70000'),
        _rejected(AppLinkRejection.invalidParameter),
      );
    });

    test('rejects usernames with spaces', () {
      expect(
        _parse('ssh://bad%20user@example.com'),
        _rejected(AppLinkRejection.invalidParameter),
      );
    });

    test('ignores paths, queries and fragments', () {
      expect(
        _parse('ssh://example.com/home?prompt=hi#frag'),
        const SshHostAppLink(hostname: 'example.com'),
      );
    });

    test('sanitized URL keeps only validated parts', () {
      final link =
          _parse('ssh://deploy@example.com:2222/path?x=1#y') as SshHostAppLink;
      expect(link.toSanitizedUrl(), 'ssh://deploy@example.com:2222');
      expect(link.effectivePort, 2222);

      final bare = _parse('ssh://example.com') as SshHostAppLink;
      expect(bare.toSanitizedUrl(), 'ssh://example.com');
      expect(bare.effectivePort, 22);

      final ipv6 = _parse('ssh://[2001:db8::1]') as SshHostAppLink;
      expect(Uri.parse(ipv6.toSanitizedUrl()).host, '2001:db8::1');
    });
  });

  group('parseAppLinkString', () {
    test('rejects other schemes', () {
      expect(
        _parse('https://example.com/open?host=1'),
        _rejected(AppLinkRejection.unsupportedScheme),
      );
      expect(
        _parse('file:///tmp/x'),
        _rejected(AppLinkRejection.unsupportedScheme),
      );
    });

    test('rejects text that is not a URL', () {
      expect(
        _parse('monkeyssh://open?host=1&window=[1'),
        isNot(isA<OpenHostAppLink>()),
      );
      expect(_parse('http://[::1'), _rejected(AppLinkRejection.malformed));
    });

    test('rejects over-long links without parsing them', () {
      final link = 'monkeyssh://open?host=1&pad=${'x' * maxAppLinkLength}';
      expect(_parse(link), _rejected(AppLinkRejection.tooLong));
    });

    test('rejects URLs whose components fail to decode later', () {
      for (final link in [
        'monkeyssh:%FF?host=1',
        'monkeyssh://open?host=1&x=%FF',
        'ssh://example.com:999999999999999999999999',
        'ssh://%FF@example.com',
      ]) {
        expect(_parse(link), isA<RejectedAppLink>(), reason: link);
        expect(
          () => parseAppLink(Uri.parse(link)),
          returnsNormally,
          reason: link,
        );
      }
    });

    test('trims surrounding whitespace', () {
      expect(
        _parse('  monkeyssh://open?host=1\n'),
        const OpenHostAppLink(hostId: 1),
      );
    });

    test('diagnostics categories carry no link content', () {
      for (final link in [
        _parse('monkeyssh://open?host=1'),
        _parse('monkeyssh://chat?host=1&session=secret-session'),
        _parse('monkeyssh://preset?id=1'),
        _parse('ssh://root@private.example.com'),
        _parse('ssh://root:pw@private.example.com'),
      ]) {
        expect([
          'open',
          'chat',
          'preset',
          'ssh',
          'rejected',
        ], contains(link.diagnosticsAction));
      }
    });
  });
}

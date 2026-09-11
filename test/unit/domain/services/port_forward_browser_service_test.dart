// ignore_for_file: public_member_api_docs

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/port_proxy_name.dart';
import 'package:monkeyssh/domain/services/port_forward_browser_service.dart';

PortForward _buildPortForward({
  String forwardType = 'local',
  String localHost = '127.0.0.1',
  int localPort = 8080,
}) => PortForward(
  id: 1,
  name: 'Web',
  hostId: 1,
  forwardType: forwardType,
  localHost: localHost,
  localPort: localPort,
  remoteHost: 'localhost',
  remotePort: 80,
  autoStart: false,
  createdAt: DateTime(2026),
);

void main() {
  group('canOpenPortForwardInBrowser', () {
    test('allows only local loopback forwards', () {
      expect(canOpenPortForwardInBrowser(_buildPortForward()), isTrue);
      expect(
        canOpenPortForwardInBrowser(_buildPortForward(forwardType: 'remote')),
        isFalse,
      );
      expect(
        canOpenPortForwardInBrowser(
          _buildPortForward(localHost: '192.168.1.20'),
        ),
        isFalse,
      );
      expect(
        canOpenPortForwardInBrowser(_buildPortForward(localPort: 0)),
        isFalse,
      );
    });
  });

  group('isPortForwardBrowserSupported', () {
    test('allows mobile and macOS WebView platforms only', () {
      expect(
        isPortForwardBrowserSupported(platform: TargetPlatform.android),
        isTrue,
      );
      expect(
        isPortForwardBrowserSupported(platform: TargetPlatform.iOS),
        isTrue,
      );
      expect(
        isPortForwardBrowserSupported(platform: TargetPlatform.macOS),
        isTrue,
      );
      expect(
        isPortForwardBrowserSupported(platform: TargetPlatform.linux),
        isFalse,
      );
      expect(
        isPortForwardBrowserSupported(platform: TargetPlatform.windows),
        isFalse,
      );
    });
  });

  group('isPortForwardLoopbackHost', () {
    test('accepts explicit loopback addresses only', () {
      expect(isPortForwardLoopbackHost('localhost'), isTrue);
      expect(isPortForwardLoopbackHost('127.0.0.5'), isTrue);
      expect(isPortForwardLoopbackHost('127.0.0.53%lo'), isTrue);
      expect(isPortForwardLoopbackHost('::1'), isTrue);
      expect(isPortForwardLoopbackHost('::1%lo0'), isTrue);
      expect(isPortForwardLoopbackHost('monkeyssh.localhost'), isTrue);
      expect(isPortForwardLoopbackHost('127.example.com'), isFalse);
      expect(isPortForwardLoopbackHost('0.0.0.0'), isFalse);
    });
  });

  group('isPortForwardBrowserEntryUri', () {
    test('allows only loopback web URLs on valid ports', () {
      expect(
        isPortForwardBrowserEntryUri(Uri.parse('http://127.0.0.1:8080')),
        isTrue,
      );
      expect(
        isPortForwardBrowserEntryUri(Uri.parse('https://localhost')),
        isTrue,
      );
      expect(
        isPortForwardBrowserEntryUri(Uri.parse('http://127.0.0.53%25lo:53')),
        isTrue,
      );
      expect(
        isPortForwardBrowserEntryUri(Uri.parse('http://example.com:8080')),
        isFalse,
      );
      expect(
        isPortForwardBrowserEntryUri(Uri.parse('http://127.0.0.1:0')),
        isFalse,
      );
    });
  });

  group('buildPortForwardBrowserUriForBind', () {
    test('builds an http URL for loopback forwards', () {
      expect(
        buildPortForwardBrowserUriForBind(
          localHost: '127.0.0.1',
          localPort: 8080,
        ).toString(),
        'http://127.0.0.1:8080',
      );
    });

    test('maps wildcard bind addresses to loopback', () {
      expect(
        buildPortForwardBrowserUriForBind(
          localHost: '0.0.0.0',
          localPort: 8080,
        ).toString(),
        'http://127.0.0.1:8080',
      );
    });

    test('maps IPv6 loopback bind addresses to localhost', () {
      expect(
        buildPortForwardBrowserUriForBind(
          localHost: '::1',
          localPort: 8080,
        ).toString(),
        'http://localhost:8080',
      );
    });

    test('preserves distinct IPv4 loopback bind addresses', () {
      expect(
        buildPortForwardBrowserUriForBind(
          localHost: '127.0.0.5',
          localPort: 8080,
        ).toString(),
        'http://127.0.0.5:8080',
      );
      expect(
        buildPortForwardBrowserUriForBind(
          localHost: '127.0.0.53%lo',
          localPort: 8080,
        ).toString(),
        'http://127.0.0.53:8080',
      );
    });
  });

  group('portForwardBrowserHostForPortForwardId', () {
    test('assigns stable distinct localhost hosts', () {
      expect(
        portForwardBrowserHostForPortForwardId(1),
        'monkeyssh-1.localhost',
      );
      expect(
        portForwardBrowserHostForPortForwardId(2),
        'monkeyssh-2.localhost',
      );
      expect(
        portForwardBrowserHostForPortForwardId(42),
        portForwardBrowserHostForPortForwardId(42),
      );
    });

    group('portForwardBrowserFallbackHostForHostId', () {
      test('assigns stable distinct numeric loopback hosts', () {
        expect(portForwardBrowserFallbackHostForHostId(1), '127.0.0.3');
        expect(
          portForwardBrowserFallbackHostForHostId(1),
          portForwardBrowserFallbackHostForHostId(1),
        );
        expect(
          portForwardBrowserFallbackHostForHostId(1),
          isNot(portForwardBrowserFallbackHostForHostId(2)),
        );
        expect(
          isPortForwardLoopbackHost(
            portForwardBrowserFallbackHostForHostId(42),
          ),
          isTrue,
        );
      });
    });

    group('proxy names', () {
      test('generates a stable DNS-safe host-scoped name', () {
        expect(generatedPortProxyName('Dev Box!', hostId: 42), 'dev-box');
        expect(
          generatedPortProxyName('Dev Box!', hostId: 42),
          generatedPortProxyName('Dev Box!', hostId: 42),
        );
        expect(
          generatedPortProxyName(
            'OVH davidpollforlasd com production workspace',
            hostId: 57,
          ),
          'ovh-davidpol',
        );
      });

      test('adds the saved host ID only for duplicate generated labels', () {
        expect(
          generatedPortProxyName('Dev Box', hostId: 42, includeHostId: true),
          'dev-box-42',
        );
      });

      test('uses and normalizes a custom localhost prefix', () {
        expect(normalizeOptionalPortProxyName('API.Dev.LocalHost'), 'api.dev');
      });

      group('resolveGeneratedPortProxyNames', () {
        test('extends colliding short slugs for different names', () {
          expect(
            resolveGeneratedPortProxyNames([
              (id: 1, label: 'OVH Davidpollforlasd Production'),
              (id: 2, label: 'OVH Davidpollforlasd Staging'),
            ]),
            {1: 'ovh-davidpollforlasd-p', 2: 'ovh-davidpollforlasd-s'},
          );
        });

        test('uses IDs only for duplicate normalized names', () {
          expect(
            resolveGeneratedPortProxyNames([
              (id: 42, label: 'Dev Box'),
              (id: 43, label: 'Dev Box!'),
              (id: 44, label: 'Production'),
            ]),
            {42: 'dev-box-42', 43: 'dev-box-43', 44: 'production'},
          );
        });

        test('keeps host aliases outside the saved-forward namespace', () {
          expect(
            resolveGeneratedPortProxyNames([(id: 1, label: 'MonkeySSH 1')]),
            {1: 'host-monkeys'},
          );
          expect(isReservedSavedForwardProxyName('monkeyssh-1'), isTrue);
          expect(isReservedSavedForwardProxyName('host-monkeyssh-1'), isFalse);
        });

        test('keeps duplicate-name IDs clear of reserved custom aliases', () {
          expect(
            resolveGeneratedPortProxyNames(
              [(id: 42, label: 'Dev Box'), (id: 43, label: 'Dev Box!')],
              reservedNames: const ['dev-box-42'],
            ),
            {42: 'dev-box-host-42', 43: 'dev-box-43'},
          );
        });
      });

      test('validates DNS labels and allows an empty generated-name field', () {
        final sixtyCharacterLabel = List.filled(60, 'a').join();
        final maximumLengthPrefix = [
          sixtyCharacterLabel,
          sixtyCharacterLabel,
          sixtyCharacterLabel,
          List.filled(38, 'a').join(),
        ].join('.');
        final overlongPrefix = [
          sixtyCharacterLabel,
          sixtyCharacterLabel,
          sixtyCharacterLabel,
          List.filled(39, 'a').join(),
        ].join('.');

        expect(validatePortProxyName(''), isNull);
        expect(validatePortProxyName('api.dev'), isNull);
        expect(validatePortProxyName('api.dev.localhost'), isNull);
        expect(validatePortProxyName('-api'), isNotNull);
        expect(validatePortProxyName('api_1'), isNotNull);
        expect(validatePortProxyName(maximumLengthPrefix), isNull);
        expect(validatePortProxyName(overlongPrefix), isNotNull);
      });
    });
  });

  group('rewriteUriForPortForwardBrowser', () {
    test('preserves the request while replacing the forwarded endpoint', () {
      expect(
        rewriteUriForPortForwardBrowser(
          Uri.parse('https://localhost:8080/login?next=%2F'),
          sourceUri: Uri.parse('http://127.0.0.1:8080'),
          browserUri: Uri.parse('http://monkeyssh-42.localhost:8080'),
        ),
        Uri.parse('https://monkeyssh-42.localhost:8080/login?next=%2F'),
      );
    });

    group('shouldUsePortForwardBrowserFallback', () {
      final browserUri = Uri.parse('http://dev-box.localhost:49152');

      test('retries a failed friendly main-frame endpoint once', () {
        expect(
          shouldUsePortForwardBrowserFallback(
            browserUri: browserUri,
            failedUri: null,
            isForMainFrame: true,
            alreadyTried: false,
          ),
          isTrue,
        );
        expect(
          shouldUsePortForwardBrowserFallback(
            browserUri: browserUri,
            failedUri: browserUri,
            isForMainFrame: true,
            alreadyTried: false,
          ),
          isTrue,
        );
        expect(
          shouldUsePortForwardBrowserFallback(
            browserUri: browserUri,
            failedUri: browserUri,
            isForMainFrame: true,
            alreadyTried: true,
          ),
          isFalse,
        );
        expect(
          shouldUsePortForwardBrowserFallback(
            browserUri: browserUri,
            failedUri: browserUri,
            isForMainFrame: null,
            alreadyTried: false,
          ),
          isFalse,
        );
      });

      test('ignores subresources and unrelated endpoints', () {
        expect(
          shouldUsePortForwardBrowserFallback(
            browserUri: browserUri,
            failedUri: browserUri,
            isForMainFrame: false,
            alreadyTried: false,
          ),
          isFalse,
        );
        expect(
          shouldUsePortForwardBrowserFallback(
            browserUri: browserUri,
            failedUri: Uri.parse('http://example.com:49152'),
            isForMainFrame: true,
            alreadyTried: false,
          ),
          isFalse,
        );
      });
    });

    test('keeps an active saved-forward fallback on loopback', () {
      final fallbackUri = Uri.parse('http://127.0.0.1:8080');
      expect(
        shouldLoadPortForwardBrowserFallbackDirectly(
          requestedUri: fallbackUri,
          fallbackUri: fallbackUri,
          fallbackActive: true,
        ),
        isTrue,
      );
      expect(
        shouldLoadPortForwardBrowserFallbackDirectly(
          requestedUri: fallbackUri,
          fallbackUri: fallbackUri,
          fallbackActive: false,
        ),
        isFalse,
      );
    });

    test('preserves the failed route when building a fallback request', () {
      expect(
        buildPortForwardBrowserFallbackRequestUri(
          browserUri: Uri.parse('http://dev-box.localhost:49152'),
          fallbackUri: Uri.parse('http://127.0.0.44:49152'),
          requestedUri: Uri.parse(
            'https://dev-box.localhost:49152/dashboard?tab=1#logs',
          ),
        ),
        Uri.parse('https://127.0.0.44:49152/dashboard?tab=1#logs'),
      );
    });

    test('rewrites a detected remote port to its ephemeral proxy port', () {
      expect(
        rewriteUriForPortForwardBrowser(
          Uri.parse('http://localhost:3000/dashboard'),
          sourceUri: Uri.parse('http://localhost:3000'),
          browserUri: Uri.parse('http://dev-box.localhost:49152'),
        ),
        Uri.parse('http://dev-box.localhost:49152/dashboard'),
      );
    });

    test('does not rewrite a different local port', () {
      expect(
        rewriteUriForPortForwardBrowser(
          Uri.parse('http://localhost:3000'),
          sourceUri: Uri.parse('http://127.0.0.1:8080'),
          browserUri: Uri.parse('http://monkeyssh-42.localhost:8080'),
        ),
        isNull,
      );
    });

    test('does not rewrite the same port on a different loopback host', () {
      expect(
        rewriteUriForPortForwardBrowser(
          Uri.parse('http://127.0.0.2:8080'),
          sourceUri: Uri.parse('http://127.0.0.1:8080'),
          browserUri: Uri.parse('http://monkeyssh-1.localhost:8080'),
        ),
        isNull,
      );
    });

    test('treats default loopback host spellings as equivalent', () {
      expect(
        rewriteUriForPortForwardBrowser(
          Uri.parse('http://localhost:8080'),
          sourceUri: Uri.parse('http://0.0.0.0:8080'),
          browserUri: Uri.parse('http://monkeyssh-1.localhost:8080'),
        ),
        Uri.parse('http://monkeyssh-1.localhost:8080'),
      );
    });
  });

  group('normalizePortForwardBrowserUri', () {
    test('maps wildcard URL hosts to loopback', () {
      expect(
        normalizePortForwardBrowserUri(
          Uri.parse('http://0.0.0.0:3000/path'),
        ).toString(),
        'http://127.0.0.1:3000/path',
      );
    });

    test('preserves IPv4 loopback URL hosts', () {
      expect(
        normalizePortForwardBrowserUri(
          Uri.parse('http://127.0.0.5:3000/path'),
        ).toString(),
        'http://127.0.0.5:3000/path',
      );
    });
  });

  group('shouldLaunchPortForwardBrowserUriExternally', () {
    test('hands app links to the operating system', () {
      expect(
        shouldLaunchPortForwardBrowserUriExternally(
          Uri.parse('mailto:dev@example.com'),
        ),
        isTrue,
      );
      expect(
        shouldLaunchPortForwardBrowserUriExternally(
          Uri.parse('vscode://file/project/main.dart'),
        ),
        isTrue,
      );
    });

    test('keeps browser-native schemes inside the WebView', () {
      expect(
        shouldLaunchPortForwardBrowserUriExternally(
          Uri.parse('https://example.com'),
        ),
        isFalse,
      );
      expect(
        shouldLaunchPortForwardBrowserUriExternally(
          Uri.parse('javascript:void(0)'),
        ),
        isFalse,
      );
      expect(
        shouldLaunchPortForwardBrowserUriExternally(
          Uri.parse('blob:https://example.com/id'),
        ),
        isFalse,
      );
      expect(
        shouldLaunchPortForwardBrowserUriExternally(
          Uri.parse('file:///tmp/report.pdf'),
        ),
        isFalse,
      );
    });
  });

  group('portForwardBrowserDisplayOrigin', () {
    test('formats web origins with their scheme and port', () {
      expect(
        portForwardBrowserDisplayOrigin(
          Uri.parse('https://example.com:8443/path'),
        ),
        'https://example.com:8443',
      );
    });

    test('does not call Uri.origin for non-web schemes', () {
      expect(
        portForwardBrowserDisplayOrigin(
          Uri.parse('file://localhost/tmp/report.html'),
        ),
        'localhost',
      );
      expect(
        portForwardBrowserDisplayOrigin(Uri.parse('content://documents/42')),
        'documents',
      );
      expect(
        portForwardBrowserDisplayOrigin(Uri.parse('blob:opaque-id')),
        'blob',
      );
      expect(
        portForwardBrowserDisplayOrigin(Uri.parse('http:relative-path')),
        'http',
      );
    });
  });
}

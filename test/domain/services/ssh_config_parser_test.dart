import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/ssh_config_import_planner.dart';
import 'package:monkeyssh/domain/services/ssh_config_parser.dart';

SshConfigImportPlan _plan(String text) =>
    buildSshConfigImportPlan(parseSshConfig(text));

SshConfigImportEntry _entry(SshConfigImportPlan plan, String label) =>
    plan.entries.singleWhere((entry) => entry.label == label);

void main() {
  group('splitSshConfigArguments', () {
    test('splits on spaces and tabs', () {
      expect(splitSshConfigArguments('a  b\tc'), ['a', 'b', 'c']);
    });

    test('groups double- and single-quoted text', () {
      expect(splitSshConfigArguments('"a b" \'c d\''), ['a b', 'c d']);
    });

    test('joins quotes in the middle of a token', () {
      expect(splitSshConfigArguments('pre"fix suf"fix'), ['prefix suffix']);
    });

    test('honours backslash escapes like argv_split', () {
      expect(splitSshConfigArguments(r'a\ b'), ['a b']);
      expect(splitSshConfigArguments(r'"say \"hi\""'), ['say "hi"']);
      expect(splitSshConfigArguments(r'c:\\path'), [r'c:\path']);
      expect(splitSshConfigArguments(r'keep\x'), [r'keep\x']);
    });

    test('stops at a comment only at the start of a token', () {
      expect(splitSshConfigArguments('value # note'), ['value']);
      expect(splitSshConfigArguments('a#b'), ['a#b']);
      expect(splitSshConfigArguments('"#quoted"'), ['#quoted']);
    });

    test('rejects an unterminated quote', () {
      expect(
        () => splitSshConfigArguments('"open'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('sshConfigPatternMatches', () {
    test('handles * and ? like OpenSSH match_pattern', () {
      expect(sshConfigPatternMatches('*', ''), isTrue);
      expect(sshConfigPatternMatches('*.internal', 'db.internal'), isTrue);
      expect(sshConfigPatternMatches('*.internal', 'internal'), isFalse);
      expect(sshConfigPatternMatches('web?', 'web1'), isTrue);
      expect(sshConfigPatternMatches('web?', 'web12'), isFalse);
      expect(sshConfigPatternMatches('a*b*c', 'axxbyyc'), isTrue);
      expect(sshConfigPatternMatches('a*b*c', 'axxbyy'), isFalse);
    });
  });

  group('parseSshConfig syntax', () {
    test('ignores comments and blank lines', () {
      final document = parseSshConfig('''
# Comment
   # indented comment

Host web
  HostName web.example.com # trailing comment
''');
      expect(document.skipped, isEmpty);
      expect(document.resolve('web').hostName, 'web.example.com');
    });

    test('accepts = separators and any keyword case', () {
      final document = parseSshConfig('''
Host=web
  HOSTNAME=web.example.com
  port = 2222
  User   deploy
''');
      final options = document.resolve('web');
      expect(options.hostName, 'web.example.com');
      expect(options.port, 2222);
      expect(options.user, 'deploy');
    });

    test('handles CRLF line endings and a byte order mark', () {
      final document = parseSshConfig(
        '\uFEFFHost web\r\n  HostName example.com\r\n  Port 22\r\n',
      );
      expect(document.skipped, isEmpty);
      expect(document.resolve('web').hostName, 'example.com');
    });

    test('reads quoted values', () {
      final document = parseSshConfig('''
Host "quoted alias"
  User "first last"
  IdentityFile "~/.ssh/my key"
''');
      expect(document.concreteAliases, ['quoted alias']);
      final options = document.resolve('quoted alias');
      expect(options.user, 'first last');
      expect(options.identityFiles, ['~/.ssh/my key']);
    });

    test('skips an unterminated quote with a reason', () {
      final document = parseSshConfig('''
Host web
  User "broken
''');
      expect(document.skipped.single.lineNumber, 2);
      expect(document.skipped.single.kind, SshConfigSkipKind.invalid);
      expect(document.skipped.single.reason, contains('quote'));
    });

    test('skips a keyword with no value', () {
      final document = parseSshConfig('Host web\n  User\n');
      expect(document.skipped.single.keyword, 'User');
      expect(document.skipped.single.reason, 'Missing value.');
    });

    test('skips an invalid port and keeps looking for a valid one', () {
      final document = parseSshConfig('''
Host web
  Port abc
  Port 0x16
  Port 70000
Host *
  Port 2200
''');
      expect(document.skipped.map((s) => s.lineNumber), [2, 3, 4]);
      expect(document.resolve('web').port, 2200);
    });

    test('skips everything under a Host line with no pattern', () {
      final document = parseSshConfig('''
Host
  User ghost
Host real
  User alice
''');
      expect(document.skipped.map((s) => s.lineNumber), [1, 2]);
      expect(document.concreteAliases, ['real']);
      expect(document.resolve('real').user, 'alice');
    });
  });

  group('first-value precedence', () {
    test('a specific block before Host * wins', () {
      final document = parseSshConfig('''
Host web
  User alice
Host *
  User default
  Port 2222
''');
      final options = document.resolve('web');
      expect(options.user, 'alice');
      expect(options.port, 2222);
    });

    test('Host * before a specific block wins, as in OpenSSH', () {
      final document = parseSshConfig('''
Host *
  User default
Host web
  User alice
''');
      expect(document.resolve('web').user, 'default');
    });

    test('global directives before any Host apply first', () {
      final document = parseSshConfig('''
User global
Port 2022
Host web
  User alice
''');
      final options = document.resolve('web');
      expect(options.user, 'global');
      expect(options.port, 2022);
    });

    test('the first value inside one block wins too', () {
      final document = parseSshConfig('''
Host web
  HostName first.example.com
  HostName second.example.com
''');
      expect(document.resolve('web').hostName, 'first.example.com');
    });

    test('forwards and identity files accumulate across blocks', () {
      final document = parseSshConfig('''
Host web
  LocalForward 8080 localhost:80
  IdentityFile ~/.ssh/web
Host *
  LocalForward 9090 localhost:90
  IdentityFile ~/.ssh/default
''');
      final options = document.resolve('web');
      expect(options.localForwards.map((f) => f.bindPort), [8080, 9090]);
      expect(options.identityFiles, ['~/.ssh/web', '~/.ssh/default']);
    });
  });

  group('host patterns', () {
    test('wildcard hosts supply defaults instead of entries', () {
      final plan = _plan('''
Host *.internal
  User ops
  Port 2201
Host db.internal
  HostName 10.0.0.5
Host *
  ServerAliveInterval 30
''');
      expect(plan.entries.map((e) => e.label), ['db.internal']);
      final db = _entry(plan, 'db.internal');
      expect(db.hostname, '10.0.0.5');
      expect(db.username, 'ops');
      expect(db.port, 2201);
      // Host * only sets options import doesn't use, so it adds nothing.
      expect(plan.defaultPatterns, ['*.internal']);
    });

    test('a Host line with several patterns creates one entry per alias', () {
      final plan = _plan('''
Host web1 web2
  User deploy
''');
      expect(plan.entries.map((e) => e.label), ['web1', 'web2']);
      expect(_entry(plan, 'web1').hostname, 'web1');
      expect(_entry(plan, 'web2').hostname, 'web2');
      expect(_entry(plan, 'web2').username, 'deploy');
    });

    test('aliases for the same endpoint merge into one entry', () {
      final plan = _plan('''
Host web web.example.com
  HostName web.example.com
  User deploy
''');
      final entry = plan.entries.single;
      expect(entry.label, 'web');
      expect(entry.aliases, ['web', 'web.example.com']);
    });

    test('negated patterns exclude hosts from a block', () {
      final plan = _plan('''
Host * !bastion
  ProxyJump bastion
Host bastion
  HostName bastion.example.com
Host app
  HostName app.internal
''');
      expect(_entry(plan, 'bastion').jumpEntryId, isNull);
      expect(_entry(plan, 'app').jumpEntryId, _entry(plan, 'bastion').id);
    });

    test('an alias negated on its own line is not an entry', () {
      final plan = _plan('''
Host foo !foo
  User x
Host bar
''');
      expect(plan.entries.map((e) => e.label), ['bar']);
    });

    test('? patterns are wildcards', () {
      final plan = _plan('''
Host web?
  User deploy
Host web1
''');
      expect(plan.entries.map((e) => e.label), ['web1']);
      expect(_entry(plan, 'web1').username, 'deploy');
    });

    test('pattern matching ignores case', () {
      final document = parseSshConfig('''
Host *.EXAMPLE.com
  User upper
Host api.example.com
''');
      expect(document.resolve('api.example.com').user, 'upper');
    });

    test('expands %h in HostName and warns about other tokens', () {
      final plan = _plan('''
Host *.lab
  HostName %h.example.com
Host box.lab
Host other
  HostName %r-%h
''');
      expect(_entry(plan, 'box.lab').hostname, 'box.lab.example.com');
      final other = _entry(plan, 'other');
      expect(other.hostname, '%r-other');
      expect(other.warnings.single, contains('%h'));
    });

    test('defaults to the alias and port 22', () {
      final entry = _plan('Host plain\n').entries.single;
      expect(entry.hostname, 'plain');
      expect(entry.port, 22);
      expect(entry.username, isNull);
    });
  });

  group('ProxyJump', () {
    test('a single hop to another alias reuses that alias entry', () {
      final plan = _plan('''
Host bastion
  HostName bastion.example.com
  User jump
Host app
  HostName 10.0.0.2
  ProxyJump bastion
''');
      expect(plan.entries, hasLength(2));
      final app = _entry(plan, 'app');
      expect(plan.jumpChain(app).map((e) => e.label), ['bastion']);
      expect(plan.entries.where((e) => e.isJumpOnly), isEmpty);
    });

    test('a hop that is not an alias becomes a jump-only entry', () {
      final plan = _plan('''
Host app
  ProxyJump admin@gateway.example.com:2222
''');
      final hop = plan.entries.singleWhere((e) => e.isJumpOnly);
      expect(hop.label, 'admin@gateway.example.com:2222');
      expect(hop.hostname, 'gateway.example.com');
      expect(hop.username, 'admin');
      expect(hop.port, 2222);
      expect(_entry(plan, 'app').jumpEntryId, hop.id);
    });

    test('a hop picks up config for its name, with spec overrides', () {
      final plan = _plan('''
Host gw
  HostName gw.example.com
  User gwuser
  Port 2022
Host app
  ProxyJump other@gw
''');
      final hop = plan.entries.singleWhere((e) => e.isJumpOnly);
      expect(hop.hostname, 'gw.example.com');
      expect(hop.username, 'other');
      expect(hop.port, 2022);
    });

    test('accepts ssh:// URIs and bracketed IPv6 hops', () {
      expect(parseSshConfigProxyJump('ssh://me@jump:2200'), [
        const SshConfigJumpHop(host: 'jump', user: 'me', port: 2200),
      ]);
      expect(parseSshConfigProxyJump('[2001:db8::1]:22'), [
        const SshConfigJumpHop(host: '2001:db8::1', port: 22),
      ]);
      expect(parseSshConfigProxyJump('none'), isEmpty);
    });

    test('rejects malformed hops', () {
      for (final value in ['a,,b', '@host', 'host:abc', '[::1', 'host:0']) {
        expect(
          () => parseSshConfigProxyJump(value),
          throwsA(isA<FormatException>()),
          reason: value,
        );
      }
      final document = parseSshConfig('Host app\n  ProxyJump host:abc\n');
      expect(document.skipped.single.kind, SshConfigSkipKind.invalid);
    });

    test('a chain connects each hop through the previous one', () {
      final plan = _plan('''
Host outer
  HostName outer.example.com
Host inner
  HostName inner.example.com
Host target
  ProxyJump outer,inner
''');
      final target = _entry(plan, 'target');
      final chain = plan.jumpChain(target);
      expect(chain.map((e) => e.label), ['inner (via outer)', 'outer']);
      expect(chain.first.isJumpOnly, isTrue);
      expect(chain.first.hostname, 'inner.example.com');
      // The inner alias itself still connects directly.
      expect(_entry(plan, 'inner').jumpEntryId, isNull);
      expect(chain.last.id, _entry(plan, 'outer').id);
    });

    test('a chain matching a hop’s own ProxyJump reuses that alias', () {
      final plan = _plan('''
Host outer
Host inner
  ProxyJump outer
Host target
  ProxyJump outer,inner
''');
      expect(plan.entries.where((e) => e.isJumpOnly), isEmpty);
      final chain = plan.jumpChain(_entry(plan, 'target'));
      expect(chain.map((e) => e.label), ['inner', 'outer']);
    });

    test('the first hop keeps its own ProxyJump', () {
      final plan = _plan('''
Host edge
  ProxyJump vpn
Host target
  ProxyJump edge
''');
      final chain = plan.jumpChain(_entry(plan, 'target'));
      expect(chain.map((e) => e.label), ['edge', 'vpn']);
    });

    test('ProxyJump none overrides a later wildcard ProxyJump', () {
      final plan = _plan('''
Host direct
  ProxyJump none
Host *
  ProxyJump bastion
''');
      expect(_entry(plan, 'direct').jumpEntryId, isNull);
    });

    test('a ProxyCommand before ProxyJump wins and is skipped', () {
      final plan = _plan('''
Host app
  ProxyCommand ssh -W %h:%p gw
  ProxyJump bastion
''');
      final app = _entry(plan, 'app');
      expect(app.jumpEntryId, isNull);
      expect(app.warnings.single, contains('ProxyCommand on line 2'));
      expect(plan.skipped.single.kind, SshConfigSkipKind.command);
    });

    test('a ProxyJump before ProxyCommand wins', () {
      final plan = _plan('''
Host app
  ProxyJump bastion
Host *
  ProxyCommand nc %h %p
''');
      final app = _entry(plan, 'app');
      expect(app.jumpEntryId, isNotNull);
      expect(app.warnings, isEmpty);
      expect(plan.skipped.single.keyword, 'ProxyCommand');
    });

    test('ProxyCommand none does not hide a later ProxyJump warning', () {
      final plan = _plan('''
Host app
  ProxyCommand none
  ProxyJump bastion
''');
      final app = _entry(plan, 'app');
      expect(app.jumpEntryId, isNull);
      expect(app.warnings, isEmpty);
    });

    test('a loop blocks every host in it instead of being followed', () {
      final plan = _plan('''
Host a
  ProxyJump b
Host b
  ProxyJump a
Host c
''');
      final a = _entry(plan, 'a');
      final b = _entry(plan, 'b');
      expect(a.jumpEntryId, isNull);
      expect(a.unsupportedReason, contains('loops'));
      expect(b.unsupportedReason, contains('Its jump host a'));
      expect(_entry(plan, 'c').unsupportedReason, isNull);
    });

    test('a self-reference is blocked', () {
      final plan = _plan('Host a\n  ProxyJump a\n');
      expect(plan.entries.single.jumpEntryId, isNull);
      expect(plan.entries.single.unsupportedReason, contains('loops'));
    });

    test('allows exactly $sshConfigMaxJumpDepth hops and blocks more', () {
      String chainOf(int count) =>
          [for (var i = 0; i < count; i++) 'h$i'].join(',');
      final ok = _plan('Host target\n  ProxyJump ${chainOf(8)}\n');
      final okTarget = _entry(ok, 'target');
      expect(ok.jumpChain(okTarget), hasLength(8));
      expect(okTarget.unsupportedReason, isNull);

      final deep = _plan('Host target\n  ProxyJump ${chainOf(9)}\n');
      final deepTarget = _entry(deep, 'target');
      expect(
        deepTarget.unsupportedReason,
        contains('follows at most $sshConfigMaxJumpDepth'),
      );
    });

    for (final reversed in [false, true]) {
      test(
        'depth is judged per host, not per lookup order (reversed: $reversed)',
        () {
          final blocks = [
            for (var i = 1; i < 10; i++) 'Host h$i\n  ProxyJump h${i + 1}\n',
            'Host h10\n',
          ];
          final plan = _plan((reversed ? blocks.reversed : blocks).join());
          // h1 jumps through h2..h10: nine hops.
          expect(
            _entry(plan, 'h1').unsupportedReason,
            contains('follows at most $sshConfigMaxJumpDepth'),
          );
          // h2 has exactly eight and h8 two; both import intact.
          expect(_entry(plan, 'h2').unsupportedReason, isNull);
          expect(plan.jumpChain(_entry(plan, 'h2')), hasLength(8));
          expect(_entry(plan, 'h8').unsupportedReason, isNull);
          expect(plan.jumpChain(_entry(plan, 'h8')).map((e) => e.label), [
            'h9',
            'h10',
          ]);
        },
      );
    }

    for (final badFirst in [true, false]) {
      test(
        'a looping alias never merges with a valid one (bad first: $badFirst)',
        () {
          const bad =
              'Host bad\n  HostName shared.example.com\n'
              '  User me\n  ProxyJump bad\n';
          const good =
              'Host good\n  HostName shared.example.com\n'
              '  User me\n';
          final plan = _plan(badFirst ? '$bad$good' : '$good$bad');
          expect(_entry(plan, 'bad').unsupportedReason, contains('loops'));
          expect(_entry(plan, 'good').unsupportedReason, isNull);
          expect(_entry(plan, 'good').aliases, ['good']);
        },
      );
    }

    test('a huge ProxyJump list is blocked without exhausting the stack', () {
      final hops = [for (var i = 0; i < 3000; i++) 'h$i'].join(',');
      final text = 'Host target\n  User me\n  ProxyJump $hops\nHost ok\n';
      final plan = _plan(text);
      expect(
        _entry(plan, 'target').unsupportedReason,
        contains('more than $sshConfigMaxJumpDepth'),
      );
      expect(_entry(plan, 'ok').unsupportedReason, isNull);
    });

    test('a long chain of aliases stays fast and judged per host', () {
      final text = [
        for (var i = 1; i < 2000; i++) 'Host h$i\n  ProxyJump h${i + 1}\n',
        'Host h2000\n',
      ].join();
      final plan = _plan(text);
      expect(_entry(plan, 'h1').unsupportedReason, isNotNull);
      expect(_entry(plan, 'h1992').unsupportedReason, isNull);
      expect(plan.jumpChain(_entry(plan, 'h1992')), hasLength(8));
      expect(_entry(plan, 'h1991').unsupportedReason, isNotNull);
    });

    test('a jump-only host keeps its IdentityFile', () {
      final plan = _plan('''
Host gw
  HostName gw.example.com
  User gwuser
  IdentityFile ~/.ssh/gw
Host app
  ProxyJump special@gw
''');
      final hop = plan.entries.singleWhere((e) => e.isJumpOnly);
      expect(hop.username, 'special');
      expect(hop.keyNeeded, isTrue);
      expect(hop.identityFiles, ['~/.ssh/gw']);
    });
  });

  group('forwards', () {
    test('parses LocalForward and RemoteForward forms', () {
      final document = parseSshConfig('''
Host web
  LocalForward 8080 localhost:80
  LocalForward 127.0.0.1:5432 db.internal:5432
  LocalForward [::1]:9000 [2001:db8::2]:9001
  LocalForward *:3000 localhost:3000
  RemoteForward 9090 localhost:3000
  RemoteForward 0.0.0.0:8443 127.0.0.1:443
''');
      expect(document.skipped, isEmpty);
      final options = document.resolve('web');
      expect(options.localForwards, [
        const SshConfigForward(
          type: SshConfigForwardType.local,
          bindPort: 8080,
          targetHost: 'localhost',
          targetPort: 80,
          lineNumber: 2,
        ),
        const SshConfigForward(
          type: SshConfigForwardType.local,
          bindHost: '127.0.0.1',
          bindPort: 5432,
          targetHost: 'db.internal',
          targetPort: 5432,
          lineNumber: 3,
        ),
        const SshConfigForward(
          type: SshConfigForwardType.local,
          bindHost: '::1',
          bindPort: 9000,
          targetHost: '2001:db8::2',
          targetPort: 9001,
          lineNumber: 4,
        ),
        const SshConfigForward(
          type: SshConfigForwardType.local,
          bindHost: '*',
          bindPort: 3000,
          targetHost: 'localhost',
          targetPort: 3000,
          lineNumber: 5,
        ),
      ]);
      expect(options.remoteForwards.map((f) => f.bindHost), [null, '0.0.0.0']);
      expect(options.remoteForwards.first.bindPort, 9090);
      expect(options.remoteForwards.first.targetPort, 3000);
    });

    test('skips unsupported and malformed forwards with reasons', () {
      final document = parseSshConfig('''
Host web
  LocalForward /tmp/sock /var/run/app.sock
  LocalForward 8080
  RemoteForward 1080
  LocalForward 8080 localhost
  LocalForward 99999 localhost:80
  LocalForward ::1:80 localhost:80
  DynamicForward 1080
''');
      final kinds = {
        for (final skip in document.skipped) skip.lineNumber: skip.kind,
      };
      expect(kinds, {
        2: SshConfigSkipKind.unsupported,
        3: SshConfigSkipKind.invalid,
        4: SshConfigSkipKind.unsupported,
        5: SshConfigSkipKind.invalid,
        6: SshConfigSkipKind.invalid,
        7: SshConfigSkipKind.invalid,
        8: SshConfigSkipKind.unsupported,
      });
      expect(document.skipped[2].reason, contains('SOCKS'));
      expect(document.resolve('web').localForwards, isEmpty);
    });

    test('plan attaches forwards in line order and flags exposed ones', () {
      final plan = _plan('''
Host web
  RemoteForward 9090 localhost:3000
  LocalForward *:8080 localhost:80
''');
      final entry = plan.entries.single;
      expect(entry.forwards.map((f) => f.lineNumber), [2, 3]);
      expect(entry.warnings.single, contains('0.0.0.0'));
      expect(sshConfigForwardIsExposed(entry.forwards.first), isFalse);
      expect(sshConfigForwardIsExposed(entry.forwards.last), isTrue);
    });

    test('jump-only entries carry no forwards', () {
      final plan = _plan('''
Host *
  LocalForward 8080 localhost:80
Host app
  ProxyJump gw.example.com
''');
      final hop = plan.entries.singleWhere((e) => e.isJumpOnly);
      expect(hop.forwards, isEmpty);
      expect(_entry(plan, 'app').forwards, hasLength(1));
    });
  });

  group('skipped directives', () {
    test('Match blocks are skipped with every directive listed', () {
      final plan = _plan('''
Host web
  User alice
Match host web user root
  User root
  Port 2222
Host api
  User bob
''');
      expect(plan.skipped.map((s) => s.lineNumber), [3, 4, 5]);
      expect(plan.skipped.first.kind, SshConfigSkipKind.match);
      expect(plan.skipped[1].reason, contains('Match'));
      expect(_entry(plan, 'web').port, 22);
      expect(_entry(plan, 'api').username, 'bob');
    });

    test('Match exec is reported as a command and never run', () {
      final document = parseSshConfig('''
Match exec "touch /tmp/pwned"
  User x
''');
      expect(document.skipped.first.kind, SshConfigSkipKind.command);
      expect(document.skipped.first.reason, contains('never'));
    });

    test('Match final and Match canonical stay skipped', () {
      final document = parseSshConfig('''
Match final all
  User finaluser
Match canonical all
  Port 2200
Host web
  User ordinaryuser
''');
      final options = document.resolve('web');
      expect(options.user, 'ordinaryuser');
      expect(options.port, isNull);
      expect(document.skipped.map((s) => s.lineNumber), [1, 2, 3, 4]);
    });

    test('entries a skipped Match block may change carry a warning', () {
      final plan = _plan('''
Match host web,!other
  User root
Match user bob
  Port 2222
Match host nothing
Host web
Host api
  HostName api.example.com
''');
      expect(_entry(plan, 'web').warnings, [
        'Skipped Match blocks on lines 1, 3 may change this host’s settings.',
      ]);
      expect(_entry(plan, 'api').warnings, [
        'The skipped Match block on line 3 may change this host’s settings.',
      ]);
    });

    test('Match all applies to every host', () {
      final document = parseSshConfig('''
Match host other
  User skipped
Match all
  User everyone
Host web
''');
      expect(document.resolve('web').user, 'everyone');
      expect(document.skipped.map((s) => s.lineNumber), [1, 2]);
    });

    test('Include, commands, and unsupported options are listed', () {
      final plan = _plan('''
Include ~/.ssh/config.d/*
Host web
  ProxyCommand nc %h %p
  LocalCommand say hi
  RemoteCommand tmux attach
  PermitLocalCommand yes
  KnownHostsCommand /bin/false
  ForwardAgent yes
  FrobnicateWidgets yes
''');
      final reasons = {for (final skip in plan.skipped) skip.keyword: skip};
      expect(reasons['Include']!.kind, SshConfigSkipKind.include);
      for (final keyword in [
        'ProxyCommand',
        'LocalCommand',
        'RemoteCommand',
        'PermitLocalCommand',
        'KnownHostsCommand',
      ]) {
        expect(reasons[keyword]!.kind, SshConfigSkipKind.command);
        expect(reasons[keyword]!.reason, contains('never'));
      }
      expect(reasons['ForwardAgent']!.reason, contains('doesn’t use'));
      expect(reasons['FrobnicateWidgets']!.reason, 'Unknown option.');
      expect(plan.skipped, hasLength(8));
    });
  });

  group('IdentityFile', () {
    test('marks the host as needing a key', () {
      final plan = _plan('''
Host web
  IdentityFile ~/.ssh/id_web
Host api
  IdentityFile none
Host plain
''');
      expect(_entry(plan, 'web').keyNeeded, isTrue);
      expect(_entry(plan, 'web').identityFiles, ['~/.ssh/id_web']);
      expect(_entry(plan, 'api').keyNeeded, isFalse);
      expect(_entry(plan, 'plain').keyNeeded, isFalse);
    });

    test('a wildcard IdentityFile applies to every host', () {
      final plan = _plan('''
Host *
  IdentityFile ~/.ssh/id_ed25519
Host web
''');
      expect(_entry(plan, 'web').keyNeeded, isTrue);
    });
  });

  test('a realistic config imports as expected', () {
    final plan = _plan('''
# Personal machines
Include ~/.orbstack/ssh/config

Host github.com
  User git
  IdentityFile ~/.ssh/github

Host bastion
  HostName bastion.corp.example.com
  User me
  IdentitiesOnly yes

Host dev-* !dev-legacy
  ProxyJump bastion
  User me

Host dev-box dev-legacy
  HostName %h.corp.internal
  LocalForward 5432 localhost:5432

Host *
  ServerAliveInterval 30
  AddKeysToAgent yes
  UseKeychain yes
''');
    expect(plan.entries.map((e) => e.label), [
      'github.com',
      'bastion',
      'dev-box',
      'dev-legacy',
    ]);
    final devBox = _entry(plan, 'dev-box');
    expect(devBox.hostname, 'dev-box.corp.internal');
    expect(devBox.username, 'me');
    expect(plan.jumpChain(devBox).single.label, 'bastion');
    expect(devBox.forwards.single.bindPort, 5432);
    final legacy = _entry(plan, 'dev-legacy');
    expect(legacy.jumpEntryId, isNull);
    expect(legacy.username, isNull);
    expect(_entry(plan, 'github.com').keyNeeded, isTrue);
    expect(plan.skipped.map((s) => s.keyword), [
      'Include',
      'IdentitiesOnly',
      'ServerAliveInterval',
      'AddKeysToAgent',
      'UseKeychain',
    ]);
    expect(plan.defaultPatterns, ['dev-* !dev-legacy']);
  });
}

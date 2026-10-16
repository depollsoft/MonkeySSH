/// Reads OpenSSH client configuration (`~/.ssh/config`) text.
///
/// The parser only reads text. It never opens `Include` files and never runs
/// `ProxyCommand`, `LocalCommand`, `Match exec` or any other directive that
/// would execute something; those are reported as skipped with a reason.
///
/// Resolution follows OpenSSH: for each option the first value obtained wins,
/// blocks are applied in file order, and options that accumulate
/// (`LocalForward`, `RemoteForward`, `IdentityFile`) collect every value.
library;

import 'package:flutter/foundation.dart';

/// Why a directive was not imported.
enum SshConfigSkipKind {
  /// A `Match` block, or a directive inside one.
  match,

  /// An `Include` directive.
  include,

  /// A directive that runs a command (`ProxyCommand`, `LocalCommand`, ...).
  command,

  /// An option MonkeySSH does not use, or an unknown option.
  unsupported,

  /// A value that could not be parsed.
  invalid,
}

/// One directive that the import leaves out, with a user-facing reason.
@immutable
class SshConfigSkippedDirective {
  /// Creates a skipped directive record.
  const SshConfigSkippedDirective({
    required this.lineNumber,
    required this.keyword,
    required this.kind,
    required this.reason,
  });

  /// One-based line number in the pasted text.
  final int lineNumber;

  /// The keyword as written, for example `ProxyCommand`.
  final String keyword;

  /// The category of the skip.
  final SshConfigSkipKind kind;

  /// Short explanation shown in the import preview.
  final String reason;

  @override
  String toString() => 'line $lineNumber $keyword: $reason';
}

/// One hop of a `ProxyJump` list: `[user@]host[:port]`.
@immutable
class SshConfigJumpHop {
  /// Creates a jump hop.
  const SshConfigJumpHop({required this.host, this.user, this.port});

  /// Host name or alias to look up in the same config.
  final String host;

  /// User override from the hop spec.
  final String? user;

  /// Port override from the hop spec.
  final int? port;

  /// The hop as OpenSSH would accept it.
  String get display {
    final buffer = StringBuffer();
    if (user != null) buffer.write('$user@');
    buffer.write(host.contains(':') ? '[$host]' : host);
    if (port != null) buffer.write(':$port');
    return buffer.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is SshConfigJumpHop &&
      other.host == host &&
      other.user == user &&
      other.port == port;

  @override
  int get hashCode => Object.hash(host, user, port);

  @override
  String toString() => display;
}

/// Direction of a port forward.
enum SshConfigForwardType {
  /// `LocalForward`: listen on the phone, connect from the server.
  local,

  /// `RemoteForward`: listen on the server, connect from the phone.
  remote,
}

/// A parsed `LocalForward` or `RemoteForward`.
@immutable
class SshConfigForward {
  /// Creates a forward.
  const SshConfigForward({
    required this.type,
    required this.bindPort,
    required this.targetHost,
    required this.targetPort,
    required this.lineNumber,
    this.bindHost,
  });

  /// Local or remote forward.
  final SshConfigForwardType type;

  /// Listen address as written; null means the OpenSSH default (loopback).
  ///
  /// An empty string or `*` means every interface.
  final String? bindHost;

  /// Listen port.
  final int bindPort;

  /// Destination host.
  final String targetHost;

  /// Destination port.
  final int targetPort;

  /// One-based line number of the directive.
  final int lineNumber;

  @override
  bool operator ==(Object other) =>
      other is SshConfigForward &&
      other.type == type &&
      other.bindHost == bindHost &&
      other.bindPort == bindPort &&
      other.targetHost == targetHost &&
      other.targetPort == targetPort;

  @override
  int get hashCode =>
      Object.hash(type, bindHost, bindPort, targetHost, targetPort);

  @override
  String toString() {
    final bind = bindHost == null ? '' : '$bindHost:';
    final keyword = type == SshConfigForwardType.local
        ? 'LocalForward'
        : 'RemoteForward';
    return '$keyword $bind$bindPort $targetHost:$targetPort';
  }
}

/// One `Host` pattern, possibly negated with `!`.
@immutable
class SshConfigHostPattern {
  /// Creates a host pattern.
  SshConfigHostPattern(this.pattern, {this.negated = false})
    : _lowerPattern = pattern.toLowerCase(),
      hasWildcard = pattern.contains('*') || pattern.contains('?');

  /// The pattern without its `!` prefix.
  final String pattern;

  final String _lowerPattern;

  /// Whether the pattern excludes matching hosts.
  final bool negated;

  /// Whether the pattern uses `*` or `?` wildcards.
  final bool hasWildcard;

  /// Whether this pattern names exactly one host alias.
  bool get isConcrete => !negated && !hasWildcard;

  /// Whether [host] matches the pattern, ignoring its negation.
  bool matches(String host) => matchesLowerCase(host.toLowerCase());

  /// [matches] for a host name that is already lower case.
  bool matchesLowerCase(String host) => hasWildcard
      ? sshConfigPatternMatches(_lowerPattern, host)
      : _lowerPattern == host;

  @override
  String toString() => negated ? '!$pattern' : pattern;
}

/// A directive the importer understands, kept for resolution.
@immutable
class SshConfigDirective {
  /// Creates a directive.
  const SshConfigDirective({
    required this.lineNumber,
    required this.keyword,
    required this.value,
  });

  /// One-based line number.
  final int lineNumber;

  /// Lower-case keyword.
  final String keyword;

  /// Parsed value: a [String], [int], [SshConfigForward], or a list of
  /// [SshConfigJumpHop] (empty for `ProxyJump none`).
  final Object value;
}

/// A `Host` block, the implicit global block, or a `Match all` block.
@immutable
class SshConfigBlock {
  /// Creates a block.
  const SshConfigBlock({
    required this.patterns,
    required this.directives,
    this.lineNumber,
  });

  /// One-based line of the `Host` or `Match all` line; null for the global
  /// block before the first `Host`.
  final int? lineNumber;

  /// Host patterns. Empty means the block applies to every host.
  final List<SshConfigHostPattern> patterns;

  /// Understood directives in file order.
  final List<SshConfigDirective> directives;

  /// Whether the block applies to every host.
  bool get matchesEverything => patterns.isEmpty;

  /// Whether this block applies to [host], using OpenSSH rules: at least one
  /// positive pattern matches and no negated pattern matches.
  bool matches(String host) => matchesLowerCase(host.toLowerCase());

  /// [matches] for a host name that is already lower case.
  bool matchesLowerCase(String host) =>
      patterns.isEmpty || sshConfigPatternListMatches(patterns, host);

  /// Whether the block only supplies defaults (no concrete alias).
  bool get isDefaultsOnly => !patterns.any((pattern) => pattern.isConcrete);
}

/// Options resolved for one host name.
@immutable
class SshConfigResolvedOptions {
  /// Creates resolved options.
  const SshConfigResolvedOptions({
    required this.name,
    required this.localForwards,
    required this.remoteForwards,
    required this.identityFiles,
    this.hostName,
    this.port,
    this.user,
    this.proxyJump,
    this.proxyCommandLine,
  });

  /// The name that was resolved.
  final String name;

  /// First `HostName`, unexpanded.
  final String? hostName;

  /// First valid `Port`.
  final int? port;

  /// First `User`.
  final String? user;

  /// First `ProxyJump` hops when it precedes any `ProxyCommand`. Empty for
  /// `ProxyJump none`.
  final List<SshConfigJumpHop>? proxyJump;

  /// Line of the first `ProxyCommand` when it precedes any `ProxyJump` and is
  /// not `none`.
  final int? proxyCommandLine;

  /// Every `LocalForward`, in file order.
  final List<SshConfigForward> localForwards;

  /// Every `RemoteForward`, in file order.
  final List<SshConfigForward> remoteForwards;

  /// Every `IdentityFile` path, in file order.
  final List<String> identityFiles;
}

/// A parsed OpenSSH client config.
@immutable
class SshConfigDocument {
  /// Creates a document.
  const SshConfigDocument({
    required this.blocks,
    required this.skipped,
    this.skippedMatchBlocks = const [],
  });

  /// Blocks in file order, including the global block when present.
  final List<SshConfigBlock> blocks;

  /// Every directive the import leaves out, in line order.
  final List<SshConfigSkippedDirective> skipped;

  /// Skipped `Match` blocks that held at least one directive.
  final List<SshConfigSkippedMatchBlock> skippedMatchBlocks;

  /// Concrete aliases in order of first appearance.
  ///
  /// A pattern is concrete when it has no wildcard and is not negated, and
  /// only when its own block applies to it (`Host foo !foo` does not).
  List<String> get concreteAliases {
    final seen = <String>{};
    final aliases = <String>[];
    for (final block in blocks) {
      for (final pattern in block.patterns) {
        if (!pattern.isConcrete) continue;
        final alias = pattern.pattern;
        if (!block.matches(alias)) continue;
        if (seen.add(alias.toLowerCase())) aliases.add(alias);
      }
    }
    return aliases;
  }

  /// Wildcard or global blocks that supply defaults instead of entries.
  List<SshConfigBlock> get defaultBlocks =>
      blocks.where((block) => block.isDefaultsOnly).toList(growable: false);

  /// Resolves the options OpenSSH would use for [name].
  SshConfigResolvedOptions resolve(String name) {
    String? hostName;
    int? port;
    String? user;
    List<SshConfigJumpHop>? proxyJump;
    int? proxyCommandLine;
    var proxyDecided = false;
    final localForwards = <SshConfigForward>[];
    final remoteForwards = <SshConfigForward>[];
    final identityFiles = <String>[];
    final lowerName = name.toLowerCase();
    for (final block in blocks) {
      if (!block.matchesLowerCase(lowerName)) continue;
      for (final directive in block.directives) {
        final value = directive.value;
        switch (directive.keyword) {
          case 'hostname':
            hostName ??= value as String;
          case 'port':
            port ??= value as int;
          case 'user':
            user ??= value as String;
          case 'proxyjump':
            if (!proxyDecided) {
              proxyDecided = true;
              proxyJump = List.unmodifiable(value as List<SshConfigJumpHop>);
            }
          case 'proxycommand':
            if (!proxyDecided) {
              proxyDecided = true;
              if ((value as String).toLowerCase() != 'none') {
                proxyCommandLine = directive.lineNumber;
              }
            }
          case 'localforward':
            localForwards.add(value as SshConfigForward);
          case 'remoteforward':
            remoteForwards.add(value as SshConfigForward);
          case 'identityfile':
            final path = value as String;
            if (path.toLowerCase() != 'none') identityFiles.add(path);
        }
      }
    }
    return SshConfigResolvedOptions(
      name: name,
      hostName: hostName,
      port: port,
      user: user,
      proxyJump: proxyJump,
      proxyCommandLine: proxyCommandLine,
      localForwards: List.unmodifiable(localForwards),
      remoteForwards: List.unmodifiable(remoteForwards),
      identityFiles: List.unmodifiable(identityFiles),
    );
  }
}

/// Whether lower-case [host] matches [patterns]: at least one positive
/// pattern matches and no negated pattern does.
bool sshConfigPatternListMatches(
  List<SshConfigHostPattern> patterns,
  String host,
) {
  var matched = false;
  for (final pattern in patterns) {
    if (!pattern.matchesLowerCase(host)) continue;
    if (pattern.negated) return false;
    matched = true;
  }
  return matched;
}

/// A `Match` block the import skipped, kept so entries it might affect can
/// say so.
@immutable
class SshConfigSkippedMatchBlock {
  /// Creates a skipped block record.
  const SshConfigSkippedMatchBlock({
    required this.lineNumber,
    required this.hostPatterns,
  });

  /// One-based line of the `Match` line.
  final int lineNumber;

  /// Patterns from its `host` and `originalhost` criteria, or null when the
  /// block has no such criterion and could apply to any host.
  final List<SshConfigHostPattern>? hostPatterns;

  /// Whether the block could apply to a host reached as [alias] at
  /// [hostname].
  bool mayApplyTo(String alias, String hostname) {
    final patterns = hostPatterns;
    if (patterns == null) return true;
    return sshConfigPatternListMatches(patterns, alias.toLowerCase()) ||
        sshConfigPatternListMatches(patterns, hostname.toLowerCase());
  }
}

/// OpenSSH `match_pattern`: `*` matches any run of characters (including
/// none) and `?` matches exactly one.
bool sshConfigPatternMatches(String pattern, String text) {
  var p = 0;
  var t = 0;
  var starPattern = -1;
  var starText = 0;
  while (t < text.length) {
    if (p < pattern.length &&
        (pattern[p] == '?' || (pattern[p] != '*' && pattern[p] == text[t]))) {
      p++;
      t++;
    } else if (p < pattern.length && pattern[p] == '*') {
      starPattern = p++;
      starText = t;
    } else if (starPattern >= 0) {
      p = starPattern + 1;
      t = ++starText;
    } else {
      return false;
    }
  }
  while (p < pattern.length && pattern[p] == '*') {
    p++;
  }
  return p == pattern.length;
}

/// Splits the arguments of a config line the way OpenSSH's `argv_split`
/// does: whitespace separates tokens, single or double quotes group text,
/// a backslash escapes a quote, a backslash or (outside quotes) a space, and
/// a `#` at the start of a token begins a comment.
///
/// Throws [FormatException] for an unterminated quote.
List<String> splitSshConfigArguments(String input) {
  final tokens = <String>[];
  var i = 0;
  while (i < input.length) {
    final char = input[i];
    if (char == ' ' || char == '\t') {
      i++;
      continue;
    }
    if (char == '#') break;
    final token = StringBuffer();
    String? quote;
    while (i < input.length) {
      final c = input[i];
      if (c == r'\' && i + 1 < input.length) {
        final next = input[i + 1];
        if (next == "'" ||
            next == '"' ||
            next == r'\' ||
            (quote == null && next == ' ')) {
          token.write(next);
          i += 2;
          continue;
        }
        token.write(c);
        i++;
        continue;
      }
      if (quote == null && (c == ' ' || c == '\t')) break;
      if (quote == null && (c == '"' || c == "'")) {
        quote = c;
      } else if (quote != null && c == quote) {
        quote = null;
      } else {
        token.write(c);
      }
      i++;
    }
    if (quote != null) {
      throw const FormatException('Unterminated quote');
    }
    tokens.add(token.toString());
  }
  return tokens;
}

/// Parses a `ProxyJump` value into hops.
///
/// Returns an empty list for `none`. Throws [FormatException] for an invalid
/// hop.
List<SshConfigJumpHop> parseSshConfigProxyJump(String value) {
  if (value.toLowerCase() == 'none') return const [];
  final hops = <SshConfigJumpHop>[];
  for (final rawHop in value.split(',')) {
    final hop = rawHop.trim();
    if (hop.isEmpty) {
      throw const FormatException('Empty jump host');
    }
    hops.add(_parseJumpHop(hop));
  }
  return hops;
}

SshConfigJumpHop _parseJumpHop(String hop) {
  var rest = hop;
  if (rest.toLowerCase().startsWith('ssh://')) {
    rest = rest.substring(6);
    if (rest.endsWith('/')) rest = rest.substring(0, rest.length - 1);
  }
  String? user;
  final at = rest.lastIndexOf('@');
  if (at >= 0) {
    user = rest.substring(0, at);
    rest = rest.substring(at + 1);
    if (user.isEmpty) throw FormatException('Empty user in $hop');
  }
  final (host, port) = _splitHostPort(rest, original: hop);
  return SshConfigJumpHop(host: host, user: user, port: port);
}

(String, int?) _splitHostPort(String value, {required String original}) {
  if (value.startsWith('[')) {
    final close = value.indexOf(']');
    if (close < 0) throw FormatException('Unclosed bracket in $original');
    final host = value.substring(1, close);
    final tail = value.substring(close + 1);
    if (host.isEmpty) throw FormatException('Empty host in $original');
    if (tail.isEmpty) return (host, null);
    if (!tail.startsWith(':')) {
      throw FormatException('Unexpected text after ] in $original');
    }
    return (host, _parsePort(tail.substring(1), original: original));
  }
  final colon = value.indexOf(':');
  if (colon < 0) {
    if (value.isEmpty) throw FormatException('Empty host in $original');
    return (value, null);
  }
  final host = value.substring(0, colon);
  if (host.isEmpty) throw FormatException('Empty host in $original');
  return (host, _parsePort(value.substring(colon + 1), original: original));
}

int _parsePort(String value, {required String original}) {
  final port = tryParseSshConfigPort(value);
  if (port == null) throw FormatException('Invalid port in $original');
  return port;
}

final _digitsPattern = RegExp(r'^[0-9]{1,5}$');

/// Parses a TCP port written as plain decimal digits from 1 to 65535.
int? tryParseSshConfigPort(String value) {
  if (!_digitsPattern.hasMatch(value)) return null;
  final port = int.parse(value);
  return port < 1 || port > 65535 ? null : port;
}

/// Parses a forward's listen side: `port`, `bind:port` or `[bind]:port`.
(String?, int) _parseForwardListen(String value, {required String original}) {
  if (value.contains('/')) {
    throw const FormatException('Unix socket forwards are not supported');
  }
  if (value.startsWith('[')) {
    final close = value.indexOf(']');
    if (close < 0 || close + 1 >= value.length || value[close + 1] != ':') {
      throw FormatException('Invalid listen address in $original');
    }
    return (
      value.substring(1, close),
      _parsePort(value.substring(close + 2), original: original),
    );
  }
  final colon = value.lastIndexOf(':');
  if (colon < 0) return (null, _parsePort(value, original: original));
  final bind = value.substring(0, colon);
  if (bind.contains(':')) {
    throw FormatException('Put IPv6 listen addresses in [brackets]: $original');
  }
  return (bind, _parsePort(value.substring(colon + 1), original: original));
}

/// Parses a forward's connect side: `host:port` or `[host]:port`.
(String, int) _parseForwardTarget(String value, {required String original}) {
  if (value.contains('/')) {
    throw const FormatException('Unix socket forwards are not supported');
  }
  final (host, port) = _splitHostPort(value, original: original);
  if (port == null) {
    throw FormatException('Missing destination port in $original');
  }
  if (!value.startsWith('[') && value.indexOf(':') != value.lastIndexOf(':')) {
    throw FormatException('Put IPv6 destinations in [brackets]: $original');
  }
  return (host, port);
}

/// Keywords whose directives run a command.
const _commandKeywords = <String, String>{
  'proxycommand': 'ProxyCommand',
  'localcommand': 'LocalCommand',
  'remotecommand': 'RemoteCommand',
  'knownhostscommand': 'KnownHostsCommand',
  'permitlocalcommand': 'PermitLocalCommand',
};

/// Client options OpenSSH knows that MonkeySSH does not import.
const _knownUnsupportedKeywords = <String>{
  'addkeystoagent',
  'addressfamily',
  'batchmode',
  'bindaddress',
  'bindinterface',
  'canonicaldomains',
  'canonicalizefallbacklocal',
  'canonicalizehostname',
  'canonicalizemaxdots',
  'canonicalizepermittedcnames',
  'casignaturealgorithms',
  'certificatefile',
  'challengeresponseauthentication',
  'channeltimeout',
  'checkhostip',
  'ciphers',
  'clearallforwardings',
  'compression',
  'connectionattempts',
  'connecttimeout',
  'controlmaster',
  'controlpath',
  'controlpersist',
  'enableescapecommandline',
  'enablesshkeysign',
  'escapechar',
  'exitonforwardfailure',
  'fingerprinthash',
  'forkafterauthentication',
  'forwardagent',
  'forwardx11',
  'forwardx11timeout',
  'forwardx11trusted',
  'gatewayports',
  'globalknownhostsfile',
  'gssapiauthentication',
  'gssapidelegatecredentials',
  'hashknownhosts',
  'hostbasedacceptedalgorithms',
  'hostbasedauthentication',
  'hostbasedkeytypes',
  'hostkeyalgorithms',
  'hostkeyalias',
  'identitiesonly',
  'identityagent',
  'ignoreunknown',
  'ipqos',
  'kbdinteractiveauthentication',
  'kbdinteractivedevices',
  'kexalgorithms',
  'loglevel',
  'logverbose',
  'macs',
  'nohostauthenticationforlocalhost',
  'numberofpasswordprompts',
  'obscurekeystroketiming',
  'passwordauthentication',
  'permitremoteopen',
  'pkcs11provider',
  'preferredauthentications',
  'protocol',
  'proxyusefdpass',
  'pubkeyacceptedalgorithms',
  'pubkeyacceptedkeytypes',
  'pubkeyauthentication',
  'refuseconnection',
  'rekeylimit',
  'requesttty',
  'requiredrsasize',
  'revokedhostkeys',
  'securitykeyprovider',
  'sendenv',
  'serveralivecountmax',
  'serveraliveinterval',
  'sessiontype',
  'setenv',
  'stdinnull',
  'streamlocalbindmask',
  'streamlocalbindunlink',
  'stricthostkeychecking',
  'syslogfacility',
  'tag',
  'tcpkeepalive',
  'tunnel',
  'tunneldevice',
  'updatehostkeys',
  'usekeychain',
  'useprivilegedport',
  'userknownhostsfile',
  'verifyhostkeydns',
  'versionaddendum',
  'visualhostkey',
  'warnweakcrypto',
  'xauthlocation',
};

final _trailingWhitespace = RegExp(r'[\s\f]+$');
final _keywordPattern = RegExp(r'^([^\s=]+)\s*(?:=\s*)?(.*)$');

/// Parses OpenSSH client config [text].
///
/// Never throws: malformed lines become [SshConfigSkippedDirective]s with
/// [SshConfigSkipKind.invalid].
SshConfigDocument parseSshConfig(String text) {
  final blocks = <SshConfigBlock>[];
  final skipped = <SshConfigSkippedDirective>[];
  var currentPatterns = <SshConfigHostPattern>[];
  var currentDirectives = <SshConfigDirective>[];
  int? currentLine;
  var hasCurrentBlock = false;
  // Set while inside a block whose directives are all skipped.
  ({SshConfigSkipKind kind, String reason})? skippedBlock;

  void closeBlock() {
    if (hasCurrentBlock &&
        (currentLine != null || currentDirectives.isNotEmpty)) {
      blocks.add(
        SshConfigBlock(
          lineNumber: currentLine,
          patterns: List.unmodifiable(currentPatterns),
          directives: List.unmodifiable(currentDirectives),
        ),
      );
    }
    currentPatterns = <SshConfigHostPattern>[];
    currentDirectives = <SshConfigDirective>[];
    currentLine = null;
    hasCurrentBlock = false;
  }

  void skip(
    int lineNumber,
    String keyword,
    SshConfigSkipKind kind,
    String reason,
  ) => skipped.add(
    SshConfigSkippedDirective(
      lineNumber: lineNumber,
      keyword: keyword,
      kind: kind,
      reason: reason,
    ),
  );

  final skippedMatchBlocks = <SshConfigSkippedMatchBlock>[];
  ({int lineNumber, List<SshConfigHostPattern>? hostPatterns, int directives})?
  pendingMatch;
  void closeSkippedMatch() {
    final match = pendingMatch;
    pendingMatch = null;
    if (match == null || match.directives == 0) return;
    skippedMatchBlocks.add(
      SshConfigSkippedMatchBlock(
        lineNumber: match.lineNumber,
        hostPatterns: match.hostPatterns,
      ),
    );
  }

  // Directives before the first Host apply to every host.
  hasCurrentBlock = true;

  final source = text.startsWith('﻿') ? text.substring(1) : text;
  final lines = source.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final line = lines[index].replaceAll(_trailingWhitespace, '');
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    final keywordMatch = _keywordPattern.firstMatch(trimmed);
    if (keywordMatch == null) continue;
    final keywordAsWritten = keywordMatch.group(1)!;
    final keyword = keywordAsWritten.toLowerCase();
    final rest = keywordMatch.group(2) ?? '';

    List<String> args;
    try {
      args = splitSshConfigArguments(rest);
    } on FormatException {
      skip(
        lineNumber,
        keywordAsWritten,
        SshConfigSkipKind.invalid,
        'Unterminated quote.',
      );
      continue;
    }

    if (keyword == 'host') {
      closeBlock();
      closeSkippedMatch();
      skippedBlock = null;
      if (args.isEmpty) {
        skip(
          lineNumber,
          keywordAsWritten,
          SshConfigSkipKind.invalid,
          'Host needs at least one pattern.',
        );
        // OpenSSH rejects this line; skip the block it would have started.
        skippedBlock = (
          kind: SshConfigSkipKind.invalid,
          reason: 'Belongs to a Host line with no pattern.',
        );
        continue;
      }
      hasCurrentBlock = true;
      currentLine = lineNumber;
      currentPatterns = [
        for (final arg in args)
          if (arg.startsWith('!'))
            SshConfigHostPattern(arg.substring(1), negated: true)
          else
            SshConfigHostPattern(arg),
      ];
      continue;
    }

    if (keyword == 'match') {
      closeBlock();
      closeSkippedMatch();
      final criteria = args
          .map((arg) => arg.toLowerCase())
          .toList(growable: false);
      // Only a bare `Match all` applies on the first pass. `canonical` and
      // `final` blocks belong to later passes this import doesn't run.
      if (criteria.length == 1 && criteria.single == 'all') {
        skippedBlock = null;
        hasCurrentBlock = true;
        currentLine = lineNumber;
        currentPatterns = <SshConfigHostPattern>[];
        continue;
      }
      skippedBlock = (
        kind: SshConfigSkipKind.match,
        reason: 'Inside a skipped Match block.',
      );
      pendingMatch = (
        lineNumber: lineNumber,
        hostPatterns: _matchHostPatterns(args),
        directives: 0,
      );
      final runsCommand = criteria.contains('exec');
      skip(
        lineNumber,
        keywordAsWritten,
        runsCommand ? SshConfigSkipKind.command : SshConfigSkipKind.match,
        runsCommand
            ? 'Match exec runs a command, which import never does. The block '
                  'is skipped.'
            : 'Match conditions aren’t evaluated, so the block is skipped.',
      );
      continue;
    }

    if (skippedBlock case final block?) {
      skip(lineNumber, keywordAsWritten, block.kind, block.reason);
      if (pendingMatch case final match?) {
        pendingMatch = (
          lineNumber: match.lineNumber,
          hostPatterns: match.hostPatterns,
          directives: match.directives + 1,
        );
      }
      continue;
    }

    if (keyword == 'include') {
      skip(
        lineNumber,
        keywordAsWritten,
        SshConfigSkipKind.include,
        'Include files aren’t read. Paste their contents to import them.',
      );
      continue;
    }

    if (args.isEmpty) {
      skip(
        lineNumber,
        keywordAsWritten,
        SshConfigSkipKind.invalid,
        'Missing value.',
      );
      continue;
    }

    final commandName = _commandKeywords[keyword];
    if (commandName != null) {
      skip(
        lineNumber,
        keywordAsWritten,
        SshConfigSkipKind.command,
        keyword == 'proxycommand'
            ? 'ProxyCommand runs a local command, which import never does. '
                  'Use ProxyJump instead.'
            : '$commandName runs a command, which import never does.',
      );
      if (keyword == 'proxycommand') {
        // Kept so ProxyCommand-before-ProxyJump precedence still applies.
        currentDirectives.add(
          SshConfigDirective(
            lineNumber: lineNumber,
            keyword: keyword,
            value: args.join(' '),
          ),
        );
      }
      continue;
    }

    switch (keyword) {
      case 'hostname':
      case 'user':
      case 'identityfile':
        if (args.length != 1) {
          skip(
            lineNumber,
            keywordAsWritten,
            SshConfigSkipKind.invalid,
            'Expected one value.',
          );
          continue;
        }
        currentDirectives.add(
          SshConfigDirective(
            lineNumber: lineNumber,
            keyword: keyword,
            value: args.single,
          ),
        );
      case 'port':
        final port = args.length == 1
            ? tryParseSshConfigPort(args.single)
            : null;
        if (port == null) {
          skip(
            lineNumber,
            keywordAsWritten,
            SshConfigSkipKind.invalid,
            'Port must be a number from 1 to 65535.',
          );
          continue;
        }
        currentDirectives.add(
          SshConfigDirective(
            lineNumber: lineNumber,
            keyword: keyword,
            value: port,
          ),
        );
      case 'proxyjump':
        try {
          if (args.length != 1) {
            throw const FormatException('Expected one value');
          }
          currentDirectives.add(
            SshConfigDirective(
              lineNumber: lineNumber,
              keyword: keyword,
              value: parseSshConfigProxyJump(args.single),
            ),
          );
        } on FormatException catch (error) {
          skip(
            lineNumber,
            keywordAsWritten,
            SshConfigSkipKind.invalid,
            'Couldn’t read the jump host list: ${error.message}.',
          );
        }
      case 'localforward':
      case 'remoteforward':
        final type = keyword == 'localforward'
            ? SshConfigForwardType.local
            : SshConfigForwardType.remote;
        if (type == SshConfigForwardType.remote && args.length == 1) {
          skip(
            lineNumber,
            keywordAsWritten,
            SshConfigSkipKind.unsupported,
            'Dynamic (SOCKS) remote forwarding isn’t supported.',
          );
          continue;
        }
        if (args.length != 2) {
          skip(
            lineNumber,
            keywordAsWritten,
            SshConfigSkipKind.invalid,
            'Expected a listen port and a host:port destination.',
          );
          continue;
        }
        try {
          final original = args.join(' ');
          final (bindHost, bindPort) = _parseForwardListen(
            args[0],
            original: original,
          );
          final (targetHost, targetPort) = _parseForwardTarget(
            args[1],
            original: original,
          );
          currentDirectives.add(
            SshConfigDirective(
              lineNumber: lineNumber,
              keyword: keyword,
              value: SshConfigForward(
                type: type,
                bindHost: bindHost,
                bindPort: bindPort,
                targetHost: targetHost,
                targetPort: targetPort,
                lineNumber: lineNumber,
              ),
            ),
          );
        } on FormatException catch (error) {
          skip(
            lineNumber,
            keywordAsWritten,
            error.message.startsWith('Unix socket')
                ? SshConfigSkipKind.unsupported
                : SshConfigSkipKind.invalid,
            '${error.message}.',
          );
        }
      case 'dynamicforward':
        skip(
          lineNumber,
          keywordAsWritten,
          SshConfigSkipKind.unsupported,
          'Dynamic (SOCKS) forwarding isn’t supported.',
        );
      default:
        skip(
          lineNumber,
          keywordAsWritten,
          SshConfigSkipKind.unsupported,
          _knownUnsupportedKeywords.contains(keyword)
              ? 'MonkeySSH doesn’t use this option.'
              : 'Unknown option.',
        );
    }
  }
  closeBlock();
  closeSkippedMatch();

  return SshConfigDocument(
    blocks: List.unmodifiable(blocks),
    skipped: List.unmodifiable(skipped),
    skippedMatchBlocks: List.unmodifiable(skippedMatchBlocks),
  );
}

/// Host patterns from a `Match` line's `host` and `originalhost` criteria.
///
/// Returns null when the line has no such criterion, or negates one, so the
/// block could apply to any host.
List<SshConfigHostPattern>? _matchHostPatterns(List<String> args) {
  const noArgument = {'all', 'canonical', 'final'};
  final patterns = <SshConfigHostPattern>[];
  var i = 0;
  while (i < args.length) {
    final criterion = args[i].toLowerCase();
    if (noArgument.contains(criterion)) {
      i++;
      continue;
    }
    final value = i + 1 < args.length ? args[i + 1] : '';
    if (criterion == 'host' || criterion == 'originalhost') {
      for (final raw in value.split(',')) {
        if (raw.isEmpty) continue;
        patterns.add(
          raw.startsWith('!')
              ? SshConfigHostPattern(raw.substring(1), negated: true)
              : SshConfigHostPattern(raw),
        );
      }
    } else if (criterion == '!host' || criterion == '!originalhost') {
      return null;
    }
    i += 2;
  }
  return patterns.isEmpty ? null : patterns;
}

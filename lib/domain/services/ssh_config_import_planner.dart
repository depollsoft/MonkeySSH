/// Turns a parsed OpenSSH client config into the host entries MonkeySSH would
/// create, so the user can preview them before anything is saved.
library;

import 'package:flutter/foundation.dart';

import 'port_forward_browser_service.dart' show isPortForwardLoopbackHost;
import 'ssh_config_parser.dart';

/// Deepest `ProxyJump` nesting the planner follows before giving up.
const sshConfigMaxJumpDepth = 8;

/// One host MonkeySSH would create from the config.
@immutable
class SshConfigImportEntry {
  /// Creates an entry.
  const SshConfigImportEntry({
    required this.id,
    required this.label,
    required this.aliases,
    required this.hostname,
    required this.port,
    required this.forwards,
    required this.identityFiles,
    required this.warnings,
    required this.isJumpOnly,
    this.username,
    this.jumpEntryId,
    this.unsupportedReason,
  });

  /// Stable identifier within the plan.
  final String id;

  /// Display label for the saved host.
  final String label;

  /// Every config alias this entry stands for; empty for jump-only entries.
  final List<String> aliases;

  /// Hostname or address to connect to.
  final String hostname;

  /// SSH port.
  final int port;

  /// User from the config, if any.
  final String? username;

  /// Entry used as this host's jump host.
  final String? jumpEntryId;

  /// Port forwards to save with the host.
  final List<SshConfigForward> forwards;

  /// `IdentityFile` paths. A path on a laptop does not put the key on the
  /// phone, so these only mark the host as needing a key.
  final List<String> identityFiles;

  /// Problems the user should see before importing.
  final List<String> warnings;

  /// Whether this entry exists only because another host jumps through it.
  final bool isJumpOnly;

  /// Why this entry can't be imported as configured (a ProxyJump loop or a
  /// chain longer than [sshConfigMaxJumpDepth]), or null.
  final String? unsupportedReason;

  /// Whether the host needs a key imported separately.
  bool get keyNeeded => identityFiles.isNotEmpty;
}

/// The preview of an `ssh_config` import.
@immutable
class SshConfigImportPlan {
  /// Creates a plan.
  const SshConfigImportPlan({
    required this.entries,
    required this.skipped,
    required this.defaultPatterns,
  });

  /// Entries: aliases in file order, then jump-only hosts.
  final List<SshConfigImportEntry> entries;

  /// Every directive left out, with reasons.
  final List<SshConfigSkippedDirective> skipped;

  /// Patterns of wildcard blocks applied as defaults (`*` for global
  /// directives).
  final List<String> defaultPatterns;

  /// Looks up an entry by [SshConfigImportEntry.id].
  SshConfigImportEntry? entryById(String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// The jump hosts [entry] connects through, nearest first.
  List<SshConfigImportEntry> jumpChain(SshConfigImportEntry entry) {
    final chain = <SshConfigImportEntry>[];
    final seen = <String>{entry.id};
    var next = entry.jumpEntryId;
    while (next != null && seen.add(next)) {
      final hop = entryById(next);
      if (hop == null) break;
      chain.add(hop);
      next = hop.jumpEntryId;
    }
    return chain;
  }
}

/// A host resolved from the config, before it becomes an entry.
class _Node {
  _Node({
    required this.name,
    required this.label,
    required this.hostname,
    required this.port,
    required this.username,
    required this.jump,
    required this.warnings,
    required this.identityFiles,
    required this.problem,
  });

  final String name;
  final String label;
  final String hostname;
  final int port;
  final String? username;
  final _Node? jump;
  final List<String> warnings;
  final List<String> identityFiles;

  /// Why this host's own ProxyJump chain can't be imported, or null.
  final String? problem;

  /// Number of jump hosts between the phone and this host.
  late final int chainLength = jump == null ? 0 : jump!.chainLength + 1;

  /// [problem], or the first problem further down the chain.
  late final String? unsupportedReason =
      problem ??
      (jump?.unsupportedReason == null
          ? null
          : 'Its jump host ${jump!.label} can’t be imported: '
                '${jump!.unsupportedReason}');

  late final String signature =
      '${username ?? ''}@${hostname.toLowerCase()}:$port'
      '${jump == null ? '' : '>${jump!.signature}'}';
}

/// Thrown while resolving a `ProxyJump` chain that returns to [key].
class _JumpLoop implements Exception {
  const _JumpLoop(this.key);

  final String key;
}

/// Builds the import preview for [document].
SshConfigImportPlan buildSshConfigImportPlan(SshConfigDocument document) {
  final memo = <String, _Node>{};
  final optionsCache = <String, SshConfigResolvedOptions>{};
  SshConfigResolvedOptions optionsFor(String name) =>
      optionsCache[name.toLowerCase()] ??= document.resolve(name);

  // Results never depend on how deep the caller is, so they can be cached.
  // Hosts inside a loop are not cached: they unwind with _JumpLoop and are
  // resolved again on their own.
  _Node resolve(
    String name, {
    required List<String> stack,
    String? user,
    int? port,
    List<SshConfigJumpHop> via = const [],
    String? label,
  }) {
    final key = [
      name.toLowerCase(),
      user ?? '',
      port?.toString() ?? '',
      via.map((hop) => hop.display).join(','),
    ].join('|');
    final cached = memo[key];
    if (cached != null) return cached;
    if (stack.contains(key)) throw _JumpLoop(key);

    final options = optionsFor(name);
    final warnings = <String>[];
    final hostname = _expandHostName(options.hostName, name, warnings);

    _Node? jump;
    String? problem;
    List<SshConfigJumpHop>? hops;
    if (via.isNotEmpty) {
      hops = via;
    } else if (options.proxyJump case final proxyJump?
        when proxyJump.isNotEmpty) {
      hops = proxyJump;
    } else if (options.proxyCommandLine case final line?) {
      warnings.add(
        'ProxyCommand on line $line was skipped, so this host connects '
        'directly. Add a jump host if it needs one.',
      );
    }
    if (hops != null) {
      final last = hops.last;
      try {
        jump = resolve(
          last.host,
          stack: [...stack, key],
          user: last.user,
          port: last.port,
          via: hops.sublist(0, hops.length - 1),
          label: hops.length > 1
              ? '${last.display} (via ${hops[hops.length - 2].display})'
              : last.display,
        );
      } on _JumpLoop catch (loop) {
        if (loop.key != key) rethrow;
        problem =
            'its ProxyJump chain through ${last.display} loops back to '
            'it.';
      }
    }

    final node = _Node(
      name: name,
      label: label ?? name,
      hostname: hostname,
      port: port ?? options.port ?? 22,
      username: user ?? options.user,
      jump: jump,
      warnings: warnings,
      identityFiles: options.identityFiles,
      problem:
          problem ??
          (jump != null && jump.chainLength + 1 > sshConfigMaxJumpDepth
              ? 'its ProxyJump chain has ${jump.chainLength + 1} hops, and '
                    'MonkeySSH follows at most $sshConfigMaxJumpDepth.'
              : null),
    );
    memo[key] = node;
    return node;
  }

  List<String> matchWarnings(String name, String hostname) {
    final lines = [
      for (final block in document.skippedMatchBlocks)
        if (block.mayApplyTo(name, hostname)) block.lineNumber,
    ];
    if (lines.isEmpty) return const [];
    final where = lines.length == 1
        ? 'The skipped Match block on line ${lines.single}'
        : 'Skipped Match blocks on lines ${lines.join(', ')}';
    return ['$where may change this host’s settings.'];
  }

  final entries = <SshConfigImportEntry>[];
  final entryIdsBySignature = <String, String>{};
  final entryIndexById = <String, int>{};
  var hopCount = 0;

  String entryIdForJump(_Node node) {
    final existing = entryIdsBySignature[node.signature];
    if (existing != null) return existing;
    final jumpId = node.jump == null ? null : entryIdForJump(node.jump!);
    final id = 'jump:${hopCount++}';
    entryIdsBySignature[node.signature] = id;
    entryIndexById[id] = entries.length;
    entries.add(
      SshConfigImportEntry(
        id: id,
        label: node.label,
        aliases: const [],
        hostname: node.hostname,
        port: node.port,
        username: node.username,
        jumpEntryId: jumpId,
        forwards: const [],
        identityFiles: node.identityFiles,
        warnings: List.unmodifiable([
          ...node.warnings,
          ...matchWarnings(node.name, node.hostname),
        ]),
        isJumpOnly: true,
        unsupportedReason: node.unsupportedReason,
      ),
    );
    return id;
  }

  // Resolve every alias first so a jump hop that equals an alias reuses it.
  final aliasNodes = <(String, _Node, SshConfigResolvedOptions)>[];
  for (final alias in document.concreteAliases) {
    final node = resolve(alias, stack: const []);
    aliasNodes.add((alias, node, optionsFor(alias)));
  }

  final aliasEntryIds = <String>[];
  for (final (alias, node, options) in aliasNodes) {
    final forwards = [...options.localForwards, ...options.remoteForwards]
      ..sort((a, b) => a.lineNumber.compareTo(b.lineNumber));
    final existingId = entryIdsBySignature[node.signature];
    final existingIndex = existingId == null
        ? null
        : entryIndexById[existingId];
    final existing = existingIndex == null ? null : entries[existingIndex];
    if (existing != null &&
        !existing.isJumpOnly &&
        listEquals(existing.forwards, forwards) &&
        listEquals(existing.identityFiles, options.identityFiles)) {
      // `Host web web.example.com` style duplicates become one host.
      entries[existingIndex!] = SshConfigImportEntry(
        id: existing.id,
        label: existing.label,
        aliases: List.unmodifiable([...existing.aliases, alias]),
        hostname: existing.hostname,
        port: existing.port,
        username: existing.username,
        jumpEntryId: existing.jumpEntryId,
        forwards: existing.forwards,
        identityFiles: existing.identityFiles,
        warnings: existing.warnings,
        isJumpOnly: false,
        unsupportedReason: existing.unsupportedReason,
      );
      continue;
    }
    final id = 'host:${alias.toLowerCase()}';
    entryIdsBySignature.putIfAbsent(node.signature, () => id);
    entryIndexById[id] = entries.length;
    aliasEntryIds.add(id);
    entries.add(
      SshConfigImportEntry(
        id: id,
        label: alias,
        aliases: List.unmodifiable([alias]),
        hostname: node.hostname,
        port: node.port,
        username: node.username,
        forwards: List.unmodifiable(forwards),
        identityFiles: options.identityFiles,
        warnings: List.unmodifiable([
          ...node.warnings,
          ...matchWarnings(alias, node.hostname),
          if (_hasToken(node.username))
            'User contains % tokens, which aren’t expanded.',
          for (final forward in forwards)
            if (sshConfigForwardIsExposed(forward))
              _exposedForwardWarning(forward),
        ]),
        isJumpOnly: false,
        unsupportedReason: node.unsupportedReason,
      ),
    );
  }

  // Link jumps after every alias is registered.
  final aliasNodeById = {
    for (final (alias, node, _) in aliasNodes)
      'host:${alias.toLowerCase()}': node,
  };
  for (final id in aliasEntryIds) {
    final node = aliasNodeById[id]!;
    final jump = node.jump;
    if (jump == null) continue;
    final jumpId = entryIdForJump(jump);
    final index = entryIndexById[id]!;
    final entry = entries[index];
    entries[index] = SshConfigImportEntry(
      id: entry.id,
      label: entry.label,
      aliases: entry.aliases,
      hostname: entry.hostname,
      port: entry.port,
      username: entry.username,
      jumpEntryId: jumpId,
      forwards: entry.forwards,
      identityFiles: entry.identityFiles,
      warnings: entry.warnings,
      isJumpOnly: false,
      unsupportedReason: entry.unsupportedReason,
    );
  }

  // Concrete aliases first in file order, then jump-only hosts.
  final ordered = [
    ...entries.where((entry) => !entry.isJumpOnly),
    ...entries.where((entry) => entry.isJumpOnly),
  ];

  return SshConfigImportPlan(
    entries: List.unmodifiable(ordered),
    skipped: document.skipped,
    defaultPatterns: List.unmodifiable([
      for (final block in document.defaultBlocks)
        if (block.directives.isNotEmpty && block.patterns.isEmpty)
          '*'
        else if (block.directives.isNotEmpty)
          block.patterns.join(' '),
    ]),
  );
}

bool _hasToken(String? value) => value != null && value.contains('%');

/// The listen address MonkeySSH saves for [forward].
///
/// OpenSSH binds to loopback by default; an empty address or `*` means every
/// interface.
String sshConfigForwardBindHost(SshConfigForward forward) =>
    switch (forward.bindHost) {
      null =>
        forward.type == SshConfigForwardType.local ? '127.0.0.1' : 'localhost',
      '' || '*' => '0.0.0.0',
      final String host => host,
    };

/// Whether [forward] listens on more than loopback.
bool sshConfigForwardIsExposed(SshConfigForward forward) =>
    !isPortForwardLoopbackHost(sshConfigForwardBindHost(forward));

/// Whether an imported [forward] starts when the host connects.
///
/// Only local forwards bound to loopback do. A remote forward lets the
/// server open connections to the phone's side, so it starts manually.
bool sshConfigForwardAutoStarts(SshConfigForward forward) =>
    forward.type == SshConfigForwardType.local &&
    !sshConfigForwardIsExposed(forward);

String _exposedForwardWarning(SshConfigForward forward) {
  final keyword = forward.type == SshConfigForwardType.local
      ? 'LocalForward'
      : 'RemoteForward';
  return '$keyword on line ${forward.lineNumber} listens on '
      '${sshConfigForwardBindHost(forward)}, not only loopback, so it won’t '
      'start automatically.';
}

String _expandHostName(String? hostName, String name, List<String> warnings) {
  if (hostName == null) return name;
  if (!hostName.contains('%')) return hostName;
  final buffer = StringBuffer();
  var unsupported = false;
  for (var i = 0; i < hostName.length; i++) {
    final char = hostName[i];
    if (char != '%' || i + 1 >= hostName.length) {
      buffer.write(char);
      continue;
    }
    final token = hostName[++i];
    switch (token) {
      case 'h':
        buffer.write(name);
      case '%':
        buffer.write('%');
      default:
        unsupported = true;
        buffer.write('%$token');
    }
  }
  if (unsupported) {
    warnings.add(
      'HostName uses % tokens other than %h, which aren’t expanded.',
    );
  }
  return buffer.toString();
}

const _preferredGeneratedPortProxySlugLength = 12;
const _maximumDnsLabelLength = 63;
const _savedForwardProxyNamePrefix = 'monkeyssh-';

/// Error raised when a user-defined proxy name is already assigned.
class PortProxyNameConflictException extends FormatException {
  /// Creates a conflict for [proxyName].
  PortProxyNameConflictException(this.proxyName)
    : super('Proxy domain "$proxyName.localhost" is already in use');

  /// Conflicting proxy name without the `.localhost` suffix.
  final String proxyName;
}

/// Normalizes a stored custom proxy name without its `.localhost` suffix.
String? normalizeOptionalStoredPortProxyName(String? value) {
  final normalized = value?.trim().toLowerCase() ?? '';
  if (normalized.isEmpty) {
    return null;
  }
  return normalized.endsWith('.localhost')
      ? normalized.substring(0, normalized.length - '.localhost'.length)
      : normalized;
}

/// Builds the complete normalized base used by generated proxy aliases.
String normalizedPortProxySlug(String hostLabel) {
  var base = hostLabel
      .trim()
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.isEmpty) {
    base = 'host';
  }
  if (base.startsWith(_savedForwardProxyNamePrefix)) {
    base = 'host-$base';
  }
  return base;
}

/// Whether [proxyName] belongs to the saved-forward browser namespace.
bool isReservedSavedForwardProxyName(String proxyName) =>
    proxyName.startsWith(_savedForwardProxyNamePrefix);

/// Builds the short readable default used by generated proxy aliases.
String generatedPortProxySlug(String hostLabel) => _portProxySlugPrefix(
  normalizedPortProxySlug(hostLabel),
  _preferredGeneratedPortProxySlugLength,
);

/// Resolves collision-free generated names for a set of saved hosts.
///
/// Different normalized names extend beyond the preferred short prefix only as
/// far as needed. Numeric IDs are reserved for true duplicate normalized names
/// or the rare case where names remain indistinguishable at the DNS limit.
Map<int, String> resolveGeneratedPortProxyNames(
  Iterable<({int id, String label})> hosts, {
  Iterable<String> reservedNames = const [],
}) {
  final reservedNameSet = reservedNames.toSet();
  final normalizedById = <int, String>{
    for (final host in hosts) host.id: normalizedPortProxySlug(host.label),
  };
  final normalizedCounts = <String, int>{};
  for (final normalized in normalizedById.values) {
    normalizedCounts.update(
      normalized,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  final resolved = <int, String>{};
  final usedNames = {...reservedNameSet};
  final prefixLengths = <int, int>{};
  final normalizedEntries = normalizedById.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  for (final entry in normalizedEntries) {
    if (normalizedCounts[entry.value]! > 1) {
      final name = _uniquePortProxySlugWithHostId(
        entry.value,
        entry.key,
        usedNames,
      );
      resolved[entry.key] = name;
      usedNames.add(name);
    } else {
      prefixLengths[entry.key] = entry.value.length.clamp(
        1,
        _preferredGeneratedPortProxySlugLength,
      );
    }
  }

  while (prefixLengths.isNotEmpty) {
    final candidates = <int, String>{
      for (final entry in prefixLengths.entries)
        entry.key: _portProxySlugPrefix(
          normalizedById[entry.key]!,
          entry.value,
        ),
    };
    final candidateCounts = <String, int>{};
    for (final name in [
      ...reservedNameSet,
      ...resolved.values,
      ...candidates.values,
    ]) {
      candidateCounts.update(name, (count) => count + 1, ifAbsent: () => 1);
    }

    // Fallbacks must avoid every name still in play this pass, not only the
    // names assigned so far, or one could take another candidate's name.
    final blockedNames = {...usedNames, ...candidates.values};
    final completedIds = <int>[];
    for (final entry in candidates.entries) {
      if (candidateCounts[entry.value] == 1 &&
          !usedNames.contains(entry.value)) {
        resolved[entry.key] = entry.value;
        usedNames.add(entry.value);
        completedIds.add(entry.key);
        continue;
      }

      final normalized = normalizedById[entry.key]!;
      final nextLength = _nextDistinctPrefixLength(
        normalized,
        currentLength: prefixLengths[entry.key]!,
        currentPrefix: entry.value,
      );
      if (nextLength == null) {
        final name = _uniquePortProxySlugWithHostId(
          entry.value,
          entry.key,
          blockedNames,
        );
        resolved[entry.key] = name;
        usedNames.add(name);
        blockedNames.add(name);
        completedIds.add(entry.key);
      } else {
        prefixLengths[entry.key] = nextLength;
      }
    }
    for (final id in completedIds) {
      prefixLengths.remove(id);
    }
  }

  return Map.unmodifiable(resolved);
}

int? _nextDistinctPrefixLength(
  String normalized, {
  required int currentLength,
  required String currentPrefix,
}) {
  final maximumLength = normalized.length.clamp(1, _maximumDnsLabelLength);
  for (var length = currentLength + 1; length <= maximumLength; length++) {
    if (_portProxySlugPrefix(normalized, length) != currentPrefix) {
      return length;
    }
  }
  return null;
}

String _uniquePortProxySlugWithHostId(
  String slug,
  int hostId,
  Set<String> usedNames,
) {
  var attempt = 0;
  while (true) {
    final suffix = switch (attempt) {
      0 => '-$hostId',
      1 => '-host-$hostId',
      _ => '-host-$hostId-$attempt',
    };
    final candidate = _portProxySlugWithSuffix(slug, suffix);
    if (!usedNames.contains(candidate)) {
      return candidate;
    }
    attempt++;
  }
}

String _portProxySlugWithSuffix(String slug, String suffix) {
  final maximumBaseLength = _maximumDnsLabelLength - suffix.length;
  return '${_portProxySlugPrefix(slug, maximumBaseLength)}$suffix';
}

String _portProxySlugPrefix(String normalized, int maximumLength) {
  if (normalized.length <= maximumLength) {
    return normalized;
  }
  return normalized
      .substring(0, maximumLength)
      .replaceFirst(RegExp(r'-+$'), '');
}

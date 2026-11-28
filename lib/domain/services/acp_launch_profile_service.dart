import 'package:flutter/foundation.dart';

import '../models/acp_provider.dart';
import 'shell_quoting.dart';
import 'windows_remote_powershell.dart';

const _profileMarker = '__MONKEYSSH_ACP_PROFILE__';

/// One selectable isolated profile exposed by an ACP provider.
@immutable
class AcpLaunchProfile {
  /// Creates a launch profile.
  const AcpLaunchProfile({
    required this.argument,
    required this.label,
    this.isActive = false,
    this.showInTitle = false,
  });

  /// Exact value passed to the provider's profile option, or `null` for the
  /// provider's base/default invocation.
  final String? argument;

  /// Human-readable profile name.
  final String label;

  /// Whether the provider reports this as its currently active profile.
  final bool isActive;

  /// Whether this choice came from a list containing multiple profiles.
  final bool showInTitle;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpLaunchProfile &&
          argument == other.argument &&
          label == other.label &&
          isActive == other.isActive &&
          showInTitle == other.showInTitle;

  @override
  int get hashCode => Object.hash(argument, label, isActive, showInTitle);
}

/// Builds a bounded, read-only remote command that enumerates launch profiles.
String buildAcpLaunchProfileDiscoveryCommand({
  required AcpLaunchProfileSupport support,
  required bool isWindows,
}) => switch (support.discoveryKind) {
  AcpLaunchProfileDiscoveryKind.nestedProfileDirectories =>
    isWindows
        ? _buildWindowsNestedProfilesCommand(support)
        : _buildPosixNestedProfilesCommand(support),
  AcpLaunchProfileDiscoveryKind.homeDirectoryPrefix =>
    isWindows
        ? _buildWindowsHomePrefixCommand(support)
        : _buildPosixHomePrefixCommand(support),
};

/// Parses profile discovery output, rejecting malformed or unsafe names.
List<AcpLaunchProfile> parseAcpLaunchProfiles(
  String output,
  AcpLaunchProfileSupport support,
) {
  final profiles = <String?, AcpLaunchProfile>{};

  void add(String? argument, {required bool active}) {
    if (argument != null && !isValidAcpLaunchProfileName(argument)) return;
    final existing = profiles[argument];
    final label = argument == null || argument == support.defaultProfileArgument
        ? 'Default'
        : argument;
    profiles[argument] = AcpLaunchProfile(
      argument: argument,
      label: label,
      isActive: active || (existing?.isActive ?? false),
    );
  }

  for (final rawLine in output.split('\n')) {
    final line = rawLine.replaceAll('\r', '');
    final parts = line.split('\u001f');
    if (parts.length != 3 || parts[0] != _profileMarker) continue;
    final argument = parts[1].isEmpty ? null : parts[1];
    add(argument, active: parts[2] == '1');
  }

  final defaultArgument = switch (support.discoveryKind) {
    AcpLaunchProfileDiscoveryKind.nestedProfileDirectories =>
      support.defaultProfileArgument,
    AcpLaunchProfileDiscoveryKind.homeDirectoryPrefix => null,
  };
  if (!profiles.containsKey(defaultArgument)) {
    add(defaultArgument, active: false);
  }

  final result = profiles.values.toList(growable: false)
    ..sort((a, b) {
      final aIsDefault = a.argument == defaultArgument;
      final bIsDefault = b.argument == defaultArgument;
      if (aIsDefault && bIsDefault) return 0;
      if (aIsDefault) return -1;
      if (bIsDefault) return 1;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
  return List.unmodifiable(result);
}

typedef _NestedProfileMetadata = ({
  String environment,
  String homeDirectory,
  String profilesDirectory,
  String activeFile,
  String defaultArgument,
});

_NestedProfileMetadata _requireNestedProfileMetadata(
  AcpLaunchProfileSupport support,
) {
  final environment = support.profileHomeEnvironmentVariable;
  final homeDirectory = support.defaultProfileHomeDirectory;
  final profilesDirectory = support.nestedProfilesDirectory;
  final activeFile = support.activeProfileFile;
  final defaultArgument = support.defaultProfileArgument;
  if (environment == null ||
      homeDirectory == null ||
      profilesDirectory == null ||
      activeFile == null ||
      defaultArgument == null) {
    throw const FormatException('Nested profile metadata is incomplete');
  }
  return (
    environment: environment,
    homeDirectory: homeDirectory,
    profilesDirectory: profilesDirectory,
    activeFile: activeFile,
    defaultArgument: defaultArgument,
  );
}

String _buildPosixNestedProfilesCommand(AcpLaunchProfileSupport support) {
  final metadata = _requireNestedProfileMetadata(support);
  final quotedMarker = shellEscapePosixArg(_profileMarker);
  final quotedEnvironment = shellEscapePosixArg(metadata.environment);
  final quotedHomeDirectory = shellEscapePosixArg(metadata.homeDirectory);
  final quotedProfilesDirectory = shellEscapePosixArg(
    metadata.profilesDirectory,
  );
  final quotedActiveFile = shellEscapePosixArg(metadata.activeFile);
  final quotedDefault = shellEscapePosixArg(metadata.defaultArgument);
  return '__fl_profile_root=\$(printenv $quotedEnvironment 2>/dev/null || :); '
      r'[ -n "$__fl_profile_root" ] || '
      '__fl_profile_root="\$HOME"/$quotedHomeDirectory; '
      r'__fl_profile_root=${__fl_profile_root%/}; '
      r'__fl_profile_parent=${__fl_profile_root%/*}; '
      'if [ "\${__fl_profile_parent##*/}" = $quotedProfilesDirectory ]; then '
      r'__fl_profile_root=${__fl_profile_parent%/*}; fi; '
      '__fl_profile_active=\$(cat "\$__fl_profile_root"/$quotedActiveFile '
      '2>/dev/null || :); '
      '[ -n "\$__fl_profile_active" ] || __fl_profile_active=$quotedDefault; '
      '__fl_profile_flag=0; '
      '[ "\$__fl_profile_active" = $quotedDefault ] && __fl_profile_flag=1; '
      'printf \'%s\\037%s\\037%s\\n\' $quotedMarker $quotedDefault '
      r'"$__fl_profile_flag"; '
      'for __fl_profile_dir in '
      '"\$__fl_profile_root"/$quotedProfilesDirectory/*; do '
      r'[ -d "$__fl_profile_dir" ] || continue; '
      r'__fl_profile_name=${__fl_profile_dir##*/}; '
      '__fl_profile_flag=0; '
      r'[ "$__fl_profile_name" = "$__fl_profile_active" ] && '
      '__fl_profile_flag=1; '
      'printf \'%s\\037%s\\037%s\\n\' $quotedMarker '
      r'"$__fl_profile_name" "$__fl_profile_flag"; done';
}

String _buildPosixHomePrefixCommand(AcpLaunchProfileSupport support) {
  final prefix = support.homeDirectoryPrefix;
  if (prefix == null || prefix.isEmpty) {
    throw const FormatException('Profile directory prefix is required');
  }
  final quotedPrefix = shellEscapePosixArg(prefix);
  final quotedMarker = shellEscapePosixArg(_profileMarker);
  return 'for __fl_profile_dir in "\$HOME"/$quotedPrefix*; do '
      r'[ -d "$__fl_profile_dir" ] || continue; '
      r'__fl_profile_base=${__fl_profile_dir##*/}; '
      '__fl_profile_name=\${__fl_profile_base#${_posixParameterPrefix(prefix)}}; '
      r'[ -n "$__fl_profile_name" ] || continue; '
      'printf \'%s\\037%s\\0370\\n\' $quotedMarker '
      r'"$__fl_profile_name"; done';
}

String _buildWindowsNestedProfilesCommand(AcpLaunchProfileSupport support) {
  final metadata = _requireNestedProfileMetadata(support);
  final env = powerShellSingleQuote(metadata.environment);
  final home = powerShellSingleQuote(metadata.homeDirectory);
  final nested = powerShellSingleQuote(metadata.profilesDirectory);
  final active = powerShellSingleQuote(metadata.activeFile);
  final defaultValue = powerShellSingleQuote(metadata.defaultArgument);
  final marker = powerShellSingleQuote(_profileMarker);
  final body =
      '\$__flRoot=[Environment]::GetEnvironmentVariable($env); '
      r'if ([string]::IsNullOrWhiteSpace($__flRoot)) { '
      '\$__flRoot=Join-Path \$HOME $home }; '
      r'$__flRoot=$__flRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, '
      '[IO.Path]::AltDirectorySeparatorChar); '
      r'$__flParent=Split-Path -Parent $__flRoot; '
      'if ((Split-Path -Leaf \$__flParent) -eq $nested) { '
      r'$__flRoot=Split-Path -Parent $__flParent }; '
      '\$__flActive=(Get-Content -LiteralPath (Join-Path \$__flRoot $active) '
      '-ErrorAction SilentlyContinue | Select-Object -First 1); '
      'if ([string]::IsNullOrWhiteSpace(\$__flActive)) { \$__flActive=$defaultValue }; '
      "\$__flFlag=if (\$__flActive -eq $defaultValue) {'1'} else {'0'}; "
      '[void]\$__flOut.Append($marker + [char]31 + $defaultValue + '
      r'[char]31 + $__flFlag + "`n"); '
      '\$__flProfiles=Join-Path \$__flRoot $nested; '
      r'Get-ChildItem -LiteralPath $__flProfiles -Directory '
      '-ErrorAction SilentlyContinue | ForEach-Object { '
      r"$__flFlag=if ($_.Name -eq $__flActive) {'1'} else {'0'}; "
      '[void]\$__flOut.Append($marker + [char]31 + \$_.Name + '
      r'[char]31 + $__flFlag + "`n") };';
  return buildWindowsPowerShellCommand(powerShellUtf8OutputScript(body));
}

String _buildWindowsHomePrefixCommand(AcpLaunchProfileSupport support) {
  final prefix = support.homeDirectoryPrefix;
  if (prefix == null || prefix.isEmpty) {
    throw const FormatException('Profile directory prefix is required');
  }
  final quotedPrefix = powerShellSingleQuote(prefix);
  final quotedMarker = powerShellSingleQuote(_profileMarker);
  final body =
      r'Get-ChildItem -LiteralPath $HOME -Directory -ErrorAction SilentlyContinue | '
      'Where-Object { \$_.Name.StartsWith($quotedPrefix, [System.StringComparison]::Ordinal) } | '
      'ForEach-Object { '
      '\$__flName=\$_.Name.Substring($quotedPrefix.Length); '
      r'if ($__flName) { [void]$__flOut.Append('
      '$quotedMarker + [char]31 + \$__flName + [char]31 + "0`n") } };';
  return buildWindowsPowerShellCommand(powerShellUtf8OutputScript(body));
}

String _posixParameterPrefix(String value) =>
    value.replaceAll(RegExp(r'([][\\*?])'), r'\\$1');

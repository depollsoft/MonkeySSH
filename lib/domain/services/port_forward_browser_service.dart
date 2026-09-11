import 'package:flutter/foundation.dart';

import '../../data/database/database.dart';
import '../models/port_proxy_name.dart';

/// Returns whether the embedded WebView browser is available on [platform].
bool isPortForwardBrowserSupported({TargetPlatform? platform}) {
  final targetPlatform = platform ?? defaultTargetPlatform;
  return targetPlatform == TargetPlatform.android ||
      targetPlatform == TargetPlatform.iOS ||
      targetPlatform == TargetPlatform.macOS;
}

/// Returns whether [portForward] can be opened in the embedded browser.
bool canOpenPortForwardInBrowser(PortForward portForward) =>
    portForward.forwardType == 'local' &&
    isPortForwardBrowserHost(portForward.localHost) &&
    _isValidPort(portForward.localPort);

/// Returns whether [uri] is a valid initial embedded-browser URL.
bool isPortForwardBrowserEntryUri(Uri uri) {
  final port = portForwardBrowserUriPort(uri);
  return _isValidPort(port) &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      isPortForwardBrowserHost(uri.host);
}

/// Returns the effective network port for [uri], including scheme defaults.
int portForwardBrowserUriPort(Uri uri) {
  if (uri.hasPort) {
    return uri.port;
  }
  return switch (uri.scheme) {
    'http' => 80,
    'https' => 443,
    _ => 0,
  };
}

/// Builds the local URL used to browse a local bind address and port.
Uri buildPortForwardBrowserUriForBind({
  required String localHost,
  required int localPort,
}) => Uri(
  scheme: 'http',
  host: _browserHostForBindAddress(localHost),
  port: localPort,
);

/// Returns a stable localhost origin dedicated to [portForwardId].
///
/// Distinct hosts keep WebView cookies scoped to one forwarded service.
String portForwardBrowserHostForPortForwardId(int portForwardId) =>
    'monkeyssh-${portForwardId.abs().toRadixString(36)}.localhost';

/// Returns a DNS-independent loopback host dedicated to one saved host.
String portForwardBrowserFallbackHostForHostId(int hostId) {
  const usableLoopbackAddressCount = 0x00fffffd;
  final addressValue = (hostId.abs() % usableLoopbackAddressCount) + 2;
  return '127.${(addressValue >> 16) & 0xff}.'
      '${(addressValue >> 8) & 0xff}.${addressValue & 0xff}';
}

/// Normalizes a user-entered proxy name to the prefix stored before
/// `.localhost`.
String normalizePortProxyName(String value) =>
    normalizeOptionalStoredPortProxyName(value) ?? '';

/// Normalizes an optional proxy name, returning null for an empty value.
String? normalizeOptionalPortProxyName(String? value) {
  if (value == null) {
    return null;
  }
  final normalized = normalizePortProxyName(value);
  return normalized.isEmpty ? null : normalized;
}

/// Returns a validation message when [value] is not a valid `.localhost`
/// prefix.
String? validatePortProxyName(String? value) {
  final normalized = normalizeOptionalPortProxyName(value);
  if (normalized == null) {
    return null;
  }
  if (normalized.length > 221) {
    return 'Proxy name is too long';
  }
  for (final label in normalized.split('.')) {
    if (label.isEmpty ||
        label.length > 63 ||
        !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label)) {
      return 'Use letters, numbers, hyphens, or dots';
    }
  }
  return null;
}

/// Builds a stable generated proxy prefix from a host label and database ID.
String generatedPortProxyName(
  String hostLabel, {
  int? hostId,
  bool includeHostId = false,
}) {
  final suffix = includeHostId && hostId != null ? '-$hostId' : '';
  return '${generatedPortProxySlug(hostLabel)}$suffix';
}

/// Rewrites a loopback [uri] for one forwarded service's browser-only relay.
///
/// Returns null when [uri] does not target [sourceUri].
Uri? rewriteUriForPortForwardBrowser(
  Uri uri, {
  required Uri sourceUri,
  required Uri browserUri,
}) {
  if ((uri.scheme != 'http' && uri.scheme != 'https') ||
      !isPortForwardBrowserHost(uri.host) ||
      !_samePortForwardBrowserSourceHost(uri.host, sourceUri.host) ||
      portForwardBrowserUriPort(uri) != portForwardBrowserUriPort(sourceUri)) {
    return null;
  }
  return uri.replace(
    host: browserUri.host,
    port: portForwardBrowserUriPort(browserUri),
  );
}

/// Whether a failed friendly browser endpoint should retry through loopback.
bool shouldUsePortForwardBrowserFallback({
  required Uri browserUri,
  required Uri? failedUri,
  required bool? isForMainFrame,
  required bool alreadyTried,
}) =>
    (isForMainFrame ?? false) &&
    !alreadyTried &&
    (failedUri == null ||
        (failedUri.host.toLowerCase() == browserUri.host.toLowerCase() &&
            portForwardBrowserUriPort(failedUri) ==
                portForwardBrowserUriPort(browserUri)));

/// Whether an active loopback fallback request must bypass friendly rewriting.
bool shouldLoadPortForwardBrowserFallbackDirectly({
  required Uri requestedUri,
  required Uri? fallbackUri,
  required bool fallbackActive,
}) {
  if (!fallbackActive || fallbackUri == null) {
    return false;
  }
  final normalizedRequestedUri = normalizePortForwardBrowserUri(requestedUri);
  final normalizedFallbackUri = normalizePortForwardBrowserUri(fallbackUri);
  return normalizedRequestedUri.host.toLowerCase() ==
          normalizedFallbackUri.host.toLowerCase() &&
      portForwardBrowserUriPort(normalizedRequestedUri) ==
          portForwardBrowserUriPort(normalizedFallbackUri);
}

/// Replaces only a failed friendly endpoint with its loopback fallback.
Uri buildPortForwardBrowserFallbackRequestUri({
  required Uri browserUri,
  required Uri fallbackUri,
  Uri? requestedUri,
}) {
  final candidate =
      requestedUri != null &&
          requestedUri.host.toLowerCase() == browserUri.host.toLowerCase() &&
          portForwardBrowserUriPort(requestedUri) ==
              portForwardBrowserUriPort(browserUri)
      ? requestedUri
      : browserUri;
  return candidate.replace(
    host: fallbackUri.host,
    port: portForwardBrowserUriPort(fallbackUri),
  );
}

/// Returns whether [uri] should be handed to another installed application.
bool shouldLaunchPortForwardBrowserUriExternally(Uri uri) =>
    uri.scheme.isNotEmpty &&
    !const {
      'about',
      'blob',
      'content',
      'data',
      'file',
      'http',
      'https',
      'javascript',
    }.contains(uri.scheme.toLowerCase());

/// Returns a safe origin label for browser permission and dialog prompts.
String portForwardBrowserDisplayOrigin(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (uri.host.isNotEmpty &&
      const {'http', 'https', 'ws', 'wss'}.contains(scheme)) {
    return uri.origin;
  }
  if (uri.authority.isNotEmpty) {
    return uri.authority;
  }
  return uri.scheme.isEmpty ? 'This page' : uri.scheme;
}

/// Normalizes wildcard and IPv6 loopback hosts for embedded browser loading.
Uri normalizePortForwardBrowserUri(Uri uri) =>
    uri.replace(host: _browserHostForBindAddress(uri.host));

/// Returns whether [host] is a browser-safe local bind address.
bool isPortForwardBrowserHost(String host) {
  final normalized = _withoutAddressZone(host);
  return normalized.isEmpty ||
      normalized == 'localhost' ||
      normalized == '0.0.0.0' ||
      normalized == '::' ||
      normalized == '::1' ||
      normalized == '[::]' ||
      normalized == '[::1]' ||
      normalized.endsWith('.localhost') ||
      _isLoopbackIpv4Address(normalized);
}

/// Returns whether [host] is an explicit loopback bind address.
bool isPortForwardLoopbackHost(String host) {
  final normalized = _withoutAddressZone(host);
  return normalized == 'localhost' ||
      normalized == '::1' ||
      normalized == '[::1]' ||
      normalized.endsWith('.localhost') ||
      _isLoopbackIpv4Address(normalized);
}

String _browserHostForBindAddress(String localHost) {
  final host = _withoutAddressZone(localHost);
  if (host.isEmpty || host == '0.0.0.0') {
    return '127.0.0.1';
  }
  if (_isLoopbackIpv4Address(host)) {
    return host;
  }
  if (host == '::' || host == '[::]' || host == '::1' || host == '[::1]') {
    return 'localhost';
  }
  return host;
}

String _withoutAddressZone(String host) {
  final normalized = host
      .trim()
      .toLowerCase()
      .replaceFirst(RegExp(r'^\['), '')
      .replaceFirst(RegExp(r'\]$'), '');
  final zoneIndex = normalized.indexOf('%');
  return zoneIndex < 0 ? normalized : normalized.substring(0, zoneIndex);
}

bool _samePortForwardBrowserSourceHost(String left, String right) {
  final normalizedLeft = _browserHostForBindAddress(left);
  final normalizedRight = _browserHostForBindAddress(right);
  if (normalizedLeft == normalizedRight) {
    return true;
  }
  return _isDefaultLoopbackBrowserHost(normalizedLeft) &&
      _isDefaultLoopbackBrowserHost(normalizedRight);
}

bool _isDefaultLoopbackBrowserHost(String host) =>
    host == '127.0.0.1' || host == 'localhost';

bool _isLoopbackIpv4Address(String host) {
  final parts = host.split('.');
  if (parts.length != 4 || parts.first != '127') {
    return false;
  }

  return parts.skip(1).every((part) {
    final value = int.tryParse(part);
    return value != null && value >= 0 && value <= 255;
  });
}

bool _isValidPort(int port) => port >= 1 && port <= 65535;

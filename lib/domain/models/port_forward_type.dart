/// Stored `PortForward.forwardType` for a local forward (`ssh -L`).
const localPortForwardType = 'local';

/// Stored `PortForward.forwardType` for a remote forward (`ssh -R`).
const remotePortForwardType = 'remote';

/// Stored `PortForward.forwardType` for a SOCKS5 dynamic forward (`ssh -D`).
///
/// A dynamic forward has no fixed destination: `remoteHost` is empty and
/// `remotePort` is zero. The SOCKS client names each destination, and the SSH
/// server resolves and connects to it.
const dynamicPortForwardType = 'dynamic';

/// The only address a dynamic forward listens on.
///
/// The SOCKS listener has no authentication, so it never binds beyond the
/// device's IPv4 loopback interface.
const dynamicPortForwardBindHost = '127.0.0.1';

/// Whether [forwardType] is a SOCKS5 dynamic forward.
bool isDynamicPortForwardType(String forwardType) =>
    forwardType == dynamicPortForwardType;

/// Compact label for a dynamic forward's listener, such as `127.0.0.1:1080`.
///
/// A port of zero means the system picks a free port when the forward starts.
String dynamicPortForwardListenerLabel(int localPort) =>
    '$dynamicPortForwardBindHost:${localPort > 0 ? localPort : 'auto'}';

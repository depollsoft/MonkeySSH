# HANDOFF (package ssh1)

Edits needed outside this package's files, or inside regions owned by another package.

## Done here, inside a region another package owns (please re-base on it)

- `lib/domain/services/ssh_service.dart`, `_runPortForwardOperation` (serial gate helper):
  finding 9 removed `enum _PortForwardOperationKind`. The gate's named parameter changed
  from `required _PortForwardOperationKind kind` to `bool isStop = false`, and the slot
  record from `({Future<void> done, _PortForwardOperationKind kind})` to
  `({Future<void> done, bool isStop})`. Only the signature and the one record literal were
  touched; the gate body is unchanged. `isPortForwardStarting` reads `!operation.isStop`.

## Not done here (other package owns the file/region)

- `lib/domain/services/ssh_service.dart`, `_automaticPortForwardTarget` (~host-normalisation
  region): finding 12 asks to hoist the per-call `RegExp(r'^\[')`, `RegExp(r'\]$')` and
  `RegExp(r'(^|\s)tcp6(?:\s|$)', caseSensitive: false)` allocations to top-level `final`s
  (the `^p(\d+)$` lsof pattern in `parseRemoteListeningTcpListeners` is already hoisted as
  `_lsofPidLinePattern`). Finding 8 rewrites that function anyway, so fold it in there.
- `lib/domain/services/port_forward_runtime_service.dart`, `_connectedSessionsForHost`:
  finding 12 — iterate `sshService.allSessions` instead of `sshService.sessions.values`
  (`sessions` copies the map on every read). `ActiveSessionsNotifier.getConnectionsForHost`,
  `getPreferredConnectionForHost` and `getConnectionForActiveLocalForward` already use
  `allSessions`; any mocktail `SshService` mock that stubs `sessions` for those paths must
  now stub `allSessions` too (see `ssh_service_test.dart` "reports host-key connection
  failures separately from authentication").
- `lib/domain/services/secure_transfer_service.dart` ~1514-1516 and ~1666-1668: finding 13 —
  replace `_argon2idIterations/_argon2idMemoryKiB/_argon2idLanes` with the fields of a
  single `const _defaultArgon2id = TransferArgon2idProfile();` so the import defaults cannot
  drift from the export profile. Skipped here because it is a replacement, not an additive
  edit, in a file this package does not own.

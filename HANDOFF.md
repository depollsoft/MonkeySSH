# HANDOFF (package acp3, branch refactor/sa5-acp3)

Edits needed outside the files this package owns. Everything on the owned
side is done and the tree compiles with these left as they are.

## 1. Telemetry provider categories (report_acp Part 2, finding 6)

Done here: `AcpBuiltinProvider` now carries `telemetryCategory` (snake_case,
unique, pinned by `test/domain/models/acp_provider_test.dart`).

Outside edits:

- `lib/domain/services/acp_telemetry_adapter.dart`, `_providerCategory`:
  replace the 11-branch if-chain with
  ```dart
  static String _providerCategory(String providerId) =>
      acpBuiltinProviders
          .firstWhereOrNull((provider) => provider.id == providerId)
          ?.telemetryCategory ??
      (providerId.startsWith(acpCustomProviderReservedIdPrefix)
          ? 'unknown'
          : 'custom');
  ```
  (needs `package:collection/collection.dart`).
- `lib/domain/services/telemetry_service.dart`,
  `_allowedAcpProviderCategories`: change `static const` to `static final`
  and build it as
  `{for (final p in acpBuiltinProviders) p.telemetryCategory, 'custom', 'unknown'}`.
  Why: adding a built-in provider then needs one literal, not three.

## 2. Antigravity / Muse special cases in the bridge builders (Part 2, finding 5)

Not done: `lib/domain/services/monkeymux_acp_bridge_service.dart` is not
owned by this package. Proposed edits there:

- `buildMonkeyMuxAcpProviderCommand`: emit `_antigravityTerminalProgramPreamble`
  / `_antigravityWindowsTerminalProgramPreamble` unconditionally (they only
  set `TERM_PROGRAM` when it is absent, which is harmless for every program)
  and drop the `providerId == AcpBuiltinProviderIds.antigravity` gates; update
  `test/domain/services/monkeymux_acp_bridge_service_test.dart:551-592`
  (the "other provider has no TERM_PROGRAM" assertion inverts).
- Move the Muse knowledge onto provider data: add
  `AcpExecutableProbe.executableOverrideEnvironmentVariables`
  (`{'muse': 'MUSE_CODE_EXECUTABLE'}` on `acpMuseCodeProvider`) and
  `AcpBuiltinProvider.windowsLaunchPreamble` (the current
  `_museWindowsExecutablePreamble`), then have
  `buildMonkeyMuxAcpExecutableProbeCommand` /
  `buildMonkeyMuxAcpWindowsExecutableProbeScript` take a
  `Map<String, String> overrideVariables` (built by
  `acp_connection_support.dart:_allBuiltinAcpExecutableNames` from the
  probes) and emit the `if name == X && env Y set` clause per entry instead
  of the literal `muse`. The fields were deliberately not added here because
  nothing would read them until the bridge is changed.

## 3. Custom ACP provider subsystem deletion (Part 3, finding 2)

Confirmed dead: `grep -rn "AcpCustomProviderDefinition.create\|AcpCommandApproval.approve" lib`
-> 0 production hits; nothing writes `SettingKeys.acpCustomProviders`; the
new-session sheet filters `!provider.isCustom`.

Not done: the delete cannot keep the tree compiling without editing
`lib/domain/services/acp_session_manager.dart` (forbidden for this package):
it calls `_providerService.getCustomProvider(providerId)`, reads
`custom.isCommandApproved`, passes `launch.isCustom`, and raises
`AcpSessionErrorKind.commandNotApproved` (`:1472-1500`, `:764`, `:1007`,
`:1313`, `:1785-1812`, `:1992`, `:3229`, `:3284`, `:3828`). Its test
(`acp_session_manager_test.dart:919-943`) and
`test/widget/acp_new_session_sheet_test.dart:211` construct
`AcpCustomProviderDefinition.create`.

Removal list once the session manager owner drops that branch:

- `lib/domain/models/acp_provider.dart`: `validateAcpCustomProviderId`,
  `validateAcpProviderLabel`, `validateAcpLaunchCommand` (keep the
  `AcpLaunchCommand.tryFromJson` control-character guard if still wanted),
  `computeAcpLaunchCommandFingerprint`, `AcpCommandApproval`,
  `AcpCustomProviderDefinition`, `AcpProvider.isCustom`, the four
  `acpProvider*MaxLength` constants, the `crypto` import.
- `lib/domain/services/acp_provider_service.dart`: `listCustomProviders`,
  `getCustomProvider`, `_decodeCustomProviders`; `watchAllProviders` returns
  `Stream.value(acpBuiltinProviders)` (or the provider becomes a plain
  `Provider<List<AcpProvider>>`).
- `lib/domain/models/acp_session_state.dart`: `commandNotApproved`,
  `isCustomProvider`; `lib/domain/services/acp_lifecycle_service.dart:29`
  guard; `lib/domain/services/settings_service.dart:103`
  `SettingKeys.acpCustomProviders`;
  `lib/presentation/widgets/acp_new_session_sheet.dart:710,764,882`.
- Tests: `test/domain/models/acp_provider_test.dart` groups
  `validateAcpCustomProviderId`, `validateAcpProviderLabel`,
  `computeAcpLaunchCommandFingerprint`, `AcpCommandApproval`,
  `AcpCustomProviderDefinition`; `test/domain/services/acp_provider_service_test.dart`;
  `acp_session_manager_test.dart:919-943`; `acp_lifecycle_service_test.dart:710`.

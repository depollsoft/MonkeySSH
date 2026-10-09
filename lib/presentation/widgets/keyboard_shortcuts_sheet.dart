import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../shortcuts/app_shortcuts.dart';

/// One visible row in the shortcuts list. The numbered window shortcuts
/// share a row.
@immutable
class KeyboardShortcutListEntry {
  /// Creates a list row.
  const KeyboardShortcutListEntry({
    required this.group,
    required this.label,
    required this.chord,
    required this.semanticChord,
  });

  /// Section the row belongs to.
  final AppShortcutGroup group;

  /// What the shortcut does.
  final String label;

  /// Chord as shown on the keycap.
  final String chord;

  /// Chord as read by screen readers.
  final String semanticChord;
}

/// Rows for the shortcuts list on [platform], in display order.
List<KeyboardShortcutListEntry> keyboardShortcutListEntries(
  TargetPlatform platform,
) {
  final shortcuts = appShortcutsFor(platform);
  final numbered = [
    for (final shortcut in shortcuts)
      if (shortcut.action == AppShortcutAction.goToWindow) shortcut,
  ];
  final entries = <KeyboardShortcutListEntry>[];
  var numberedAdded = false;
  for (final shortcut in shortcuts) {
    if (shortcut.action != AppShortcutAction.goToWindow ||
        numbered.length < 2) {
      entries.add(
        KeyboardShortcutListEntry(
          group: shortcut.group,
          label: shortcut.label,
          chord: describeAppShortcutChord(shortcut, platform),
          semanticChord: describeAppShortcutChordForSemantics(
            shortcut,
            platform,
          ),
        ),
      );
      continue;
    }
    if (numberedAdded) {
      continue;
    }
    numberedAdded = true;
    final first = numbered.first;
    final last = numbered.last;
    entries.add(
      KeyboardShortcutListEntry(
        group: first.group,
        label:
            'Go to window numbered ${first.windowNumber}–${last.windowNumber}',
        chord: '${describeAppShortcutChord(first, platform)}–${last.key.glyph}',
        semanticChord:
            '${describeAppShortcutChordForSemantics(first, platform)} '
            'to ${last.key.spokenName}',
      ),
    );
  }
  return entries;
}

/// Short statement of which chords stay with the terminal on [platform].
String keyboardShortcutPrecedenceNote(TargetPlatform platform) =>
    switch (appShortcutSchemeFor(platform)) {
      AppShortcutModifierScheme.command =>
        'Only these ⌘ chords belong to the app. Every other key, including '
            'other ⌘, ⌃ and ⌥ chords, goes to the terminal program.',
      AppShortcutModifierScheme.controlShift =>
        'Only these Ctrl+Shift chords belong to the app. Every other key, '
            'including other Ctrl, Alt and Meta chords, goes to the terminal '
            'program.',
      null => '',
    };

/// Opens the shortcuts list as a bottom sheet.
Future<void> showKeyboardShortcutsSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const KeyboardShortcutsSheet(),
    );

/// Bottom sheet listing the app's keyboard shortcuts.
class KeyboardShortcutsSheet extends StatefulWidget {
  /// Creates the sheet.
  const KeyboardShortcutsSheet({super.key});

  static _KeyboardShortcutsSheetState? _open;

  /// Whether a shortcuts sheet is showing.
  static bool get isOpen => _open?.mounted ?? false;

  /// Closes the showing shortcuts sheet. Returns false when none is open.
  static bool closeIfOpen() {
    final route = _open?._route;
    final navigator = route?.navigator;
    if (route == null || navigator == null || !route.isActive) {
      return false;
    }
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
    return true;
  }

  @override
  State<KeyboardShortcutsSheet> createState() => _KeyboardShortcutsSheetState();
}

class _KeyboardShortcutsSheetState extends State<KeyboardShortcutsSheet> {
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    KeyboardShortcutsSheet._open = this;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    if (identical(KeyboardShortcutsSheet._open, this)) {
      KeyboardShortcutsSheet._open = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final platform = defaultTargetPlatform;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(
            FluttyTheme.spacingMd,
            0,
            FluttyTheme.spacingMd,
            FluttyTheme.spacingMd,
          ),
          children: [
            Semantics(
              header: true,
              child: Text(
                'keyboard shortcuts',
                style: FluttyTheme.displayMono(
                  fontSize: 18,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: FluttyTheme.spacingSm),
            Text(
              keyboardShortcutPrecedenceNote(platform),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (platform == TargetPlatform.iOS) ...[
              const SizedBox(height: FluttyTheme.spacingXs),
              Text(
                'Hold ⌘ anywhere to peek at this list.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: FluttyTheme.spacingSm),
            KeyboardShortcutsList(platform: platform),
          ],
        ),
      ),
    );
  }
}

/// Grouped shortcut rows with keycaps.
class KeyboardShortcutsList extends StatelessWidget {
  /// Creates the list for [platform].
  const KeyboardShortcutsList({
    required this.platform,
    this.groups = AppShortcutGroup.values,
    this.dense = false,
    super.key,
  });

  /// Platform whose chords to show.
  final TargetPlatform platform;

  /// Sections to include, in order.
  final List<AppShortcutGroup> groups;

  /// Uses tighter rows, for the hold-⌘ peek.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final entries = keyboardShortcutListEntries(platform);
    final children = <Widget>[];
    for (final group in groups) {
      final rows = entries.where((entry) => entry.group == group).toList();
      if (rows.isEmpty) {
        continue;
      }
      children
        ..add(_GroupHeader(title: group.title, dense: dense))
        ..addAll(rows.map((entry) => _ShortcutRow(entry: entry, dense: dense)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.dense});

  final String title;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        top: dense ? FluttyTheme.spacingSm : FluttyTheme.spacingMd,
        bottom: FluttyTheme.spacingXs,
      ),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: FluttyTheme.monoStyle.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.entry, required this.dense});

  final KeyboardShortcutListEntry entry;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '${entry.label}: ${entry.semanticChord}',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: dense ? 32 : 44),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  entry.label,
                  style: dense
                      ? theme.textTheme.bodyMedium
                      : theme.textTheme.bodyLarge,
                ),
              ),
              const SizedBox(width: FluttyTheme.spacingSm),
              KeyboardShortcutKeycap(chord: entry.chord),
            ],
          ),
        ),
      ),
    );
  }
}

/// A chord drawn as a keycap.
class KeyboardShortcutKeycap extends StatelessWidget {
  /// Creates a keycap showing [chord].
  const KeyboardShortcutKeycap({required this.chord, super.key});

  /// Chord text, such as `⌘T`.
  final String chord;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          chord,
          style: FluttyTheme.monoStyle.copyWith(
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// The list shown while ⌘ is held on iPadOS.
class KeyboardShortcutsPeek extends StatelessWidget {
  /// Creates the peek panel.
  const KeyboardShortcutsPeek({super.key});

  static const double _twoColumnWidth = 560;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final platform = defaultTargetPlatform;
    final size = MediaQuery.sizeOf(context);
    final twoColumns = size.width >= _twoColumnWidth + 64;
    final width = math.min(
      twoColumns ? _twoColumnWidth : 360.0,
      size.width - FluttyTheme.spacingMd * 2,
    );
    var content = twoColumns
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: KeyboardShortcutsList(
                  platform: platform,
                  groups: const [AppShortcutGroup.windows],
                  dense: true,
                ),
              ),
              const SizedBox(width: FluttyTheme.spacingLg),
              Expanded(
                child: KeyboardShortcutsList(
                  platform: platform,
                  groups: const [
                    AppShortcutGroup.session,
                    AppShortcutGroup.help,
                  ],
                  dense: true,
                ),
              ),
            ],
          )
        : KeyboardShortcutsList(platform: platform, dense: true);
    content = SingleChildScrollView(child: content);
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: width,
            maxHeight: size.height * 0.8,
          ),
          child: Material(
            key: const ValueKey('keyboard-shortcuts-peek'),
            color: theme.colorScheme.surface,
            // Flat on dark; light themes may lift it off the content below.
            elevation: theme.brightness == Brightness.light ? 3 : 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Semantics(
              liveRegion: true,
              label: 'Keyboard shortcuts',
              child: Padding(
                padding: const EdgeInsets.all(FluttyTheme.spacingMd),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'keyboard shortcuts',
                            style: FluttyTheme.displayMono(
                              fontSize: 16,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        Text(
                          '⌘/ keeps it open',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    Flexible(child: content),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Settings row that opens the shortcuts list. Empty where the platform has
/// no app shortcuts.
class KeyboardShortcutsSettingsTile extends StatelessWidget {
  /// Creates the settings row.
  const KeyboardShortcutsSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    final platform = defaultTargetPlatform;
    final scheme = appShortcutSchemeFor(platform);
    if (scheme == null) {
      return const SizedBox.shrink();
    }
    final showChord = scheme == AppShortcutModifierScheme.command
        ? '⌘/'
        : 'Ctrl+Shift+/';
    return ListTile(
      key: const ValueKey('settings-keyboard-shortcuts'),
      leading: const Icon(Icons.keyboard_command_key),
      title: const Text('Keyboard shortcuts'),
      subtitle: Text(
        'Hardware keyboard shortcuts for windows, files and focus. '
        'Press $showChord to see them anywhere.',
      ),
      onTap: () => unawaited(showKeyboardShortcutsSheet(context)),
    );
  }
}

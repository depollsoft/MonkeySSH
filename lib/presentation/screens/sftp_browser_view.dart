import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/services/settings_service.dart';

/// Settings key holding each host's SFTP sort and hidden-file choices.
const sftpBrowserViewsSettingKey = SettingKeys.sftpBrowserViews;

/// Settings key holding each host's SFTP filter and the folder it belongs to.
const sftpBrowserFiltersSettingKey = SettingKeys.sftpBrowserFilters;

/// A filter typed into the browser for one directory.
typedef SftpBrowserFilter = ({String directory, String query});

/// What the SFTP browser sorts entries by. Folders always come first.
enum SftpSortField {
  /// File name, in byte order like `ls` in the C locale.
  name('Name'),

  /// File size. Folders keep name order.
  size('Size'),

  /// Last modified time.
  modified('Modified'),

  /// File extension, then name. Folders keep name order.
  type('Type');

  const SftpSortField(this.label);

  /// Label shown in the view options.
  final String label;
}

/// How one host's SFTP browser sorts and whether it shows hidden files.
@immutable
class SftpBrowserViewSettings {
  /// Creates view settings.
  const SftpBrowserViewSettings({
    this.sortField = SftpSortField.name,
    this.descending = false,
    this.showHidden = true,
  });

  /// Reads settings saved by [toJson], ignoring unknown or malformed values.
  factory SftpBrowserViewSettings.fromJson(Object? json) {
    if (json is! Map) return const SftpBrowserViewSettings();
    final sort = json['sort'];
    return SftpBrowserViewSettings(
      sortField: SftpSortField.values.firstWhere(
        (field) => field.name == sort,
        orElse: () => SftpSortField.name,
      ),
      descending: json['descending'] == true,
      showHidden: json['showHidden'] != false,
    );
  }

  /// Field entries are sorted by.
  final SftpSortField sortField;

  /// Whether the sort runs from largest, newest or last.
  final bool descending;

  /// Whether names starting with `.` are listed.
  final bool showHidden;

  /// Whether these are the defaults, which need no saved entry.
  bool get isDefault => this == const SftpBrowserViewSettings();

  /// Returns a copy with the given fields replaced.
  SftpBrowserViewSettings copyWith({
    SftpSortField? sortField,
    bool? descending,
    bool? showHidden,
  }) => SftpBrowserViewSettings(
    sortField: sortField ?? this.sortField,
    descending: descending ?? this.descending,
    showHidden: showHidden ?? this.showHidden,
  );

  /// Encodes these settings for [SettingsService].
  Map<String, Object> toJson() => {
    'sort': sortField.name,
    'descending': descending,
    'showHidden': showHidden,
  };

  @override
  bool operator ==(Object other) =>
      other is SftpBrowserViewSettings &&
      other.sortField == sortField &&
      other.descending == descending &&
      other.showHidden == showHidden;

  @override
  int get hashCode => Object.hash(sortField, descending, showHidden);
}

/// Whether [name] is hidden by the Unix dot-file convention.
bool isHiddenSftpName(String name) => name.startsWith('.');

/// Applies [settings] and the [filter] typed for the current directory.
///
/// Hidden entries are dropped unless shown, the filter keeps names containing
/// it (ignoring case), and folders sort before files. [alwaysShow] names an
/// entry that stays listed regardless, such as a file opened from a path link.
List<SftpName> applySftpBrowserView(
  Iterable<SftpName> entries,
  SftpBrowserViewSettings settings, {
  String filter = '',
  String? alwaysShow,
}) {
  final query = filter.trim().toLowerCase();
  final visible = entries
      .where(
        (entry) =>
            entry.filename == alwaysShow ||
            ((settings.showHidden || !isHiddenSftpName(entry.filename)) &&
                (query.isEmpty ||
                    entry.filename.toLowerCase().contains(query))),
      )
      .toList();
  int byName(SftpName a, SftpName b) => a.filename.compareTo(b.filename);
  int compareWithin(SftpName a, SftpName b, {required bool directories}) {
    final primary = switch (settings.sortField) {
      SftpSortField.name => 0,
      SftpSortField.size =>
        directories ? 0 : (a.attr.size ?? 0).compareTo(b.attr.size ?? 0),
      SftpSortField.modified => (a.attr.modifyTime ?? 0).compareTo(
        b.attr.modifyTime ?? 0,
      ),
      SftpSortField.type =>
        directories
            ? 0
            : _sftpExtension(a.filename).compareTo(_sftpExtension(b.filename)),
    };
    final result = primary != 0 ? primary : byName(a, b);
    return settings.descending ? -result : result;
  }

  return visible..sort((a, b) {
    final aIsDirectory = a.attr.isDirectory;
    final bIsDirectory = b.attr.isDirectory;
    if (aIsDirectory != bIsDirectory) return aIsDirectory ? -1 : 1;
    return compareWithin(a, b, directories: aIsDirectory);
  });
}

String _sftpExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

Color _mutedTextColor(ThemeData theme) =>
    theme.textTheme.bodyMedium?.color ?? theme.colorScheme.onSurfaceVariant;

Color _inputSurfaceColor(ThemeData theme) =>
    theme.inputDecorationTheme.fillColor ??
    theme.colorScheme.surfaceContainerHighest;

/// Resolves a tinted accent surface and a foreground color that clears WCAG AA
/// contrast across dark, light, and terminal-derived themes.
({Color background, Color foreground}) resolveSftpTintedAccentColors(
  ThemeData theme, {
  required Color baseSurface,
  double darkAlpha = 0.28,
  double lightAlpha = 0.14,
}) {
  final scheme = theme.colorScheme;
  final isDark = theme.brightness == Brightness.dark;
  final tint = scheme.primary.withValues(
    alpha: isDark ? darkAlpha : lightAlpha,
  );
  final composite = Color.alphaBlend(tint, baseSurface);
  final primaryContrast = _contrastRatio(scheme.primary, composite);
  final onSurfaceContrast = _contrastRatio(scheme.onSurface, composite);
  final foreground = !isDark && primaryContrast >= 4.5
      ? scheme.primary
      : onSurfaceContrast >= 4.5
      ? scheme.onSurface
      : _contrastRatio(Colors.white, composite) >=
            _contrastRatio(Colors.black, composite)
      ? Colors.white
      : Colors.black;
  return (background: composite, foreground: foreground);
}

/// Literal ascending/descending labels for a [SftpSortField].
({String ascending, String descending}) sftpSortOrderLabels(
  SftpSortField field,
) => switch (field) {
  SftpSortField.name ||
  SftpSortField.type => (ascending: 'A to Z', descending: 'Z to A'),
  SftpSortField.size => (ascending: 'Smallest', descending: 'Largest'),
  SftpSortField.modified => (ascending: 'Oldest', descending: 'Newest'),
};

/// Counts entries eligible under [settings] and how many match [filter].
///
/// [hiddenMatched] counts dot-files that match [filter] while hidden files are
/// turned off, so empty states can offer to reveal them.
({int matched, int total, int hiddenMatched}) countSftpFilterMatches(
  Iterable<SftpName> entries,
  SftpBrowserViewSettings settings,
  String filter,
) {
  final query = filter.trim().toLowerCase();
  var total = 0;
  var matched = 0;
  var hiddenMatched = 0;
  for (final entry in entries) {
    final hidden = isHiddenSftpName(entry.filename);
    final matchesQuery =
        query.isEmpty || entry.filename.toLowerCase().contains(query);
    if (!settings.showHidden && hidden) {
      if (query.isNotEmpty && matchesQuery) {
        hiddenMatched++;
      }
      continue;
    }
    total++;
    if (matchesQuery) {
      matched++;
    }
  }
  return (matched: matched, total: total, hiddenMatched: hiddenMatched);
}

/// Splits [filename] into plain and highlighted [TextSpan]s for every
/// case-insensitive occurrence of [query].
List<InlineSpan> buildHighlightedSftpFilenameSpans({
  required String filename,
  required String query,
  required TextStyle baseStyle,
  required TextStyle matchStyle,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) {
    return [TextSpan(text: filename, style: baseStyle)];
  }
  final haystack = filename.toLowerCase();
  final spans = <InlineSpan>[];
  var cursor = 0;
  while (cursor < filename.length) {
    final index = haystack.indexOf(needle, cursor);
    if (index < 0) {
      spans.add(TextSpan(text: filename.substring(cursor), style: baseStyle));
      break;
    }
    if (index > cursor) {
      spans.add(
        TextSpan(text: filename.substring(cursor, index), style: baseStyle),
      );
    }
    final end = index + needle.length;
    spans.add(
      TextSpan(text: filename.substring(index, end), style: matchStyle),
    );
    cursor = end;
  }
  return spans;
}

/// Describes the current sort for buttons and screen readers.
String describeSftpSort(SftpBrowserViewSettings settings) {
  final direction = switch (settings.sortField) {
    SftpSortField.name ||
    SftpSortField.type => settings.descending ? 'Z to A' : 'A to Z',
    SftpSortField.size =>
      settings.descending ? 'largest first' : 'smallest first',
    SftpSortField.modified =>
      settings.descending ? 'newest first' : 'oldest first',
  };
  return 'Sorted by ${settings.sortField.label.toLowerCase()}, $direction';
}

/// Loads and saves SFTP browser view settings per host.
abstract interface class SftpBrowserViewStore {
  /// Loads the settings saved for [hostId], or the defaults.
  Future<SftpBrowserViewSettings> load(int hostId);

  /// Saves [settings] for [hostId].
  Future<void> save(int hostId, SftpBrowserViewSettings settings);

  /// Loads the filter last typed for [hostId], with its folder.
  Future<SftpBrowserFilter?> loadFilter(int hostId);

  /// Saves [filter] for [hostId], or forgets it when null.
  Future<void> saveFilter(int hostId, SftpBrowserFilter? filter);
}

/// [SftpBrowserViewStore] kept in the app settings table under
/// [sftpBrowserViewsSettingKey], one entry per host.
class SettingsSftpBrowserViewStore implements SftpBrowserViewStore {
  /// Creates a store backed by [settings].
  const SettingsSftpBrowserViewStore(this._settings);

  final SettingsService _settings;

  @override
  Future<SftpBrowserViewSettings> load(int hostId) async {
    final saved = await _settings.getJson(sftpBrowserViewsSettingKey);
    return SftpBrowserViewSettings.fromJson(saved?[hostId.toString()]);
  }

  /// Defaults remove the host's entry rather than storing it.
  @override
  Future<void> save(int hostId, SftpBrowserViewSettings settings) =>
      _settings.updateJson(sftpBrowserViewsSettingKey, (current) {
        final views = current ?? <String, dynamic>{};
        if (settings.isDefault) {
          views.remove(hostId.toString());
        } else {
          views[hostId.toString()] = settings.toJson();
        }
        return views.isEmpty ? null : views;
      });

  @override
  Future<SftpBrowserFilter?> loadFilter(int hostId) async {
    final saved = await _settings.getJson(sftpBrowserFiltersSettingKey);
    final entry = saved?[hostId.toString()];
    if (entry is! Map) return null;
    final directory = entry['directory'];
    final query = entry['query'];
    if (directory is! String || query is! String || query.isEmpty) {
      return null;
    }
    return (directory: directory, query: query);
  }

  @override
  Future<void> saveFilter(int hostId, SftpBrowserFilter? filter) =>
      _settings.updateJson(sftpBrowserFiltersSettingKey, (current) {
        final filters = current ?? <String, dynamic>{};
        if (filter == null) {
          filters.remove(hostId.toString());
        } else {
          filters[hostId.toString()] = {
            'directory': filter.directory,
            'query': filter.query,
          };
        }
        return filters.isEmpty ? null : filters;
      });
}

/// Provider for [SftpBrowserViewStore].
final sftpBrowserViewStoreProvider = Provider<SftpBrowserViewStore>(
  (ref) => SettingsSftpBrowserViewStore(ref.watch(settingsServiceProvider)),
);

/// Shows sort and hidden-file choices.
///
/// When [onChanged] is provided, every tap applies immediately so the file list
/// updates live behind the sheet. Returns the final settings if they changed,
/// or null when dismissed unchanged.
Future<SftpBrowserViewSettings?> showSftpBrowserViewOptions(
  BuildContext context,
  SftpBrowserViewSettings settings, {
  ValueChanged<SftpBrowserViewSettings>? onChanged,
}) => showModalBottomSheet<SftpBrowserViewSettings>(
  context: context,
  showDragHandle: true,
  // Sized to its options, scrolling only when the screen is too short.
  isScrollControlled: true,
  builder: (context) =>
      _SftpBrowserViewOptionsSheet(initial: settings, onChanged: onChanged),
);

class _SftpBrowserViewOptionsSheet extends StatefulWidget {
  const _SftpBrowserViewOptionsSheet({required this.initial, this.onChanged});

  final SftpBrowserViewSettings initial;
  final ValueChanged<SftpBrowserViewSettings>? onChanged;

  @override
  State<_SftpBrowserViewOptionsSheet> createState() =>
      _SftpBrowserViewOptionsSheetState();
}

class _SftpBrowserViewOptionsSheetState
    extends State<_SftpBrowserViewOptionsSheet> {
  late SftpBrowserViewSettings _settings = widget.initial;

  void _update(SftpBrowserViewSettings next) {
    if (next == _settings) return;
    setState(() => _settings = next);
    widget.onChanged?.call(next);
  }

  void _close() =>
      Navigator.of(context).pop(_settings == widget.initial ? null : _settings);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = _mutedTextColor(theme);
    final orderLabels = sftpSortOrderLabels(_settings.sortField);
    final textScale = MediaQuery.textScalerOf(context).scale(1);

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'view options',
                      style: FluttyTheme.displayMono(
                        fontSize: 15,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _close,
                    constraints: const BoxConstraints.tightFor(
                      width: 44,
                      height: 44,
                    ),
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.close, size: 20, color: muted),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
              child: Text(
                'sort by',
                style: FluttyTheme.displayMono(fontSize: 12, color: muted),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final useWrap = constraints.maxWidth < 320 || textScale > 1.3;
                  final tiles = [
                    for (final field in SftpSortField.values)
                      _ViewChoicePill(
                        label: field.label,
                        selected: _settings.sortField == field,
                        showCheck: true,
                        onTap: () =>
                            _update(_settings.copyWith(sortField: field)),
                      ),
                  ];
                  if (useWrap) {
                    return Wrap(
                      spacing: FluttyTheme.spacingSm,
                      runSpacing: FluttyTheme.spacingSm,
                      children: tiles,
                    );
                  }
                  return Row(
                    children: [
                      for (var i = 0; i < tiles.length; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        Expanded(child: tiles[i]),
                      ],
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              child: Text(
                'order',
                style: FluttyTheme.displayMono(fontSize: 12, color: muted),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: _ViewChoicePill(
                      label: orderLabels.ascending,
                      icon: Icons.arrow_upward,
                      selected: !_settings.descending,
                      onTap: () =>
                          _update(_settings.copyWith(descending: false)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ViewChoicePill(
                      label: orderLabels.descending,
                      icon: Icons.arrow_downward,
                      selected: _settings.descending,
                      onTap: () =>
                          _update(_settings.copyWith(descending: true)),
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Divider(height: 1),
            ),
            SwitchListTile(
              contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 12),
              secondary: Icon(
                _settings.showHidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 20,
                color: _settings.showHidden ? muted : scheme.primary,
              ),
              title: const Text('Show hidden files'),
              subtitle: Text(
                '.dotfiles',
                style: FluttyTheme.monoStyle.copyWith(
                  fontSize: 12,
                  color: muted,
                ),
              ),
              value: _settings.showHidden,
              onChanged: (value) =>
                  _update(_settings.copyWith(showHidden: value)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewChoicePill extends StatelessWidget {
  const _ViewChoicePill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.showCheck = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final bool showCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final restingBg = _inputSurfaceColor(theme);
    final accent = resolveSftpTintedAccentColors(
      theme,
      baseSurface: scheme.surface,
      darkAlpha: 0.30,
    );
    final bgColor = selected ? accent.background : restingBg;
    final foreground = selected ? accent.foreground : scheme.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: bgColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outline,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 15, color: foreground),
                    const SizedBox(width: 5),
                  ] else if (showCheck && selected) ...[
                    Icon(Icons.check, size: 14, color: foreground),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: foreground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact filter field, live sort/view pill and selection trigger shown above
/// the SFTP file list.
class SftpBrowserToolbar extends StatefulWidget {
  /// Creates the toolbar.
  const SftpBrowserToolbar({
    required this.filterController,
    required this.onFilterChanged,
    required this.settings,
    required this.onShowViewOptions,
    this.onToggleSortDirection,
    this.onStartSelection,
    this.matchCount,
    this.totalCount,
    super.key,
  });

  /// Holds the filter text.
  final TextEditingController filterController;

  /// Called with the new filter text as the user types or clears it.
  final ValueChanged<String> onFilterChanged;

  /// Current sort and hidden-file settings.
  final SftpBrowserViewSettings settings;

  /// Opens the sort and hidden-file options.
  final VoidCallback onShowViewOptions;

  /// Quickly flips sort direction on long-press of the sort pill.
  final VoidCallback? onToggleSortDirection;

  /// Enters selection mode, or null to hide the button.
  final VoidCallback? onStartSelection;

  /// Number of entries matching the active filter, or null when not filtering
  /// or still loading.
  final int? matchCount;

  /// Total eligible entries in the current directory, or null while loading.
  final int? totalCount;

  @override
  State<SftpBrowserToolbar> createState() => _SftpBrowserToolbarState();
}

const _toolbarControlHeight = 48.0;
const _toolbarControlRadius = BorderRadius.all(
  Radius.circular(FluttyTheme.radiusSm),
);

class _SftpBrowserToolbarState extends State<SftpBrowserToolbar> {
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'sftp-filter-field',
    onKeyEvent: _handleKeyEvent,
  )..addListener(_onFilterFocusChanged);
  final _filterButtonFocus = FocusNode(debugLabel: 'sftp-filter-button');
  bool _filterRequested = false;

  void _openFilter() {
    setState(() => _filterRequested = true);
    _focusNode.requestFocus();
  }

  void _onFilterFocusChanged() {
    if (!_focusNode.hasFocus && _filterRequested) {
      setState(() => _filterRequested = false);
    }
  }

  void _closeFilter() {
    setState(() => _filterRequested = false);
    _focusNode.unfocus();
    _filterButtonFocus.requestFocus();
    if (widget.filterController.text.isNotEmpty) {
      widget.filterController.clear();
      widget.onFilterChanged('');
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _filterButtonFocus.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _closeFilter();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = _mutedTextColor(theme);
    final inputFill = _inputSurfaceColor(theme);
    final settings = widget.settings;
    final sortDescription = describeSftpSort(settings);
    final viewTooltip = settings.showHidden
        ? 'Sort and view: $sortDescription'
        : 'Sort and view: $sortDescription, hidden files off';
    final textScale = MediaQuery.textScalerOf(context).scale(1);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 8, 6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 340 || textScale > 1.35;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: widget.filterController,
                    builder: (context, value, _) {
                      final hasText = value.text.isNotEmpty;
                      final hasQuery = value.text.trim().isNotEmpty;
                      if (!_filterRequested && !hasQuery) {
                        return Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton.icon(
                            focusNode: _filterButtonFocus,
                            onPressed: _openFilter,
                            style: TextButton.styleFrom(
                              foregroundColor: muted,
                              backgroundColor: inputFill,
                              minimumSize: const Size(
                                48,
                                _toolbarControlHeight,
                              ),
                              shape: const RoundedRectangleBorder(
                                borderRadius: _toolbarControlRadius,
                              ),
                              side: BorderSide(color: scheme.outline),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                            ),
                            icon: const Icon(Icons.search, size: 18),
                            label: const Text(
                              'Filter',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        );
                      }
                      final hasCount =
                          hasQuery &&
                          widget.matchCount != null &&
                          widget.totalCount != null;
                      final count = hasCount
                          ? Semantics(
                              container: true,
                              liveRegion: true,
                              label:
                                  '${widget.matchCount} of ${widget.totalCount} items match',
                              child: ExcludeSemantics(
                                child: Text(
                                  '${widget.matchCount}/${widget.totalCount}',
                                  key: const ValueKey('sftpFilterMatchCount'),
                                  style: FluttyTheme.monoStyle.copyWith(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: muted,
                                  ),
                                ),
                              ),
                            )
                          : null;
                      final restingBorderColor = hasQuery
                          ? scheme.primary.withValues(alpha: 0.7)
                          : scheme.outline;
                      return Semantics(
                        label: 'Filter names in this folder',
                        child: TextField(
                          key: const ValueKey('sftpFilterField'),
                          controller: widget.filterController,
                          focusNode: _focusNode,
                          onChanged: widget.onFilterChanged,
                          textInputAction: TextInputAction.search,
                          autocorrect: false,
                          enableSuggestions: false,
                          style: FluttyTheme.monoStyle.copyWith(
                            fontSize: 13.5,
                            color: scheme.onSurface,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            filled: true,
                            fillColor: inputFill,
                            hintText: 'Filter names',
                            hintStyle: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 13.5,
                              color: muted,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: _toolbarControlRadius,
                              borderSide: BorderSide(color: restingBorderColor),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: _toolbarControlRadius,
                              borderSide: BorderSide(color: restingBorderColor),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: _toolbarControlRadius,
                              borderSide: BorderSide(
                                color: scheme.primary,
                                width: 1.5,
                              ),
                            ),
                            prefixIcon: Icon(
                              Icons.search,
                              size: 18,
                              color: hasQuery ? scheme.primary : muted,
                            ),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: _toolbarControlHeight,
                            ),
                            suffixIconConstraints: const BoxConstraints(
                              minWidth: 44,
                              minHeight: _toolbarControlHeight,
                            ),
                            helper: compact ? count : null,
                            suffixIcon: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!compact && count != null)
                                  Padding(
                                    padding: const EdgeInsetsDirectional.only(
                                      start: 4,
                                      end: 2,
                                    ),
                                    child: count,
                                  ),
                                IconButton(
                                  tooltip: hasText
                                      ? 'Clear filter'
                                      : 'Close filter',
                                  constraints: const BoxConstraints.tightFor(
                                    width: 44,
                                    height: _toolbarControlHeight,
                                  ),
                                  padding: EdgeInsets.zero,
                                  icon: Icon(
                                    Icons.close,
                                    size: 17,
                                    color: muted,
                                  ),
                                  onPressed: _closeFilter,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                _SortViewPill(
                  key: const ValueKey('sftpSortViewButton'),
                  settings: settings,
                  tooltip: viewTooltip,
                  compact: compact,
                  onTap: widget.onShowViewOptions,
                  onLongPress: widget.onToggleSortDirection == null
                      ? null
                      : () {
                          unawaited(HapticFeedback.selectionClick());
                          widget.onToggleSortDirection!();
                        },
                ),
                if (widget.onStartSelection != null) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Select files',
                    onPressed: widget.onStartSelection,
                    constraints: const BoxConstraints.tightFor(
                      width: 44,
                      height: _toolbarControlHeight,
                    ),
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      Icons.check_circle_outline,
                      size: 20,
                      color: muted,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Interactive preview of the filter button and expanded field.
@Preview(name: 'SFTP filter toolbar', size: Size(390, 100))
Widget sftpFilterToolbarPreview() => MaterialApp(
  theme: FluttyTheme.dark,
  home: const Scaffold(body: _SftpFilterToolbarPreview()),
);

class _SftpFilterToolbarPreview extends StatefulWidget {
  const _SftpFilterToolbarPreview();

  @override
  State<_SftpFilterToolbarPreview> createState() =>
      _SftpFilterToolbarPreviewState();
}

class _SftpFilterToolbarPreviewState extends State<_SftpFilterToolbarPreview> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SftpBrowserToolbar(
    filterController: _controller,
    onFilterChanged: (_) {},
    settings: const SftpBrowserViewSettings(),
    onShowViewOptions: () => unawaited(
      showSftpBrowserViewOptions(context, const SftpBrowserViewSettings()),
    ),
  );
}

class _SortViewPill extends StatelessWidget {
  const _SortViewPill({
    required this.settings,
    required this.tooltip,
    required this.compact,
    required this.onTap,
    this.onLongPress,
    super.key,
  });

  final SftpBrowserViewSettings settings;
  final String tooltip;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = _mutedTextColor(theme);
    final isCustom = !settings.isDefault;
    final accent = resolveSftpTintedAccentColors(
      theme,
      baseSurface: scheme.surface,
    );
    final bgColor = isCustom ? accent.background : _inputSurfaceColor(theme);
    final borderColor = isCustom ? scheme.primary : scheme.outline;
    final fgColor = isCustom ? accent.foreground : muted;
    final directionIcon = settings.descending
        ? Icons.arrow_downward
        : Icons.arrow_upward;

    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Material(
          color: bgColor,
          shape: RoundedRectangleBorder(
            borderRadius: _toolbarControlRadius,
            side: BorderSide(color: borderColor),
          ),
          child: InkWell(
            borderRadius: _toolbarControlRadius,
            onTap: onTap,
            onLongPress: onLongPress,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: 48,
                minHeight: _toolbarControlHeight,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: ExcludeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        compact ? Icons.tune : Icons.sort,
                        size: 18,
                        color: fgColor,
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 6),
                        Text(
                          settings.sortField.label.toLowerCase(),
                          style: FluttyTheme.monoStyle.copyWith(
                            fontSize: 12,
                            fontWeight: isCustom
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: fgColor,
                          ),
                        ),
                      ],
                      const SizedBox(width: 2),
                      Icon(directionIcon, size: 13, color: fgColor),
                      if (!settings.showHidden) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.visibility_off_outlined,
                          size: 13,
                          color: fgColor,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

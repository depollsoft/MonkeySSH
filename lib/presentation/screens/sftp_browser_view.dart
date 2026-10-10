import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/services/settings_service.dart';

/// Settings key holding each host's SFTP sort and hidden-file choices.
const sftpBrowserViewsSettingKey = 'sftp_browser_views';

/// Settings key holding each host's SFTP filter and the folder it belongs to.
const sftpBrowserFiltersSettingKey = 'sftp_browser_filters';

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

/// Shows sort and hidden-file choices; returns the new settings, or null
/// when dismissed unchanged.
Future<SftpBrowserViewSettings?> showSftpBrowserViewOptions(
  BuildContext context,
  SftpBrowserViewSettings settings,
) => showModalBottomSheet<SftpBrowserViewSettings>(
  context: context,
  showDragHandle: true,
  // Sized to its options, scrolling only when the screen is too short.
  isScrollControlled: true,
  builder: (context) => _SftpBrowserViewOptionsSheet(initial: settings),
);

class _SftpBrowserViewOptionsSheet extends StatefulWidget {
  const _SftpBrowserViewOptionsSheet({required this.initial});

  final SftpBrowserViewSettings initial;

  @override
  State<_SftpBrowserViewOptionsSheet> createState() =>
      _SftpBrowserViewOptionsSheetState();
}

class _SftpBrowserViewOptionsSheetState
    extends State<_SftpBrowserViewOptionsSheet> {
  late SftpBrowserViewSettings _settings = widget.initial;

  void _update(SftpBrowserViewSettings next) {
    setState(() => _settings = next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'sort by',
                style: FluttyTheme.displayMono(
                  fontSize: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            RadioGroup<SftpSortField>(
              groupValue: _settings.sortField,
              onChanged: (field) {
                if (field != null) {
                  _update(_settings.copyWith(sortField: field));
                }
              },
              child: Column(
                children: [
                  for (final field in SftpSortField.values)
                    RadioListTile<SftpSortField>(
                      value: field,
                      title: Text(field.label),
                    ),
                ],
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.swap_vert),
              title: const Text('Reverse order'),
              subtitle: Text(describeSftpSort(_settings)),
              value: _settings.descending,
              onChanged: (value) =>
                  _update(_settings.copyWith(descending: value)),
            ),
            const Divider(height: 1),
            SwitchListTile(
              secondary: const Icon(Icons.visibility_outlined),
              title: const Text('Show hidden files'),
              subtitle: const Text('Names that start with a dot'),
              value: _settings.showHidden,
              onChanged: (value) =>
                  _update(_settings.copyWith(showHidden: value)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () =>
                    Navigator.of(context)
                        .pop(_settings == widget.initial ? null : _settings),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Filter field plus view and selection buttons shown above the file list.
class SftpBrowserToolbar extends StatelessWidget {
  /// Creates the toolbar.
  const SftpBrowserToolbar({
    required this.filterController,
    required this.onFilterChanged,
    required this.settings,
    required this.onShowViewOptions,
    this.onStartSelection,
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

  /// Enters selection mode, or null to hide the button.
  final VoidCallback? onStartSelection;

  @override
  Widget build(BuildContext context) {
    final sortDescription = describeSftpSort(settings);
    final viewTooltip = settings.showHidden
        ? 'Sort and view: $sortDescription'
        : 'Sort and view: $sortDescription, hidden files off';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: filterController,
              builder: (context, value, _) => TextField(
                key: const ValueKey('sftpFilterField'),
                controller: filterController,
                onChanged: onFilterChanged,
                textInputAction: TextInputAction.search,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Filter this folder',
                  prefixIcon: const Icon(Icons.filter_list, size: 20),
                  suffixIcon: value.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear filter',
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () {
                            filterController.clear();
                            onFilterChanged('');
                          },
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: viewTooltip,
            onPressed: onShowViewOptions,
            // The dot marks a non-default view: hidden files are filtered.
            icon: Badge(
              isLabelVisible: !settings.showHidden,
              smallSize: 8,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: const Icon(Icons.sort),
            ),
          ),
          if (onStartSelection != null)
            IconButton(
              tooltip: 'Select files',
              onPressed: onStartSelection,
              icon: const Icon(Icons.checklist),
            ),
        ],
      ),
    );
  }
}

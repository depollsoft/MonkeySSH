import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/iterm_color_scheme.dart';
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/iterm_color_scheme_service.dart';
import '../../domain/services/terminal_theme_service.dart';
import 'brand_error_state.dart';
import 'brand_list_skeleton.dart';
import 'terminal_overlay_focus.dart';
import 'theme_preview_card.dart';

const _liveThemeSearchMinLength = 2;
const _liveThemeSearchDebounce = Duration(milliseconds: 350);
const _liveThemeResultLimit = 24;

/// A reusable widget for selecting terminal themes.
///
/// Displays themes in a grid with visual previews, organized by category
/// (dark/light) with search/filter capability.
class TerminalThemePicker extends ConsumerStatefulWidget {
  /// Creates a new [TerminalThemePicker].
  const TerminalThemePicker({
    required this.selectedThemeId,
    required this.onThemeSelected,
    this.currentSelectionLabel,
    this.onThemePreviewed,
    this.previewOnTap = false,
    this.scrollController,
    super.key,
  });

  /// The currently selected theme ID.
  final String? selectedThemeId;

  /// Called when a theme is selected.
  final ValueChanged<TerminalThemeData> onThemeSelected;

  /// Label shown above the selected theme preview.
  final String? currentSelectionLabel;

  /// Called when a theme should be previewed without closing the picker.
  final ValueChanged<TerminalThemeData>? onThemePreviewed;

  /// Whether tapping an installed theme previews it instead of selecting it.
  final bool previewOnTap;

  /// Optional scroll controller supplied by a surrounding draggable sheet.
  final ScrollController? scrollController;

  @override
  ConsumerState<TerminalThemePicker> createState() =>
      _TerminalThemePickerState();
}

class _TerminalThemePickerState extends ConsumerState<TerminalThemePicker> {
  String _searchQuery = '';
  String _liveSearchQuery = '';
  String? _importingSchemeId;
  ItermColorSchemeMetadata? _previewingScheme;
  _ThemeFilter _filter = _ThemeFilter.all;
  final TextEditingController _searchController = TextEditingController();
  Timer? _liveSearchDebounceTimer;
  int _livePreviewGeneration = 0;

  @override
  void dispose() {
    _liveSearchDebounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themesAsync = ref.watch(allTerminalThemesProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final availableThemes = themesAsync.asData?.value ?? TerminalThemes.all;
    final liveSearchText = _searchQuery.trim();
    final isLiveSearchPending =
        liveSearchText.length >= _liveThemeSearchMinLength &&
        liveSearchText != _liveSearchQuery;
    final liveResultsAsync =
        _liveSearchQuery.length >= _liveThemeSearchMinLength &&
            !isLiveSearchPending
        ? ref.watch(itermColorSchemeSearchProvider(_liveSearchQuery))
        : null;

    // Get the currently selected theme for the preview
    final currentTheme = widget.selectedThemeId != null
        ? TerminalThemes.getById(
            widget.selectedThemeId!,
            additionalThemes: availableThemes,
          )
        : null;

    return NestedScrollView(
      controller: widget.scrollController,
      headerSliverBuilder: (context, innerBoxIsScrolled) => [
        // Currently selected preview (always visible)
        if (currentTheme != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _CurrentSelectionPreview(
                theme: currentTheme,
                label: widget.currentSelectionLabel ?? 'Currently Selected',
              ),
            ),
          ),

        // Collapsible search and filter bar
        SliverAppBar(
          floating: true,
          snap: true,
          automaticallyImplyLeading: false,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          toolbarHeight: 120,
          flexibleSpace: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Search field
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search themes...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: _clearSearch,
                          )
                        : null,
                    isDense: true,
                  ),
                  onChanged: _handleSearchChanged,
                ),
                const SizedBox(height: 12),
                // Filter chips
                Row(
                  children: [
                    _FilterChip(
                      label: 'All',
                      isSelected: _filter == _ThemeFilter.all,
                      onTap: () => setState(() => _filter = _ThemeFilter.all),
                    ),
                    const SizedBox(width: 8),
                    _FilterChip(
                      label: 'Dark',
                      isSelected: _filter == _ThemeFilter.dark,
                      onTap: () => setState(() => _filter = _ThemeFilter.dark),
                    ),
                    const SizedBox(width: 8),
                    _FilterChip(
                      label: 'Light',
                      isSelected: _filter == _ThemeFilter.light,
                      onTap: () => setState(() => _filter = _ThemeFilter.light),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
      body: themesAsync.when(
        loading: () => const BrandListSkeleton(),
        error: (_, _) => BrandErrorState(
          title: 'couldn’t load themes',
          message: 'The terminal theme list didn’t load.',
          onRetry: () => ref.invalidate(allTerminalThemesProvider),
        ),
        data: (themes) {
          final filtered = _filterThemes(themes);
          if (filtered.isEmpty && liveSearchText.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.palette_outlined,
                    size: 48,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No themes found',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              ),
            );
          }

          return _buildThemeGrid(
            filtered,
            installedThemes: themes,
            liveResultsAsync: liveResultsAsync,
            isLiveSearchPending: isLiveSearchPending,
          );
        },
      ),
    );
  }

  void _clearSearch() {
    _liveSearchDebounceTimer?.cancel();
    _livePreviewGeneration += 1;
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _liveSearchQuery = '';
      _previewingScheme = null;
    });
  }

  void _handleSearchChanged(String value) {
    _liveSearchDebounceTimer?.cancel();
    _livePreviewGeneration += 1;
    final query = value.trim();
    setState(() {
      _searchQuery = value;
      _previewingScheme = null;
      if (query.length < _liveThemeSearchMinLength) {
        _liveSearchQuery = '';
      }
    });
    if (query.length < _liveThemeSearchMinLength || query == _liveSearchQuery) {
      return;
    }
    _liveSearchDebounceTimer = Timer(_liveThemeSearchDebounce, () {
      if (!mounted) {
        return;
      }
      setState(() => _liveSearchQuery = query);
    });
  }

  List<TerminalThemeData> _filterThemes(List<TerminalThemeData> themes) {
    var result = themes;

    // Apply type filter
    if (_filter == _ThemeFilter.dark) {
      result = result.where((t) => t.isDark).toList();
    } else if (_filter == _ThemeFilter.light) {
      result = result.where((t) => !t.isDark).toList();
    }

    // Apply search filter. Match on the same trimmed text the live repository
    // search uses so surrounding whitespace never hides installed themes.
    final query = _searchQuery.trim().toLowerCase();
    if (query.isNotEmpty) {
      result = result
          .where((t) => t.name.toLowerCase().contains(query))
          .toList();
    }

    return result;
  }

  Widget _buildThemeGrid(
    List<TerminalThemeData> themes, {
    required List<TerminalThemeData> installedThemes,
    required AsyncValue<List<ItermColorSchemeMetadata>>? liveResultsAsync,
    required bool isLiveSearchPending,
  }) {
    // Separate custom themes
    final builtInThemes = themes.where((t) => !t.isCustom).toList();
    final customThemes = themes.where((t) => t.isCustom).toList();

    // Group built-in by dark/light
    final darkThemes = builtInThemes.where((t) => t.isDark).toList();
    final lightThemes = builtInThemes.where((t) => !t.isDark).toList();

    final installedThemeIds = installedThemes.map((theme) => theme.id).toSet();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (customThemes.isNotEmpty) ...[
          const _SectionHeader(title: 'Custom Themes'),
          _ThemeGridSection(
            themes: customThemes,
            selectedThemeId: widget.selectedThemeId,
            onThemeSelected: _handleThemeActivated,
            onLongPress: _handleCustomThemeLongPress,
          ),
          const SizedBox(height: 16),
        ],
        if (darkThemes.isNotEmpty) ...[
          const _SectionHeader(title: 'Dark Themes'),
          _ThemeGridSection(
            themes: darkThemes,
            selectedThemeId: widget.selectedThemeId,
            onThemeSelected: _handleThemeActivated,
          ),
          const SizedBox(height: 16),
        ],
        if (lightThemes.isNotEmpty) ...[
          const _SectionHeader(title: 'Light Themes'),
          _ThemeGridSection(
            themes: lightThemes,
            selectedThemeId: widget.selectedThemeId,
            onThemeSelected: _handleThemeActivated,
          ),
        ],
        ..._buildLiveRepositorySection(
          installedThemeIds: installedThemeIds,
          liveResultsAsync: liveResultsAsync,
          isLiveSearchPending: isLiveSearchPending,
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  void _handleThemeActivated(TerminalThemeData theme) {
    _livePreviewGeneration++;
    setState(() => _previewingScheme = null);
    if (!widget.previewOnTap) {
      widget.onThemeSelected(theme);
      return;
    }
    widget.onThemePreviewed?.call(theme);
  }

  List<Widget> _buildLiveRepositorySection({
    required Set<String> installedThemeIds,
    required AsyncValue<List<ItermColorSchemeMetadata>>? liveResultsAsync,
    required bool isLiveSearchPending,
  }) {
    final query = _searchQuery.trim();
    if (query.isEmpty) {
      return const [];
    }
    if (query.length < _liveThemeSearchMinLength) {
      return [
        const SizedBox(height: 8),
        const _SectionHeader(title: 'iTerm2ColorSchemes.com'),
        const _LiveThemeMessage(
          icon: Icons.search,
          message: 'Type at least 2 characters to search the live repository.',
        ),
      ];
    }

    return [
      const SizedBox(height: 8),
      const _SectionHeader(title: 'iTerm2ColorSchemes.com'),
      if (isLiveSearchPending)
        const _LiveThemeMessage(
          icon: Icons.sync,
          message: 'Searching live repository...',
          isLoading: true,
        )
      else if (liveResultsAsync == null)
        const _LiveThemeMessage(
          icon: Icons.search,
          message: 'Type at least 2 characters to search the live repository.',
        )
      else
        liveResultsAsync.when(
          loading: () => const _LiveThemeMessage(
            icon: Icons.sync,
            message: 'Searching live repository...',
            isLoading: true,
          ),
          error: (_, _) => const _LiveThemeMessage(
            icon: Icons.cloud_off_outlined,
            message: 'Could not search iTerm2ColorSchemes.com.',
          ),
          data: (schemes) {
            final remoteSchemes = schemes
                .where((scheme) => !installedThemeIds.contains(scheme.id))
                .toList(growable: false);
            if (remoteSchemes.isEmpty) {
              return const _LiveThemeMessage(
                icon: Icons.check_circle_outline,
                message:
                    'No additional live themes found. Matching built-ins are shown above.',
              );
            }
            return _LiveThemePreviewGrid(
              schemes: remoteSchemes,
              importingSchemeId: _importingSchemeId,
              previewingScheme: _previewingScheme,
              onSchemePreviewed: _previewLiveScheme,
              onSchemeSelected: _importLiveScheme,
            );
          },
        ),
    ];
  }

  void _previewLiveScheme(ItermColorSchemeMetadata scheme) {
    final previewGeneration = _livePreviewGeneration + 1;
    _livePreviewGeneration = previewGeneration;
    setState(() => _previewingScheme = scheme);
    if (!widget.previewOnTap || widget.onThemePreviewed == null) {
      return;
    }
    unawaited(_loadLiveThemePreview(scheme, previewGeneration));
  }

  Future<void> _loadLiveThemePreview(
    ItermColorSchemeMetadata scheme,
    int previewGeneration,
  ) async {
    try {
      final theme = await ref
          .read(itermColorSchemeServiceProvider)
          .loadTheme(scheme);
      if (!mounted ||
          previewGeneration != _livePreviewGeneration ||
          _previewingScheme?.id != scheme.id) {
        return;
      }
      widget.onThemePreviewed?.call(theme);
    } on ItermColorSchemeException catch (error) {
      if (!mounted ||
          previewGeneration != _livePreviewGeneration ||
          _previewingScheme?.id != scheme.id) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not preview ${scheme.name}: ${error.message}'),
        ),
      );
    }
  }

  Future<void> _importLiveScheme(ItermColorSchemeMetadata scheme) async {
    if (_importingSchemeId != null) {
      return;
    }

    _livePreviewGeneration++;
    var didSelectTheme = false;
    setState(() => _importingSchemeId = scheme.id);
    try {
      final liveSchemeService = ref.read(itermColorSchemeServiceProvider);
      final themeService = ref.read(terminalThemeServiceProvider);
      final importedTheme = await liveSchemeService.loadTheme(scheme);
      final builtInTheme = TerminalThemes.getById(importedTheme.id);
      final theme = builtInTheme ?? importedTheme.copyWith(isCustom: true);

      if (builtInTheme == null) {
        await themeService.saveCustomTheme(theme);
        if (mounted) {
          ref
            ..invalidate(allTerminalThemesProvider)
            ..invalidate(customTerminalThemesProvider);
        }
      }

      if (mounted) {
        didSelectTheme = true;
        widget.onThemeSelected(theme);
      }
    } on ItermColorSchemeException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not import ${scheme.name}: ${error.message}'),
          ),
        );
      }
    } finally {
      if (mounted && !didSelectTheme) {
        setState(() => _importingSchemeId = null);
      }
    }
  }

  void _handleCustomThemeLongPress(TerminalThemeData theme) {
    showModalBottomSheet<void>(
      context: context,
      requestFocus: terminalOverlayRouteRequestFocus(context),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.delete,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete theme',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(theme);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(TerminalThemeData theme) {
    showDialog<void>(
      context: context,
      requestFocus: terminalOverlayRouteRequestFocus(context),
      builder: (context) => AlertDialog(
        title: const Text('Delete theme?'),
        content: Text('Are you sure you want to delete "${theme.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await _deleteCustomTheme(theme);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteCustomTheme(TerminalThemeData theme) async {
    try {
      await ref.read(terminalThemeServiceProvider).deleteCustomTheme(theme.id);
      if (!mounted) {
        return;
      }
      ref
        ..invalidate(allTerminalThemesProvider)
        ..invalidate(customTerminalThemesProvider);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deleted "${theme.name}"')));
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete "${theme.name}": $error')),
      );
    }
  }
}

class _LiveThemePreviewGrid extends StatelessWidget {
  const _LiveThemePreviewGrid({
    required this.schemes,
    required this.importingSchemeId,
    required this.previewingScheme,
    required this.onSchemePreviewed,
    required this.onSchemeSelected,
  });

  final List<ItermColorSchemeMetadata> schemes;
  final String? importingSchemeId;
  final ItermColorSchemeMetadata? previewingScheme;
  final ValueChanged<ItermColorSchemeMetadata> onSchemePreviewed;
  final ValueChanged<ItermColorSchemeMetadata> onSchemeSelected;

  @override
  Widget build(BuildContext context) {
    final visibleSchemes = schemes
        .take(_liveThemeResultLimit)
        .toList(growable: false);
    final activePreview =
        previewingScheme != null &&
            visibleSchemes.any((scheme) => scheme.id == previewingScheme!.id)
        ? previewingScheme
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (activePreview != null) ...[
          SizedBox(
            height: 168,
            child: _LiveThemePreviewCard(
              scheme: activePreview,
              isImporting: importingSchemeId == activePreview.id,
              isBusy: importingSchemeId != null,
              onTap: () => onSchemeSelected(activePreview),
            ),
          ),
          const SizedBox(height: 12),
        ],
        _LiveThemeCompactList(
          schemes: visibleSchemes,
          importingSchemeId: importingSchemeId,
          previewingSchemeId: activePreview?.id,
          onSchemePreviewed: onSchemePreviewed,
          onSchemeSelected: onSchemeSelected,
        ),
        if (schemes.length > visibleSchemes.length) ...[
          const SizedBox(height: 12),
          _LiveThemeMessage(
            icon: Icons.manage_search,
            message:
                'Showing the first ${visibleSchemes.length} live matches. '
                'Refine your search to narrow the results.',
          ),
        ],
      ],
    );
  }
}

class _LiveThemeCompactList extends StatelessWidget {
  const _LiveThemeCompactList({
    required this.schemes,
    required this.importingSchemeId,
    required this.previewingSchemeId,
    required this.onSchemePreviewed,
    required this.onSchemeSelected,
  });

  final List<ItermColorSchemeMetadata> schemes;
  final String? importingSchemeId;
  final String? previewingSchemeId;
  final ValueChanged<ItermColorSchemeMetadata> onSchemePreviewed;
  final ValueChanged<ItermColorSchemeMetadata> onSchemeSelected;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Column(
      children: [
        for (final scheme in schemes)
          _LiveThemeCompactTile(
            scheme: scheme,
            isImporting: importingSchemeId == scheme.id,
            isBusy: importingSchemeId != null,
            isPreviewing: previewingSchemeId == scheme.id,
            onPreview: () => onSchemePreviewed(scheme),
            onImport: () => onSchemeSelected(scheme),
          ),
      ],
    ),
  );
}

class _LiveThemeCompactTile extends StatelessWidget {
  const _LiveThemeCompactTile({
    required this.scheme,
    required this.isImporting,
    required this.isBusy,
    required this.isPreviewing,
    required this.onPreview,
    required this.onImport,
  });

  final ItermColorSchemeMetadata scheme;
  final bool isImporting;
  final bool isBusy;
  final bool isPreviewing;
  final VoidCallback onPreview;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: isImporting
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.palette_outlined),
    title: Text(scheme.name),
    subtitle: Text(
      isPreviewing
          ? 'Preview shown above'
          : 'Preview before importing from iTerm2ColorSchemes.com',
    ),
    trailing: IconButton(
      icon: const Icon(Icons.download_outlined),
      tooltip: 'Import theme',
      onPressed: isBusy ? null : onImport,
    ),
    enabled: !isBusy || isImporting,
    selected: isPreviewing,
    onTap: isBusy ? null : onPreview,
  );
}

class _LiveThemePreviewCard extends ConsumerWidget {
  const _LiveThemePreviewCard({
    required this.scheme,
    required this.isImporting,
    required this.isBusy,
    required this.onTap,
  });

  final ItermColorSchemeMetadata scheme;
  final bool isImporting;
  final bool isBusy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeAsync = ref.watch(itermColorSchemeThemeProvider(scheme));
    return themeAsync.when(
      data: (theme) => _LiveThemePreviewFrame(
        isImporting: isImporting,
        child: ThemePreviewCard(
          theme: theme,
          isSelected: false,
          trailingIcon: Icons.download_outlined,
          onTap: isBusy ? () {} : onTap,
        ),
      ),
      loading: () => _LiveThemePreviewPlaceholder(
        name: scheme.name,
        isImporting: isImporting,
        isBusy: isBusy,
        onTap: onTap,
      ),
      error: (_, _) => _LiveThemePreviewError(
        name: scheme.name,
        isBusy: isBusy,
        onTap: onTap,
      ),
    );
  }
}

class _LiveThemePreviewFrame extends StatelessWidget {
  const _LiveThemePreviewFrame({
    required this.child,
    required this.isImporting,
  });

  final Widget child;
  final bool isImporting;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      child,
      if (isImporting)
        DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.scrim.withAlpha(90),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Center(child: CircularProgressIndicator()),
        ),
    ],
  );
}

class _LiveThemePreviewPlaceholder extends StatelessWidget {
  const _LiveThemePreviewPlaceholder({
    required this.name,
    required this.isImporting,
    required this.isBusy,
    required this.onTap,
  });

  final String name;
  final bool isImporting;
  final bool isBusy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _LiveThemePreviewFrame(
    isImporting: isImporting,
    child: _LiveThemePreviewShell(
      name: name,
      icon: Icons.download_outlined,
      onTap: isBusy ? null : onTap,
      child: const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    ),
  );
}

class _LiveThemePreviewError extends StatelessWidget {
  const _LiveThemePreviewError({
    required this.name,
    required this.isBusy,
    required this.onTap,
  });

  final String name;
  final bool isBusy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _LiveThemePreviewShell(
      name: name,
      icon: Icons.refresh,
      onTap: isBusy ? null : onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.broken_image_outlined, color: colorScheme.error),
          const SizedBox(height: 8),
          Text(
            'Preview unavailable',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveThemePreviewShell extends StatelessWidget {
  const _LiveThemePreviewShell({
    required this.name,
    required this.icon,
    required this.child,
    required this.onTap,
  });

  final String name;
  final IconData icon;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colorScheme.outline),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ColoredBox(
                  color: colorScheme.surfaceContainerHighest,
                  child: child,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  border: Border(top: BorderSide(color: colorScheme.outline)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(icon, size: 12, color: colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveThemeMessage extends StatelessWidget {
  const _LiveThemeMessage({
    required this.icon,
    required this.message,
    this.isLoading = false,
  });

  final IconData icon;
  final String message;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            if (isLoading)
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(icon, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _ThemeFilter { all, dark, light }

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? colorScheme.primary : colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? colorScheme.primary : colorScheme.outline,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: isSelected ? colorScheme.onPrimary : colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _CurrentSelectionPreview extends StatelessWidget {
  const _CurrentSelectionPreview({required this.theme, required this.label});

  final TerminalThemeData theme;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withAlpha(50),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withAlpha(100)),
      ),
      child: Row(
        children: [
          // Mini preview
          Container(
            width: 60,
            height: 44,
            decoration: BoxDecoration(
              color: theme.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.outline),
            ),
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    _colorDot(theme.green),
                    _colorDot(theme.blue),
                    _colorDot(theme.red),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  r'$ _',
                  style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: 8,
                    color: theme.foreground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  theme.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
          // Check icon
          Icon(Icons.check_circle, color: colorScheme.primary, size: 24),
        ],
      ),
    );
  }

  Widget _colorDot(Color color) => Container(
    width: 6,
    height: 6,
    margin: const EdgeInsets.only(right: 2),
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _ThemeGridSection extends StatelessWidget {
  const _ThemeGridSection({
    required this.themes,
    required this.selectedThemeId,
    required this.onThemeSelected,
    this.onLongPress,
  });

  final List<TerminalThemeData> themes;
  final String? selectedThemeId;
  final ValueChanged<TerminalThemeData> onThemeSelected;
  final ValueChanged<TerminalThemeData>? onLongPress;

  @override
  Widget build(BuildContext context) {
    final resolvedSelectedThemeId = selectedThemeId == null
        ? null
        : TerminalThemes.resolveThemeId(selectedThemeId!);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width < 420 ? 2 : (width < 720 ? 3 : 4);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.9,
          ),
          itemCount: themes.length,
          itemBuilder: (context, index) {
            final theme = themes[index];
            return ThemePreviewCard(
              theme: theme,
              isSelected: theme.id == resolvedSelectedThemeId,
              onTap: () => onThemeSelected(theme),
              onLongPress: onLongPress != null
                  ? () => onLongPress!(theme)
                  : null,
            );
          },
        );
      },
    );
  }
}

/// Shows a theme picker dialog and returns the selected theme.
///
/// When [onThemePreviewed] is supplied, installed themes preview on tap and the
/// user confirms the previewed theme with an explicit action.
///
/// [requestFocus] controls whether the picker route takes focus when shown.
Future<TerminalThemeData?> showThemePickerDialog({
  required BuildContext context,
  required String? currentThemeId,
  ValueChanged<TerminalThemeData>? onThemePreviewed,
  bool? requestFocus,
}) async => showModalBottomSheet<TerminalThemeData>(
  context: context,
  barrierColor: onThemePreviewed == null ? null : Colors.transparent,
  isScrollControlled: true,
  requestFocus: requestFocus,
  useSafeArea: true,
  builder: (context) => _TerminalThemePickerBottomSheet(
    currentThemeId: currentThemeId,
    onThemePreviewed: onThemePreviewed,
  ),
);

class _TerminalThemePickerBottomSheet extends StatefulWidget {
  const _TerminalThemePickerBottomSheet({
    required this.currentThemeId,
    required this.onThemePreviewed,
  });

  final String? currentThemeId;
  final ValueChanged<TerminalThemeData>? onThemePreviewed;

  @override
  State<_TerminalThemePickerBottomSheet> createState() =>
      _TerminalThemePickerBottomSheetState();
}

class _TerminalThemePickerBottomSheetState
    extends State<_TerminalThemePickerBottomSheet> {
  TerminalThemeData? _previewTheme;

  bool get _usesLivePreview => widget.onThemePreviewed != null;

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final keyboardVisible = viewInsets.bottom > 0;
    final initialChildSize = _resolveInitialChildSize(
      keyboardVisible: keyboardVisible,
    );
    final minChildSize = _usesLivePreview ? 0.38 : 0.5;
    final maxChildSize = _usesLivePreview && !keyboardVisible ? 0.74 : 0.95;
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight > viewInsets.bottom
            ? constraints.maxHeight - viewInsets.bottom
            : constraints.maxHeight;
        return AnimatedPadding(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(bottom: viewInsets.bottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: availableHeight),
            child: DraggableScrollableSheet(
              initialChildSize: initialChildSize,
              minChildSize: minChildSize,
              maxChildSize: maxChildSize,
              expand: false,
              builder: (context, scrollController) => Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.outline,
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: const SizedBox(
                        key: ValueKey('terminal-theme-picker-handle'),
                        width: 40,
                        height: 4,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Text(
                          _usesLivePreview ? 'Preview Theme' : 'Select Theme',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TerminalThemePicker(
                      selectedThemeId:
                          _previewTheme?.id ?? widget.currentThemeId,
                      currentSelectionLabel: _previewTheme == null
                          ? 'Currently Selected'
                          : 'Previewing',
                      onThemeSelected: _selectTheme,
                      onThemePreviewed: _previewThemeInTerminal,
                      previewOnTap: _usesLivePreview,
                      scrollController: scrollController,
                    ),
                  ),
                  if (_usesLivePreview)
                    _ThemePreviewActionBar(
                      previewTheme: _previewTheme,
                      onCancel: () => Navigator.pop(context),
                      onUseTheme: _previewTheme == null
                          ? null
                          : () => Navigator.pop(context, _previewTheme),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  double _resolveInitialChildSize({required bool keyboardVisible}) {
    if (!_usesLivePreview) {
      return 0.85;
    }
    return keyboardVisible ? 0.95 : 0.58;
  }

  void _previewThemeInTerminal(TerminalThemeData theme) {
    setState(() => _previewTheme = theme);
    widget.onThemePreviewed?.call(theme);
  }

  void _selectTheme(TerminalThemeData theme) => Navigator.pop(context, theme);
}

class _ThemePreviewActionBar extends StatelessWidget {
  const _ThemePreviewActionBar({
    required this.previewTheme,
    required this.onCancel,
    required this.onUseTheme,
  });

  final TerminalThemeData? previewTheme;
  final VoidCallback onCancel;
  final VoidCallback? onUseTheme;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final themeName = previewTheme?.name;
    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  themeName == null
                      ? 'Tap a theme to preview it on this terminal.'
                      : 'Previewing $themeName',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              TextButton(onPressed: onCancel, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: onUseTheme,
                child: const Text('Use Theme'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

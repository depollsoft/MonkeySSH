import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderBase;

import '../../data/database/database.dart';
import '../../data/repositories/group_repository.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../data/repositories/snippet_repository.dart';
import '../../domain/services/settings_service.dart';

/// Shared stream of all saved hosts for presentation screens.
final allHostsProvider = StreamProvider<List<Host>>((ref) {
  final repo = ref.watch(hostRepositoryProvider);
  return repo.watchAll();
});

/// Stream of a single saved host, or `null` when it no longer exists.
final hostByIdProvider = StreamProvider.autoDispose.family<Host?, int>((
  ref,
  hostId,
) {
  final repo = ref.watch(hostRepositoryProvider);
  return repo.watchById(hostId);
});

/// Shared stream of all saved SSH keys for presentation screens.
final allKeysProvider = StreamProvider<List<SshKey>>((ref) {
  final repo = ref.watch(keyRepositoryProvider);
  return repo.watchAll();
});

/// Shared stream of all host groups for presentation screens.
final allGroupsProvider = StreamProvider<List<Group>>((ref) {
  final repo = ref.watch(groupRepositoryProvider);
  return repo.watchAll();
});

/// Shared stream of all snippets for presentation screens.
final allSnippetsProvider = StreamProvider<List<Snippet>>((ref) {
  final repo = ref.watch(snippetRepositoryProvider);
  return repo.watchAll();
});

/// Shared stream of all snippet folders for presentation screens.
final allSnippetFoldersProvider = StreamProvider<List<SnippetFolder>>((ref) {
  final repo = ref.watch(snippetRepositoryProvider);
  return repo.watchAllFolders();
});

/// Shared stream of all port forwards for presentation screens.
final allPortForwardsProvider = StreamProvider<List<PortForward>>((ref) {
  final repo = ref.watch(portForwardRepositoryProvider);
  return repo.watchAll();
});

/// Stream of saved port forwards for a single host.
final portForwardsForHostProvider = StreamProvider.autoDispose
    .family<List<PortForward>, int>((ref, hostId) {
      final repo = ref.watch(portForwardRepositoryProvider);
      return repo.watchByHostId(hostId);
    });

/// Signature for invalidating shared providers from any Riverpod context.
typedef ProviderInvalidator =
    void Function(ProviderBase<Object?> provider, {bool asReload});

/// Refreshes shared entity list providers after migration imports replace data.
void invalidateImportedEntityProviders(ProviderInvalidator invalidate) {
  invalidate(allHostsProvider);
  invalidate(allKeysProvider);
  invalidate(allGroupsProvider);
  invalidate(allSnippetsProvider);
  invalidate(allSnippetFoldersProvider);
  invalidate(allPortForwardsProvider);
}

/// Refreshes presentation providers that depend on synced settings and data.
void invalidateSyncedDataProviders(ProviderInvalidator invalidate) {
  // Settings notifiers and theme providers watch this service. Recreating it
  // reloads all persisted settings, including those added after this helper.
  invalidate(settingsServiceProvider);
  invalidateImportedEntityProviders(invalidate);
}

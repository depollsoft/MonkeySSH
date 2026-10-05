import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acp_provider.dart';

/// Provider for the ACP providers offered in session pickers: the built-in
/// providers bundled with the app.
final acpProvidersProvider = StreamProvider<List<AcpProvider>>(
  (ref) => Stream.value(acpBuiltinProviders),
);

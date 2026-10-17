import '../domain/services/host_agent_forwarding_service.dart';
import '../domain/services/ssh_agent_forwarding.dart';
import '../presentation/widgets/agent_signature_dialog.dart';
import 'router.dart';

/// Creates the UI-backed per-signature prompt for SSH agent forwarding.
///
/// Shows a dialog through the app navigator. Resolves
/// [SshAgentSignatureDecision.unavailable] when no UI is available, so the
/// signature is refused.
SshAgentSignaturePromptHandler createAgentSignaturePromptHandler() =>
    (request, {required timeout}) async {
      final context = appNavigatorKey.currentContext;
      final navigator = appNavigatorKey.currentState;
      if (context == null || navigator == null || !navigator.mounted) {
        return SshAgentSignatureDecision.unavailable;
      }
      return showAgentSignatureDialog(
        context: context,
        request: request,
        timeout: timeout,
      );
    };

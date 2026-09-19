// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' show InvalidDataException;

import '../../domain/models/port_proxy_name.dart';
import '../../domain/models/remote_multiplexer.dart';
import '../view_models/host_edit_view_model.dart';

String? validateHostFieldLength(String value, String label) =>
    value.length > 255 ? '$label must be 255 characters or fewer' : null;

String hostSaveFailureMessage(Exception error) => switch (error) {
  PortProxyNameConflictException() =>
    '${error.message}. Choose a different proxy domain.',
  InvalidDataException() =>
    'Couldn’t save this host. Check the field values and try again.',
  FormatException() => 'Couldn’t read the saved credentials. Re-enter the password or import the SSH key again.',
  _ => 'Couldn’t save this host. Check the required fields and try again.',
};

typedef HostWindowConfig = ({
  String session,
  String directory,
  String flags,
  bool disableStatusBar,
});

({HostWindowConfig mux, HostWindowConfig agent, RemoteMuxBackend agentBackend})
carryWindowConfigAcrossModeChange({
  required HostStartupMode from,
  required HostStartupMode to,
  required HostWindowConfig mux,
  required HostWindowConfig agent,
  required RemoteMuxBackend agentBackend,
}) {
  var nextMux = mux;
  var nextAgent = agent;
  var nextAgentBackend = agentBackend;
  String seed(String current, String value) =>
      current.trim().isEmpty && value.trim().isNotEmpty ? value : current;
  if (from.usesRemoteMultiplexer && to == HostStartupMode.agent) {
    final agentUnconfigured = agent.session.trim().isEmpty;
    nextAgent = (
      session: seed(agent.session, mux.session),
      directory: seed(agent.directory, mux.directory),
      flags: seed(agent.flags, mux.flags),
      disableStatusBar: agentUnconfigured
          ? mux.disableStatusBar
          : agent.disableStatusBar,
    );
    if (agentUnconfigured) {
      nextAgentBackend = from.remoteMuxBackend == RemoteMuxBackend.tmux
          ? RemoteMuxBackend.tmux
          : RemoteMuxBackend.monkeyMux;
    }
  } else if (from == HostStartupMode.agent && to.usesRemoteMultiplexer) {
    final muxUnconfigured = mux.session.trim().isEmpty;
    nextMux = (
      session: seed(mux.session, agent.session),
      directory: seed(mux.directory, agent.directory),
      flags: seed(mux.flags, agent.flags),
      disableStatusBar: muxUnconfigured
          ? agent.disableStatusBar
          : mux.disableStatusBar,
    );
  }
  return (mux: nextMux, agent: nextAgent, agentBackend: nextAgentBackend);
}

import 'package:drift/drift.dart' show InvalidDataException;
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/port_proxy_name.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/presentation/screens/host_edit_logic.dart';
import 'package:monkeyssh/presentation/view_models/host_edit_view_model.dart';

void main() {
  test('screen field length validation counts the untrimmed value', () {
    for (final label in ['Label', 'Hostname', 'Username']) {
      expect(validateHostFieldLength('a' * 255, label), isNull);
      expect(
        validateHostFieldLength('${'a' * 255} ', label),
        '$label must be 255 characters or fewer',
      );
    }
  });
  test('save failure messages preserve specific exception precedence', () {
    expect(
      hostSaveFailureMessage(PortProxyNameConflictException('work')),
      'Proxy domain "work.localhost" is already in use. Choose a different proxy domain.',
    );
    expect(
      hostSaveFailureMessage(InvalidDataException('invalid')),
      'Couldn’t save this host. Check the field values and try again.',
    );
    expect(
      hostSaveFailureMessage(const FormatException('secret')),
      'Couldn’t read the saved credentials. Re-enter the password or import the SSH key again.',
    );
    expect(
      hostSaveFailureMessage(Exception('secret')),
      'Couldn’t save this host. Check the required fields and try again.',
    );
  });
  test('window configuration seeds only blank destination fields', () {
    const blank = (
      session: ' ',
      directory: '',
      flags: '',
      disableStatusBar: false,
    );
    const mux = (
      session: ' work ',
      directory: '~/project',
      flags: '-L work',
      disableStatusBar: true,
    );
    for (final mode in [
      HostStartupMode.tmux,
      HostStartupMode.monkeyMux,
      HostStartupMode.muxAuto,
    ]) {
      final toAgent = carryWindowConfigAcrossModeChange(
        from: mode,
        to: HostStartupMode.agent,
        mux: mux,
        agent: blank,
        agentBackend: RemoteMuxBackend.monkeyMux,
      );
      expect(toAgent.agent, mux);
      expect(toAgent.mux, mux);
      expect(
        toAgent.agentBackend,
        mode == HostStartupMode.tmux
            ? RemoteMuxBackend.tmux
            : RemoteMuxBackend.monkeyMux,
      );
      final toMux = carryWindowConfigAcrossModeChange(
        from: HostStartupMode.agent,
        to: mode,
        mux: blank,
        agent: mux,
        agentBackend: RemoteMuxBackend.tmux,
      );
      expect(toMux.mux, mux);
      expect(toMux.agent, mux);
    }
    const configured = (
      session: 'existing',
      directory: '',
      flags: '-L own',
      disableStatusBar: false,
    );
    final result = carryWindowConfigAcrossModeChange(
      from: HostStartupMode.tmux,
      to: HostStartupMode.agent,
      mux: mux,
      agent: configured,
      agentBackend: RemoteMuxBackend.monkeyMux,
    );
    expect(result.agent, (
      session: 'existing',
      directory: '~/project',
      flags: '-L own',
      disableStatusBar: false,
    ));
    expect(result.agentBackend, RemoteMuxBackend.monkeyMux);
    final unchanged = carryWindowConfigAcrossModeChange(
      from: HostStartupMode.none,
      to: HostStartupMode.agent,
      mux: mux,
      agent: blank,
      agentBackend: RemoteMuxBackend.tmux,
    );
    expect(unchanged.agent, blank);
  });
}

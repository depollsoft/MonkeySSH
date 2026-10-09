/// Route names for type-safe navigation.
abstract final class Routes {
  /// Home screen route.
  static const home = 'home';

  /// Lock screen route.
  static const lock = 'lock';

  /// Hosts list route.
  static const hosts = 'hosts';

  /// Add host route.
  static const hostAdd = 'host-add';

  /// Edit host route.
  static const hostEdit = 'host-edit';

  /// Import hosts from an OpenSSH client config.
  static const hostImportSshConfig = 'host-import-ssh-config';

  /// Terminal session route.
  static const terminal = 'terminal';

  /// SFTP browser route.
  static const sftp = 'sftp';

  /// Keys management route.
  static const keys = 'keys';

  /// Add key route.
  static const keyAdd = 'key-add';

  /// Snippets route.
  static const snippets = 'snippets';

  /// Full-screen ACP agent chat route.
  static const agentChat = 'agent-chat';

  /// Add snippet route.
  static const snippetAdd = 'snippet-add';

  /// Edit snippet route.
  static const snippetEdit = 'snippet-edit';

  /// Port forwards route.
  static const portForwards = 'port-forwards';

  /// Add port forward route.
  static const portForwardAdd = 'port-forward-add';

  /// Edit port forward route.
  static const portForwardEdit = 'port-forward-edit';

  /// Embedded port-forward browser route.
  static const portForwardBrowser = 'port-forward-browser';

  /// Settings route.
  static const settings = 'settings';

  /// App Review demo route.
  static const appReviewDemo = 'app-review-demo';

  /// Authentication setup route.
  static const authSetup = 'auth-setup';

  /// Upgrade route.
  static const upgrade = 'upgrade';
}

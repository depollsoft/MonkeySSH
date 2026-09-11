# MonkeySSH Privacy Policy

MonkeySSH is a local-first SSH client. The app is designed to help you connect to servers you configure, manage SSH keys, browse remote files, run coding agents on those servers in native chat or terminal windows, and resume terminal workflows without requiring a MonkeySSH cloud account.

## Information you provide

MonkeySSH stores the connection details you choose to save, such as host names, ports, usernames, labels, snippets, port-forwarding rules, trusted host keys, and SSH keys. These records are stored on your device so the app can connect to your hosts and restore your workspace.

When you connect to a server, your device sends the information required by SSH, SFTP, and port-forwarding protocols directly to the server you selected. MonkeySSH does not operate an SSH proxy for these connections.

## Credentials and keys

Saved credentials and private keys are stored locally using platform security features where available. MonkeySSH supports PIN and biometric app unlock to help protect local app data. You are responsible for the servers, accounts, and keys you add to the app.

## Files and clipboard

If you use SFTP, remote editing, transfer bundles, clipboard sync, agent attachments, or document import/export features, MonkeySSH processes the files or text you select to complete that action. File and clipboard data is handled for the requested transfer, attachment, or edit operation and is not sent to MonkeySSH-operated cloud services.

## Coding agents

Native agent windows and terminal launches run coding agents that are installed and signed in on your own server. Prompts, attachments you add, permission decisions, and the agent's responses travel over your SSH connection between your device and that server. The agent and its provider handle model requests under their own terms; MonkeySSH does not relay agent conversations through MonkeySSH-operated services.

Agent Management runs package-manager commands (npm, pipx, Homebrew, or the agent's own update command) on your server over SSH to install, repair, or update agents. Those commands download packages from the corresponding registries from your server, not from your device. Version checks query the same registries from your server.

## Purchases

If you purchase MonkeySSH Pro, Apple or Google processes the transaction through the applicable app store. MonkeySSH receives purchase entitlement information from the store so it can unlock Pro features. Payment details are handled by Apple or Google, not by MonkeySSH.

## Diagnostics and analytics

MonkeySSH does not include third-party advertising SDKs. Analytics and crash reporting are off by default. If you enable "Share analytics and crash reports" in Settings, MonkeySSH uses Firebase Analytics and Firebase Crashlytics to collect anonymous feature usage events and sanitized crash reports. This data helps understand which broad app areas are used, where setup or connection flows fail, how often terminal/SFTP/window-switching/agent-launch features are used, and where crashes happen.

Analytics events use coarse labels and buckets, such as feature names, auth-method category, error category, duration bucket, file-count bucket, size bucket, multiplexer backend, agent tool type, and purchase result category. Analytics and crash reports do not include hostnames, usernames, IP addresses you configure, commands, terminal output, remote file paths, file names, tmux session or window names, clipboard contents, passwords, passphrases, private keys, tokens, or raw SSH/SFTP/tmux data. You can turn sharing off in Settings; when it is off, MonkeySSH disables analytics and crash collection in the app.

App store platforms may also provide aggregate crash, purchase, and usage information to developers under their own privacy policies.

## Permissions

MonkeySSH may request device permissions only when needed for a feature you choose to use, such as:

- biometric authentication for unlocking the app
- files, documents, or photo library access for import, export, upload, download, transfer packages, and agent attachments
- camera, microphone, and location access only for pages in the in-app browser that you explicitly allow
- the current Wi-Fi network name, only when a host is configured to skip its jump host on networks you list
- notifications or Live Activities for connection status, terminal alerts, and agent activity such as a finished turn or a pending permission request

You can manage these permissions in your device settings.

## Data deletion

You can remove saved hosts, keys, snippets, settings, transfer bundles, and other local app data from within the app or by deleting the app from your device. Data stored on remote servers must be managed on those servers.

## Contact

For privacy or support questions, open an issue at:

https://github.com/depollsoft/MonkeySSH/issues

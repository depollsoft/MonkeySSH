// ignore_for_file: public_member_api_docs

// Public test-only keys generated with ssh-keygen. Never use for authentication
// outside tests. The encrypted copy uses one bcrypt round and the passphrase
// `correct`.

const sshEd25519PrivateKey = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCy0LzCJbFLU88xjh8ei9duo6y9ZbMYrO52Gw2cVZGr9wAAAKCpVtFcqVbR
XAAAAAtzc2gtZWQyNTUxOQAAACCy0LzCJbFLU88xjh8ei9duo6y9ZbMYrO52Gw2cVZGr9w
AAAEDJU2YF+wrjfIV6RGuy8Vj5XcdJtlmkC7USovpc0SrGc7LQvMIlsUtTzzGOHx6L126j
rL1lsxis7nYbDZxVkav3AAAAFm1vbmtleXNzaC10ZXN0LWZpeHR1cmUBAgMEBQYH
-----END OPENSSH PRIVATE KEY-----
''';

/// Passphrase protecting the encrypted fixture keys.
const sshKeyFixturePassphrase = 'correct';

const sshEd25519EncryptedPrivateKey = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBFEx5/gz
YH4/pb0urjz4uiAAAAAQAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAILLQvMIlsUtTzzGO
Hx6L126jrL1lsxis7nYbDZxVkav3AAAAoLtvxEiYSFsZFjELdypJCVfRc3v0xSWCHUgnTc
J8bySor9WIKTpUxttRiNjiDb6yN+HFQfzUfWvjhn+1tsKBDrUZo/qDEAJV/qG1d4z5Bky8
VBocnnKYQuN4yI2gkz19oeJD5QkkT0A7/7+E5TabgxYO9TxgXrTVSrAfui5lO6uXx+7qtr
g3SekvAsW6exyHZ/5ndWyZMUCBfB37UzHY1r8=
-----END OPENSSH PRIVATE KEY-----
''';

# Upstream source

Vendored from the `dartssh2` 4.1.0 archive on pub.dev
(sha256 `39359aceafcf5940b868249e3c9c6d86e4e0f989eec7417d033c943157c84c51`,
https://github.com/vicajilau/dartssh2). See `README.md` for the patch, which is
limited to `SSHAgentChannel` in `lib/src/ssh_agent.dart`, two additions in
`lib/src/ssh_channel.dart`, and the agent channel-open check in
`lib/src/ssh_client.dart`. Replace this directory with the released package
once an equivalent fix ships upstream.

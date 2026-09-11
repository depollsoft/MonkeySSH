// Generated PowerShell intentionally mixes raw and interpolated strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings, use_raw_strings
import 'dart:convert';

import 'windows_remote_powershell.dart';

/// Launches the stdin-delivered quota probe in the same environment as versions.
String buildWindowsAgentUsageCommand(Map<String, String> executables) {
  final input = base64.encode(utf8.encode(jsonEncode(executables)));
  final missingNode = base64.encode(
    utf8.encode(
      [
        for (final id in executables.keys)
          '__monkeyssh_usage__=${jsonEncode({'id': id, 'status': 'runtimeUnavailable'})}',
        '',
      ].join('\n'),
    ),
  );
  const bootstrap =
      "process.env.MONKEYSSH_USAGE_PROBE='1';"
      "const r=require('readline').createInterface({input:process.stdin});"
      "r.once('line',s=>{r.close();eval(Buffer.from(s,'base64').toString())})";
  return buildCompactWindowsPowerShellCommand(
    '$powerShellProfilePathPreamble'
    // An SSH service can miss fnm/Volta PATH entries. npm launchers also live
    // beside their node.exe; use a resolved CLI's installation as a fallback.
    r'$__flNode=(Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source;'
    'if (!\$__flNode) { '
    '\$__flAgents=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'$input\')) | ConvertFrom-Json; '
    r'foreach ($__flAgent in $__flAgents.PSObject.Properties) { '
    r"$__flCandidate=Join-Path (Split-Path -Parent $__flAgent.Value) 'node.exe'; "
    r'if (Test-Path -LiteralPath $__flCandidate -PathType Leaf) { $__flNode=$__flCandidate; break } } }; '
    'if (!\$__flNode) { '
    '\$__flBytes=[Convert]::FromBase64String(\'$missingNode\'); '
    r'[Console]::OpenStandardOutput().Write($__flBytes,0,$__flBytes.Length); exit 1 }; '
    r'try { [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false) } catch {}; '
    '& \$__flNode -e ${powerShellSingleQuote(bootstrap)} $input 2>\$null',
  );
}

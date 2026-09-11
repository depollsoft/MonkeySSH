import 'windows_remote_powershell.dart';

/// Best-effort cleanup appended after a verified Windows launcher update.
///
/// Keep builds used within seven days so another client has time to attach.
/// Windows refuses deletion of loaded executables; those remain for a later
/// connection to prune. Only recognized files and empty directories are removed.
String buildMonkeyMuxWindowsCleanupScript({
  required String installRoot,
  required String executablePath,
  required String platform,
}) =>
    '''
& {
  \$cleanupRoot = ${powerShellSingleQuote(installRoot)}
  \$cleanupCurrent = ${powerShellSingleQuote(executablePath)}
  \$cleanupPlatform = ${powerShellSingleQuote(platform)}
$_cleanupBody
}
''';

const _cleanupBody = r'''
  $removed = 0
  $retained = 0
  function Get-PlainItem([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
      return $item
    }
  }
  function Remove-EmptyDirectory([string]$Path) {
    try { [IO.Directory]::Delete($Path, $false) } catch { }
  }
  try {
    $cleanupRoot = [IO.Path]::GetFullPath($cleanupRoot)
    $cleanupCurrent = [IO.Path]::GetFullPath($cleanupCurrent)
    # Do not traverse junctions or symbolic links, including root ancestors.
    $ancestor = [IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($cleanupCurrent))
    while ($null -ne $ancestor) {
      if ($null -eq (Get-PlainItem $ancestor.FullName)) { return }
      $ancestor = $ancestor.Parent
    }
    $current = Get-PlainItem $cleanupCurrent
    if ($null -eq $current -or $current.PSIsContainer) { return }
    $currentDirectory = $current.Directory.FullName
    $currentLease = Join-Path $currentDirectory '.last-used'
    if (Test-Path -LiteralPath $currentLease) {
      if ($null -eq (Get-PlainItem $currentLease)) { return }
    }
    # The marker records reuse without modifying a locked executable.
    [IO.File]::WriteAllText($currentLease, '')
    $cutoff = [DateTime]::UtcNow.AddDays(-7)
    foreach ($version in @(Get-ChildItem -LiteralPath $cleanupRoot -Directory -Force)) {
      if ($version.Name -notmatch '^[0-9]+[.][0-9]+[.][0-9]+$' -or
          $null -eq (Get-PlainItem $version.FullName)) { continue }
      $platformDirectory = Get-PlainItem (Join-Path $version.FullName $cleanupPlatform)
      if ($null -eq $platformDirectory -or -not $platformDirectory.PSIsContainer) { continue }
      # Include the original version/platform/monkeymux.exe layout.
      $directories = @($platformDirectory) + @(
        Get-ChildItem -LiteralPath $platformDirectory.FullName -Directory -Force |
          Where-Object { $_.Name -match '^[0-9a-fA-F]{64}$' -and
            $null -ne (Get-PlainItem $_.FullName) }
      )
      foreach ($directory in $directories) {
        $candidate = Join-Path $directory.FullName 'monkeymux.exe'
        if ([string]::Equals($candidate, $cleanupCurrent, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $binary = Get-PlainItem $candidate
        if ($null -eq $binary -or $binary.PSIsContainer) { continue }
        $leasePath = Join-Path $directory.FullName '.last-used'
        $lease = Get-PlainItem $leasePath
        if ((Test-Path -LiteralPath $leasePath) -and ($null -eq $lease -or $lease.PSIsContainer)) { continue }
        if ($binary.LastWriteTimeUtc -ge $cutoff -or
            ($null -ne $lease -and $lease.LastWriteTimeUtc -ge $cutoff)) { continue }
        try {
          # No force, process termination, or recursive directory deletion.
          # DeleteFile refuses loaded images and handles without delete sharing.
          [IO.File]::Delete($candidate)
          $removed++
          if ($null -ne $lease) { [IO.File]::Delete($leasePath) }
          if ($directory.FullName -ne $platformDirectory.FullName) {
            Remove-EmptyDirectory $directory.FullName
          }
        } catch { $retained++ }
      }
      Remove-EmptyDirectory $platformDirectory.FullName
      Remove-EmptyDirectory $version.FullName
    }
  } catch { $retained++ }
  Write-Output "MONKEYMUX_CLEANUP:$removed`:$retained"
''';

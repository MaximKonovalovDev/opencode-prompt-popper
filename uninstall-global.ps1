# Removes Prompt Popper: kills the tray app, deletes the startup link, commands, and plugin.
# Your prompts.json is backed up into the global folder first. Reinstall anytime with install-global.ps1.
# Usage: pwsh -NoProfile -File uninstall-global.ps1

$ErrorActionPreference = 'Continue'
$DestDir = Join-Path $HOME '.config\opencode\prompt-popper'
$CommandsDir = Join-Path $HOME '.config\opencode\commands'
$PluginFile = Join-Path $HOME '.config\opencode\plugin\prompt-popper.mjs'
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\OpencodePromptPopper.lnk'

# Back up prompts before deleting.
$dstPrompts = Join-Path $DestDir 'prompts.json'
if (Test-Path $dstPrompts) {
  $bak = $dstPrompts + ".uninstall-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
  Copy-Item $dstPrompts $bak -Force
  Write-Host "Prompts backed up to: $bak"
}

$old = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*prompt-popper.ps1*' }
foreach ($p in $old) { try { Stop-Process -Id $p.ProcessId -Force; Write-Host "Stopped tray PID $($p.ProcessId)." } catch {} }

if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host 'Startup link removed.' }
if (Test-Path $PluginFile) { Remove-Item $PluginFile -Force; Write-Host 'Plugin removed.' }
foreach ($f in @('pp-go','pp-fix','pp-explain','pp-review','pp-test','pp-plan','pp-commit','pp-clean','pp-summarize','pp-error')) {
  $c = Join-Path $CommandsDir "$f.md"
  if (Test-Path $c) { Remove-Item $c -Force }
}
Write-Host 'Slash commands removed.'
Write-Host 'Done. Global folder kept (with log + backups): ' $DestDir

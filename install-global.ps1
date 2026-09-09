# Installs Prompt Popper GLOBALLY: tray app + slash commands + Desktop agent tools + startup shortcut.
# Run once: pwsh -NoProfile -STA -File install-global.ps1
# Safe to re-run: backs up a locally-edited prompts.json, overwrites the rest, restarts the tray.

$ErrorActionPreference = 'Stop'
$SrcDir = Split-Path -Parent $PSCommandPath
$DestDir = Join-Path $HOME '.config\opencode\prompt-popper'
$CommandsDir = Join-Path $HOME '.config\opencode\commands'
$PluginDir = Join-Path $HOME '.config\opencode\plugin'
$StartupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'

New-Item -ItemType Directory -Force $DestDir | Out-Null
New-Item -ItemType Directory -Force $CommandsDir | Out-Null
New-Item -ItemType Directory -Force $PluginDir | Out-Null

# Keep the user's on-machine edits: back up prompts.json if it differs from the repo copy.
$srcPrompts = Join-Path $SrcDir 'prompts.json'
$dstPrompts = Join-Path $DestDir 'prompts.json'
if ((Test-Path $dstPrompts) -and (Test-Path $srcPrompts)) {
  $a = (Get-FileHash $dstPrompts).Hash; $b = (Get-FileHash $srcPrompts).Hash
  if ($a -ne $b) {
    $bak = $dstPrompts + ".local-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item $dstPrompts $bak -Force
    Write-Host "Your local prompts.json backed up to: $bak"
  }
}

Copy-Item (Join-Path $SrcDir 'prompt-popper.ps1') (Join-Path $DestDir 'prompt-popper.ps1') -Force
Copy-Item $srcPrompts $dstPrompts -Force
Copy-Item (Join-Path $SrcDir 'start-popper.cmd') (Join-Path $DestDir 'start-popper.cmd') -Force
if (Test-Path (Join-Path $SrcDir 'icon.ico')) { Copy-Item (Join-Path $SrcDir 'icon.ico') (Join-Path $DestDir 'icon.ico') -Force }

# Same prompts as slash commands (/pp-go, ...) — native in Opencode Desktop, TUI, web.
$prompts = (Get-Content $srcPrompts -Raw | ConvertFrom-Json).prompts
foreach ($p in $prompts) {
  $name = [string]$p.command
  if (-not $name) { continue }
  $body = "---`ndescription: Prompt Popper premade prompt: $($p.label)`n---`n`n$($p.text)`n"
  Set-Content (Join-Path $CommandsDir "$name.md") $body -Encoding UTF8
}
Write-Host "Slash commands: $($prompts.Count) files in $CommandsDir (try /pp-go)"

# Desktop agent tools (pp_list, pp_get) — model-side, so they work in Desktop too.
$pluginSrc = Join-Path $SrcDir 'plugin\prompt-popper.mjs'
if (Test-Path $pluginSrc) {
  $node = (Get-Command node -ErrorAction SilentlyContinue).Source
  if ($node) {
    & $node --check $pluginSrc 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "plugin failed node --check" }
    Write-Host 'Plugin syntax OK.'
  } else { Write-Host 'node not found, skipping plugin syntax check.' }
  Copy-Item $pluginSrc (Join-Path $PluginDir 'prompt-popper.mjs') -Force
  Write-Host "Plugin installed: $PluginDir\prompt-popper.mjs"
}

# Desktop double-click bat (pops the panel, starts the tray if needed).
$batSrc = Join-Path $SrcDir 'ShowPopper.bat'
if (Test-Path $batSrc) {
  $desk = [Environment]::GetFolderPath('Desktop')
  Copy-Item $batSrc (Join-Path $desk 'PromptPopper.bat') -Force
  Write-Host "Desktop bat: $desk\PromptPopper.bat"
}

# Startup shortcut so the tray icon returns after reboot.
$lnk = Join-Path $StartupDir 'OpencodePromptPopper.lnk'
$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($lnk)
$sc.TargetPath = Join-Path $DestDir 'start-popper.cmd'
$sc.WorkingDirectory = $DestDir
$sc.Description = 'Opencode Prompt Popper (tray icon + hotkeys)'
$sc.Save()
Write-Host "Startup link: $lnk"

# Restart the tray app on the new code.
$old = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*prompt-popper.ps1*' }
foreach ($p in $old) { try { Stop-Process -Id $p.ProcessId -Force } catch {} }
Start-Sleep -Seconds 2
Start-Process (Join-Path $DestDir 'start-popper.cmd')
Write-Host 'Tray app restarted. Look near the clock for the >_ icon.'
Write-Host "Installed to: $DestDir"

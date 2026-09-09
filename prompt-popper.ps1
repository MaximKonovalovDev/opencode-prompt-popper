# Opencode Prompt Popper v2 — global tray icon + searchable popup + hotkeys + GitHub sync.
# No installs. Only built-in Windows Forms + gh CLI (for sync). Runs STA.
# Left-click tray icon (or Ctrl+Alt+P) for the popup. Type to filter, Enter to paste.
# Click a prompt (or Ctrl+Alt+1..8) to paste into the last focused app + press Enter.

param()

# Must run STA for Clipboard + Windows Forms. Relaunch with -STA if needed.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if (-not $pwsh) { $pwsh = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
  Start-Process $pwsh ('-NoProfile -STA -WindowStyle Hidden -File "' + $PSCommandPath + '"')
  exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $PSCommandPath
$PromptsFile = Join-Path $ScriptDir 'prompts.json'
$LogFile = Join-Path $ScriptDir 'prompt-popper.log'
$IconFile = Join-Path $ScriptDir 'icon.ico'

# Single instance only.
$mutex = New-Object Threading.Mutex($false, 'Global\OpencodePromptPopper')
if (-not $mutex.WaitOne(0)) {
  [Windows.Forms.MessageBox]::Show('Prompt Popper is already running (check the tray icons near the clock).', 'Prompt Popper')
  exit
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Win32 {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
}
'@

function Write-PopLog($msg) {
  try { Add-Content $LogFile ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

$script:prompts = @()
$script:enterDefault = $true
$script:syncRepo = ''
$script:syncOnStart = $false

function Load-Prompts {
  $json = Get-Content $PromptsFile -Raw | ConvertFrom-Json
  $script:prompts = @($json.prompts)
  if ($json.settings) {
    if ($null -ne $json.settings.pressEnterByDefault) { $script:enterDefault = [bool]$json.settings.pressEnterByDefault }
    if ($json.settings.syncRepo) { $script:syncRepo = [string]$json.settings.syncRepo }
    if ($null -ne $json.settings.syncOnStart) { $script:syncOnStart = [bool]$json.settings.syncOnStart }
  }
  # Hotkey labels for the first 8 only.
  for ($i = 0; $i -lt $script:prompts.Count; $i++) {
    $hk = if ($i -lt 8) { "Ctrl+Alt+$($i + 1)" } else { 'search' }
    $script:prompts[$i] | Add-Member -NotePropertyName '_hotkey' -NotePropertyValue $hk -Force
  }
}

function Should-Enter($p) {
  if ($null -ne $p.enter) { return [bool]$p.enter }
  return $script:enterDefault
}

# Remember the last non-popper window so paste goes back to Opencode.
$script:lastAppWindow = [IntPtr]::Zero

function Update-LastWindow($popupHandle) {
  $fg = [Win32]::GetForegroundWindow()
  if ($fg -ne [IntPtr]::Zero -and $fg -ne $popupHandle) { $script:lastAppWindow = $fg }
}

function Set-ClipboardRetry($text) {
  for ($try = 1; $try -le 3; $try++) {
    try { [Windows.Forms.Clipboard]::SetText($text); return $true }
    catch { Start-Sleep -Milliseconds 120 }
  }
  return $false
}

function Paste-Prompt($p) {
  if (-not $p) { return }
  try {
    $popup.Hide()
    Start-Sleep -Milliseconds 80
    if ($script:lastAppWindow -ne [IntPtr]::Zero) { [Win32]::SetForegroundWindow($script:lastAppWindow) | Out-Null }
    Start-Sleep -Milliseconds 180
    if (-not (Set-ClipboardRetry ([string]$p.text))) { throw 'clipboard busy after 3 tries' }
    Start-Sleep -Milliseconds 150
    [Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 150
    if (Should-Enter $p) { [Windows.Forms.SendKeys]::SendWait('{ENTER}') }
    Write-PopLog ("pasted: " + $p.label)
  } catch {
    Write-PopLog ("PASTE FAILED: " + $_.Exception.Message)
    [Windows.Forms.MessageBox]::Show("Paste failed: $($_.Exception.Message)", 'Prompt Popper')
  }
}

function Sync-FromGitHub {
  if (-not $script:syncRepo) {
    [Windows.Forms.MessageBox]::Show('No syncRepo in prompts.json settings.', 'Prompt Popper')
    return
  }
  $gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
  if (-not $gh) {
    [Windows.Forms.MessageBox]::Show('gh CLI not found. Install it or edit prompts.json by hand.', 'Prompt Popper')
    return
  }
  try {
    $b64 = & $gh api ("repos/" + $script:syncRepo + "/contents/prompts.json") --jq '.content' 2>&1
    if ($LASTEXITCODE -ne 0) { throw [string]$b64 }
    $clean = ([string]$b64) -replace '\s', ''
    $bytes = [Convert]::FromBase64String($clean)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $parsed = $text | ConvertFrom-Json
    if (-not $parsed.prompts -or $parsed.prompts.Count -eq 0) { throw 'downloaded file has no prompts' }
    Copy-Item $PromptsFile ($PromptsFile + ".backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
    Set-Content $PromptsFile $text -Encoding UTF8
    Load-Prompts
    Rebuild-Menu
    Apply-Filter
    Write-PopLog ("synced from GitHub: " + $script:prompts.Count + " prompts")
    $tray.ShowBalloonTip(3000, 'Prompt Popper', ("Synced " + $script:prompts.Count + " prompts from GitHub."), [Windows.Forms.ToolTipIcon]::Info)
  } catch {
    Write-PopLog ("SYNC FAILED: " + $_.Exception.Message)
    [Windows.Forms.MessageBox]::Show("Sync failed: $($_.Exception.Message)", 'Prompt Popper')
  }
}

# --- Popup: search box + list ---
$popup = New-Object Windows.Forms.Form
$popup.Text = 'Prompts'
$popup.FormBorderStyle = 'FixedToolWindow'
$popup.ShowInTaskbar = $false
$popup.TopMost = $true
$popup.StartPosition = 'Manual'
$popup.ClientSize = New-Object Drawing.Size(300, 320)
$popup.Add_Deactivate({ $popup.Hide() })

$search = New-Object Windows.Forms.TextBox
$search.Location = New-Object Drawing.Point(8, 8)
$search.Size = New-Object Drawing.Size(284, 24)
if ($PSVersionTable.PSEdition -eq 'Core') { $search.PlaceholderText = 'Type to filter...' }
$popup.Controls.Add($search)

$list = New-Object Windows.Forms.ListBox
$list.Location = New-Object Drawing.Point(8, 40)
$list.Size = New-Object Drawing.Size(284, 272)
$popup.Controls.Add($list)

$script:shown = @()

function Apply-Filter {
  $q = $search.Text.Trim().ToLower()
  $list.Items.Clear()
  $script:shown = @()
  for ($i = 0; $i -lt $script:prompts.Count; $i++) {
    $p = $script:prompts[$i]
    if ($q -eq '' -or $p.label.ToLower().Contains($q)) {
      $list.Items.Add("$($p.label)  ($($p._hotkey))") | Out-Null
      $script:shown += $p
    }
  }
  if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
}

function Paste-Selected {
  if ($list.SelectedIndex -ge 0 -and $list.SelectedIndex -lt $script:shown.Count) {
    Paste-Prompt $script:shown[$list.SelectedIndex]
  }
}

$search.Add_TextChanged({ Apply-Filter })
$search.Add_KeyDown({
  param($s, $e)
  if ($e.KeyCode -eq [Windows.Forms.Keys]::Enter) { Paste-Selected; $e.Handled = $true }
  elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Down) { $list.Focus(); if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 } }
  elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) { $popup.Hide() }
})
$list.Add_DoubleClick({ Paste-Selected })
$list.Add_KeyDown({
  param($s, $e)
  if ($e.KeyCode -eq [Windows.Forms.Keys]::Enter) { Paste-Selected; $e.Handled = $true }
  elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) { $popup.Hide() }
})

function Show-Popup {
  $search.Text = ''
  Apply-Filter
  $pos = [Windows.Forms.Cursor]::Position
  $x = $pos.X - 150
  if ($x -lt 0) { $x = 0 }
  $y = $pos.Y - ($popup.Height + 20)
  if ($y -lt 0) { $y = $pos.Y + 20 }
  $popup.Location = New-Object Drawing.Point($x, $y)
  $popup.Show()
  $popup.Activate()
  $search.Focus()
}

# --- Tray icon ---
$tray = New-Object Windows.Forms.NotifyIcon
if (Test-Path $IconFile) { $tray.Icon = New-Object Drawing.Icon($IconFile) }
else { $tray.Icon = [Drawing.SystemIcons]::Application }
$tray.Text = 'Opencode Prompt Popper'
$tray.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip

function Rebuild-Menu {
  $menu.Items.Clear()
  foreach ($pp in $script:prompts) {
    $pp = $p
    $item = $menu.Items.Add("$($pp.label)  ($($pp._hotkey))")
    $item.Add_Click({ Paste-Prompt $pp }.GetNewClosure())
  }
  $menu.Items.Add('-') | Out-Null
  $menu.Items.Add('Show popup (Ctrl+Alt+P)', $null, { Show-Popup }) | Out-Null
  $menu.Items.Add('Sync from GitHub', $null, { Sync-FromGitHub }) | Out-Null
  $menu.Items.Add('Reload prompts', $null, { Load-Prompts; Rebuild-Menu; Apply-Filter }) | Out-Null
  $menu.Items.Add('Edit prompts.json', $null, { Start-Process notepad.exe $PromptsFile }) | Out-Null
  $menu.Items.Add('Open log', $null, { if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } }) | Out-Null
  $menu.Items.Add('-') | Out-Null
  $menu.Items.Add('Restart', $null, {
    $tray.Visible = $false
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { $pwsh = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
    Start-Process $pwsh ('-NoProfile -STA -WindowStyle Hidden -File "' + $PSCommandPath + '"')
    [Windows.Forms.Application]::Exit()
  }) | Out-Null
  $menu.Items.Add('Quit', $null, { $tray.Visible = $false; [Windows.Forms.Application]::Exit() }) | Out-Null
}

$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({
  param($s, $e)
  if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-Popup }
})

# --- Track last focused window (so paste returns to Opencode) ---
$trackTimer = New-Object Windows.Forms.Timer
$trackTimer.Interval = 500
$trackTimer.Add_Tick({ Update-LastWindow $popup.Handle })
$trackTimer.Start()

# --- Global hotkeys via key-state poll (no driver, no admin) ---
$VK_CONTROL = 0x11; $VK_ALT = 0x12; $VK_P = 0x50
$script:wasDown = @{}
function Key-Held($vk) { ([Win32]::GetAsyncKeyState($vk) -band 0x8000) -ne 0 }

$hotTimer = New-Object Windows.Forms.Timer
$hotTimer.Interval = 80
$hotTimer.Add_Tick({
  Update-LastWindow $popup.Handle
  $ctrl = Key-Held $VK_CONTROL
  $alt = Key-Held $VK_ALT
  if (-not ($ctrl -and $alt)) { $script:wasDown.Clear(); return }
  $max = [Math]::Min(8, $script:prompts.Count)
  for ($i = 0; $i -lt $max; $i++) {
    $vk = 0x31 + $i  # 1..8
    $key = "d$vk"
    $down = Key-Held $vk
    if ($down -and -not $script:wasDown[$key]) { Paste-Prompt $script:prompts[$i] }
    $script:wasDown[$key] = $down
  }
  $pDown = Key-Held $VK_P
  if ($pDown -and -not $script:wasDown['p']) { Show-Popup }
  $script:wasDown['p'] = $pDown
})
$hotTimer.Start()

# --- Start ---
try {
  Load-Prompts
} catch {
  Write-PopLog ("START FAILED: " + $_.Exception.Message)
  [Windows.Forms.MessageBox]::Show("Bad prompts.json: $($_.Exception.Message)", 'Prompt Popper')
  $tray.Visible = $false
  $mutex.ReleaseMutex()
  exit 1
}
Rebuild-Menu
Apply-Filter
Write-PopLog ("started with " + $script:prompts.Count + " prompts")
if ($script:syncOnStart) { Sync-FromGitHub }

$tray.ShowBalloonTip(3000, 'Prompt Popper', ("Running with " + $script:prompts.Count + " prompts. Click the icon or press Ctrl+Alt+P."), [Windows.Forms.ToolTipIcon]::Info)

[Windows.Forms.Application]::Run()
$tray.Visible = $false
$mutex.ReleaseMutex()

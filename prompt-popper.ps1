# Opencode Prompt Popper v4 — glass hover panel + hotkeys + GitHub sync.
# No installs. Only built-in Windows Forms + gh CLI (for sync). Runs STA.
# Left-click tray icon (or Ctrl+Alt+P): small glass panel hovers always on top.
# Click a button, type to filter, pick a chip, Enter pastes. Ctrl+Alt+1..8 anywhere.
# Design cues: Wox Glass dark (acrylic + transparent panels) + Raycast palette
# (near-black canvas, hairline borders, keycap hints).
# Preview: pwsh -STA -File prompt-popper.ps1 -Preview  |  Off-screen shot: -Shot out.png

param([switch]$Preview, [string]$Shot)

# Must run STA for Clipboard + Windows Forms. Relaunch with -STA if needed.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if (-not $pwsh) { $pwsh = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
  $flag = if ($Preview) { ' -Preview' } elseif ($Shot) { " -Shot `"$Shot`"" } else { '' }
  Start-Process $pwsh ('-NoProfile -STA -WindowStyle Hidden -File "' + $PSCommandPath + '"' + $flag)
  exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $PSCommandPath
$PromptsFile = Join-Path $ScriptDir 'prompts.json'
$LogFile = Join-Path $ScriptDir 'prompt-popper.log'
$IconFile = Join-Path $ScriptDir 'icon.ico'

# Single instance only (preview/shot may run next to the tray).
if (-not $Preview -and -not $Shot) {
  $mutex = New-Object Threading.Mutex($false, 'Global\OpencodePromptPopper')
  if (-not $mutex.WaitOne(0)) {
    [Windows.Forms.MessageBox]::Show('Prompt Popper is already running (check the tray icons near the clock).', 'Prompt Popper')
    exit
  }
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Win32 {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("user32.dll")] public static extern bool ReleaseCapture();
  [DllImport("user32.dll")] public static extern int SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);
}
public static class Acrylic {
  [StructLayout(LayoutKind.Sequential)] struct AccentPolicy { public int AccentState; public int AccentFlags; public int GradientColor; public int AnimationId; }
  [StructLayout(LayoutKind.Sequential)] struct WcaData { public int Attribute; public IntPtr Data; public int SizeOfData; }
  [DllImport("user32.dll")] static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WcaData data);
  public static bool Enable(IntPtr hwnd, int alpha, int rgb) {
    try {
      var policy = new AccentPolicy { AccentState = 4, AccentFlags = 0, GradientColor = (alpha << 24) | rgb, AnimationId = 0 };
      int size = Marshal.SizeOf(policy);
      IntPtr ptr = Marshal.AllocHGlobal(size);
      Marshal.StructureToPtr(policy, ptr, false);
      var data = new WcaData { Attribute = 19, Data = ptr, SizeOfData = size };
      int r = SetWindowCompositionAttribute(hwnd, ref data);
      Marshal.FreeHGlobal(ptr);
      return r != 0;
    } catch { return false; }
  }
}
'@

# Theme: near-black canvas, hairline borders, one green accent.
$C_BG     = [Drawing.Color]::FromArgb(0x0B, 0x0B, 0x10)
$C_ROW    = [Drawing.Color]::FromArgb(0x16, 0x16, 0x1F)
$C_HOVER  = [Drawing.Color]::FromArgb(0x23, 0x23, 0x2F)
$C_LINE   = [Drawing.Color]::FromArgb(0x2A, 0x2A, 0x35)
$C_ACCENT = [Drawing.Color]::FromArgb(0xA6, 0xE3, 0xA1)
$C_TEXT   = [Drawing.Color]::FromArgb(0xE6, 0xE6, 0xED)
$C_DIM    = [Drawing.Color]::FromArgb(0x8A, 0x8A, 0x99)
$C_BOX    = [Drawing.Color]::FromArgb(0x13, 0x13, 0x1B)
$C_CAT    = @{
  'Act'   = [Drawing.Color]::FromArgb(0xA6, 0xE3, 0xA1)
  'Think' = [Drawing.Color]::FromArgb(0x89, 0xB4, 0xFA)
  'Tidy'  = [Drawing.Color]::FromArgb(0xF9, 0xE2, 0xAF)
  'Other' = [Drawing.Color]::FromArgb(0xCB, 0xA6, 0xF7)
}

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
  for ($i = 0; $i -lt $script:prompts.Count; $i++) {
    $hk = if ($i -lt 8) { "$($i + 1)" } else { '' }
    $script:prompts[$i] | Add-Member -NotePropertyName '_hotkey' -NotePropertyValue $hk -Force
    if (-not $script:prompts[$i].category) { $script:prompts[$i] | Add-Member -NotePropertyName 'category' -NotePropertyValue 'Other' -Force }
  }
}

function Cat-Color($cat) {
  if ($C_CAT.ContainsKey($cat)) { return $C_CAT[$cat] }
  return $C_CAT['Other']
}

function Should-Enter($p) {
  if ($null -ne $p.enter) { return [bool]$p.enter }
  return $script:enterDefault
}

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
    if ($Preview -or $Shot) { $popup.Hide() }
    else {
      $popup.Hide()
      Start-Sleep -Milliseconds 80
      if ($script:lastAppWindow -ne [IntPtr]::Zero) { [Win32]::SetForegroundWindow($script:lastAppWindow) | Out-Null }
      Start-Sleep -Milliseconds 180
    }
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

# --- Popup: small glass hover panel, always on top, never auto-hides ---
$popup = New-Object Windows.Forms.Form
$popup.Text = 'Prompt Popper'
$popup.FormBorderStyle = 'None'
$popup.ShowInTaskbar = $false
$popup.TopMost = $true
$popup.BackColor = $C_BG
$popup.Opacity = 0.9
$popup.ClientSize = New-Object Drawing.Size(308, 428)
$popup.Font = New-Object Drawing.Font('Segoe UI', 9)

function Set-Rounded($form, $radius) {
  try {
    $w = $form.ClientSize.Width; $h = $form.ClientSize.Height
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($w - $d, 0, $d, $d, 270, 90)
    $path.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
    $path.AddArc(0, $h - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $form.Region = New-Object Drawing.Region($path)
  } catch {}
}
$popup.Add_Shown({
  Set-Rounded $popup 14
  try { [Acrylic]::Enable($popup.Handle, 0xB4, 0x0B0B10) | Out-Null } catch {}
})
$popup.Add_Resize({ Set-Rounded $popup 14 })
$popup.Add_Paint({
  param($s, $e)
  try {
    $pen = New-Object Drawing.Pen($C_LINE, 1)
    $r = New-Object Drawing.Rectangle(1, 1, ($s.ClientSize.Width - 3), ($s.ClientSize.Height - 3))
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $d = 28
    $path.AddArc($r.X, $r.Y, $d, $d, 180, 90)
    $path.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
    $path.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $e.Graphics.DrawPath($pen, $path)
    $pen.Dispose(); $path.Dispose()
  } catch {}
})

# Header (drag to move).
$header = New-Object Windows.Forms.Panel
$header.Location = New-Object Drawing.Point(0, 0)
$header.Size = New-Object Drawing.Size(308, 38)
$header.BackColor = [Drawing.Color]::Transparent
$popup.Controls.Add($header)

$title = New-Object Windows.Forms.Label
$title.Text = '>_ popper'
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 11)
$title.ForeColor = $C_ACCENT
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(12, 8)
$title.BackColor = [Drawing.Color]::Transparent
$header.Controls.Add($title)

$closeBtn = New-Object Windows.Forms.Label
$closeBtn.Text = 'x'
$closeBtn.Font = New-Object Drawing.Font('Segoe UI', 11)
$closeBtn.ForeColor = $C_DIM
$closeBtn.AutoSize = $true
$closeBtn.Location = New-Object Drawing.Point(284, 7)
$closeBtn.Cursor = 'Hand'
$closeBtn.BackColor = [Drawing.Color]::Transparent
$closeBtn.Add_Click({ $popup.Hide() })
$closeBtn.Add_MouseEnter({ $closeBtn.ForeColor = [Drawing.Color]::FromArgb(0xF3, 0x8B, 0xA8) })
$closeBtn.Add_MouseLeave({ $closeBtn.ForeColor = $C_DIM })
$header.Controls.Add($closeBtn)

$drag = {
  if ([Windows.Forms.MouseButtons]::Left -eq [Windows.Forms.Control]::MouseButtons) {
    [Win32]::ReleaseCapture() | Out-Null
    [Win32]::SendMessage($popup.Handle, 0xA1, 0x2, 0) | Out-Null
  }
}
$header.Add_MouseMove($drag)
$title.Add_MouseMove($drag)

# Search box.
$search = New-Object Windows.Forms.TextBox
$search.Location = New-Object Drawing.Point(12, 42)
$search.Size = New-Object Drawing.Size(284, 24)
$search.Font = New-Object Drawing.Font('Segoe UI', 9)
$search.BackColor = $C_BOX
$search.ForeColor = $C_TEXT
$search.BorderStyle = 'FixedSingle'
$popup.Controls.Add($search)
if ($PSVersionTable.PSEdition -eq 'Core') { try { $search.PlaceholderText = 'Type to filter...' } catch {} }

# Category chips.
$chips = New-Object Windows.Forms.FlowLayoutPanel
$chips.Location = New-Object Drawing.Point(12, 72)
$chips.Size = New-Object Drawing.Size(284, 28)
$chips.BackColor = [Drawing.Color]::Transparent
$popup.Controls.Add($chips)

$script:activeCat = 'All'

function Build-Chips {
  $chips.Controls.Clear()
  $cats = @('All') + @($script:prompts | ForEach-Object { $_.category } | Select-Object -Unique)
  foreach ($c in $cats) {
    $cc = $c
    $b = New-Object Windows.Forms.Label
    $b.Text = "  $cc  "
    $b.AutoSize = $true
    $b.Font = New-Object Drawing.Font('Segoe UI Semibold', 8)
    $b.Cursor = 'Hand'
    $b.Margin = New-Object Windows.Forms.Padding(0, 4, 6, 0)
    $b.Padding = New-Object Windows.Forms.Padding(4, 3, 4, 3)
    if ($cc -eq $script:activeCat) { $b.BackColor = $C_ACCENT; $b.ForeColor = [Drawing.Color]::Black }
    elseif ($cc -ne 'All') { $b.BackColor = $C_ROW; $b.ForeColor = (Cat-Color $cc) }
    else { $b.BackColor = $C_ROW; $b.ForeColor = $C_TEXT }
    $b.Add_Click({ $script:activeCat = $cc; Build-Chips; Apply-Filter; $search.Focus() }.GetNewClosure())
    $chips.Controls.Add($b)
  }
}

# Prompt buttons (scrollable rows).
$rows = New-Object Windows.Forms.FlowLayoutPanel
$rows.Location = New-Object Drawing.Point(12, 104)
$rows.Size = New-Object Drawing.Size(284, 292)
$rows.FlowDirection = 'TopDown'
$rows.WrapContents = $false
$rows.AutoScroll = $true
$rows.BackColor = [Drawing.Color]::Transparent
$popup.Controls.Add($rows)

$script:shown = @()
$script:selIdx = -1

function Paint-Row($panel, $state) {
  $edge = $panel.Controls | Where-Object { $_.Tag -eq 'edge' } | Select-Object -First 1
  if ($state -eq 'base') { $panel.BackColor = $C_ROW; if ($edge) { $edge.Visible = $false } }
  else { $panel.BackColor = $C_HOVER; if ($edge) { $edge.Visible = $true } }
}

function Set-Selected($idx) {
  $script:selIdx = $idx
  for ($k = 0; $k -lt $rows.Controls.Count; $k++) {
    if ($k -eq $idx) { Paint-Row $rows.Controls[$k] 'selected' } else { Paint-Row $rows.Controls[$k] 'base' }
  }
}

function Apply-Filter {
  $q = $search.Text.Trim().ToLower()
  $rows.Controls.Clear()
  $script:shown = @()
  foreach ($p in $script:prompts) {
    if ($script:activeCat -ne 'All' -and $p.category -ne $script:activeCat) { continue }
    if ($q -ne '' -and -not ($p.label.ToLower().Contains($q))) { continue }
    $script:shown += $p
  }
  for ($i = 0; $i -lt $script:shown.Count; $i++) {
    $pp = $script:shown[$i]
    $ii = $i
    $row = New-Object Windows.Forms.Panel
    $row.Size = New-Object Drawing.Size(260, 42)
    $row.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 6)
    $row.Cursor = 'Hand'
    $row.BackColor = $C_ROW

    $edge = New-Object Windows.Forms.Panel
    $edge.Size = New-Object Drawing.Size(3, 42)
    $edge.Location = New-Object Drawing.Point(0, 0)
    $edge.BackColor = $C_ACCENT
    $edge.Tag = 'edge'
    $edge.Visible = $false
    $row.Controls.Add($edge)

    $dot = New-Object Windows.Forms.Label
    $dot.Text = '●'
    $dot.Font = New-Object Drawing.Font('Segoe UI', 8)
    $dot.ForeColor = (Cat-Color $pp.category)
    $dot.AutoSize = $true
    $dot.Location = New-Object Drawing.Point(11, 12)
    $dot.BackColor = [Drawing.Color]::Transparent
    $row.Controls.Add($dot)

    $name = New-Object Windows.Forms.Label
    $name.Text = $pp.label
    $name.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
    $name.ForeColor = $C_TEXT
    $name.AutoSize = $false
    $name.Size = New-Object Drawing.Size(170, 24)
    $name.Location = New-Object Drawing.Point(30, 9)
    $name.BackColor = [Drawing.Color]::Transparent
    $row.Controls.Add($name)

    if ($pp._hotkey) {
      $kbd = New-Object Windows.Forms.Label
      $kbd.Text = $pp._hotkey
      $kbd.Font = New-Object Drawing.Font('Segoe UI', 8)
      $kbd.ForeColor = $C_DIM
      $kbd.BackColor = $C_BOX
      $kbd.BorderStyle = 'FixedSingle'
      $kbd.TextAlign = 'MiddleCenter'
      $kbd.AutoSize = $false
      $kbd.Size = New-Object Drawing.Size(24, 18)
      $kbd.Location = New-Object Drawing.Point(228, 12)
      $row.Controls.Add($kbd)
      $kbd.Add_Click({ Paste-Prompt $pp }.GetNewClosure())
      $kbd.Add_MouseEnter({ Set-Selected $ii }.GetNewClosure())
    }

    $row.Add_Click({ Paste-Prompt $pp }.GetNewClosure())
    $name.Add_Click({ Paste-Prompt $pp }.GetNewClosure())
    $dot.Add_Click({ Paste-Prompt $pp }.GetNewClosure())
    $edge.Add_Click({ Paste-Prompt $pp }.GetNewClosure())
    $row.Add_MouseEnter({ Set-Selected $ii }.GetNewClosure())
    $name.Add_MouseEnter({ Set-Selected $ii }.GetNewClosure())
    $dot.Add_MouseEnter({ Set-Selected $ii }.GetNewClosure())
    $rows.Controls.Add($row)
  }
  if ($script:shown.Count -gt 0) { Set-Selected 0 } else { $script:selIdx = -1 }
}

function Paste-Selected {
  if ($script:selIdx -ge 0 -and $script:selIdx -lt $script:shown.Count) {
    Paste-Prompt $script:shown[$script:selIdx]
  }
}

$search.Add_TextChanged({ Apply-Filter })
$search.Add_KeyDown({
  param($s, $e)
  if ($e.KeyCode -eq [Windows.Forms.Keys]::Enter) { Paste-Selected; $e.Handled = $true }
  elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Down) { if ($script:shown.Count -gt 0) { Set-Selected ([Math]::Min($script:selIdx + 1, $script:shown.Count - 1)) } }
  elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Up) { if ($script:shown.Count -gt 0) { Set-Selected ([Math]::Max($script:selIdx - 1, 0)) } }
  elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) { $popup.Hide() }
})

# Footer hint.
$foot = New-Object Windows.Forms.Label
$foot.Text = 'type filters · Enter pastes · Esc closes · Ctrl+Alt+1..8 anywhere'
$foot.Font = New-Object Drawing.Font('Segoe UI', 7)
$foot.ForeColor = $C_DIM
$foot.AutoSize = $false
$foot.Size = New-Object Drawing.Size(284, 16)
$foot.Location = New-Object Drawing.Point(12, 404)
$foot.BackColor = [Drawing.Color]::Transparent
$popup.Controls.Add($foot)

function Show-Popup {
  $search.Text = ''
  $script:activeCat = 'All'
  Build-Chips
  Apply-Filter
  if ($Preview -or $Shot) { $popup.StartPosition = 'CenterScreen' }
  else {
    $pos = [Windows.Forms.Cursor]::Position
    $x = $pos.X - 154
    if ($x -lt 0) { $x = 0 }
    $y = $pos.Y - ($popup.Height + 20)
    if ($y -lt 0) { $y = $pos.Y + 20 }
    $popup.Location = New-Object Drawing.Point($x, $y)
  }
  $popup.Show()
  $popup.Activate() | Out-Null
  [void]$search.Focus()
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
    if ($menu) { Rebuild-Menu }
    Build-Chips
    Apply-Filter
    Write-PopLog ("synced from GitHub: " + $script:prompts.Count + " prompts")
    if ($tray) { $tray.ShowBalloonTip(3000, 'Prompt Popper', ("Synced " + $script:prompts.Count + " prompts from GitHub."), [Windows.Forms.ToolTipIcon]::Info) }
  } catch {
    Write-PopLog ("SYNC FAILED: " + $_.Exception.Message)
    [Windows.Forms.MessageBox]::Show("Sync failed: $($_.Exception.Message)", 'Prompt Popper')
  }
}

# --- Load data ---
try {
  Load-Prompts
} catch {
  Write-PopLog ("START FAILED: " + $_.Exception.Message)
  [Windows.Forms.MessageBox]::Show("Bad prompts.json: $($_.Exception.Message)", 'Prompt Popper')
  if ($mutex) { $mutex.ReleaseMutex() }
  exit 1
}
Build-Chips
Apply-Filter

$script:shotPath = $Shot
function Invoke-SelfShot {
  try {
    $popup.Refresh()
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 300
    $bmp2 = New-Object Drawing.Bitmap($popup.ClientSize.Width, $popup.ClientSize.Height)
    $popup.DrawToBitmap($bmp2, (New-Object Drawing.Rectangle(0, 0, $bmp2.Width, $bmp2.Height)))
    $dest = if ($script:shotPath) { $script:shotPath } else { "$env:TEMP\popper-shot2.png" }
    $bmp2.Save($dest, [Drawing.Imaging.ImageFormat]::Png)
    $bmp2.Dispose()
    Write-Host "shot saved: $dest"
  } catch {
    Write-Host ("SHOT FAILED: " + $_.Exception.Message)
  }
}

# Headless design shot: show, shoot, exit.
if ($Shot) {
  $popup.Add_Shown({
    $dt = New-Object Windows.Forms.Timer
    $dt.Interval = 900
    $dt.Add_Tick({ param($s, $e) $s.Stop(); Invoke-SelfShot; [Windows.Forms.Application]::ExitThread() })
    $dt.Start()
  })
  $auto = New-Object Windows.Forms.Timer
  $auto.Interval = 8000
  $auto.Add_Tick({ $popup.Hide(); [Windows.Forms.Application]::ExitThread() })
  $auto.Start()
  Show-Popup
  [Windows.Forms.Application]::Run()
  exit
}

# Preview mode: popup only, auto-close (for screenshots).
if ($Preview) {
  $popup.Add_Shown({
    $dt = New-Object Windows.Forms.Timer
    $dt.Interval = 900
    $dt.Add_Tick({ param($s, $e) $s.Stop(); Invoke-SelfShot })
    $dt.Start()
  })
  $auto = New-Object Windows.Forms.Timer
  $auto.Interval = 6000
  $auto.Add_Tick({ $popup.Hide(); [Windows.Forms.Application]::ExitThread() })
  $auto.Start()
  Show-Popup
  [Windows.Forms.Application]::Run()
  exit
}

# --- Tray icon ---
$tray = $null
$menu = $null
$tray = New-Object Windows.Forms.NotifyIcon
if (Test-Path $IconFile) { $tray.Icon = New-Object Drawing.Icon($IconFile) }
else { $tray.Icon = [Drawing.SystemIcons]::Application }
$tray.Text = 'Opencode Prompt Popper'
$tray.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip

function Rebuild-Menu {
  $menu.Items.Clear()
  foreach ($pp in $script:prompts) {
    $item = $menu.Items.Add($pp.label + $(if ($pp._hotkey) { "  (Ctrl+Alt+$($pp._hotkey))" } else { '' }))
    $item.Add_Click({ Paste-Prompt $pp }.GetNewClosure())
  }
  $menu.Items.Add('-') | Out-Null
  $menu.Items.Add('Show popup (Ctrl+Alt+P)', $null, { Show-Popup }) | Out-Null
  $menu.Items.Add('Sync from GitHub', $null, { Sync-FromGitHub }) | Out-Null
  $menu.Items.Add('Reload prompts', $null, { Load-Prompts; Rebuild-Menu; Build-Chips; Apply-Filter }) | Out-Null
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
Rebuild-Menu

$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({
  param($s, $e)
  if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-Popup }
})

$trackTimer = New-Object Windows.Forms.Timer
$trackTimer.Interval = 500
$trackTimer.Add_Tick({ Update-LastWindow $popup.Handle })
$trackTimer.Start()

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
    $vk = 0x31 + $i
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

Write-PopLog ("started with " + $script:prompts.Count + " prompts")
if ($script:syncOnStart) { Sync-FromGitHub }

$tray.ShowBalloonTip(3000, 'Prompt Popper', ("Running with " + $script:prompts.Count + " prompts. Click the icon or press Ctrl+Alt+P."), [Windows.Forms.ToolTipIcon]::Info)

[Windows.Forms.Application]::Run()
$tray.Visible = $false
$mutex.ReleaseMutex()

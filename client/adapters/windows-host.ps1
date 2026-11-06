# Jarvis Voice for Windows — the helper that talks to Windows itself.
#
# Started by client/adapters/windows.mjs as `powershell.exe -NoProfile -NonInteractive -Command -`,
# with this script sent on standard input (Jarvis never changes PowerShell's execution policy).
# It reads one JSON request per line and answers one JSON line each ("@@J {...}").
#
# Only documented, user-level Windows APIs are used: the Start menu's app list, UI Automation
# (the accessibility API screen readers use), SendKeys, GDI screen copy, SoundPlayer and SAPI.
# Nothing here needs administrator rights, and apps running as administrator are out of reach
# (Windows does not let a normal process automate them) — which is reported, not worked around.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class JarvisWin {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public static string Title(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
}
'@

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

function Norm([string]$s) { if ($null -eq $s) { return '' }; return (($s.ToLowerInvariant() -replace '[^\p{L}\p{N}]+', ' ').Trim()) }

# Windows with a title, one per process: what "running apps" means to a person.
function Get-AppWindows {
  $list = @()
  foreach ($p in (Get-Process | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle })) {
    $path = $null
    try { $path = $p.Path } catch { }
    $desc = $null
    try { $desc = $p.MainModule.FileVersionInfo.FileDescription } catch { }
    $list += [pscustomobject]@{ pid = $p.Id; name = $p.ProcessName; title = $p.MainWindowTitle; description = $desc; path = $path; handle = [int64]$p.MainWindowHandle }
  }
  return $list
}

# Every top-level window UI Automation can see, whichever process owns it — this also finds
# windows a process's "main window" misses (packaged/Store apps, apps with several windows).
function Get-TopWindows {
  $list = @()
  $kids = $AE::RootElement.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($w in $kids) {
    try {
      $c = $w.Current
      if (-not $c.Name -or $c.NativeWindowHandle -eq 0 -or $c.IsOffscreen) { continue }
      $pname = $null; $desc = $null; $path = $null
      try { $p = Get-Process -Id $c.ProcessId; $pname = $p.ProcessName; $path = $p.Path; $desc = $p.MainModule.FileVersionInfo.FileDescription } catch { }
      $list += [pscustomobject]@{ pid = $c.ProcessId; name = $pname; title = $c.Name; description = $desc; path = $path; handle = [int64]$c.NativeWindowHandle }
    } catch { }
  }
  return $list
}

# The process for an app name: exact process name, file description, or words of the window title.
function Find-AppWindow([string]$name) {
  $want = Norm $name
  if (-not $want) { return $null }
  $wins = @(Get-AppWindows) + @(Get-TopWindows)
  $hit = $wins | Where-Object { (Norm $_.name) -eq $want -or (Norm $_.description) -eq $want } | Select-Object -First 1
  if (-not $hit) { $hit = $wins | Where-Object { (Norm $_.title).EndsWith($want) -or (Norm $_.title).StartsWith($want) } | Select-Object -First 1 }
  if (-not $hit) { $hit = $wins | Where-Object { (Norm $_.description).Contains($want) -or (Norm $_.title).Contains($want) } | Select-Object -First 1 }
  return $hit
}

function Get-Front {
  $h = [JarvisWin]::GetForegroundWindow()
  if ($h -eq [IntPtr]::Zero) { return $null }
  [uint32]$procId = 0
  [void][JarvisWin]::GetWindowThreadProcessId($h, [ref]$procId)
  $name = $null
  $desc = $null
  try { $p = Get-Process -Id $procId; $name = $p.ProcessName; $desc = $p.MainModule.FileVersionInfo.FileDescription } catch { }
  return [pscustomobject]@{ pid = [int]$procId; name = $name; description = $desc; title = [JarvisWin]::Title($h); handle = [int64]$h }
}

function Focus-Window($win) {
  $h = [IntPtr][int64]$win.handle
  if ([JarvisWin]::IsIconic($h)) { [void][JarvisWin]::ShowWindowAsync($h, 9) } # SW_RESTORE
  try { $AE::FromHandle($h).SetFocus() } catch { try { [Microsoft.VisualBasic.Interaction]::AppActivate([int]$win.pid) } catch { } }
  Start-Sleep -Milliseconds 150
  $front = Get-Front
  return ($null -ne $front -and $front.pid -eq $win.pid)
}

function Require-Window([string]$app) {
  # A window that has only just opened can take a moment to be visible to UI Automation.
  $until = (Get-Date).AddSeconds(3)
  do {
    $win = Find-AppWindow $app
    if ($win) { return $win }
    Start-Sleep -Milliseconds 300
  } while ((Get-Date) -lt $until)
  throw "$app is not open (no window of it was found)."
}

function Read-Tree($root, [int]$maxNodes = 1500, [int]$maxChars = 12000) {
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $out = New-Object System.Text.StringBuilder
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  $stack = New-Object System.Collections.Stack
  $stack.Push(@($root, 0))
  $count = 0
  while ($stack.Count -gt 0 -and $count -lt $maxNodes -and $out.Length -lt $maxChars) {
    $item = $stack.Pop()
    $el = $item[0]; $depth = $item[1]
    $count++
    try {
      $c = $el.Current
      $type = $c.ControlType.ProgrammaticName -replace '^ControlType\.', ''
      $text = $c.Name
      if (-not $c.IsPassword) {
        $vp = $null
        if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
          $v = $vp.Current.Value
          if ($v -and $v -ne $text) { $text = if ($text) { "$($text): $v" } else { $v } }
        }
        $tp = $null
        if (($type -eq 'Document' -or $type -eq 'Edit') -and $el.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$tp)) {
          $t = $tp.DocumentRange.GetText(6000)
          if ($t -and $t -ne $text) { $text = if ($text) { "$($text): $t" } else { $t } }
        }
      } else { $text = "$($c.Name) (password field)" }
      if ($text -and $seen.Add("$type|$text")) { [void]$out.AppendLine(("  " * [Math]::Min($depth, 8)) + "[$type] " + ($text -replace '\s+', ' ')) }
      if ($depth -lt 14) {
        $kids = @()
        $child = $walker.GetFirstChild($el)
        while ($null -ne $child -and $kids.Count -lt 300) { $kids += $child; $child = $walker.GetNextSibling($child) }
        for ($i = $kids.Count - 1; $i -ge 0; $i--) { $stack.Push(@($kids[$i], ($depth + 1))) }
      }
    } catch { }
  }
  $s = $out.ToString()
  if ($s.Length -gt $maxChars) { $s = $s.Substring(0, $maxChars) + "`n…" }
  return $s
}

function Find-Element($root, [string]$label, [string]$role) {
  $want = Norm $label
  $all = $root.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $best = $null; $bestScore = 0
  foreach ($el in $all) {
    try {
      $c = $el.Current
      if (-not $c.IsEnabled -or $c.IsOffscreen) { continue }
      $n = Norm $c.Name
      if (-not $n) { continue }
      $score = 0
      if ($n -eq $want) { $score = 3 } elseif ($n.StartsWith($want)) { $score = 2 } elseif ($n.Contains($want)) { $score = 1 }
      if ($score -eq 0) { continue }
      $type = ($c.ControlType.ProgrammaticName -replace '^ControlType\.', '').ToLowerInvariant()
      if ($role -and $type.Contains((Norm $role).Replace(' ', ''))) { $score += 2 }
      if (@('button', 'hyperlink', 'tabitem', 'menuitem', 'checkbox', 'listitem', 'treeitem', 'radiobutton', 'splitbutton') -contains $type) { $score += 1 }
      if ($score -gt $bestScore) { $best = $el; $bestScore = $score }
    } catch { }
  }
  return $best
}

function Escape-SendKeys([string]$text) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $text.ToCharArray()) {
    switch -regex ([string]$ch) {
      '[+^%~(){}\[\]]' { [void]$sb.Append('{' + $ch + '}'); break }
      "`n" { [void]$sb.Append('{ENTER}'); break }
      "`r" { break }
      "`t" { [void]$sb.Append('{TAB}'); break }
      default { [void]$sb.Append($ch) }
    }
  }
  return $sb.ToString()
}

$KeyNames = @{
  'enter' = '{ENTER}'; 'return' = '{ENTER}'; 'escape' = '{ESC}'; 'esc' = '{ESC}'; 'tab' = '{TAB}'; 'space' = ' ';
  'backspace' = '{BACKSPACE}'; 'delete' = '{DELETE}'; 'del' = '{DELETE}'; 'up' = '{UP}'; 'down' = '{DOWN}'; 'left' = '{LEFT}';
  'right' = '{RIGHT}'; 'home' = '{HOME}'; 'end' = '{END}'; 'pageup' = '{PGUP}'; 'page up' = '{PGUP}'; 'pagedown' = '{PGDN}';
  'page down' = '{PGDN}'; 'insert' = '{INSERT}'
}
function Convert-Keys([string]$keys) {
  $parts = ($keys.ToLowerInvariant() -split '\s*\+\s*') | Where-Object { $_ }
  $mods = ''; $key = ''
  foreach ($p in $parts) {
    switch ($p) {
      { $_ -in 'ctrl', 'control', 'cmd', 'command', 'meta' } { $mods += '^'; continue }
      { $_ -in 'shift' } { $mods += '+'; continue }
      { $_ -in 'alt', 'option', 'opt' } { $mods += '%'; continue }
      { $_ -in 'win', 'windows', 'super' } { throw 'The Windows key cannot be pressed by Jarvis.' }
      default {
        if ($KeyNames.ContainsKey($p)) { $key = $KeyNames[$p] }
        elseif ($p -match '^f([1-9]|1[0-6])$') { $key = '{' + $p.ToUpperInvariant() + '}' }
        elseif ($p.Length -eq 1) { $key = Escape-SendKeys $p }
        else { throw "I don't know the key '$p'." }
      }
    }
  }
  if (-not $key) { throw "No key to press in '$keys'." }
  return $mods + $key
}

function Shot($rect) {
  $max = 1600
  $bmp = New-Object System.Drawing.Bitmap $rect.Width, $rect.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
  $g.Dispose()
  if ($bmp.Width -gt $max) {
    $h = [int]($bmp.Height * $max / $bmp.Width)
    $small = New-Object System.Drawing.Bitmap $bmp, $max, $h
    $bmp.Dispose(); $bmp = $small
  }
  $ms = New-Object System.IO.MemoryStream
  $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
  $params = New-Object System.Drawing.Imaging.EncoderParameters 1
  $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 80L
  $bmp.Save($ms, $codec, $params)
  $bmp.Dispose()
  return [Convert]::ToBase64String($ms.ToArray())
}

$SettingsPages = @{
  'privacy' = 'ms-settings:privacy'; 'microphone' = 'ms-settings:privacy-microphone'; 'camera' = 'ms-settings:privacy-webcam';
  'sound' = 'ms-settings:sound'; 'bluetooth' = 'ms-settings:bluetooth'; 'wifi' = 'ms-settings:network-wifi'; 'network' = 'ms-settings:network';
  'display' = 'ms-settings:display'; 'displays' = 'ms-settings:display'; 'notifications' = 'ms-settings:notifications';
  'apps' = 'ms-settings:appsfeatures'; 'startup' = 'ms-settings:startupapps'; 'accessibility' = 'ms-settings:easeofaccess';
  'keyboard' = 'ms-settings:typing'; 'updates' = 'ms-settings:windowsupdate'; 'software-update' = 'ms-settings:windowsupdate';
  'battery' = 'ms-settings:batterysaver'; 'general' = 'ms-settings:'; 'screen-recording' = 'ms-settings:privacy'
}

$global:player = $null
$global:synth = $null

$handlers = @{
  'ping' = { param($a) 'pong' }
  'apps' = { param($a)
    $apps = @()
    try { $apps = @(Get-StartApps | ForEach-Object { [pscustomobject]@{ name = $_.Name; id = $_.AppID } }) } catch { }
    if ($apps.Count -eq 0) {
      $dirs = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs")
      foreach ($d in $dirs) { if (Test-Path $d) { Get-ChildItem -Path $d -Recurse -Filter *.lnk | ForEach-Object { $apps += [pscustomobject]@{ name = $_.BaseName; id = "lnk:" + $_.FullName } } } }
    }
    , $apps
  }
  'running' = { param($a)
    $seen = @{}
    $out = @()
    foreach ($w in (@(Get-AppWindows) + @(Get-TopWindows))) {
      if ($seen.ContainsKey([string]$w.handle)) { continue }
      $seen[[string]$w.handle] = $true
      $out += [pscustomobject]@{ pid = $w.pid; name = $w.name; title = $w.title; description = $w.description }
    }
    , $out
  }
  'front' = { param($a) Get-Front }
  'open' = { param($a)
    $id = [string]$a.id
    if ($id.StartsWith('lnk:')) { Start-Process -FilePath $id.Substring(4) } else { Start-Process -FilePath ("shell:AppsFolder\" + $id) }
    'started'
  }
  'find' = { param($a) Find-AppWindow ([string]$a.name) }
  'focus' = { param($a) $w = Require-Window ([string]$a.name); [pscustomobject]@{ focused = (Focus-Window $w); title = $w.title } }
  'close' = { param($a)
    $w = Find-AppWindow ([string]$a.name)
    if (-not $w) { return [pscustomobject]@{ state = 'not-running' } }
    $p = Get-Process -Id $w.pid
    if ($a.force) { Stop-Process -Id $w.pid -Force; return [pscustomobject]@{ state = 'ended'; title = $w.title } }
    [void]$p.CloseMainWindow()
    if ($p.WaitForExit(6000)) { return [pscustomobject]@{ state = 'closed'; title = $w.title } }
    $still = Find-AppWindow ([string]$a.name)
    [pscustomobject]@{ state = 'still-open'; title = $(if ($still) { $still.title } else { $w.title }) }
  }
  'read' = { param($a)
    $w = Require-Window ([string]$a.name)
    $root = $AE::FromHandle([IntPtr][int64]$w.handle)
    [pscustomobject]@{ title = $w.title; text = (Read-Tree $root) }
  }
  'click' = { param($a)
    $w = Require-Window ([string]$a.name)
    $root = $AE::FromHandle([IntPtr][int64]$w.handle)
    $el = Find-Element $root ([string]$a.label) ([string]$a.role)
    if (-not $el) { throw "There is nothing labelled '$($a.label)' in $($w.title)." }
    $p = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); return "pressed '$($el.Current.Name)'" }
    if ($el.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { $p.Toggle(); return "toggled '$($el.Current.Name)'" }
    if ($el.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select(); return "selected '$($el.Current.Name)'" }
    if ($el.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p)) { $p.Expand(); return "opened '$($el.Current.Name)'" }
    throw "'$($el.Current.Name)' can't be pressed through UI Automation."
  }
  'type' = { param($a)
    $w = Require-Window ([string]$a.name)
    if (-not (Focus-Window $w)) { throw "$($a.name) could not be brought to the front, so nothing was typed." }
    $root = $AE::FromHandle([IntPtr][int64]$w.handle)
    $target = $null
    if ($a.field) { $target = Find-Element $root ([string]$a.field) 'edit' }
    if (-not $target) { $target = $AE::FocusedElement }
    if ($target -and $target.Current.IsPassword) { throw 'That is a password field; Jarvis never types into password fields.' }
    if ($target -and $a.field) { try { $target.SetFocus() } catch { } }
    $front = Get-Front
    if (-not $front -or $front.pid -ne $w.pid) { throw "$($a.name) is no longer in front, so nothing was typed." }
    [System.Windows.Forms.SendKeys]::SendWait((Escape-SendKeys ([string]$a.text)))
    $value = $null
    $vp = $null
    try { if ($target -and $target.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { $value = $vp.Current.Value } } catch { }
    if ($a.submit) { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') }
    [pscustomobject]@{ verified = $(if ($null -ne $value) { $value.Contains([string]$a.text) } else { $null }) }
  }
  'keys' = { param($a)
    $w = Require-Window ([string]$a.name)
    if (-not (Focus-Window $w)) { throw "$($a.name) could not be brought to the front, so no keys were pressed." }
    [System.Windows.Forms.SendKeys]::SendWait((Convert-Keys ([string]$a.keys)))
    'pressed'
  }
  'shot' = { param($a)
    if ($a.name) {
      $w = Require-Window ([string]$a.name)
      $r = New-Object JarvisWin+RECT
      [void][JarvisWin]::GetWindowRect([IntPtr][int64]$w.handle, [ref]$r)
      $rect = New-Object System.Drawing.Rectangle $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top)
    } else { $rect = [System.Windows.Forms.SystemInformation]::VirtualScreen }
    if ($rect.Width -le 0 -or $rect.Height -le 0) { throw 'There is nothing on screen to capture.' }
    [pscustomobject]@{ image = (Shot $rect); width = $rect.Width; height = $rect.Height }
  }
  'url' = { param($a)
    if ($a.browser) { Start-Process -FilePath ([string]$a.browser) -ArgumentList ([string]$a.url) } else { Start-Process -FilePath ([string]$a.url) }
    'opened'
  }
  'path' = { param($a)
    if ($a.program) { Start-Process -FilePath ([string]$a.program) -ArgumentList ('"' + [string]$a.path + '"') } else { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + [string]$a.path + '"') }
    'opened'
  }
  'settings' = { param($a)
    $key = (Norm ([string]$a.pane)).Replace(' ', '-')
    $uri = $SettingsPages[$key]
    if (-not $uri) { $uri = 'ms-settings:' }
    Start-Process -FilePath $uri
    $uri
  }
  'terminal' = { param($a)
    $cwd = if ($a.cwd) { [string]$a.cwd } else { $env:USERPROFILE }
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) { Start-Process -FilePath $wt.Source -ArgumentList @('-d', ('"' + $cwd + '"'), 'powershell', '-NoExit', '-Command', [string]$a.command) }
    else { Start-Process -FilePath 'powershell.exe' -WorkingDirectory $cwd -ArgumentList @('-NoExit', '-Command', [string]$a.command) }
    'started'
  }
  'play' = { param($a)
    if ($global:player) { $global:player.Stop() }
    $global:player = New-Object System.Media.SoundPlayer ([string]$a.file)
    $global:player.Load()
    $global:player.Play()
    'playing'
  }
  'say' = { param($a)
    if (-not $global:synth) { Add-Type -AssemblyName System.Speech; $global:synth = New-Object System.Speech.Synthesis.SpeechSynthesizer }
    $global:synth.SpeakAsyncCancelAll()
    [void]$global:synth.SpeakAsync([string]$a.text)
    'speaking'
  }
  'speaking' = { param($a) [pscustomobject]@{ speaking = ($null -ne $global:synth -and $global:synth.State -eq 'Speaking') } }
  'stop' = { param($a)
    if ($global:player) { $global:player.Stop() }
    if ($global:synth) { $global:synth.SpeakAsyncCancelAll() }
    'stopped'
  }
}

[Console]::Out.WriteLine('@@J {"ready":true}')
[Console]::Out.Flush()
while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
  if (-not $line.Trim()) { continue }
  $id = $null
  try {
    $req = $line | ConvertFrom-Json
    $id = $req.id
    $h = $handlers[[string]$req.op]
    if (-not $h) { throw "unknown operation $($req.op)" }
    $result = & $h $req.args
    $out = @{ id = $id; ok = $true; result = $result }
  } catch {
    $out = @{ id = $id; ok = $false; error = $_.Exception.Message }
  }
  [Console]::Out.WriteLine('@@J ' + ($out | ConvertTo-Json -Compress -Depth 6))
  [Console]::Out.Flush()
}

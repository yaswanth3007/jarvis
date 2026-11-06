# Jarvis Voice's icon in the Windows notification area. Started by client/tray.mjs (script sent
# on standard input, like windows-host.ps1). Reads {"status","muted","tip","notify"} lines;
# writes "menu <id>" when the user picks a menu item.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function New-JarvisIcon([bool]$muted) {
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $color = if ($muted) { [System.Drawing.Color]::FromArgb(255, 150, 150, 150) } else { [System.Drawing.Color]::FromArgb(255, 64, 200, 255) }
  $pen = New-Object System.Drawing.Pen $color, 3
  $g.DrawEllipse($pen, 3, 3, 26, 26)
  $brush = New-Object System.Drawing.SolidBrush $color
  $g.FillEllipse($brush, 11, 11, 10, 10)
  $g.Dispose()
  return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = New-JarvisIcon $false
$icon.Text = 'Jarvis Voice'
$icon.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$status = $menu.Items.Add('Starting…'); $status.Enabled = $false
[void]$menu.Items.Add('-')
$mute = $menu.Items.Add('Pause listening')
$face = $menu.Items.Add('Open the JARVIS interface')
$logs = $menu.Items.Add('Open the logs folder')
[void]$menu.Items.Add('-')
$quit = $menu.Items.Add('Quit Jarvis Voice')
$icon.ContextMenuStrip = $menu
function Say([string]$s) { [Console]::Out.WriteLine($s); [Console]::Out.Flush() }
$mute.add_Click({ Say 'menu mute' })
$face.add_Click({ Say 'menu face' })
$logs.add_Click({ Say 'menu logs' })
$quit.add_Click({ Say 'menu quit' })
$icon.add_DoubleClick({ Say 'menu face' })

$script:reader = [Console]::In
$script:pending = $script:reader.ReadLineAsync()
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.add_Tick({
  while ($script:pending.IsCompleted) {
    $line = $script:pending.Result
    if ($null -eq $line) { $icon.Visible = $false; [System.Windows.Forms.Application]::Exit(); return }
    try {
      $m = $line | ConvertFrom-Json
      if ($m.status) { $status.Text = [string]$m.status }
      if ($null -ne $m.muted) {
        $mute.Text = $(if ($m.muted) { 'Resume listening' } else { 'Pause listening' })
        $icon.Icon = New-JarvisIcon ([bool]$m.muted)
      }
      if ($m.tip) { $t = [string]$m.tip; if ($t.Length -gt 63) { $t = $t.Substring(0, 63) }; $icon.Text = $t }
      if ($m.notify) { $icon.ShowBalloonTip(4000, 'Jarvis', [string]$m.notify, 'Info') }
    } catch { }
    $script:pending = $script:reader.ReadLineAsync()
  }
})
$timer.Start()
Say 'ready'
[System.Windows.Forms.Application]::Run()
$icon.Visible = $false

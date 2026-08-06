# toast-notify.ps1 - Windows toast notification for scheduled agents.
# ASCII-ONLY on purpose (no BOM): the Japanese body is READ from -PayloadPath (UTF-8 file),
# never written as a literal here. Modeled on the proven hooks\conscience-notify.ps1 pattern:
# BurntToast first (real toast, stays in Action Center), NotifyIcon balloon as fallback.
param(
  [Parameter(Mandatory=$true)][string]$PayloadPath,
  [string]$Title = "Lucas Cleanup"
)
$ErrorActionPreference = 'Continue'

try { $body = (Get-Content -Path $PayloadPath -Raw -Encoding UTF8) } catch { $body = '(payload read failed)' }
if ([string]::IsNullOrWhiteSpace($body)) { exit 0 }
$body = $body.Trim()

$done = $false
try {
  if (Get-Module -ListAvailable -Name BurntToast) {
    Import-Module BurntToast -ErrorAction Stop
    New-BurntToastNotification -Text $Title, $body -ErrorAction Stop
    $done = $true
  }
} catch { $done = $false }

if (-not $done) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [System.Drawing.SystemIcons]::Information
    $ni.Visible = $true
    $ni.BalloonTipTitle = $Title
    $ni.BalloonTipText  = $body
    $ni.ShowBalloonTip(8000)
    Start-Sleep -Seconds 9
    $ni.Dispose()
    $done = $true
  } catch { $done = $false }
}

if ($done) { exit 0 } else { exit 1 }

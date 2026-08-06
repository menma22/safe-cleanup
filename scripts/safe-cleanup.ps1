# safe-cleanup.ps1 - Task Scheduler entry point for task "SafeCleanup" (every 30 minutes).
#
# DETERMINISTIC SYSTEM: NO LLM, NO AI AGENT, NO `claude -p` anywhere in this path.
# It replaces the former scheduled agent "Lucas-HourlyCleanup" (retired 2026-08-06).
# Why the agent was removable: every kill/keep decision was ALREADY hard-coded in the
# skill scripts - kill-dead.ps1 (orphan + leaf + no-window + CRITICAL/session0/claude/
# voice guards) and kill-ghosts.ps1 (no taskbar window + CPU idle gate + PROTECT list).
# The model only chained those scripts in a fixed order and formatted one summary line,
# which plain PowerShell does for free. Its prompt even forbade any other kill path, so
# the model had zero discretion left to exercise.
#
# ASCII-ONLY on purpose (and no BOM): Windows PowerShell 5.1 decodes BOM-less UTF-8 as
# cp932, and that corruption can pollute parsing of adjacent lines - not just display.
# All Japanese lives in safe-cleanup.config.json (UTF-8) and is read at runtime.
#
# Success is decided by the WORK PRODUCT, never by "the process exited": each kill script
# ends with a machine-readable "#RESULT ..." line that is emitted only after its kill loop
# has actually run, and this wrapper fails the run if that line is absent. The exit code
# merely reports that verdict outward (0 = ok, 1 = failure -> LastTaskResult). The separate
# sentinel file the old agent needed is gone because the #RESULT line IS the sentinel, and
# it comes from the worker itself rather than from a model promising it finished.
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root     = 'C:\Users\mahim\.claude'
$scripts  = Join-Path $root 'scripts'
$skillDir = Join-Path $root 'skills\windows-safe-cleanup\scripts'
$logDir   = Join-Path $scripts 'logs'
$cfgPath  = Join-Path $scripts 'safe-cleanup.config.json'
$notifier = Join-Path $scripts 'toast-notify.ps1'
$health   = Join-Path $logDir 'safe-cleanup.health'
$payload  = Join-Path $logDir 'safe-cleanup.payload'
$lock     = Join-Path $logDir 'safe-cleanup.lock'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

function Write-Health([string]$line) {
  ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $line) | Out-File $health -Append -Encoding utf8
  if (Test-Path $health) { (Get-Content $health -Tail 300) | Out-File $health -Encoding utf8 }
}

function Get-RamPct {
  $os = Get-CimInstance Win32_OperatingSystem
  return [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize * 100, 1)
}

# The kill scripts end with a machine-readable "#RESULT k=v k=v" line. Parsing that single
# contract line is why this wrapper never has to interpret their human-facing Japanese text.
function Get-ResultMap([string]$text) {
  $map = @{}
  $line = ($text -split "`r?`n") | Where-Object { $_.Trim().StartsWith('#RESULT') } | Select-Object -Last 1
  if ($line) {
    foreach ($tok in ($line.Trim().Substring(7).Trim() -split '\s+')) {
      $kv = $tok -split '=', 2
      if ($kv.Count -eq 2) { $map[$kv[0]] = $kv[1] }
    }
  }
  return $map
}
function MapNum($map, [string]$key) {
  if ($map.ContainsKey($key) -and $map[$key] -ne '') { try { return [double]$map[$key] } catch { return 0 } }
  return 0
}
function MapStr($map, [string]$key) {
  if ($map.ContainsKey($key)) { return [string]$map[$key] }
  return ''
}

# --- config ---
try {
  $raw = (Get-Content $cfgPath -Raw -Encoding UTF8) -replace "^\uFEFF", ''
  $cfg = $raw | ConvertFrom-Json
} catch {
  Write-Health ('FATAL config-unreadable: ' + $_.Exception.Message)
  exit 1
}

# --- concurrency guard (guards against a manual run overlapping a scheduled one; the
# scheduler itself already enforces MultipleInstancesPolicy=IgnoreNew). The window is tied
# to the task's ExecutionTimeLimit of PT10M: a run cannot legitimately outlive it, so a lock
# older than that is PROVABLY stale. Keeping the window <= 10 min also means a lock left by a
# crashed run can never block the next scheduled run 30 min later - the guard must not be
# able to kill a legitimate run, or the safety net becomes the failure. ---
if ((Test-Path $lock) -and ((Get-Item $lock).LastWriteTime -gt (Get-Date).AddMinutes(-10))) {
  Write-Health 'SKIP previous-run-still-active'
  exit 0
}
Set-Content $lock (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

$log = Join-Path $logDir ('safe-cleanup-' + (Get-Date -Format 'yyyy-MM-dd') + '.log')
("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] start") | Out-File $log -Append -Encoding utf8

$ramBefore = Get-RamPct
$failures  = @()

# --- step 1: provably dead orphan leaves (no arguments: the rules are fixed in the script) ---
$deadMap = @{}
try {
  $out = & (Join-Path $skillDir 'kill-dead.ps1') 2>&1 | Out-String
  $out.TrimEnd() | Out-File $log -Append -Encoding utf8
  $deadMap = Get-ResultMap $out
  if (-not $deadMap.ContainsKey('killed')) { $failures += 'kill-dead:no-result-line' }
} catch {
  $failures += ('kill-dead:' + $_.Exception.Message.Split("`n")[0])
}

# --- step 2: windowless + CPU-idle ghost GUI apps (allowlist and threshold from config) ---
$ghostMap = @{}
try {
  $out = & (Join-Path $skillDir 'kill-ghosts.ps1') -AppNames $cfg.appNames -MaxCpuPct $cfg.maxCpuPct 2>&1 | Out-String
  $out.TrimEnd() | Out-File $log -Append -Encoding utf8
  $ghostMap = Get-ResultMap $out
  if (-not $ghostMap.ContainsKey('killed')) { $failures += 'kill-ghosts:no-result-line' }
} catch {
  $failures += ('kill-ghosts:' + $_.Exception.Message.Split("`n")[0])
}

Start-Sleep -Seconds 1
$ramAfter = Get-RamPct

# --- summary (Japanese templates come from the config, never from this ASCII-only file) ---
$deadKilled  = [int](MapNum $deadMap  'killed')
$ghostKilled = [int](MapNum $ghostMap 'killed')
$freedTotal  = [math]::Round((MapNum $deadMap 'freedMB') + (MapNum $ghostMap 'freedMB'), 1)
$ghostApps   = MapStr $ghostMap 'apps'
$busyApps    = MapStr $ghostMap 'busy'
$changed     = ($deadKilled + $ghostKilled) -gt 0
$ok          = $failures.Count -eq 0
$L           = $cfg.labels

if ($ok) {
  $parts = @()
  if (-not $changed) { $parts += $L.none }
  $parts += ($L.ram -f $ramBefore, $ramAfter)
  if ($deadKilled -gt 0) { $parts += ($L.dead -f $deadKilled) }
  if ($ghostKilled -gt 0) {
    $g = ($L.ghost -f $ghostKilled)
    if ($ghostApps) { $g = $g + ' ' + $ghostApps }
    $parts += $g
  }
  if ($changed) { $parts += ($L.freed -f $freedTotal) }
  if ($busyApps) { $parts += ($L.busy -f $busyApps) }
  $summary = ($parts -join ' / ')
} else {
  $summary = ($L.failed -f ($failures -join '; '))
}

$hhmm = Get-Date -Format 'HH:mm'
$body = '[' + $hhmm + '] ' + $summary
$body | Out-File $log -Append -Encoding utf8

# --- notify (mode from config; 'changed' keeps 48 runs/day quiet unless something happened) ---
# In 'changed' mode, stay silent unless the run is actually worth interrupting mahiro for.
# Measured 2026-08-06: ordinary tooling leaves 1-2 dead orphan leaves behind almost every cycle
# (tail.exe / sleep.exe, ~5-15MB), so "killed anything at all" would still fire ~48 toasts a day
# and get the notifications muted - the exact failure mode the toast skill warns about.
# Worth a toast = the run failed, OR a real ghost app was reclaimed, OR meaningful memory freed.
# Silence stays auditable: every run still writes a health line saying notify=skipped.
$notified = 'skipped'
$worth = (-not $ok) -or ($ghostKilled -gt 0) -or ($freedTotal -ge $cfg.notifyMinFreedMB)
$notify = $true
if ($cfg.notifyMode -eq 'changed' -and -not $worth) { $notify = $false }
if ($notify -and (Test-Path $notifier)) {
  $body | Out-File $payload -Encoding utf8
  $title = if ($ok) { $L.titleOk } else { $L.titleNg }
  try {
    & $notifier -PayloadPath $payload -Title $title | Out-Null
    $notified = ('rc=' + $LASTEXITCODE)
  } catch {
    $notified = ('error:' + $_.Exception.Message.Split("`n")[0])
  }
}

# deadFailed counts kill attempts refused by Windows (admin-owned processes such as AsusOSD).
# It is expected and permanent, so it never fails the run and never reaches the toast - but it is
# recorded here, otherwise a candidate that can NEVER be killed would stay invisible forever.
Write-Health ("result={0} dead={1} deadFailed={2} ghost={3} freedMB={4} ram={5}->{6} notify={7}" -f `
  $(if ($ok) { 'OK' } else { 'FAIL' }), $deadKilled, [int](MapNum $deadMap 'failed'), $ghostKilled, `
  $freedTotal, $ramBefore, $ramAfter, $notified)

Remove-Item $lock -Force -ErrorAction SilentlyContinue

Get-ChildItem $logDir -Filter 'safe-cleanup-*.log' |
  Sort-Object Name -Descending | Select-Object -Skip $cfg.keepLogDays |
  Remove-Item -Force -ErrorAction SilentlyContinue

if ($ok) { exit 0 } else { exit 1 }

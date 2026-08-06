# kill-dead.ps1 — find-dead.ps1 と同一条件の孤児リーフを実際に kill する。
# find-dead.ps1 で中身を確認してから実行すること。選定条件・保護対象は find-dead.ps1 と完全一致させる
# (システム重要プロセス・セッション0・claude・音声デーモン・生きた可視ウィンドウを持つプロセスは絶対に殺さない。
#  ウィンドウ除外の理由は find-dead.ps1 冒頭コメント参照=2026-07-30、Lucas-CCターミナル誤検知の実測)。
$CRITICAL = @('csrss.exe','wininit.exe','services.exe','lsass.exe','smss.exe','winlogon.exe',
  'fontdrvhost.exe','dwm.exe','LogonUI.exe','svchost.exe','System','Registry','Idle',
  'MemCompression','Memory Compression','WUDFHost.exe','spoolsv.exe','sihost.exe')

$all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, SessionId, CommandLine, @{N='MEM_MB';E={[math]::Round($_.WorkingSetSize/1MB,1)}}
$pids = @{}; foreach($p in $all){ $pids[$p.ProcessId] = $true }
$hasChild = @{}; foreach($p in $all){ $hasChild[$p.ParentProcessId] = $true }
$hasWindow = @{}
foreach($proc in (Get-Process | Where-Object { $_.MainWindowHandle -ne 0 })){ $hasWindow[[int]$proc.Id] = $true }

$dead = $all | Where-Object {
  -not $pids.ContainsKey($_.ParentProcessId) -and
  -not $hasChild.ContainsKey($_.ProcessId)   -and
  -not $hasWindow.ContainsKey([int]$_.ProcessId) -and
  $_.SessionId -ne 0                          -and
  $_.Name -notin $CRITICAL                    -and
  $_.Name -ne 'claude.exe'                    -and
  ($_.CommandLine -notmatch 'lucas-voice|lucas_voice|speak_server')
}

$freed = 0.0; $ok = 0; $fail = 0
foreach($p in $dead){
  try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $freed += $p.MEM_MB; $ok++
        ("KILLED {0,-26} pid={1,-6} {2}MB" -f $p.Name, $p.ProcessId, $p.MEM_MB) }
  catch { $fail++; ("FAILED {0,-26} pid={1,-6} : {2}" -f $p.Name, $p.ProcessId, $_.Exception.Message.Split("`n")[0]) }
}
""
("=> {0}個 kill / {1}個 失敗(管理者権限等) / 約{2}MB 解放" -f $ok, $fail, [math]::Round($freed,1))
Start-Sleep 1
$os = Get-CimInstance Win32_OperatingSystem; $tot=[math]::Round($os.TotalVisibleMemorySize/1MB,1); $free=[math]::Round($os.FreePhysicalMemory/1MB,1)
("現在RAM: 使用 {0}GB / {1}GB ({2}%)" -f [math]::Round($tot-$free,1), $tot, [math]::Round(($tot-$free)/$tot*100,1))

# 機械可読の契約行（2026-08-06 追加）。無人実行の SafeCleanup（scripts\safe-cleanup.ps1）がこの1行だけを
# 解析して結果を得る＝日本語の人間向け出力を正規表現で推測解析しなくて済む。この行の存在自体が
# 「kill ループを最後まで回した」証跡（センチネル）でもあるので、消したり書式を変えたりしないこと。
("#RESULT killed={0} failed={1} freedMB={2}" -f $ok, $fail, [math]::Round($freed,1))

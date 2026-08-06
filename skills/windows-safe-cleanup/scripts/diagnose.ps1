# diagnose.ps1 — read-only。CPU/メモリの現状と占有元を「事実」で出す。
# 肝: 累積CPU(CPU_s=プロセス寿命の合計)を「今の負荷」と誤認しない。今の負荷は必ずサンプリング差分で測る。
param([int]$Top = 15)

$os = Get-CimInstance Win32_OperatingSystem
$tot = [math]::Round($os.TotalVisibleMemorySize/1MB,1)
$free = [math]::Round($os.FreePhysicalMemory/1MB,1)
$cpu = Get-CimInstance Win32_Processor
"===== システム ====="
"CPU: $($cpu.Name)  ($($cpu.NumberOfCores)C/$($cpu.NumberOfLogicalProcessors)T)"
("RAM: 使用 {0}GB / {1}GB ({2}%)  空き {3}GB" -f [math]::Round($tot-$free,1),$tot,[math]::Round(($tot-$free)/$tot*100,1),$free)
""

# --- 現在CPU: 2サンプル差分 (累積値ではなく「今」焼いてる率) ---
"===== 現在CPU使用率 TOP$Top (3秒サンプル・全体%) ====="
$cores = $cpu.NumberOfLogicalProcessors
$s1 = Get-CimInstance Win32_PerfRawData_PerfProc_Process | Where-Object { $_.Name -notin @('_Total','Idle') }
Start-Sleep -Seconds 3
$s2 = Get-CimInstance Win32_PerfRawData_PerfProc_Process | Where-Object { $_.Name -notin @('_Total','Idle') }
$h1 = @{}; foreach($p in $s1){ $h1[$p.IDProcess] = $p }
$rows = foreach($p in $s2){
  if($h1.ContainsKey($p.IDProcess)){
    $a = $h1[$p.IDProcess]; $dt = $p.Timestamp_Sys100NS - $a.Timestamp_Sys100NS
    $dp = $p.PercentProcessorTime - $a.PercentProcessorTime
    if($dt -gt 0){ [pscustomobject]@{ Name=$p.Name; Pid=$p.IDProcess; CPU_pct=[math]::Round(($dp/$dt)*100/$cores,1) } }
  }
}
$rows | Sort-Object CPU_pct -Descending | Select-Object -First $Top | Format-Table -AutoSize | Out-String | Write-Output

# --- メモリ上位 ---
"===== メモリ占有 TOP$Top ====="
Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First $Top `
  Name, Id, @{N='MEM_MB';E={[math]::Round($_.WorkingSet64/1MB,1)}}, StartTime | Format-Table -AutoSize | Out-String | Write-Output

# --- セッション残骸の兆候(参考): 同種プロセスの多重・古い生成時刻 ---
"===== 参考: 多重プロセス種別 (残骸の温床) ====="
Get-Process | Group-Object Name | Where-Object { $_.Count -ge 5 } | Sort-Object Count -Descending |
  Select-Object @{N='Name';E={$_.Name}}, Count, @{N='MEM_MB';E={[math]::Round(($_.Group|Measure-Object WorkingSet64 -Sum).Sum/1MB,1)}} |
  Format-Table -AutoSize | Out-String | Write-Output

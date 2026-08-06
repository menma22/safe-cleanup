# find-dead.ps1 — read-only。「本当に死んでる」孤児リーフだけを列挙する(dry-run)。
# 定義: 死んでる = 親プロセスが消滅(orphan) かつ 生きた子を持たない(leaf)。
#   - 親が消えた = そのプロセスを起動したセッション/ランチャは既に無い
#   - 子が無い  = 何も抱えていない = 消しても連鎖被害ゼロ
# 除外(保護):
#   - システム重要プロセス(CRITICAL) — csrss/wininit/services/lsass/smss/winlogon 等は親(smss)が
#     設計上先に終了するため「孤児」に見えるが、kill すると Windows がクラッシュする。絶対に候補に入れない。
#   - セッション0(サービス/システム) — ユーザーが閉じ忘れた残骸ではないので触らない。
#   - claude.exe(セッション系は触らない) / 音声デーモン(lucas-voice)。
#   - 生きた可視ウィンドウを持つプロセス(MainWindowHandle!=0) — WindowsTerminal.exe 等はランチャーから
#     即デタッチする設計＋ConPTYで子シェルがWin32_Processの直接の子として見えないため、
#     「親消滅+子なし」ヒューリスティックが誤検知する。2026-07-30実測: wt.exe(タイトルLucas-CC=
#     lucas-voice/夜間インタビューの生きたclaudeセッション)がこの誤検知でkill候補に上がった
#     (Responding=True・MainWindowTitle="claude"の生存中ウィンドウだった)。ウィンドウを持つ=
#     ユーザーが今も見ている可能性があるプロセスなので「死んでる孤児」の定義から外す。
$CRITICAL = @('csrss.exe','wininit.exe','services.exe','lsass.exe','smss.exe','winlogon.exe',
  'fontdrvhost.exe','dwm.exe','LogonUI.exe','svchost.exe','System','Registry','Idle',
  'MemCompression','Memory Compression','WUDFHost.exe','spoolsv.exe','sihost.exe')

$all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, SessionId, CommandLine, @{N='MEM_MB';E={[math]::Round($_.WorkingSetSize/1MB,1)}}
$pids = @{}; foreach($p in $all){ $pids[$p.ProcessId] = $true }
$hasChild = @{}; foreach($p in $all){ $hasChild[$p.ParentProcessId] = $true }
$hasWindow = @{}
foreach($proc in (Get-Process | Where-Object { $_.MainWindowHandle -ne 0 })){ $hasWindow[[int]$proc.Id] = $true }

$dead = $all | Where-Object {
  -not $pids.ContainsKey($_.ParentProcessId) -and   # 親が消滅
  -not $hasChild.ContainsKey($_.ProcessId)   -and   # 子を持たない
  -not $hasWindow.ContainsKey([int]$_.ProcessId) -and   # 生きた可視ウィンドウを持たない(型不一致回避のためintに統一)
  $_.SessionId -ne 0                          -and   # セッション0(サービス/システム)は保護
  $_.Name -notin $CRITICAL                    -and   # システム重要プロセスは保護
  $_.Name -ne 'claude.exe'                    -and   # claudeセッション系は保護
  ($_.CommandLine -notmatch 'lucas-voice|lucas_voice|speak_server')  # 音声デーモン保護
}

"===== 死んでる孤児リーフ (kill候補・dry-run) ====="
if(-not $dead){ "  該当なし"; return }
$dead | Sort-Object MEM_MB -Descending | Select-Object Name, ProcessId, ParentProcessId, SessionId, MEM_MB,
  @{N='Cmd';E={ if($_.CommandLine){$_.CommandLine.Substring(0,[math]::Min(60,$_.CommandLine.Length))}else{''} }} |
  Format-Table -AutoSize | Out-String | Write-Output
("合計: {0}個 / {1} MB" -f @($dead).Count, [math]::Round((@($dead)|Measure-Object MEM_MB -Sum).Sum,1))
"※ これらを消すには kill-dead.ps1 を実行 (管理者権限プロセスは Access denied になる=無視可)"

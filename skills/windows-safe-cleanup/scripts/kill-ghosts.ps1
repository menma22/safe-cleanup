# kill-ghosts.ps1 — 指定したゴーストGUIアプリ族を kill する。
# 二重の安全装置:
#   (1) 窓の再検証: kill直前に各アプリ族が本当に窓ゼロかを確認し、窓を持つ(=開いてる)ものは絶対に殺さない。
#   (2) CPUアイドルゲート(-MaxCpuPct): 指定するとサンプリングし、CPU%がしきい値以上=「バックグラウンドで
#       仕事してる」族は殺さない(idleのゴーストだけ消す)。まひろ方針「動いてない(idle)なら消していい/
#       バックグラウンドタスクが動いてるなら残す」の実装。0(既定)=ゲート無効(手動掃除向け)。
# 使い方(手動): kill-ghosts.ps1 -AppNames ChatGPT,Notion,chrome
# 使い方(自律): kill-ghosts.ps1 -AppNames ChatGPT,Notion,chrome,brave -MaxCpuPct 5
param(
  [Parameter(Mandatory=$true)][string[]]$AppNames,
  [double]$MaxCpuPct = 0
)
$sig = @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public class WinGhK {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc f, IntPtr l);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
  public static List<uint> TaskbarPids() {
    var set = new HashSet<uint>();
    EnumWindows((h,l)=>{
      if(!IsWindowVisible(h)) return true;
      if((GetWindowLong(h,-20) & 0x80)!=0) return true;
      if(GetWindowTextLength(h)==0) return true;
      int c=0; DwmGetWindowAttribute(h,14,out c,4); if(c!=0) return true;
      uint pid; GetWindowThreadProcessId(h,out pid); set.Add(pid); return true;
    }, IntPtr.Zero);
    return new List<uint>(set);
  }
}
'@
if(-not ('WinGhK' -as [type])){ Add-Type -TypeDefinition $sig }
$taskbar = [WinGhK]::TaskbarPids()

# 名前指定されても絶対に殺さないハード保護(誤ってallowlistに混入しても防ぐ)
$PROTECT = @('claude','powershell','pwsh','pythonw','python','wt','WindowsTerminal',
  'explorer','csrss','wininit','services','lsass','dwm','conhost','svchost','node')

# --- pass 1: 窓なし族を候補化 (開いてる族は即PROTECT) ---
$candidates = @(); $openApps = @(); $refuseApps = @()
foreach($name in $AppNames){
  if($name -in $PROTECT){ $refuseApps += $name; "REFUSE $name : 保護対象は名前指定でも殺さない"; continue }
  $fam = Get-Process -Name $name -ErrorAction SilentlyContinue
  if(-not $fam){ "SKIP  $name : 稼働なし"; continue }
  if($fam | Where-Object { $taskbar -contains [uint32]$_.Id }){ $openApps += $name; "PROTECT $name : タスクバー窓あり=開いてるので残す"; continue }
  $candidates += [pscustomobject]@{ Name=$name; Procs=$fam }
}

# --- pass 2: CPUアイドルゲート (候補全体を1回サンプリング) ---
if($MaxCpuPct -gt 0 -and $candidates){
  $cores = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
  $snap = {}; $t0 = Get-Date
  $s1 = @{}; foreach($c in $candidates){ foreach($p in $c.Procs){ try{ $s1[$p.Id] = $p.TotalProcessorTime.TotalMilliseconds }catch{} } }
  Start-Sleep -Milliseconds 2500
  $t1 = Get-Date; $elapsedMs = ($t1 - $t0).TotalMilliseconds
  foreach($c in $candidates){
    $busyMs = 0.0
    foreach($p in $c.Procs){
      $np = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
      if($np -and $s1.ContainsKey($p.Id)){ $busyMs += ($np.TotalProcessorTime.TotalMilliseconds - $s1[$p.Id]) }
    }
    $cpuPct = [math]::Round(($busyMs / $elapsedMs) * 100 / $cores, 1)
    $c | Add-Member -NotePropertyName CpuPct -NotePropertyValue $cpuPct -Force
  }
}

# --- pass 3: kill ---
$freed = 0.0; $ok = 0; $fail = 0; $killedApps = @(); $busyApps = @()
foreach($c in $candidates){
  if($MaxCpuPct -gt 0 -and $c.CpuPct -ge $MaxCpuPct){ $busyApps += $c.Name; ("BUSY  {0} : CPU {1}% >= {2}% =バックグラウンド稼働中なので残す" -f $c.Name, $c.CpuPct, $MaxCpuPct); continue }
  $fam = $c.Procs
  $mem = [math]::Round(($fam|Measure-Object WorkingSet64 -Sum).Sum/1MB,1)
  foreach($p in $fam){ try{ Stop-Process -Id $p.Id -Force -ErrorAction Stop; $ok++ }catch{ $fail++ } }
  $freed += $mem
  $cpuNote = if($MaxCpuPct -gt 0){ " (idle CPU {0}%)" -f $c.CpuPct } else { "" }
  $killedApps += $c.Name
  ("KILLED {0,-12} {1}proc {2}MB{3}" -f $c.Name, $fam.Count, $mem, $cpuNote)
}
""
("=> kill {0} / 失敗 {1} / 約{2}MB 解放" -f $ok, $fail, [math]::Round($freed,1))
Start-Sleep 1
$os = Get-CimInstance Win32_OperatingSystem; $tot=[math]::Round($os.TotalVisibleMemorySize/1MB,1); $free=[math]::Round($os.FreePhysicalMemory/1MB,1)
("現在RAM: 使用 {0}GB / {1}GB ({2}%)" -f [math]::Round($tot-$free,1), $tot, [math]::Round(($tot-$free)/$tot*100,1))

# 機械可読の契約行（2026-08-06 追加）。無人実行の SafeCleanup（scripts\safe-cleanup.ps1）がこの1行だけを
# 解析して結果を得る＝日本語の人間向け出力を正規表現で推測解析しなくて済む。
# killed=消したアプリ族の数 / procs=実際に落としたプロセス数 / apps・busy・open は族名のカンマ区切り。
# この行の存在自体が「kill ループを最後まで回した」証跡（センチネル）なので、消したり書式を変えたりしないこと。
("#RESULT killed={0} procs={1} failed={2} freedMB={3} apps={4} busy={5} open={6}" -f `
  @($killedApps).Count, $ok, $fail, [math]::Round($freed,1), ($killedApps -join ','), ($busyApps -join ','), ($openApps -join ','))

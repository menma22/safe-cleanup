# find-ghosts.ps1 — read-only。「起動してるがタスクバーに窓が無い」ゴーストGUIアプリを検出する。
# 背景: Electron/Chromium系(ChatGPT/Notion/chrome等)はウィンドウを閉じてもプロセスが残り続けることがある。
#   ユーザーは「閉じたつもり」なのにメモリを食い続ける。これを窓の有無で機械判定する。
# 判定: 可視トップレベル窓のうち「タスクバーに出る窓」(WS_EX_TOOLWINDOW除外・DWMクローク除外・タイトルあり)の
#   所有PID集合を作り、GUIアプリのプロセス族がその集合に1つも入っていなければ GHOST。
# 注意: システムトレイに常駐させて「使ってる」アプリも窓なしに見える。ゴースト=常に不要とは限らないので、
#   kill前に必ず一覧をユーザーに見せて確認する(SKILL.md参照)。
param(
  [string[]]$AppNames = @('ChatGPT','Notion','Slack','Discord','Spotify','brave','chrome','msedge',
                          'Code','Cursor','Teams','Zoom','Telegram','Obsidian','WhatsApp','Line','Figma')
)
$sig = @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class WinGh {
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
      if((GetWindowLong(h,-20) & 0x80)!=0) return true;   // WS_EX_TOOLWINDOW -> タスクバー非表示
      if(GetWindowTextLength(h)==0) return true;           // 無題窓は除外
      int cloaked=0; DwmGetWindowAttribute(h,14,out cloaked,4); // DWMWA_CLOAKED (UWP裏側)
      if(cloaked!=0) return true;
      uint pid; GetWindowThreadProcessId(h,out pid); set.Add(pid); return true;
    }, IntPtr.Zero);
    return new List<uint>(set);
  }
}
'@
if(-not ('WinGh' -as [type])){ Add-Type -TypeDefinition $sig }
$taskbar = [WinGh]::TaskbarPids()

"===== タスクバーに窓を持つ(=意図的に開いてる)アプリ ====="
$taskbar | ForEach-Object { $pr = Get-Process -Id $_ -ErrorAction SilentlyContinue; if($pr){ "  $($pr.Name) ($_)" } }
""
"===== ゴースト判定 ====="
Get-Process | Where-Object { $_.Name -in $AppNames } | Group-Object Name | ForEach-Object {
  $fam = $_.Group
  $vis = $fam | Where-Object { $taskbar -contains [uint32]$_.Id }
  $mem = [math]::Round(($fam|Measure-Object WorkingSet64 -Sum).Sum/1MB,1)
  $status = if($vis){ 'OPEN (窓あり=保持)' } else { 'GHOST (窓なし=閉じたのに稼働)' }
  ("{0,-10} {1,3}proc {2,8}MB  => {3}" -f $_.Name, $fam.Count, $mem, $status)
}
"※ GHOST を消すには: kill-ghosts.ps1 -AppNames ChatGPT,Notion,chrome  (先にユーザー確認)"

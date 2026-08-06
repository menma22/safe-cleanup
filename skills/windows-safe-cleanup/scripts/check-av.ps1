# check-av.ps1 — read-only。サードパーティAV(McAfee等プリインbloatware)が居るか、
# それがWindows Defenderを Passive に追いやってCPUを食っていないかを判定する。
# 肝: AVを消して安全かは「Defenderが引き継げるか」で決まる。Defenderが Passive の場合、
#   3rdパーティAVを外すと自動で Active(リアルタイム保護ON) に復帰する=保護は途切れない。
"===== Windows Defender 状態 ====="
try {
  $mp = Get-MpComputerStatus -ErrorAction Stop
  ("AntivirusEnabled   : {0}" -f $mp.AntivirusEnabled)
  ("RealTimeProtection : {0}" -f $mp.RealTimeProtectionEnabled)
  ("RunningMode        : {0}" -f $mp.AMRunningMode)   # Normal=主AV / Passive=3rdパーティに主役を譲って待機
  ("定義最終更新       : {0}" -f $mp.AntivirusSignatureLastUpdated)
} catch { "Defender取得不可: $_" }
""
"===== 登録AVプロダクト (Windowsセキュリティセンター) ====="
Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
  ForEach-Object { ("{0} | productState=0x{1:X}" -f $_.displayName, $_.productState) }
""
"===== 3rdパーティAVサービス/プロセス ====="
$svc = Get-Service | Where-Object { $_.DisplayName -match 'McAfee|Norton|Avast|AVG|Kaspersky|ESET|Bitdefender' }
if($svc){ $svc | Select-Object Status, Name, DisplayName | Format-Table -AutoSize | Out-String | Write-Output } else { "  3rdパーティAVサービスなし" }
""
"# 判定の読み方:"
"#  RunningMode=Passive かつ 3rdパーティAVが Running なら、そのAVが主役でDefenderが待機中。"
"#  そのAVがプリイン(OEM)版で使っていないなら、公式アンインストーラで外すとDefenderが自動でActiveに戻る。"
"#  アンインストールは管理者昇格(UAC)が必要。外した後に必ず本スクリプトで RealTimeProtection=True を確認する。"

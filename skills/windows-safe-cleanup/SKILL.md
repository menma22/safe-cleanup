---
name: windows-safe-cleanup
description: >
  Windows PC の CPU/メモリの無駄な占有を「安全に」掃除するスキル。まひろが「CPUが重い」「メモリ食ってる」
  「ゾンビプロセス」「死んでるプロセスを消して」「バックグラウンドで無駄に動いてるやつ」「タスクバーに無いのに
  動いてるアプリ(ChatGPTやNotionを閉じたのに残ってる等)を消したい」「プリインのMcAfeeとか要らないAVを外したい」
  「PCが遅い・ファンがうるさい」と言ったとき、または常駐プロセス・プロセス整理・リソース逼迫の調査/対処が要る
  ときに必ず使うこと。明示的に「クリーンアップ」と言われなくても、動作の重さ・プロセスの多重・メモリ圧迫の話が
  出たらトリガーする。診断は read-only で即実行してよいが、プロセスの kill は必ず候補を見せて確認を取ってから行う。
---

# Windows 安全クリーンアップ

このスキルは「重い/無駄に占有されてる」を **事実で診断し、誤爆せずに掃除する** ための手順とスクリプト集。
`scripts/` の PowerShell を呼び出して使う（EnumWindows の P/Invoke や孤児判定ロジックは焼き込み済み＝毎回書き直さない）。

## 絶対に守る安全原則（この順に考える）

1. **「今の負荷」は累積CPUで判断しない。** `Get-Process` の CPU 値はプロセス寿命の総和（累積秒）で、「今焼いてる率」ではない。
   Chrome が累積14000秒でも今は2%、ということが普通に起きる。**現在CPUは必ず2サンプルの差分で測る**（`diagnose.ps1` が実施）。
2. **kill は最小スコープ。ブランケット kill 禁止。** 消していいのは (a) 死んでる孤児リーフ、(b) 窓なしゴーストGUIアプリ、だけ。
   「無駄そう」で生きてるものを巻き込まない。**削除より保存がデフォルト。**
3. **保護対象は絶対に触らない**:
   - **自分（この Claude セッション）と Claude デスクトップアプリ** — `claude.exe` は名前で丸ごと除外。
   - **音声デーモン lucas-voice** — リスナー `lucas_voice.py` と `speak_server`。特に **venv の pythonw は「shim親＋実体子」の2プロセス構成で、親shimを殺すと実体と共倒れ**する。孤児リーフ判定（子を持たない）で自動除外されるが、cmdline でも二重に保護。
   - **走行中のスケジュールタスク**（daily-notion-sync / nightly-interview 等の `claude -p` ヘッドレス）。
4. **kill は必ず「見せてから」。** 診断・列挙（`find-*` / `diagnose` / `check-av`）は read-only なので即実行してよい。
   実際に殺す（`kill-*`、AV アンインストール）前は候補一覧をまひろに出して確認を取る。システムトレイ常駐アプリは
   「窓なし」でもゴーストに見えるので、確認なしで殺さない。
5. **完了は実測で閉じる。** kill 後は解放メモリを、AV 削除後は **Defender の RealTimeProtection=True 復帰**を必ず確認する。
   「消えたはず」で終わらせない（保護に穴が空いていないかまで見る）。

## 標準ワークフロー

### 1. 診断（read-only・即実行可）
```powershell
& C:\Users\mahim\.claude\skills\windows-safe-cleanup\scripts\diagnose.ps1
```
現在CPU（サンプリング）・メモリ上位・多重プロセス種別を出す。「重い原因は誰か」をここで事実にする。
CPU張り付きの主犯がユーザーアプリでなく **プリインAV（mc-fw-host 等）や SearchIndexer** のこともある——決めつけない。

### 2. 死んでる孤児プロセスの掃除
```powershell
& ...\scripts\find-dead.ps1     # まず列挙(dry-run)して見せる
& ...\scripts\kill-dead.ps1     # 確認後に実行
```
死んでる = 親が消滅（起動元セッションが無い）かつ子なし（連鎖被害ゼロ）。たいてい少量（statusline残骸・使い捨て
ヘルパ等）。管理者権限プロセスは Access denied で残るが小さいので無視可。

### 3. ゴーストGUIアプリ（閉じたのに稼働）の掃除 ← 効果が大きいことが多い
```powershell
& ...\scripts\find-ghosts.ps1                                  # OPEN/GHOST を判定して見せる
& ...\scripts\kill-ghosts.ps1 -AppNames ChatGPT,Notion,chrome  # 確認後、GHOSTだけ指定
```
タスクバーに窓を持つ = 意図的に開いてる = 保持。窓ゼロのGUIアプリ族 = ゴースト。`kill-ghosts.ps1` は kill 直前に
**再度窓の有無を検証し、窓があるものは殺さない**ので、誤ってOPENなアプリ名を渡しても安全。
※検出対象アプリ名は `find-ghosts.ps1 -AppNames ...` で足せる。

**CPUアイドルゲート（自律運用向け）**: `kill-ghosts.ps1 -MaxCpuPct 5` を付けると、窓なしでも **CPUを使って働いてる
（バックグラウンドタスク稼働中）族は残し、CPUアイドルのゴーストだけ**を消す。人間確認できないヘッドレス自律実行で
「動いてない(idle)なら消す／動いてるなら残す」を守るための関門。手動掃除では省略可（既定0=ゲート無効）。
名前指定でも claude/powershell/pythonw/system 等は `kill-ghosts.ps1` 側のハード保護で拒否される。

## 自律運用（SafeCleanup / 30分ごと・**LLM非使用**）
このスキルの kill スクリプトは、タスクスケジューラのタスク **`SafeCleanup`（30分ごと）** から直接呼ばれる。実体は
`scripts\safe-cleanup.ps1`（決定論的な PowerShell のみ。**LLM も AIエージェントも `claude -p` も一切介在しない**）
＋ `scripts\safe-cleanup.config.json`（許可リスト・しきい値・通知モード・日本語テンプレート）
＋ `scripts\safe-cleanup.task.xml`（タスク定義。再登録用）。
自律実行では **kill-dead は毎回・kill-ghosts は許可リスト＋`-MaxCpuPct 5`** の安全サブセットのみ。許可リストの増減は
`safe-cleanup.config.json` の `appNames` を編集するだけ（再登録も再起動も不要・次の実行から反映）。

**※2026-08-06、定常エージェント `Lucas-HourlyCleanup`（毎時・sonnet5ヘッドレス）から置き換えた（まひろ指示）。**
理由: kill する/残す の判断は最初からすべて**本スキルのスクリプト側に固定**されていた（孤児＋リーフ＋窓なし＋
CRITICAL/セッション0/claude/音声デーモン保護、ゴーストは窓ゼロ再検証＋CPUアイドルゲート＋PROTECT ハード保護）。
LLM の仕事は「決まったスクリプトを決まった順に呼び、出力を日本語1行にまとめる」だけで、旧 prompt.md 自身が
「スクリプト以外の方法で kill するな」と裁量を明示的に禁じていた＝**判断が残っていないのでアルゴリズムで完全に代替できる**。
効果: 1日48回の sonnet5 起動が消えて使用量枠を食わなくなり、実行時間も約100秒→約8秒になった
（掃除エージェント自身が毎回 claude.exe を起動してメモリを食う自己矛盾も解消）。旧実装は `scripts\_retired\` に保管。

**`#RESULT` 契約行（2026-08-06 追加・変更禁止）**: `kill-dead.ps1` / `kill-ghosts.ps1` は最終行に機械可読の
`#RESULT killed=.. failed=.. freedMB=..` を出す。無人実行側はこの1行だけを解析する＝日本語の人間向け出力を
正規表現で推測解析しなくて済む。**この行は「kill ループを最後まで回した」証跡（センチネル）でもある**ので、
消したり書式を変えたりしないこと（`safe-cleanup.ps1` はこの行が無い実行を失敗として扱う）。

### 4. 不要なプリインAV（McAfee 等）の除去（任意・要 UAC）
`check-av.ps1` で「Defender が Passive に追いやられているか」を判定してから。
```powershell
& ...\scripts\check-av.ps1       # Defender=Passive & 3rdパーティAV=Running なら除去候補
```
**除去して安全な条件**: Defender が Passive（＝そのAVが主役を奪っている）で、そのAVがプリイン/未使用であること。
外せば Defender が自動で Active に戻り保護は途切れない。手順:
1. アンインストール文字列を取得（`HKLM:\...\Uninstall\*` の `UninstallString`。McAfee WPS は `mc-fw-host` を含む `wps\...\mc-update.exe /uninstall`）。
2. **管理者昇格が要る**。`Start-Process <uninstaller> -ArgumentList '/uninstall' -Verb RunAs` を **`run_in_background: true` で起動**
   （前面でUAC待ちすると2分でタイムアウトしプロンプトが埋もれる）。まひろに「画面のUACで『はい』を押して、
   アンインストーラを最後まで進めて」と伝える。**AVの除去はセキュリティ設定の変更なので、まひろの明示依頼＋UAC承認が必須**——
   勝手には進めない。
3. 完了後に `check-av.ps1` を再実行し、**RealTimeProtection=True / RunningMode=Normal** と当該サービス/フォルダの消滅を確認する。

## この環境で踏んだ実際の教訓（再発防止）

- **累積CPU誤認**: 最初「claude/音声がCPUゾンビ」と疑ったが、サンプリングしたら主犯は McAfee(mc-fw-host 21.6%)＋SearchIndexer。
  claude系は今は数%。→ 原則1。
- **"ゾンビ"の実態**: Windows に Unix 的 defunct は無い。実害は「閉じたのに残るGUIアプリ」と「プリインAVのCPU常時消費」。
  本セッションでは ChatGPT/Notion/chrome のゴースト計 **44プロセス・約3.1GB** が最大の無駄だった。
- **音声shim共倒れ**: lucas-voice の venv pythonw を親から殺すと実体リスナーが道連れになる。→ 保護対象で明示除外。
- **UAC埋もれ**: 昇格起動を前面でやるとUAC待ちでブロック→タイムアウト。バックグラウンド起動が正。
- **「子沢山claude＝孤児」リーパーを作るな（一次確認で棄却）**: 「親がclaude.exeで子を大量に抱え33h生存」という
  シグネチャは孤児に見えるが、一次照合すると **WindowsApps の Claude デスクトップアプリ本体**（`desktop_app=True`・
  **タスクバー窓あり**・pidはバージョン更新で変わる 20284→19356 等）だった。**現役の Claude 本体で、しかもヘッドレスで
  走る自分自身のセッションがこの木の中にいる**。このシグネチャで刈ると本体＋実行中セッションを自殺する。よって
  `claude.exe` は名前で全保護し、「子の数/生存時間」で claude を reap しない。explorer由来の木（手で開いた窓）と
  定刻`claude -p`（正常終了）も同様に対象外——これは別セッションの実測でも裏取りされた。真に死んだ claude 子孫は
  親が消滅すれば find-dead が leaf として拾う（それで十分・それ以上は踏み込まない）。

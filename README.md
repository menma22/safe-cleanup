# SafeCleanup — LLM を使わない Windows 自動クリーンアップ

Windows の「閉じたのに残っているアプリ」と「親が消滅した孤児プロセス」を **30分ごとに自動で・安全に**掃除する仕組み。
**AI エージェントも LLM も一切使っていない**（純粋な PowerShell とタスクスケジューラだけ）。

## この repo の主題: 定常 AI エージェントを、素のプログラムに作り直した記録

元々これは **`claude -p`（ヘッドレス Claude）を毎時起動する「定常エージェント」** だった。作り直した理由は単純で、
**LLM が何も判断していなかった**から。

| | 判断内容 | どこに実装されていたか | LLM の関与 |
|---|---|---|---|
| 孤児プロセスの選定 | 親消滅 ∧ 子なし ∧ 窓なし ∧ 保護対象でない | `kill-dead.ps1`（引数ゼロ・完全固定） | なし |
| ゴーストアプリの選定 | 窓ゼロ再検証 ∧ CPU アイドル ∧ 許可リスト内 | `kill-ghosts.ps1` | なし |
| 対象アプリ・しきい値 | 固定値 | プロンプトに直書き | なし |

LLM の仕事は「決まったスクリプトを決まった順に呼び、出力を1行にまとめる」だけだった。
しかも旧プロンプト自身が「**スクリプト以外の方法で kill するな**」と明示的に裁量を禁じていた
＝**設計上 LLM の判断余地はゼロ**。だからアルゴリズムで完全に置き換えられた。

### 置き換えた効果（実測）

| | 旧（定常 AI エージェント） | 新（決定論システム） |
|---|---|---|
| LLM 起動回数 | 24 回/日 | **0 回** |
| 1回の実行時間 | 約 100 秒 | **約 8 秒** |
| 実行間隔 | 毎時 | 30 分ごと |
| 失敗しうる原因 | 起動失敗 / OAuth 切れ / 使用量上限 / ネットワーク断 / スクリプト異常 | **スクリプト異常のみ** |
| 皮肉な副作用 | 掃除役自身が毎回 `claude.exe` を起動してメモリを食う | なし |

**教訓**: 「定刻に自動で走らせたい」は「AI エージェントにする」と同義ではない。
着手前に次の4問を通し、**1つでも「いいえ」なら素のスクリプトで作る**。

1. 自然言語の理解・生成が要るか？
2. 判断が文脈依存で、事前に条件として書き下せないか？（書き下せるなら `if` で足りる）
3. 入力が非定型か？
4. 手順が固定でなく、状況に応じて分岐・探索する必要があるか？

判定のコツ: **プロンプトを書いてみて「〜するな」という禁止事項ばかりになったら、それは裁量を潰している
＝ LLM が要らない証拠。**

## 安全設計

「迷ったら殺さない」を構造で担保する。以下は**名前で指定しても殺されない**。

- システム重要プロセス（`csrss` / `wininit` / `services` / `lsass` / `smss` / `winlogon` 等）
  ※これらは親（smss）が設計上先に終了するため**常に孤児に見える**が、kill すると Windows がクラッシュする
- セッション 0（サービス／システム）
- `claude` / `powershell` / `pythonw` / `explorer` / `node` などのハード保護リスト
- **可視ウィンドウを持つプロセス**（＝ユーザーが今見ている可能性がある）
- **タスクバーに窓を持つアプリ**（＝意図的に開いている。kill 直前に再検証する）
- **CPU を使って働いているアプリ**（＝バックグラウンドタスク稼働中。`-MaxCpuPct` のアイドルゲート）

消すのは「親が消滅し子も持たない孤児リーフ」と「窓ゼロかつ CPU アイドルのゴーストアプリ」だけ。

## 構成

```
scripts/
  safe-cleanup.ps1          # 本体（タスクスケジューラの入口）。ASCII-only・BOM なし
  safe-cleanup.config.json  # 設定（UTF-8）。対象アプリ・しきい値・通知・日本語テンプレート
  safe-cleanup.task.xml     # タスク定義（UTF-16）
  toast-notify.ps1          # Windows トースト通知（BurntToast → NotifyIcon フォールバック）
skills/windows-safe-cleanup/
  SKILL.md                  # 手動運用の手順書と、踏んだ実際の教訓
  scripts/
    diagnose.ps1            # read-only。現在CPU（サンプリング差分）とメモリ上位
    find-dead.ps1           # read-only。孤児リーフの列挙（dry-run）
    kill-dead.ps1           # 孤児リーフの kill
    find-ghosts.ps1         # read-only。OPEN / GHOST の判定
    kill-ghosts.ps1         # ゴーストアプリの kill（窓再検証＋CPUアイドルゲート）
    check-av.ps1            # read-only。サードパーティAVがDefenderをPassiveにしていないか
```

### 設計上のキモ

- **`#RESULT` 契約行**: `kill-*.ps1` は最終行に `#RESULT killed=.. failed=.. freedMB=..` を出す。
  呼び出し側はこの1行だけを解析するので、人間向けの日本語出力を正規表現で推測解析しなくて済む。
  **この行は「kill ループを最後まで回した」証跡（センチネル）** でもあり、行が無い実行は失敗として扱う。
  → 成否を「プロセスが exit したか」で判定しない（それは「何もせず正常終了」を成功と誤認する）。
- **エンコーディングの不変条件**: Windows PowerShell 5.1 は BOM なし UTF-8 を cp932 と誤読し、
  **化けたバイト列が隣接行のパースまで壊す**。よって
  **日本語を含む .ps1 は BOM 付き UTF-8**、**入口スクリプトは ASCII-only にして日本語を設定ファイルへ隔離**する。
- **通知の静粛化**: 「何か消したら通知」では静かにならない（普通に PC を使うだけで毎回 5〜15MB の孤児が出るため
  結局 48 回/日 鳴る）。条件は「**失敗した or ゴーストアプリを消した or `notifyMinFreedMB` 以上解放した**」。
  鳴らさなかった回も health ログに `notify=skipped` が残るので、沈黙と故障は区別できる。
- **多重起動ガードはタスクの `ExecutionTimeLimit` より短くする**。ガードの寿命が実行上限を超えると、
  クラッシュで残った古いロックが正当な次回実行を殺す（安全網が障害になる）。

## 導入

前提: Windows 10/11、Windows PowerShell 5.1。トーストを本番形式で出すなら [BurntToast](https://github.com/Windos/BurntToast)（無くてもバルーンにフォールバックする）。

```powershell
# 1. scripts/ と skills/ を任意の場所へ配置する
# 2. safe-cleanup.ps1 冒頭の $root / $skillDir と、task.xml 内の -File パスを配置先に合わせる
# 3. task.xml の <UserId> を自分の SID に置き換える  ( whoami /user で確認 )
# 4. タスクを登録する
Register-ScheduledTask -TaskName SafeCleanup -Xml (Get-Content .\scripts\safe-cleanup.task.xml -Raw) -Force
```

> **⚠️ パスは `C:\Users\mahim\.claude\...` にハードコードされている**（作者の環境の実物をそのまま置いている）。
> 他環境で使う場合は上記 2〜3 の書き換えが必須。

削除するとき:

```powershell
Unregister-ScheduledTask -TaskName SafeCleanup -Confirm:$false
```

まず何が消えるか見たいだけなら、read-only の dry-run から:

```powershell
& .\skills\windows-safe-cleanup\scripts\find-dead.ps1
& .\skills\windows-safe-cleanup\scripts\find-ghosts.ps1
```

## 設定（`scripts/safe-cleanup.config.json`）

編集すれば**次回実行から反映される**（タスクの再登録も PC の再起動も不要）。

| キー | 意味 |
|---|---|
| `appNames` | ゴースト判定の対象アプリ族。**ここに無いアプリは絶対に触らない** |
| `maxCpuPct` | CPU アイドルゲート（既定 5%）。下げると厳しく（消しにくく）なる |
| `notifyMode` | `always`＝毎回通知 / `changed`＝鳴らす価値がある時だけ（既定） |
| `notifyMinFreedMB` | `changed` で通知する解放量のしきい値（既定 100MB） |
| `keepLogDays` | 日次ログの保持世代数（既定 14） |
| `labels` | 通知・ログの日本語テンプレート |

## ログ

| ファイル | 内容 |
|---|---|
| `logs/safe-cleanup-<日付>.log` | 各スクリプトの生出力＋サマリ1行（日次ローテ） |
| `logs/safe-cleanup.health` | 1回1行の機械可読サマリ（`result` / `dead` / `deadFailed` / `ghost` / `freedMB` / `ram` / `notify`） |

`deadFailed` は「管理者権限プロセスなので kill が拒否された数」。永久に消せない候補が黙って見えなくなるのを防ぐために出している。

## 検証結果（2026-08-06 実測）

- 手動起動・**タスクスケジューラによる定刻発火（13:30:01）** の双方で `exit 0` / `LastTaskResult=0`
- 開いているアプリ（chrome・VS Code・msedge・Slack）は**すべて PROTECT** され無傷。消えたのは孤児リーフのみ
- トースト到達 `rc=0`／静粛時 `notify=skipped` を両方実証
- `#RESULT` 行が無い場合に失敗判定されることを単体で確認
- 編集後に ASCII-only / BOM 保持 / パース 0 エラーを再検証

## 注意

このリポジトリは、作者のローカル環境（`~/.claude/`）で**実際に動いている実物のエクスポート**。
元環境側を直したらここへ反映する必要がある（自動同期はしていない）。

## ライセンス

MIT

# Durepo 実装プラン

> Status: reviewed and amended on 2026-07-17. This document is the long-form
> design. The decisions in the following section and in
> [plan-review.md](./plan-review.md) supersede older alternatives that remain as
> historical context later in the document.

> MVP 1 implementation status (2026-07-17): complete. SQLite WAL metadata,
> resumable FSEvents batch state, retention, background error reporting, safe
> restore, and generated-directory filtering are implemented. The automated
> suite includes a 10,000-file deletion case; signed LaunchAgent restart and
> crash-recovery behavior were also exercised on macOS 26. App Store Connect
> submission and a physical Mac reboot remain release acceptance checks rather
> than implementation work.

> Version 1.0 implementation status (2026-07-17): complete as a release
> candidate. Destructive-change protection, paginated diff and selective
> restore, pre-restore snapshots with rollback-safe in-place replacement,
> hard-link/sparse/xattr/ACL fidelity, capacity retention, safe GC, scheduled
> integrity diagnostics, menu-bar controls, and local diagnostic export are
> implemented. The automated suite covers 10,000-file deletion, corruption,
> metadata fidelity, retention, and restore safety. App Store Connect upload,
> physical reboot acceptance, and optional Icon Composer conversion remain
> release operations rather than code implementation.

> Incremental snapshot update (2026-07-17): FSEventsの変更パスとcommit境界を
> SQLiteへ永続化し、通常イベントは前回のcurrent-entry indexへ対象パスだけを
> reconcileする。変更ファイルは最大4並列で処理し、同一APFS volumeでは
> `fclonefileat`で原子的なCoW cloneを固定してからSHA-256を計算する。
> clone非対応時は4 MiB以下をメモリ、それ以上を1 MiB streamingで保存する。
> Dropped/MustScan/RootChanged、index不在、manual snapshotはfull scanへ戻る。

## 0. レビュー後の確定事項

- 最低対応は **macOS 26 Tahoe / Apple Silicon** とする。macOS 27 はベータのため必須にせず、Xcode 27正式版で再検証する。
- Mac App Store配布を前提とし、GUIとLaunchAgentの双方で **App Sandboxを必須** とする。Sandbox無効版は製品構成にしない。
- 監視対象は `NSOpenPanel` でユーザーが明示選択し、GUIとAgentがそれぞれ自分で作成したread-writeのsecurity-scoped bookmarkを保存する。GUIからAgentへは通常のbookmarkで一時的にアクセス権を引き渡し、app-scoped bookmark自体はプロセス間で流用しない。App Groupでは登録情報、CAS、manifestを共有する。
- Agent実行ファイルはアプリ内の `Contents/Resources`、launchd plistは `Contents/Library/LaunchAgents` に置き、`BundleProgram` と `SMAppService.agent(plistName:)` で登録する。
- 保存先はApp Group container配下を既定とする。外付け保存先は別途ユーザー選択とbookmarkが必要であり、監視対象配下への保存は禁止する。
- Durepoは同一ユーザー権限を完全に敵対者とみなす改ざん耐性バックアップではない。Full Disk Accessを持つプロセスやユーザー自身はDurepoデータも削除し得る。保証範囲は「AIエージェント等の直近の破壊的操作からの高速復旧」であり、ownCloud/iCloud、外付け複製、リモートrepositoryへのpushによる長期バックアップは製品目的に含めない。
- 復元は既定で新規ディレクトリへ行い、パスを検証し、同一親ディレクトリ内の一時領域からrenameする。元の場所への復元は、pre-restore snapshot、ユーザーの明示確認、同一親でのstaging、失敗時rollback、自己イベント抑制を必須とする（実装済み）。
- `.git` の内容は保存するが、復元時の `*.lock` は既定で除外または明示警告する。実行中プロセス由来のロックを忠実に復元するとGitを使用不能にするためである。
- Mac App Store版はApp Storeの審査工程が同等のセキュリティ検査を含むため、個別のnotarizationは不要。Developer IDによる直接配布物を併設する場合だけHardened Runtime、`notarytool`、stapleを必須とする。
- アプリ内自動アップデータはMac App Store版に含めない。更新はApp Storeに委ねる。
- GUIは英語をdevelopment regionとし、日本語リソースを同梱する。macOSの優先言語が日本語なら日本語、それ以外は英語へフォールバックする。
- ライセンスはMIT。プライバシーポリシーとサポートURL（GitHub Issues）をApp Store Connectに登録する。
- Snapshot formatにはversionを持たせる。MVPのJSON manifestはsmoke test用で、SQLite WALへの移行時も後方読込または明示migrationを用意する。

### macOS 26 / 27の採用方針

- macOS 26: Swift 6.2のstrict concurrencyを有効化し、I/Oはactorへ隔離する。大量のsnapshot表示には改善されたSwiftUI `List`/`Table`を使い、Instruments 26のSwiftUI・Hangs・Time Profilerで測定する。
- macOS 26: Icon Composer対応の多層アイコンをリリース前に用意する。smoke buildではAppIcon asset catalogと1024px原画を保持する。
- macOS 26: `Span`/`RawSpan`はコピー・参照カウント削減に有望だが、計測なしにCASハッシュ経路へ導入しない。現在は1 MiBのbounded streaming I/Oを使用する。
- macOS 26/APFS: 同一volumeでは`fclonefileat`を使い、削除・上書きから独立したfile-level CoW cloneを原子的に固定する。別volumeまたはclone非対応filesystemではbounded copyへfallbackする。
- macOS 27: Swift Systemの`Stat`、`FilePath.stat()`、`FileDescriptor.stat()`へ、Xcode 27正式版で移行する。現在の`Darwin.lstat/fstat`をavailability付きfallbackとして残す。
- macOS 27: Swift Executors/System Traceの改善と`@concurrent`を、GUIのMainActorからI/Oを分離できているかの検証に使う。ベータ専用APIを1.0の必須経路にはしない。
- macOS 27のDiskImageKit/ASIFはVirtualization用途が中心であり、リポジトリCASの代替にはしない。

## 1. 概要

Durepoは、AIエージェントや開発ツールの誤操作によるローカルリポジトリの破壊を防ぎ、迅速に復旧するためのmacOS向けバックアップ・スナップショットツールである。

主な想定事故は以下とする。

- リポジトリ配下のファイルが大量に削除される
- `.git` ディレクトリを含めて削除される
- 未コミットの変更が失われる
- 誤った生成処理や置換処理により、多数のファイルが破壊される
- AIエージェントが広いファイルアクセス権限を持つことで、意図しない変更を行う

Gitの履歴だけでは、未コミットファイルや`.git`自体の削除には対応できないため、DurepoはGitとは独立したスナップショットを保持する。

---

## 2. 対象環境

### 対応OS

- macOS
- Apple Silicon
- APFSを前提とする

### 最低対応バージョン

- macOS 26 Tahoe以降

最低対応バージョンを高めに設定することで、以下を前提にできる。

- SwiftUI
- SMAppService
- CryptoKit
- NSXPCConnection
- modern concurrency
- APFS
- arm64専用ビルド

---

## 3. 基本方針

Durepoは以下の2つのコンポーネントで構成する。

```text
Durepo.app
├── GUIアプリ
└── LaunchAgent
```

### GUIアプリ

GUIアプリは、設定、監視、復旧操作を担当する。

主な機能は以下とする。

- 監視対象ディレクトリの登録
- 監視対象ディレクトリの削除
- バックアップ保存先の設定
- 保持ポリシーの設定
- LaunchAgentの起動・停止
- 現在の監視状態の表示
- 最近のファイル変更の表示
- スナップショット一覧の表示
- スナップショット間の差分表示
- ファイル単位の復元
- ディレクトリ単位の復元
- リポジトリ全体の復元
- 大量削除や異常検知の通知表示

### LaunchAgent

LaunchAgentは、ユーザーがログインしている間、バックグラウンドで常駐する。

主な責務は以下とする。

- FSEventsによるファイルシステム監視
- FSEventsのイベントID管理
- イベントジャーナルの記録
- 変更イベントの集約
- 差分スキャン
- ファイル内容の保存
- スナップショットの作成
- 大量削除の検知
- バックアップデータの整合性確認
- 保存期間に基づく古いデータの削除
- GUIアプリとのXPC通信

---

## 4. LaunchAgentを採用する理由

Durepoの監視対象は、ログインユーザーが所有する開発ディレクトリである。

想定例は以下。

```text
~/Developer
~/Projects
~/Source
~/Documents/Repositories
```

AIエージェントも通常はログインユーザーのコンテキストで動作するため、システム全体を監視する必要はない。

そのため、初期実装ではroot権限を持つLaunchDaemonは使用せず、ユーザー単位のLaunchAgentを採用する。

LaunchAgentの利点は以下。

- root権限が不要
- インストール時の認証が不要
- ユーザー所有ファイルへのアクセスが容易
- ユーザー単位で設定を分離できる
- GUIアプリとの連携が容易
- 通知機能を利用しやすい
- セキュリティリスクを抑えやすい
- アップデートやアンインストールが比較的簡単

通常のmacOS環境では、AIエージェントが認証なしに`sudo`を実行できる状況は想定しにくい。

したがって、バックアップ領域をroot所有にして保護するよりも、監視と復旧の使いやすさを優先する。

---

## 5. システム構成

```text
┌──────────────────────────────┐
│          Durepo.app           │
│                              │
│  SwiftUI GUI                 │
│  - 設定                      │
│  - 状態表示                  │
│  - スナップショット閲覧      │
│  - 差分表示                  │
│  - 復元操作                  │
└──────────────┬───────────────┘
               │
               │ NSXPCConnection
               │
┌──────────────▼───────────────┐
│       Durepo LaunchAgent      │
│                              │
│  FSEvents Monitor            │
│  Event Journal               │
│  Snapshot Coordinator        │
│  Content Store               │
│  Retention Manager           │
│  Integrity Checker           │
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│        Backup Storage         │
│                              │
│  SQLite Metadata             │
│  Snapshot Manifests          │
│  Content Addressable Store   │
└──────────────────────────────┘
```

---

## 6. FSEvents監視

### 採用理由

FSEventsは、macOSで大規模なディレクトリツリーを監視する用途に適している。

主な利点は以下。

- ディレクトリツリー全体を再帰的に監視できる
- ディレクトリごとにwatchを作成する必要がない
- 大量のファイルが存在しても比較的低負荷
- イベントIDを保持できる
- アプリ再起動後に途中からイベントを取得できる
- イベント欠落を検出できる
- APFSとの親和性が高い

### 監視単位

監視対象として登録されたルートディレクトリごとにFSEventStreamを作成する。

例:

```text
~/Projects/project-a
~/Projects/project-b
~/Developer/project-c
```

監視対象が多数ある場合は、共通の親ディレクトリをまとめて監視する構成も検討する。

### ファイル単位イベント

可能であれば、FSEventStream作成時に以下のフラグを使用する。

```text
kFSEventStreamCreateFlagFileEvents
```

これにより、ディレクトリ単位だけでなく、ファイル単位に近いイベントを取得する。

ただし、FSEventsの通知を完全な変更履歴とはみなさない。

イベントは以下の目的に使用する。

- 変更が発生したことの検知
- 差分スキャン対象の絞り込み
- スナップショット作成タイミングの決定
- 大量削除や異常変更の検知

最終的な状態の正しさは、ファイルシステムの再スキャンによって確認する。

---

## 7. FSEventsイベントIDの管理

監視対象ごとに、最後に正常処理したイベントIDを保存する。

例:

```json
{
  "repositoryID": "4E27A6C8-4AC1-4B71-97B6-91EF48B050B7",
  "lastProcessedEventID": 238449821
}
```

LaunchAgent再起動時には、保存済みのイベントIDを`sinceWhen`としてFSEventStreamを再開する。

```text
LaunchAgent停止
    ↓
ファイル変更発生
    ↓
LaunchAgent再起動
    ↓
保存済みイベントID以降のイベントを取得
```

ただし、以下の場合はフルスキャンを実行する。

- 保存済みイベントIDが無効
- イベント履歴が失われた
- Event ID Wrappedが通知された
- User Droppedが通知された
- Kernel Droppedが通知された
- Must Scan SubDirsが通知された
- ボリュームが変更された
- 監視対象が別のファイルシステムへ移動した

---

## 8. イベント処理フロー

FSEventsのコールバックでは、重い処理を実行しない。

コールバックではイベントを内部キューへ追加するだけとする。

```text
FSEvents callback
    ↓
内部イベントキュー
    ↓
SQLiteイベントジャーナル
    ↓
Debounce / Coalesce
    ↓
差分スキャン
    ↓
スナップショット作成
```

### Debounce

エディタやビルドツールは、短時間に大量の変更イベントを発生させる。

そのため、例えば以下のような待機時間を設ける。

```text
通常変更: 最後のイベントから500ms〜2秒
大量変更: 即時または短時間で処理開始
```

イベントが継続している場合でも、最大待機時間を設定する。

例:

```text
debounce: 1秒
maximum delay: 10秒
```

これにより、長時間継続する変更でも定期的にスナップショットを確定できる。

---

## 9. イベントジャーナル

FSEventsから受け取ったイベントは、処理前にSQLiteへ記録する。

目的は以下。

- LaunchAgentクラッシュ時の復旧
- 未処理イベントの再処理
- 異常削除の分析
- GUI上での履歴表示
- デバッグ
- 復旧操作の根拠表示

テーブル例:

```sql
CREATE TABLE file_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    repository_id TEXT NOT NULL,
    event_id INTEGER,
    path TEXT NOT NULL,
    flags INTEGER NOT NULL,
    received_at TEXT NOT NULL,
    processed_at TEXT,
    batch_id TEXT
);
```

イベントジャーナルへの記録と、イベント処理状態の更新はトランザクションで行う。

---

## 10. スナップショット方式

Durepoは、ファイルを単純にディレクトリコピーするのではなく、Content Addressable Storage方式を採用する。

### Content Addressable Storage

ファイルの内容をハッシュ化し、ハッシュ値をキーとして保存する。

例:

```text
objects/
├── 0a/
│   └── 0a86c7...
├── 8f/
│   └── 8f4e11...
└── d2/
    └── d213ca...
```

ハッシュアルゴリズムの初期候補はSHA-256とする。

SwiftではCryptoKitを利用できる。

同じ内容のファイルは一度だけ保存されるため、スナップショットを多数作成しても重複を抑えられる。

### 保存単位

通常ファイルは以下の順で処理する。

```text
ファイル読み込み
    ↓
SHA-256計算
    ↓
既存オブジェクト確認
    ↓
未保存なら一時ファイルへ書き込み
    ↓
fsync
    ↓
atomic rename
```

途中でクラッシュしても不完全なオブジェクトが正式データとして扱われないようにする。

---

## 11. スナップショットマニフェスト

スナップショットごとに、リポジトリ全体の状態を表すマニフェストを保存する。

例:

```json
{
  "snapshotID": "AFAAB119-EF39-438B-AE02-5CDEED815BDC",
  "repositoryID": "4E27A6C8-4AC1-4B71-97B6-91EF48B050B7",
  "createdAt": "2026-07-17T10:15:32+09:00",
  "lastEventID": 238449821,
  "reason": "event",
  "files": {
    "Sources/App.swift": {
      "type": "file",
      "hash": "sha256:8f4e11...",
      "size": 9821,
      "mode": 420,
      "modifiedAt": "2026-07-17T10:15:31+09:00"
    },
    ".git/HEAD": {
      "type": "file",
      "hash": "sha256:d213ca...",
      "size": 23,
      "mode": 420,
      "modifiedAt": "2026-07-17T10:14:03+09:00"
    }
  }
}
```

実際の実装では、巨大なJSONを毎回作成するよりも、SQLiteまたはバイナリ形式で管理することを検討する。

初期実装ではSQLite中心でもよい。

---

## 12. メタデータ管理

SQLiteに以下の情報を保存する。

- 監視対象リポジトリ
- 監視設定
- 最終FSEvents ID
- ファイルイベント
- スナップショット
- スナップショット内のファイル一覧
- オブジェクト参照情報
- 復元履歴
- 異常検知履歴
- バックアップ容量
- 保持ポリシー

テーブル案:

```text
repositories
repository_settings
file_events
snapshots
snapshot_entries
objects
alerts
restore_history
```

SQLiteはWALモードを使用する。

---

## 13. `.git`ディレクトリの扱い

`.git`ディレクトリは標準でバックアップ対象とする。

Durepoの目的上、`.git`を除外してはならない。

保存対象には以下を含める。

```text
.git/HEAD
.git/config
.git/index
.git/refs
.git/logs
.git/objects
.git/packed-refs
.git/worktrees
```

ただし、Gitの一時ファイルやロックファイルは、スナップショット時点で存在した場合、そのまま保存する。

例:

```text
.git/index.lock
.git/refs/heads/main.lock
```

復元時には、ロックファイルを復元するかどうかを選択できるようにしてもよい。

初期実装では忠実な完全復元を優先する。

---

## 14. シンボリックリンクと特殊ファイル

### シンボリックリンク

シンボリックリンクは、リンク先を辿らず、リンクそのものを保存する。

保存情報:

- リンク先文字列
- パーミッション
- 更新日時

監視対象ディレクトリ外へのリンクを自動的に辿ってはならない。

### ディレクトリ

ディレクトリについて以下を保存する。

- パーミッション
- 更新日時
- 拡張属性
- ACL

### 特殊ファイル

初期実装では以下を対象外とする案がある。

- socket
- FIFO
- device file

検出した場合は、GUIに警告を表示する。

---

## 15. macOS固有メタデータ

可能な範囲で以下を保存する。

- POSIX mode
- UID
- GID
- modification time
- creation time
- extended attributes
- ACL
- Finder metadata
- quarantine attribute
- resource fork

初期MVPでは、最低限以下を優先する。

- ファイル内容
- パス
- ファイル種別
- POSIX mode
- modification time
- シンボリックリンク情報

拡張属性とACLは次フェーズでもよい。

---

## 16. 差分スキャン

FSEventsは変更通知であり、完全な状態データベースではない。

そのため、イベントを受け取ったパスについて、ファイルシステムを再確認する。

処理例:

```text
変更イベント
    ↓
対象パスのstat
    ↓
存在する
    ├── ファイル内容とメタデータを取得
    └── 現在のスナップショットと比較
存在しない
    └── 削除として記録
```

ディレクトリ単位の変更やイベント欠落が疑われる場合は、そのディレクトリを再帰的にスキャンする。

実装では、イベントごとの相対パスをSQLite `event_paths`へ保存し、snapshot開始時のevent IDを境界として読み出す。前回確定snapshotの全entryとfingerprintは`current_entries`へ保存する。通常イベントでは対象パスと子孫だけを削除・再走査してmanifest全体を再構成し、未変更entryのCAS hashを再利用する。

変更ファイルの取得経路は以下とする。

```text
同一APFS volume
    fclonefileat(source fd → CAS temp)
    → cloneをSHA-256
    → CASへrename

clone非対応・別volume
    4 MiB以下: メモリへ安定読取 → hash → CASに無い場合だけwrite
    4 MiB超: 1 MiB単位でhash + streaming write
```

file-level cloneは元ファイル削除後も独立して残るが、repository全体を同一時刻に固定するvolume snapshotではない。snapshot中に到着した後続イベントは未commitのまま残し、次のincremental snapshotでreconcileする。I/Oは最大4ファイルに限定して並列化し、OSLog `snapshot` categoryと`CreateSnapshot` signpostへscan/capture/total時間と取得方式を記録する。

---

## 17. 初回スナップショット

監視対象ディレクトリを追加した時点で、必ず初回フルスナップショットを作成する。

```text
監視対象追加
    ↓
初回フルスキャン
    ↓
初回スナップショット確定
    ↓
FSEvents監視開始
```

イベント監視開始と初回スキャンの間に変更を取りこぼさないよう、以下の順序を検討する。

```text
現在のFSEvents IDを取得
    ↓
フルスキャン
    ↓
取得済みID以降のFSEventsを処理
    ↓
整合状態を確定
```

または、FSEventStreamを先に開始し、初回スキャン中のイベントをキューへ蓄積する。

---

## 18. 大量削除・異常変更の検知

Durepoは通常のバックアップだけでなく、AIエージェントによる異常操作を検知する。

検知条件案:

- 5秒以内に100ファイル以上削除
- 10秒以内に監視対象の10%以上を削除
- `.git`ディレクトリが削除された
- リポジトリ直下の複数ディレクトリが同時に削除された
- ファイル総数が短時間に大幅減少した
- 一定量以上のファイルがゼロバイト化した
- 多数のファイルが同一内容へ置換された
- 多数のファイル拡張子が一括変更された
- 大量のrenameが発生した
- 監視対象ルート自体が削除された

異常検知時の処理:

```text
異常イベント検知
    ↓
直前の確定済みスナップショットを保護
    ↓
現在状態を追加スナップショットとして保存
    ↓
自動削除・pruneを一時停止
    ↓
macOS通知を表示
    ↓
GUIに警告を表示
```

Durepoは、ファイル変更を自動的にブロックするものではない。

初期実装では、検知、保存、通知、復旧を主目的とする。

---

## 19. スナップショットのタイミング

スナップショット作成条件は以下とする。

### イベント駆動

- ファイル変更イベントを受信
- debounce後に作成
- 変更が継続していても最大待機時間到達で作成

### 定期チェック

イベント欠落対策として、定期的に整合性スキャンを実施する。

例:

```text
軽量整合性チェック: 1時間ごと
フル整合性チェック: 1日1回
```

### 手動作成

GUIから任意のタイミングでスナップショットを作成できる。

### 重要イベント

以下の場合は即時スナップショットを検討する。

- `.git`配下の大規模変更
- 大量削除
- 監視対象ルートの削除
- 異常変更検知
- LaunchAgent停止前
- アプリ更新前

---

## 20. 保持ポリシー

保持ポリシーは設定可能にする。

例:

```text
直近1時間: 全スナップショット
直近24時間: 5分ごと
直近7日: 1時間ごと
直近30日: 1日ごと
それ以前: 1週間ごと
```

または、以下の制限を選択できるようにする。

- 最大保存期間
- 最大使用容量
- 最大スナップショット数
- リポジトリごとの上限
- 異常検知スナップショットは削除対象外

初期実装では、単純な期間・容量ベースから開始する。

---

## 21. Garbage Collection

CASに保存されたオブジェクトは、スナップショットから参照されている限り削除しない。

リポジトリ登録の削除時は確認ダイアログを表示し、次を明示的に選択する。

- `スナップショットを削除`: metadataとmanifestを削除するが、CAS objectは残す。
- `スナップショットを完全に削除`: 対象manifestが参照していたCAS objectのうち、他の保持snapshotから参照されていないものだけを削除する。

GUIとAgentのsnapshot作成、および完全削除は保存領域のプロセス間ロックで直列化する。登録解除後に待機中のAgentがsnapshotを再作成しないよう、Agent経由の作成時はロック取得後にもrepository登録を再確認する。

Garbage Collectionの処理:

```text
保持対象スナップショットを決定
    ↓
参照されているオブジェクト一覧を作成
    ↓
未参照オブジェクトを抽出
    ↓
猶予期間経過後に削除
```

スナップショット削除とオブジェクト削除は別処理にする。

誤削除を防ぐため、未参照になった直後には削除しない。

例:

```text
GC猶予期間: 7日
```

異常検知中はGCを停止する。

---

## 22. 保存先

初期設定では以下を候補とする。

```text
~/Library/Application Support/Durepo/
```

例:

```text
~/Library/Application Support/Durepo/
├── durepo.sqlite
├── objects/
├── manifests/
├── logs/
└── temp/
```

ただし、監視対象リポジトリと同じディレクトリ配下には保存しない。

外付けストレージも保存先として選択できるようにする。

将来的な候補:

- 外付けAPFSボリューム
- NAS
- S3互換ストレージ
- iCloud Drive以外のクラウドバックアップ
- 別Macへの転送

MVPではローカルストレージを優先する。

---

## 23. セキュリティスコープ付きブックマーク

Sandboxを有効にする場合、GUIから選択された監視対象ディレクトリについてSecurity-Scoped Bookmarkを保存する。

app-scoped bookmarkは作成元アプリの署名IDに結び付くため、LaunchAgentがGUIのbookmarkをそのまま解決してはならない。GUIが稼働中に通常のbookmark（作成optionsは空）をApp Group経由で引き渡し、Agentはそれを解決して自分用のsecurity-scoped bookmarkを作成・保存する。

ただし、LaunchAgentとSandboxの組み合わせは実装上の制約が多いため、初期段階では以下の選択肢を比較する。

確定構成は以下とする。

- App Sandboxを有効にする（Mac App Store必須要件）
- ユーザー選択read-write entitlementとSecurity-Scoped Bookmarkを利用する
- GUIとLaunchAgentの双方をSandbox化する
- App Groupで通常bookmarkの短時間handoff、設定、CAS、manifestを共有する。永続security-scoped bookmarkはGUI用とAgent用を分離する
- bookmark解決後は処理期間だけ`startAccessingSecurityScopedResource()`し、必ず対応するstopを行う

---

## 24. GUI設計

Durepoはメニューバーアプリまたは通常のSwiftUIアプリとして実装する。

推奨は以下。

```text
メニューバー常駐
+
設定・復旧用ウィンドウ
```

### メニューバー

表示内容:

- 監視中
- 一時停止中
- エラー
- スナップショット作成中
- 異常変更検知中

操作:

- Durepoを開く
- 監視を一時停止
- 今すぐスナップショット
- 最近のスナップショット
- 終了

### メイン画面

#### Dashboard

- LaunchAgentの状態
- 監視対象数
- 最終スナップショット時刻
- 使用容量
- 最近の変更数
- 最近の警告
- バックアップ健全性

#### Repositories

- 監視対象一覧
- パス
- 状態
- 最終イベント
- 最終スナップショット
- 使用容量
- 除外設定

#### Snapshots

- スナップショット一覧
- 作成日時
- 作成理由
- 変更ファイル数
- 追加・更新・削除数
- 異常検知フラグ
- 使用容量増分

#### Diff

- 追加ファイル
- 更新ファイル
- 削除ファイル
- rename候補
- テキスト差分
- バイナリ差分情報

#### Restore

- ファイル単位
- ディレクトリ単位
- リポジトリ全体
- 元の場所へ復元
- 別ディレクトリへ復元

---

## 25. 復元方式

復元は安全性を優先する。

### デフォルト動作

元の場所へ直接上書きせず、別ディレクトリへ復元する。

例:

```text
~/Desktop/Durepo Restore/project-a-2026-07-17/
```

### 元の場所への復元

ユーザーが明示的に選択した場合のみ実行する。

復元前に現在状態を自動スナップショットとして保存する。

```text
復元開始
    ↓
現在状態をpre-restoreスナップショットとして保存
    ↓
復元
    ↓
復元結果を検証
```

### 原子的な復元

可能な場合は、一時ディレクトリに復元してからrenameする。

リポジトリ全体を置換する場合:

```text
project.restore.tmp
    ↓
復元と検証
    ↓
既存projectを退避
    ↓
atomic rename
```

---

## 26. XPC通信

GUIアプリとLaunchAgent間はNSXPCConnectionを利用する。

XPCインターフェースは、用途を限定したAPIにする。

例:

```swift
@objc protocol DurepoAgentProtocol {
    func getStatus(
        reply: @escaping (AgentStatus) -> Void
    )

    func listRepositories(
        reply: @escaping ([RepositoryInfo]) -> Void
    )

    func listSnapshots(
        repositoryID: UUID,
        reply: @escaping ([SnapshotInfo]) -> Void
    )

    func createSnapshot(
        repositoryID: UUID,
        reply: @escaping (SnapshotResult) -> Void
    )

    func restoreSnapshot(
        snapshotID: UUID,
        destination: URL,
        reply: @escaping (RestoreResult) -> Void
    )

    func pauseMonitoring(
        reply: @escaping (Bool) -> Void
    )

    func resumeMonitoring(
        reply: @escaping (Bool) -> Void
    )
}
```

以下のような汎用APIは公開しない。

```swift
run(command: String)
delete(path: String)
copy(from: String, to: String)
execute(script: String)
```

任意のコマンド実行や任意パス削除を許すと、Durepo自体が攻撃対象になる。

---

## 27. LaunchAgent登録

LaunchAgentはDurepo.appに同梱し、SMAppServiceを利用して登録する。

GUIから以下を制御する。

- LaunchAgent登録
- LaunchAgent登録解除
- 状態確認
- 起動要求
- エラー表示

LaunchAgentはログイン時に自動起動する。

LaunchAgentがクラッシュした場合はlaunchdによって再起動される設定にする。

---

## 28. ログ

ログはOSLogを使用する。

カテゴリ例:

```text
monitor
fsevents
snapshot
storage
restore
database
xpc
retention
integrity
alert
```

ログにファイル内容や機密情報を出力しない。

パスについても、必要に応じてprivacy指定を利用する。

GUIから診断ログをエクスポートできるようにする。

---

## 29. 整合性検証

定期的に以下を検証する。

- SQLiteデータベース整合性
- マニフェストとオブジェクトの対応
- CASオブジェクトのハッシュ
- 参照されているオブジェクトの存在
- 未参照オブジェクト
- スナップショットの完全性
- 保存先の空き容量
- FSEvents IDの状態
- 監視対象ディレクトリの存在

異常がある場合は通知する。

---

## 30. 障害時の挙動

### LaunchAgentクラッシュ

- launchdが再起動
- SQLiteイベントジャーナルから未処理イベントを再開
- 保存済みFSEvents IDから監視再開
- 必要に応じてフルスキャン

### GUIアプリ終了

- LaunchAgentは監視を継続
- GUIを再起動するとLaunchAgentへ再接続

### macOS再起動

- ログイン後にLaunchAgentを起動
- 前回イベントID以降を取得
- イベント履歴が無効ならフルスキャン

### 保存先容量不足

- 新規スナップショットを停止
- 既存スナップショットは削除しない
- 緊急通知を表示
- 必要に応じてGCを提案

### 監視対象の削除

- 異常イベントとして記録
- 最終スナップショットを保護
- GUI通知
- 自動復元は行わない

---

## 31. 除外設定

リポジトリ単位で除外ルールを設定できるようにする。

例:

```text
node_modules/
.build/
DerivedData/
target/
dist/
tmp/
*.log
```

ただし、`.git`はデフォルトで除外不可とする。

ユーザーが明示的に高度な設定を有効にした場合のみ、`.git`除外を許可する案もある。

除外形式は以下を検討する。

- glob
- `.gitignore`互換
- 独自ルール

MVPではglobから開始する。

---

## 32. パフォーマンス設計

### ハッシュ計算

- 並列実行する
- 同時実行数を制限する
- 大きなファイルではストリーミングハッシュを使用する
- ファイルサイズと更新日時が同じ場合、再ハッシュを省略する選択肢を持つ

ただし、更新日時だけを信用すると変更を見逃す可能性がある。

初期実装では、安全性を優先して変更イベント対象を再ハッシュする。

### I/O制御

- バックグラウンドQoSを利用
- バッテリー駆動中は負荷を下げる
- Low Power Modeでは並列数を減らす
- 大量変更時にI/Oを過剰占有しない
- GUI操作時は復元処理を優先する

### 大容量ファイル

一定サイズ以上のファイルは設定により除外可能にする。

例:

```text
1 GB以上のファイルは警告
10 GB以上はデフォルト除外
```

ただし、Git LFSオブジェクトやデータベースファイルについては別途検討する。

---

## 33. APFS最適化

実装済み:

- `fclonefileat`によるfile-level copy-on-write clone
- clone後のSHA-256検証とCAS rename
- 別volume・非対応filesystemへのmemory/streaming fallback
- volume UUIDの管理

将来的に以下を検討する。

- sparse file対応
- file IDによるrename追跡
- APFS snapshotとの連携

`clonefile`を利用すると、同一ボリューム内では高速かつ省容量に取得でき、元ファイル削除後もcloneが参照するblockは保持される。これは直近の破壊的操作からの復旧というDurepoの目的に適合する。ただしfileごとの原子的取得であり、repository全体のvolume snapshotではない。

---

## 34. Rename検知

FSEventsだけでは、常に旧パスと新パスの対応を直接取得できるとは限らない。

Rename候補は以下の情報から推定する。

- file ID
- inode
- 内容ハッシュ
- ファイルサイズ
- 近接した削除・作成イベント
- 同一バッチ内のイベント
- 更新日時

スナップショット上では、renameを特別扱いせず、削除と追加として保持しても復元には問題ない。

GUIの差分表示ではrename候補として見せる。

---

## 35. MVPの範囲

### MVP 1

- macOS Apple Silicon対応
- SwiftUI GUI
- SMAppServiceによるLaunchAgent登録
- FSEvents監視
- 監視対象ディレクトリ追加
- 初回フルスナップショット
- イベント駆動スナップショット
- SHA-256 CAS
- SQLiteメタデータ
- `.git`を含む保存
- スナップショット一覧
- 別ディレクトリへの復元
- 基本的な保持ポリシー
- 基本的なエラー通知

### MVP 2

- 大量削除検知
- `.git`削除検知
- 差分表示
- ファイル単位復元
- 元の場所への安全な復元
- FSEvents欠落時のフルスキャン
- 整合性チェック
- 外付けストレージ対応
- 除外ルール

### Version 1.0

- 高度な異常検知
- スナップショット保護
- 容量ベース保持
- GC
- extended attributes
- ACL
- APFS cloneのextent/physical-size診断
- メニューバーUI
- 診断ツール
- App Storeによるアップデート
- 復元前スナップショット

---

## 36. 実装フェーズ

### Phase 1: 技術検証

目的:

- FSEventsの挙動確認
- イベントID再開
- 大量削除時の挙動確認
- MustScanSubDirsの確認
- 10万ファイル規模の負荷測定
- `.git`ディレクトリ監視
- APFS上の性能確認

成果物:

```text
CLIベースのFSEvents監視ツール
```

### Phase 2: スナップショットエンジン

実装:

- ファイルスキャン
- SHA-256計算
- CAS保存
- SQLiteメタデータ
- スナップショット作成
- スナップショット復元
- 整合性検証

成果物:

```text
durepo-core
```

### Phase 3: LaunchAgent

実装:

- launchd常駐
- SMAppService登録
- FSEvents監視
- イベントジャーナル
- debounce
- スナップショット制御
- XPCサービス

成果物:

```text
DurepoAgent
```

### Phase 4: GUI

実装:

- SwiftUI設定画面
- 監視対象管理
- 状態表示
- スナップショット一覧
- 復元UI
- 通知

成果物:

```text
Durepo.app
```

### Phase 5: 異常検知

実装:

- 大量削除
- `.git`削除
- 大量ゼロバイト化
- ルート削除
- ファイル数急減
- prune停止
- 警告通知

### Phase 6: 品質向上

実装:

- 負荷制御
- バッテリー制御
- 外付けディスク
- ログ診断
- 自動アップデート
- クラッシュ復旧
- ストレステスト

---

## 37. テスト計画

### 基本テスト

- ファイル作成
- ファイル変更
- ファイル削除
- ディレクトリ作成
- ディレクトリ削除
- rename
- シンボリックリンク
- パーミッション変更
- `.git`変更
- `.git`削除

### 大量操作

- 1,000ファイル削除
- 10,000ファイル削除
- 100,000ファイル削除
- 10,000ファイル一括変更
- 10,000ファイルrename
- リポジトリ全体削除

### 障害試験

- スナップショット中にLaunchAgent強制終了
- SQLite書き込み中に強制終了
- CAS書き込み中に強制終了
- GUI終了
- Mac再起動
- スリープ・復帰
- 外付けディスク取り外し
- ディスク容量不足
- FSEventsイベント欠落
- 保存先破損

### 復元試験

- 単一ファイル
- ディレクトリ
- リポジトリ全体
- `.git`を含む完全復元
- 未コミット変更の復元
- 削除済みリポジトリの復元
- 別ディレクトリへの復元
- 元の場所への復元

---

## 38. 成功条件

Durepoの初期版は、以下を満たした場合に成功とする。

- GUIを終了しても監視が継続する
- Mac再起動後に自動的に監視を再開する
- `.git`を含むリポジトリ全体を保存できる
- 未コミットファイルを復元できる
- 数万ファイルの一括削除後に復元できる
- イベント欠落を検出し、フルスキャンへ移行できる
- スナップショット処理中のクラッシュから回復できる
- 同一内容のファイルを重複保存しない
- GUIから安全に復元できる
- 通常の開発作業に大きな性能影響を与えない

---

## 39. 初期ディレクトリ構成案

```text
Durepo/
├── DurepoApp/
│   ├── App/
│   ├── Views/
│   ├── ViewModels/
│   ├── XPC/
│   └── Resources/
│
├── DurepoAgent/
│   ├── Agent/
│   ├── FSEvents/
│   ├── Journal/
│   ├── Snapshot/
│   ├── Storage/
│   ├── Retention/
│   ├── Integrity/
│   └── XPC/
│
├── DurepoCore/
│   ├── Models/
│   ├── Hashing/
│   ├── FileSystem/
│   ├── Database/
│   ├── Restore/
│   └── Utilities/
│
├── DurepoShared/
│   ├── Protocols/
│   ├── DTO/
│   ├── Errors/
│   └── Constants/
│
├── DurepoTests/
├── DurepoIntegrationTests/
└── DurepoUITests/
```

---

## 40. 想定技術スタック

```text
Language:
  Swift

GUI:
  SwiftUI

Background service:
  LaunchAgent
  SMAppService

IPC:
  NSXPCConnection

Filesystem monitoring:
  FSEvents

Database:
  SQLite
  GRDBまたはSQLite.swiftを検討

Hashing:
  CryptoKit SHA-256

Logging:
  OSLog

Notifications:
  UserNotifications

Concurrency:
  Swift Concurrency
  actor
  AsyncStream
```

外部依存を減らすため、SQLiteを直接利用する案もある。

ただし、マイグレーションや型安全性を考えるとGRDBは有力候補である。

---

## 41. 将来拡張

将来的には以下を検討する。

- Intel Mac対応
- Linux対応
- Windows対応
- NASへの同期
- S3互換バックアップ
- 暗号化
- 圧縮
- BLAKE3
- Git統合
- IDE統合
- AIエージェントとの連携
- MCPサーバ
- CLI
- REST API
- 変更を行ったプロセスの追跡
- Endpoint Security Frameworkとの連携
- 自動復旧
- 組織向けポリシー管理
- 複数Mac間の同期

---

## 42. Durepoの位置付け

DurepoはGitの代替ではない。

Gitが管理するもの:

- 明示的にコミットされた履歴
- ブランチ
- タグ
- リモート共有
- コードレビュー

Durepoが管理するもの:

- 未コミット変更
- 未追跡ファイル
- `.git`ディレクトリ
- 短時間の変更履歴
- AIエージェントの誤操作
- 大量削除
- ローカル事故からの復旧

Durepoは、Gitの外側に置かれるセーフティレイヤーである。

```text
AI Agent
    ↓
Working Directory
    ↓
Git
    ↓
Durepo Snapshot Layer
```

より正確には、DurepoはGitを内包する作業ディレクトリ全体を保護する。

```text
Durepo
└── Repository
    ├── Working Tree
    └── .git
```

---

## 43. まとめ

Durepoの初期構成は以下とする。

```text
SwiftUI GUI
    +
LaunchAgent
    +
FSEvents
    +
SQLite Event Journal
    +
Content Addressable Storage
    +
Snapshot Manifest
```

LaunchAgentはログインユーザーのコンテキストで動作し、ユーザーが所有する開発ディレクトリのみを監視する。

root権限やLaunchDaemonは使用しない。

FSEventsは変更の通知とスナップショット開始の契機として利用し、最終的な整合性は差分スキャンと定期フルスキャンによって保証する。

ファイル内容はSHA-256を用いたContent Addressable Storageへ保存し、`.git`を含むリポジトリ全体を復元可能にする。

Durepoは、AIエージェント時代のローカル開発環境に対する、イベント駆動型の復旧レイヤーとして実装する。

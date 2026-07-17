# Durepo App Store Metadata

## English (U.S.)

### Promotional Text

Recover quickly from accidental repository damage. Durepo captures local snapshots of Git metadata, uncommitted work, and untracked files in the background.

### Description

Durepo is a local repository snapshot and recovery utility for macOS.

Protect the work Git has not yet saved remotely:

• Git metadata, including .git
• Uncommitted changes
• Untracked files
• Symlinks, hard links, sparse files, extended attributes, and ACLs

Durepo monitors folders you explicitly select and records incremental snapshots after filesystem changes. When a destructive operation is detected, it protects the last healthy snapshot and pauses automatic pruning.

Browse changes or all files in a snapshot, restore selected files and directories to a new location, or perform a confirmed in-place restore. Before an in-place restore, Durepo creates a pre-restore snapshot and uses a rollback-safe replacement process.

APFS clone support makes local capture and restore fast when available. Content-addressed storage deduplicates unchanged data, while integrity diagnostics, capacity-aware retention, and safe garbage collection help keep the snapshot store healthy.

All repository content is processed locally. Durepo does not upload your files or require an account.

Durepo is designed for rapid recovery from recent local damage. It is not a remote, offline, or tamper-proof backup, and should be used alongside your normal backup and version-control practices.

### Keywords

git,recovery,snapshot,repository,developer,source code,restore,version control,file protection

## Japanese

### Promotional Text

AIエージェントや開発ツールによる予期しない削除に備え、Gitメタデータ、未コミット変更、未追跡ファイルをローカルスナップショットで保護します。

### Description

Durepoは、macOS向けのローカルリポジトリ・スナップショット／復旧ユーティリティです。

Gitがまだリモートへ保存していない作業を保護します。

• .gitを含むGitメタデータ
• 未コミットの変更
• 未追跡ファイル
• シンボリックリンク、ハードリンク、スパースファイル、拡張属性、ACL

Durepoは、利用者が明示的に選択したフォルダを監視し、ファイルシステムの変更後に増分スナップショットを記録します。破壊的な操作を検出すると、直前の正常なスナップショットを保護し、自動削除を一時停止します。

スナップショットの変更点または全ファイルを参照し、選択したファイルやディレクトリを新しい場所へ復元できます。確認操作を伴う元の場所への復元にも対応しています。元の場所へ復元する前にはpre-restoreスナップショットを作成し、失敗時に戻せる安全な置換処理を行います。

利用可能な環境ではAPFS cloneを使って取得と復元を高速化します。コンテンツアドレス方式で同一データを重複排除し、整合性診断、容量ベースの保持制御、安全なガベージコレクションによってスナップショットストアを管理します。

リポジトリの内容はすべてMac上でローカル処理されます。ファイルを外部へアップロードせず、アカウント登録も必要ありません。

Durepoは、直近のローカルな破壊的操作から素早く復旧するためのツールです。リモート、オフライン、改ざん耐性を備えたバックアップの代替ではありません。通常のバックアップやバージョン管理と併用してください。

### Keywords

Git,データ復元,スナップショット,リポジトリ,ソースコード,変更保護

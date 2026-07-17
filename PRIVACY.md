# Durepo Privacy Policy / プライバシーポリシー

Effective date: July 17, 2026
施行日: 2026年7月17日

## English

Durepo is designed to process data locally on your Mac.

### Data Durepo accesses

Durepo accesses only repository or project folders that you explicitly select through the macOS folder picker. This can include file contents, file names and paths, timestamps, permissions, symbolic links, Git metadata in `.git`, uncommitted changes, and untracked files. Durepo stores a macOS security-scoped bookmark so the background agent can continue protecting the selected folder.

### Data collection and sharing

Durepo does not collect analytics, advertising identifiers, diagnostics, account information, or personal data. It does not upload repository content or snapshot metadata, and it does not include third-party analytics or advertising SDKs. Durepo makes no network requests as part of its backup and restore features.

Apple and the Mac App Store may independently process purchase, download, crash, and diagnostic information under Apple's policies and your device settings. That information is not received directly by Durepo.

### Local storage

Snapshots, content-addressed objects, repository bookmarks, and settings are stored locally in Durepo's sandboxed App Group container. Diagnostic messages use Apple's unified logging system and are designed not to record file contents; sensitive paths are marked private where practical.

Anyone or any process with sufficient access to your macOS user account or Full Disk Access may still be able to read or delete local Durepo data. Durepo is not a substitute for an offline or remote backup.

### Deleting data

Remove protected repositories in Durepo, disable its background agent, and delete Durepo's local data from the storage location displayed in Settings. Uninstalling the app alone may not immediately remove its App Group container.

### Support

Questions and privacy requests can be submitted through [Durepo GitHub Issues](https://github.com/rioriost/Durepo/issues). Do not include private repository contents, credentials, or other secrets in a public issue.

## 日本語

Durepoは、データをMac上でローカル処理するよう設計されています。

### Durepoがアクセスするデータ

Durepoは、macOSのフォルダ選択画面で利用者が明示的に選択したリポジトリまたはプロジェクトフォルダだけにアクセスします。対象には、ファイル内容、ファイル名とパス、日時、権限、シンボリックリンク、`.git`内のGitメタデータ、未コミット変更、未追跡ファイルが含まれる場合があります。バックグラウンドエージェントが継続して保護できるよう、macOSのsecurity-scoped bookmarkを保存します。

### 収集と第三者提供

Durepoは、アクセス解析、広告識別子、診断情報、アカウント情報、個人データを収集しません。リポジトリ内容やスナップショットのメタデータをアップロードせず、第三者の解析SDKや広告SDKを含みません。バックアップ・復元機能はネットワーク通信を行いません。

AppleおよびMac App Storeは、Appleのポリシーと端末設定に基づき、購入、ダウンロード、クラッシュ、診断情報を独自に処理する場合があります。Durepoがそれらを直接受け取ることはありません。

### ローカル保存

スナップショット、CASオブジェクト、リポジトリのbookmark、設定は、DurepoのSandbox化されたApp Group containerにローカル保存されます。診断メッセージにはAppleの統合ログを使用し、ファイル内容を記録せず、可能な箇所では機密性のあるパスをprivateとして扱います。

macOSのユーザーアカウントまたはFull Disk Accessへ十分な権限を持つ人やプロセスは、ローカルのDurepoデータを読み取りまたは削除できる可能性があります。Durepoはオフラインまたはリモートバックアップの代替ではありません。

### データの削除

Durepo上で保護対象リポジトリを削除し、バックグラウンドエージェントを無効にしたうえで、設定画面に表示される保存先のDurepoデータを削除してください。アプリを削除しただけでは、App Group containerが直ちに削除されない場合があります。

### サポート

質問やプライバシーに関する依頼は、[Durepo GitHub Issues](https://github.com/rioriost/Durepo/issues)へお寄せください。公開Issueに非公開リポジトリの内容、認証情報、その他の秘密情報を含めないでください。

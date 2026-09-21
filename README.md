# Durepo

Durepo is a macOS repository snapshot and recovery utility for protecting Git metadata, uncommitted changes, and untracked files from accidental destructive operations.

The `1.1.2` implementation covers the reviewed MVP 1, MVP 2, and local-recovery portions of the Version 1.0 scope. It is designed for recovery from accidental local damage, not as a tamper-proof or offline backup. It includes:

- a SwiftUI dashboard with English and Japanese localization;
- user-selected repository access through security-scoped bookmarks;
- SHA-256 content-addressed storage with streaming I/O;
- SQLite WAL metadata, resumable FSEvents batch state, count- and capacity-based retention, and safe garbage collection;
- `.git`, regular file, directory, symbolic-link, hard-link, sparse-file, extended-attribute, and ACL snapshots;
- destructive-change detection that protects the last healthy snapshot and pauses pruning;
- paginated snapshot differences, selective restore, and verified restore to a new directory;
- confirmed in-place restore with a protected pre-restore snapshot, preserved excluded files, atomic directory exchange, and a retained original directory;
- scheduled and on-demand integrity diagnostics with local JSON report export;
- English/Japanese SwiftUI and menu-bar interfaces;
- an FSEvents LaunchAgent embedded and managed with `SMAppService`;
- persisted background errors with macOS notifications and GUI alerts;
- local, ecosystem-aware exclusion suggestions selected from manifest and tool configuration evidence, with Git-tracked-path protection and confidence reporting;
- App Sandbox, App Group, Hardened Runtime, App Store export, and Developer ID notarization configuration.
- privacy manifests declaring the required reasons for file metadata, elapsed-time, and disk-space APIs.

Version `1.1.2` reorganizes the repository and snapshot interfaces, adds settings tabs and keyboard shortcuts, and makes privacy and support links available inside the app. [Release preparation](docs/release-1.1.2.md) records the App Store signing blocker and remaining validation.

See [the reviewed implementation plan](docs/plan.md), [the multi-angle review](docs/plan-review.md), [the 1.0 quality review](docs/quality-review-1.0.md), and [the release checklist](docs/release-checklist.md) for the threat model and release gates.

The [Astra review and remediation record](docs/astra-review-2026-09-16.md) documents the 1.1.1 safety fixes. Store mutations and restore reads now share a cross-process operation lock. Incomplete scans fail without replacing the current index; interrupted snapshots are recovered as protected, anomalous recovery points. Missing or inconsistent references block deletion, and a recorded integrity failure requires a successful deep check before pruning resumes.

After an in-place restore, the original tree remains in the sibling `.durepo-rollback-…` directory shown by the app. This directory is outside snapshot retention and is not removed automatically. Inspect the restored repository before manually removing that specific rollback directory. Excluded content remains excluded from the pre-restore snapshot, but is preserved in the restored tree and the retained original tree.

## Requirements

- macOS 26 Tahoe or later
- Apple Silicon
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build and test

```sh
swift test --parallel
swift run durepo-smoke
xcodegen generate
xcodebuild -project Durepo.xcodeproj -scheme Durepo \
  -configuration Debug -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

To exercise security-scoped bookmarks and `SMAppService`, select team `23889H77KX`, register the App Group `23889H77KX.st.rio.Durepo` in the Apple Developer portal, build with automatic signing, move the built app into `/Applications`, then enable the agent from Durepo. macOS may require approval in System Settings > General > Login Items.

## Distribution

Mac App Store archives use `Config/ExportOptions-AppStore.plist`. The App Store submission process performs security checks equivalent to notarization, so a separate notarization step is not used for that artifact.

Developer ID distribution is optional and uses `Config/ExportOptions-DeveloperID.plist` followed by `scripts/notarize.sh`. Store notary credentials in a Keychain profile; never add keys or credentials to the repository.

## Privacy and support

Durepo processes repository content locally and makes no network requests. Read the [privacy policy](PRIVACY.md).

Support and bug reports: [GitHub Issues](https://github.com/rioriost/Durepo/issues)

## License

[MIT](LICENSE) © 2026 Rio Fujita

---

## 日本語

Durepoは、誤操作による大量削除などから、`.git`、未コミット変更、未追跡ファイルを復旧するためのmacOS向けスナップショットツールです。`1.1.1`はレビュー済みのMVP 1・MVP 2と、ローカル復旧に関するVersion 1.0範囲を実装していますが、改ざん耐性のあるバックアップやオフラインバックアップの代替ではありません。

`1.1.0`では、マニフェストとツール設定をローカルで検出し、実在するキャッシュ・生成物だけを除外候補として提案します。Gitで追跡中の内容に一致する候補は適用せず、手動最適化画面には根拠と確信度を表示します。

`1.1.1`では保存・削除・復元の排他、読み取り失敗時の保護、障害後の回復、監視の再開、設定と画面状態の整合性を修正しました。[レビューと修正記録](docs/astra-review-2026-09-16.md)を参照してください。

元位置復元では除外対象の現在データも保持し、交換前のディレクトリを隣接する `.durepo-rollback-…` に残します。復元前snapshotには通常の除外設定が適用されます。退避ディレクトリは保持数・容量制御の対象外で、自動削除されません。復元結果を確認した後、アプリが示す退避先を必要に応じて手動で削除してください。

`1.1.2`では一覧と設定画面を整理し、キーボードショートカットとプライバシー・サポートへの導線を追加しました。[リリース準備記録](docs/release-1.1.2.md)に配布署名の阻害要因と未確認項目を記載しています。

macOSの優先言語が日本語の場合は日本語、それ以外は英語で表示します。問題の報告とサポートは[GitHub Issues](https://github.com/rioriost/Durepo/issues)を利用してください。

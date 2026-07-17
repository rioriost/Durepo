# Durepo

Durepo is a macOS repository snapshot and recovery utility for protecting Git metadata, uncommitted changes, and untracked files from accidental destructive operations.

The current `0.1.0` implementation satisfies the reviewed MVP 1 scope. It is designed for recovery from accidental local damage, not as a tamper-proof or offline backup. It includes:

- a SwiftUI dashboard with English and Japanese localization;
- user-selected repository access through security-scoped bookmarks;
- SHA-256 content-addressed storage with streaming I/O;
- SQLite WAL metadata, resumable FSEvents batch state, and a 50-snapshot retention limit per repository;
- `.git`, regular file, directory, and symbolic-link snapshots;
- integrity verification and restore to a new directory;
- an FSEvents LaunchAgent embedded and managed with `SMAppService`;
- persisted background errors with macOS notifications and GUI alerts;
- App Sandbox, App Group, Hardened Runtime, App Store export, and Developer ID notarization configuration.
- privacy manifests declaring the required reasons for file metadata and elapsed-time APIs.

See [the reviewed implementation plan](docs/plan.md) and [the multi-angle review](docs/plan-review.md) for the threat model and known gaps.

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

Durepoは、誤操作による大量削除などから、`.git`、未コミット変更、未追跡ファイルを復旧するためのmacOS向けスナップショットツールです。現在の`0.1.0`はレビュー済みのMVP 1範囲を実装していますが、改ざん耐性のあるバックアップやオフラインバックアップの代替ではありません。

macOSの優先言語が日本語の場合は日本語、それ以外は英語で表示します。問題の報告とサポートは[GitHub Issues](https://github.com/rioriost/Durepo/issues)を利用してください。

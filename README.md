# Durepo

Durepo is a macOS repository snapshot and recovery utility for protecting Git metadata, uncommitted changes, and untracked files from accidental destructive operations.

The current `0.1.0` implementation is a smoke-testable foundation, not a production backup product. It includes:

- a SwiftUI dashboard with English and Japanese localization;
- user-selected repository access through security-scoped bookmarks;
- SHA-256 content-addressed storage with streaming I/O;
- `.git`, regular file, directory, and symbolic-link snapshots;
- integrity verification and restore to a new directory;
- an FSEvents LaunchAgent embedded and managed with `SMAppService`;
- App Sandbox, App Group, Hardened Runtime, App Store export, and Developer ID notarization configuration.

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

Durepoは、誤操作による大量削除などから、`.git`、未コミット変更、未追跡ファイルを復旧するためのmacOS向けスナップショットツールです。現在の`0.1.0`はsmoke test可能な基盤実装で、製品版バックアップとしての利用はまだ想定していません。

macOSの優先言語が日本語の場合は日本語、それ以外は英語で表示します。問題の報告とサポートは[GitHub Issues](https://github.com/rioriost/Durepo/issues)を利用してください。

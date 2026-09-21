# Durepo 1.1.2 (8) — release preparation

Prepared on 2026-09-21. This is a release candidate, not a published App Store release.

## What's New — English (U.S.)

This update makes Durepo easier to navigate and use.

• Simplifies repository actions and makes snapshot details easier to read in smaller windows.
• Organizes Settings into General, Exclusion Rules, and Diagnostics.
• Adds keyboard shortcuts for navigation, adding repositories, and creating snapshots.
• Improves empty-state guidance, status labels, and English and Japanese text.
• Adds direct links to the privacy policy and support.

## このバージョンの最新情報 — 日本語

画面構成と操作性を改善しました。

・リポジトリの操作を整理し、小さなウインドウでもスナップショットの情報を確認しやすくしました。
・設定を「一般」「除外ルール」「診断」のタブに分けました。
・画面移動、リポジトリの追加、スナップショット作成のキーボードショートカットを追加しました。
・データがないときの案内、状態表示、読み上げラベル、日本語・英語の文言を改善しました。
・プライバシーポリシーとサポートへのリンクを追加しました。

## App Review notes

No account, external hardware, or network service is required.

Review steps:
1. Launch Durepo and add a disposable local Git repository.
2. Open Settings > General and enable Background Protection. macOS may ask you to allow the background item in System Settings.
3. Create or edit a file, then choose Snapshot Now or wait for the background agent.
4. Open Snapshots. Use the changes button to browse and selectively restore files; use the actions menu to protect a snapshot or restore it.
5. In-place restore requires explicit confirmation and retains the previous folder for recovery. Please use disposable test data.

Changes in version 1.1.2 (build 8): reorganized repository and snapshot interfaces; General, Exclusion Rules, and Diagnostics settings tabs; keyboard shortcuts; clearer empty states and accessibility labels; privacy and support links.

All repository content is processed locally. Backup and restore make no network requests and collect no data. Privacy and support links open the user's browser. Folder access is limited to locations explicitly selected through macOS file panels and retained security-scoped bookmarks.

## Build and upload status

- Version/build: 1.1.2 (8), `st.rio.Durepo`.
- Minimum OS: macOS 26.0. Toolchain: Xcode 27.0 (27A266a), macOS SDK 27.0.
- Existing core tests: 60 tests in two suites passed during GUI validation. Subsequent edits add links and version metadata; no core changes.
- Signed universal Release archive succeeded: `build/Archive/Durepo-1.1.2-8.xcarchive`.
- `codesign --verify --deep --strict` passed for the archived app. Separate helper verification passed. App and helper retain App Sandbox and the existing App Group.
- The archive contains `Contents/Resources/DurepoAgent`, the LaunchAgent plist, both localizations, and app/framework privacy manifests.
- Signing identity on the archive is **Apple Development**, not App Store distribution signing. Archive success is not export success.
- Earlier command-line export attempts failed with `No Accounts` and missing distribution signing identities. Xcode Settings nevertheless showed the registered account; those errors did not establish that the GUI was signed out.
- On 2026-09-21 at 12:21 JST, Xcode Organizer successfully uploaded this archive using Distribute App > App Store Connect. Xcode displayed `Durepo 1.1.2 (8) uploaded` and `Uploaded to Apple`.
- App Store Connect independently shows version 1.1.2, build 8, received at 12:21 and **Processing / 処理中**. Processing completion and release-build selection remain unverified.
- App Store Connect draft 1.1.2 exists in **Prepare for Submission / 提出準備中**. English/Japanese release notes and promotional text, plus review notes, were saved. The release method remains the inherited automatic-after-approval setting.
- Existing 1.1.1 (7) was verified **Ready for Distribution / 配信準備完了** on 2026-09-21.

Local logs: `build/release-1.1.2/archive.log`, `export.log`, `preflight-archive.json`. These are ignored build artifacts and are not committed.

## Upload route and remaining steps

The Xcode Organizer route succeeded without removing/re-adding the account or manually changing certificates. The cause of the earlier command-line/GUI discrepancy was not established. Do not repeat the upload of build 8 or revoke unrelated certificates.

The following command-line commands are retained for reference; they were not the successful upload route:

```sh
xcodebuild -exportArchive \
  -archivePath build/Archive/Durepo-1.1.2-8.xcarchive \
  -exportPath build/Export/AppStore-1.1.2-8 \
  -exportOptionsPlist Config/ExportOptions-AppStore.plist \
  -allowProvisioningUpdates

xcodebuild -exportArchive \
  -archivePath build/Archive/Durepo-1.1.2-8.xcarchive \
  -exportPath build/Upload/AppStore-1.1.2-8 \
  -exportOptionsPlist Config/ExportOptions-AppStore-Upload.plist \
  -allowProvisioningUpdates
```

Then verify processing, select build 8 for draft 1.1.2, refresh the changed UI screenshots, and complete the outstanding checks in the [preflight report](app-store-preflight-1.1.2.md). The current request covers release preparation; no Add for Review or Submit for Review action was performed.

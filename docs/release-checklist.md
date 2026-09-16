# Durepo 1.1.1 Release Checklist

Release candidate date: 2026-09-16

## Automated gates

- `swift test` passes, including destructive-change protection, 10,000-file deletion, corruption detection, capacity retention, GC, diff pagination, selective restore, in-place restore, hard links, sparse files, xattrs, and ACLs.
- Xcode 27 builds the app, framework, and embedded agent with Swift 6 strict concurrency; the deployment target remains macOS 26.
- Storage safety regressions cover concurrent capture/GC/retention, missing manifests, persistent integrity failures, interrupted commits/deletions, excluded-data preservation, and Git subdirectory/worktree discovery.
- Registry and monitor recovery regressions cover field-specific updates, deleted registrations, exclusion inheritance, and zero-cursor restarts.
- The built app contains English and Japanese localization, AppIcon assets, `PrivacyInfo.xcprivacy`, the embedded agent, and the LaunchAgent plist.
- Main app and agent are sandboxed and share only the declared App Group.
- App Store export and optional Developer ID notarization scripts are present.

## App Store Connect values

- Version: `1.1.1`
- Build: `7`
- Bundle ID: `st.rio.Durepo` (the exact identifier automatically registered by Xcode)
- Category: Utilities
- Support URL: <https://github.com/rioriost/Durepo/issues>
- Privacy policy URL: <https://github.com/rioriost/Durepo/blob/main/PRIVACY.md>
- License: MIT
- Encryption declaration: no non-exempt encryption

## Manual release operations

- The GitHub source release does not imply that build 7 has been submitted to or accepted by the Mac App Store.
- Confirm App Group `23889H77KX.st.rio.Durepo` and provisioning profiles in the Apple Developer portal.
- Run a signed Release archive and inspect Xcode's Privacy Report.
- Install the archived app in `/Applications`, enable background protection, reboot a physical Mac, and confirm monitoring resumes.
- Exercise a restore on a disposable repository while the signed sandboxed agent is enabled.
- Confirm root/parent moves, Agent downtime changes, unavailable bookmarks, and approval-required service state with the signed build.
- Check the retained rollback path after in-place restoration and manually remove only the disposable fixture after inspecting it.
- Upload the App Store archive and complete App Store review metadata/screenshots.
- Optional: after the developer accepts the Icon Composer license, convert the existing 1024px master into a layered `.icon` with Default, Dark, and Mono appearances. The complete AppIcon asset catalog remains the shipping fallback.
- For optional direct distribution, export with Developer ID and run `scripts/notarize.sh`; Mac App Store artifacts do not require separate notarization.

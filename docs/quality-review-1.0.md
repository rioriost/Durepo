# Durepo 1.0.0 Quality Review

Review date: 2026-07-17

Verdict: build 1 withdrawn after TestFlight acceptance testing; build 2 approved as the replacement release candidate after remediation and regression testing.

## Scope and threat model

Durepo 1.0.0 is suitable for rapid local recovery after an AI agent or developer tool damages a repository. It is not an offline, remote, or tamper-proof backup. A process with the same user privileges and sufficiently broad access can still remove the App Group container.

## Safety review

- Snapshot objects and manifests use temporary files, file and directory synchronization, atomic rename, and a final SQLite transaction.
- File capture opens with `O_NOFOLLOW`; APFS capture fixes a clone before hashing, while fallback reads compare pre/post `fstat` identity, size, mtime, and ctime.
- Restore rejects absolute paths, traversal, duplicates, and entries below a manifest symlink. Git lock files are not restored.
- In-place restore refuses active Git lock files, verifies the target snapshot, protects it from retention, commits a pre-restore snapshot, stages under the same parent, and rolls the original directory back if replacement fails.
- Destructive-change alerts protect the last healthy snapshot and suspend both count- and capacity-based pruning until acknowledgement.
- GC uses a complete manifest mark set, stops while protection is active or SQLite integrity is uncertain, and deletes only unreferenced CAS objects.
- Main app and agent are sandboxed. Repository access is limited to user-selected security-scoped bookmarks; shared state is limited to the declared App Group.

## Correctness and recovery review

The automated suite contains 36 tests and covers:

- `.git`, uncommitted files, symlinks, Git locks, hard links, sparse files, xattrs, and ACLs;
- SHA-256 verification, deduplication, APFS clone independence, memory/streaming fallback, and corrupt-object detection;
- event-journal restart, changes arriving during a snapshot, incremental directory deletion, and 10,000-file deletion;
- destructive-change protection, retention pause, repository-unavailable alerts, count retention, capacity retention, and GC;
- paginated changes, paginated full-snapshot browsing, selective directory restore, and rollback-safe in-place restore;
- exclusion syntax, rule persistence, optimizer behavior, and full-scan invalidation.
- exclusion and non-fatal handling of macOS-owned extended attributes under App Sandbox.

`swift test`, the CLI smoke test, Xcode Release analysis with warnings treated as errors, signed Debug build verification, Release archive, and App Store package export all passed. The exported package uses Cloud Managed Apple Distribution, the Store provisioning profile for `st.rio.Durepo`, and the expected sandbox/App Group entitlements for both executables.

## TestFlight build 1 remediation

TestFlight acceptance testing found that every snapshot failed with `EPERM` after `clonefile` succeeded. A sandboxed reproduction isolated the failure to `removexattr("com.apple.quarantine")`: macOS adds this system-owned attribute to data cloned or copied by the sandboxed process and intentionally rejects its removal. Durepo incorrectly treated that expected denial as a fatal snapshot error.

Build 2 excludes `com.apple.quarantine`, `com.apple.provenance`, and `com.apple.macl` from repository metadata and tolerates `EPERM`, `EACCES`, and unsupported-operation results only while removing such incidental attributes. Data hashing, content verification, user xattrs, ACLs, and permission errors from source reads remain strict. Restore strips all removable incidental metadata before applying the recorded repository metadata. The exact Sandbox/App Group syscall sequence, all 36 Xcode tests, and the CLI smoke test pass after the change.

## Performance review

- Normal FSEvents reconcile only dirty paths against the SQLite current-entry index.
- File work is bounded to four utility-priority operations, preventing unbounded task and SSD queue growth.
- Same-volume capture and restore prefer APFS clones; fallback copies use bounded 1 MiB streaming.
- Snapshot entry and change browsing uses SQLite pagination capped at 1,000 rows per request; the GUI requests 500.
- The 10,000-file incremental deletion test completes without loading file contents into the GUI or spawning a task per file.
- OSLog signposts report scan, capture, and total timing plus clone/memory/stream counts for Instruments regression checks.

## Platform and distribution review

- Release target: macOS 26, Swift 6 strict concurrency, English development region with Japanese localization.
- macOS 27 beta-only APIs are not in the required path; Swift System `Stat` and Xcode 27 executor profiling remain later compatibility work.
- The bundle contains all AppIcon asset sizes and a 1024px master, Privacy Manifest, English/Japanese strings, embedded Agent, and LaunchAgent plist.
- Privacy Manifest declares file metadata (`3B52.1`, `C617.1`), elapsed time (`35F9.1`), and sufficient-disk-space checking (`E174.1`).
- The replacement App Store package is version `1.0.0` build `2`; support and privacy URLs are documented in the release checklist.

## Remaining release operations

These are external acceptance steps, not missing implementation:

- physical-Mac reboot/resume acceptance with the Store-signed build;
- App Store Connect metadata, screenshots, upload, and review submission;
- optional Icon Composer layered `.icon` conversion after the developer personally accepts Apple's Icon Composer license. The complete AppIcon asset catalog is already valid for shipping.

If any physical reboot or App Store validation step reveals a failure, the 1.0 tag should be withheld until the issue is reproduced and fixed.

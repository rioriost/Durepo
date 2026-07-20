# Durepo 1.0.1 Exclusion Optimizer Quality Review

## Scope

Version 1.0.1 replaces name-only exclusion optimization with local ecosystem detection.
The optimizer recognizes project manifests and tool configuration for Node.js and major
web frameworks, Python, Swift/Xcode, Rust, Gradle/Maven, Ruby, PHP, Dart/Flutter, .NET,
CMake, Bazel, Terraform, Godot, Unity, and Unreal Engine.

## Safety properties

- A language or tool marker and the corresponding path must both exist.
- Generic names such as `target` are not suggested without ecosystem evidence.
- Existing `.gitignore` contents are not imported implicitly.
- `/usr/bin/git ls-files -z` is used read-only to test candidates against tracked paths.
- If a Git repository's tracking information cannot be verified, optimization fails closed
  and adds no rules.
- A Git-tracked file, directory, or submodule ancestor prevents the matching suggestion.
- `.git` remains unconditionally protected by `ExclusionRuleSet`.
- Repository addition applies only high-confidence suggestions. The manual editor can show
  medium-confidence suggestions, which remain unsaved until the user chooses Save.
- Scanning stops at 100,000 enumerated items and reports that results may be incomplete.

## Performance and privacy

The scan reads names and basic file metadata, plus package metadata files capped at 1 MB.
Known heavy output directories and `.git` descendants are not traversed. Git index
inspection is local and disables optional Git locks. No network request is made.

## Verification

The unit suite covers ecosystem detection, absence of name-only inference, semantic
deduplication, tracked-content protection, and fail-closed behavior in addition to the
existing snapshot, restore, retention, anomaly, and integrity tests.

The rule knowledge is informed by GitHub's CC0-licensed `github/gitignore` templates;
see `THIRD_PARTY_NOTICES.md`.

## Build 4 snapshot scheduling fix

An installed build was observed consuming about 90% CPU and delaying pending snapshots.
The cause was the scheduled integrity check: it decoded every manifest and repeatedly
scanned all symbolic-link paths while holding the snapshot store actor. On a real store
with 102 manifests and about 1.4 million indexed entries, this could monopolize the agent
long enough for FSEvents batches to accumulate.

Build 4 changes scheduled integrity checks as follows:

- Scheduled checks use SQLite `quick_check` and indexed manifest/object references instead
  of decoding every manifest.
- The scheduled check is deferred while a snapshot, debounce, full scan, or pending event
  batch exists, so repository protection has priority over maintenance.
- The interval is six hours and the agent no longer starts an automatic deep check.
- A deep check remains available explicitly from Settings.
- Symbolic-link ancestry validation now uses set membership by path component instead of
  comparing every path with every symbolic link.
- Git fsmonitor cookie events are ignored without excluding recoverable Git metadata such
  as `HEAD`, the index, refs, or other `.git` content.

On the affected real metadata database, SQLite `quick_check` completed in 0.36 seconds and
the distinct object-reference query completed in 0.43 seconds. The path-validation stress
test with 10,000 symbolic links and 10,000 files completed in 0.22 seconds. The complete
Swift suite and the warning-as-error Release build both passed.

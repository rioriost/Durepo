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

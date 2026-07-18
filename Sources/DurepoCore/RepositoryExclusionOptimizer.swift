import Foundation

public enum ExclusionSuggestionConfidence: Int, Codable, Comparable, Sendable {
    case medium = 1
    case high = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RepositoryExclusionSuggestion: Hashable, Sendable {
    public let rule: String
    public let technology: String
    public let evidence: String
    public let confidence: ExclusionSuggestionConfidence

    public init(
        rule: String,
        technology: String,
        evidence: String,
        confidence: ExclusionSuggestionConfidence
    ) {
        self.rule = rule
        self.technology = technology
        self.evidence = evidence
        self.confidence = confidence
    }
}

public struct RepositoryExclusionOptimizationResult: Sendable {
    public let rules: [String]
    public let suggestions: [RepositoryExclusionSuggestion]
    public let detectedTechnologies: [String]
    public let trackedSuggestionCount: Int
    public let gitTrackingVerificationFailed: Bool
    public let scanWasLimited: Bool

    public init(
        rules: [String],
        suggestions: [RepositoryExclusionSuggestion],
        detectedTechnologies: [String],
        trackedSuggestionCount: Int,
        gitTrackingVerificationFailed: Bool,
        scanWasLimited: Bool
    ) {
        self.rules = rules
        self.suggestions = suggestions
        self.detectedTechnologies = detectedTechnologies
        self.trackedSuggestionCount = trackedSuggestionCount
        self.gitTrackingVerificationFailed = gitTrackingVerificationFailed
        self.scanWasLimited = scanWasLimited
    }
}

/// Suggests disposable repository content using a conservative, local-only rule catalog.
///
/// The catalog is informed by GitHub's CC0 `github/gitignore` templates, but rules are
/// only suggested when the corresponding ecosystem marker and output path both exist.
/// A suggestion is rejected if it would match a Git-tracked path.
public actor RepositoryExclusionOptimizer {
    private struct ScannedItem: Sendable {
        let url: URL
        let relativePath: String
        let parentPath: String
        let name: String
        let isDirectory: Bool
    }

    private struct TechnologyContext: Hashable, Sendable {
        let id: TechnologyID
        let basePath: String
        let evidence: String
    }

    private enum TechnologyID: String, Hashable, Sendable {
        case node = "Node.js"
        case next = "Next.js"
        case nuxt = "Nuxt"
        case vite = "Vite"
        case svelte = "SvelteKit"
        case python = "Python"
        case swift = "Swift Package Manager"
        case xcode = "Xcode"
        case rust = "Rust"
        case gradle = "Gradle"
        case maven = "Maven"
        case ruby = "Ruby"
        case php = "PHP/Composer"
        case dart = "Dart/Flutter"
        case dotnet = ".NET"
        case cmake = "CMake"
        case bazel = "Bazel"
        case terraform = "Terraform"
        case godot = "Godot"
        case unity = "Unity"
        case unreal = "Unreal Engine"
    }

    private enum MatchScope: Sendable {
        case directChild
        case recursive
    }

    private struct DirectoryRule: Sendable {
        enum NameMatch: Sendable {
            case exact
            case prefix
            case suffix
        }

        let name: String
        let scope: MatchScope
        let confidence: ExclusionSuggestionConfidence
        let nameMatch: NameMatch

        init(
            _ name: String,
            scope: MatchScope = .directChild,
            confidence: ExclusionSuggestionConfidence = .high,
            nameMatch: NameMatch = .exact
        ) {
            self.name = name
            self.scope = scope
            self.confidence = confidence
            self.nameMatch = nameMatch
        }

        func matches(_ itemName: String) -> Bool {
            switch nameMatch {
            case .exact: itemName == name
            case .prefix: itemName.hasPrefix(name)
            case .suffix: itemName.hasSuffix(name)
            }
        }
    }

    private struct Candidate: Sendable {
        let rule: String
        var technologies: Set<String>
        var evidence: Set<String>
        var confidence: ExclusionSuggestionConfidence
        var matchedPaths: Set<String>
    }

    private enum TrackedPaths {
        case notGitRepository
        case available(Set<String>)
        case unavailable
    }

    private let fileManager: FileManager
    private let maximumItemCount: Int

    private static let skippableDirectoryNames: Set<String> = [
        ".build", ".cache", ".dart_tool", ".git", ".godot", ".gradle", ".mypy_cache",
        ".next", ".nuxt", ".parcel-cache", ".pytest_cache", ".ruff_cache", ".svelte-kit",
        ".terraform", ".tox", ".turbo", ".venv", "Binaries", "CMakeFiles",
        "DerivedData", "DerivedDataCache", "Intermediate", "Library", "Logs", "Obj", "Temp",
        "__pycache__", "bin", "build", "coverage", "dist", "htmlcov", "node_modules", "obj",
        "target", "venv", "vendor",
    ]

    public init(fileManager: FileManager = .default, maximumItemCount: Int = 100_000) {
        self.fileManager = fileManager
        self.maximumItemCount = max(1, maximumItemCount)
    }

    public func optimizedRules(repositoryURL: URL, including existingRules: [String]) throws -> [String] {
        try optimize(repositoryURL: repositoryURL, including: existingRules).rules
    }

    public func optimize(
        repositoryURL: URL,
        including existingRules: [String],
        minimumConfidence: ExclusionSuggestionConfidence = .medium
    ) throws -> RepositoryExclusionOptimizationResult {
        let normalizedExistingRules = ExclusionRuleSet(existingRules).rules
        let scan = try scan(repositoryURL: repositoryURL)
        let contexts = detectTechnologyContexts(in: scan.items)
        var candidates = candidates(for: contexts, in: scan.items)
        addUniversalCandidates(to: &candidates, items: scan.items)

        let trackedPaths = readTrackedPaths(repositoryURL: repositoryURL)
        if case .unavailable = trackedPaths {
            return RepositoryExclusionOptimizationResult(
                rules: normalizedExistingRules,
                suggestions: [],
                detectedTechnologies: detectedTechnologyNames(contexts),
                trackedSuggestionCount: 0,
                gitTrackingVerificationFailed: true,
                scanWasLimited: scan.wasLimited
            )
        }

        let existingRuleSet = ExclusionRuleSet(normalizedExistingRules)
        let tracked = switch trackedPaths {
        case let .available(paths): paths
        case .notGitRepository, .unavailable: Set<String>()
        }
        var suggestions: [RepositoryExclusionSuggestion] = []
        var trackedSuggestionCount = 0

        for candidate in candidates.values.sorted(by: { $0.rule < $1.rule }) {
            guard candidate.confidence >= minimumConfidence else { continue }
            if candidate.matchedPaths.allSatisfy({ existingRuleSet.excludes($0, isDirectory: candidate.rule.hasSuffix("/")) }) {
                continue
            }
            if Self.conflictsWithExistingNegation(candidate, existingRules: normalizedExistingRules) {
                continue
            }
            if matchesTrackedContent(candidate, trackedPaths: tracked) {
                trackedSuggestionCount += 1
                continue
            }
            suggestions.append(RepositoryExclusionSuggestion(
                rule: candidate.rule,
                technology: candidate.technologies.sorted().joined(separator: ", "),
                evidence: candidate.evidence.sorted().joined(separator: ", "),
                confidence: candidate.confidence
            ))
        }

        return RepositoryExclusionOptimizationResult(
            rules: normalizedExistingRules + suggestions.map(\.rule),
            suggestions: suggestions,
            detectedTechnologies: detectedTechnologyNames(contexts),
            trackedSuggestionCount: trackedSuggestionCount,
            gitTrackingVerificationFailed: false,
            scanWasLimited: scan.wasLimited
        )
    }

    private func scan(repositoryURL: URL) throws -> (items: [ScannedItem], wasLimited: Bool) {
        guard let enumerator = fileManager.enumerator(
            at: repositoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw DurepoError.invalidRepository(repositoryURL.path)
        }

        var items: [ScannedItem] = []
        var itemCount = 0
        var wasLimited = false
        for case let url as URL in enumerator {
            itemCount += 1
            if itemCount > maximumItemCount {
                wasLimited = true
                break
            }
            let relativePath = try url.safeRelativePath(from: repositoryURL)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else {
                continue
            }
            let isDirectory = values.isDirectory == true
            let item = ScannedItem(
                url: url,
                relativePath: relativePath,
                parentPath: Self.parentPath(of: relativePath),
                name: url.lastPathComponent,
                isDirectory: isDirectory
            )
            items.append(item)
            if isDirectory,
               Self.skippableDirectoryNames.contains(item.name) || item.name.hasPrefix("bazel-") {
                enumerator.skipDescendants()
            }
        }
        return (items, wasLimited)
    }

    private func detectTechnologyContexts(in items: [ScannedItem]) -> Set<TechnologyContext> {
        var contexts: Set<TechnologyContext> = []
        for item in items {
            let lowercasedName = item.name.lowercased()
            let basePath = item.parentPath

            if item.isDirectory {
                if lowercasedName.hasSuffix(".xcodeproj") || lowercasedName.hasSuffix(".xcworkspace") {
                    contexts.insert(.init(id: .xcode, basePath: basePath, evidence: item.name))
                }
                continue
            }

            switch lowercasedName {
            case "package.json":
                contexts.insert(.init(id: .node, basePath: basePath, evidence: item.name))
                for technology in nodeFrameworks(in: item.url) {
                    contexts.insert(.init(id: technology, basePath: basePath, evidence: item.name))
                }
            case "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "pipfile":
                contexts.insert(.init(id: .python, basePath: basePath, evidence: item.name))
            case "package.swift":
                contexts.insert(.init(id: .swift, basePath: basePath, evidence: item.name))
            case "cargo.toml":
                contexts.insert(.init(id: .rust, basePath: basePath, evidence: item.name))
            case "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew":
                contexts.insert(.init(id: .gradle, basePath: basePath, evidence: item.name))
            case "pom.xml", "mvnw":
                contexts.insert(.init(id: .maven, basePath: basePath, evidence: item.name))
            case "gemfile":
                contexts.insert(.init(id: .ruby, basePath: basePath, evidence: item.name))
            case "composer.json":
                contexts.insert(.init(id: .php, basePath: basePath, evidence: item.name))
            case "pubspec.yaml":
                contexts.insert(.init(id: .dart, basePath: basePath, evidence: item.name))
            case "cmakelists.txt":
                contexts.insert(.init(id: .cmake, basePath: basePath, evidence: item.name))
            case "workspace", "workspace.bazel", "module.bazel":
                contexts.insert(.init(id: .bazel, basePath: basePath, evidence: item.name))
            case "project.godot":
                contexts.insert(.init(id: .godot, basePath: basePath, evidence: item.name))
            default:
                if Self.isJavaScriptConfiguration(lowercasedName, stem: "next.config") {
                    contexts.insert(.init(id: .next, basePath: basePath, evidence: item.name))
                } else if Self.isJavaScriptConfiguration(lowercasedName, stem: "nuxt.config") {
                    contexts.insert(.init(id: .nuxt, basePath: basePath, evidence: item.name))
                } else if Self.isJavaScriptConfiguration(lowercasedName, stem: "vite.config") {
                    contexts.insert(.init(id: .vite, basePath: basePath, evidence: item.name))
                } else if Self.isJavaScriptConfiguration(lowercasedName, stem: "svelte.config") {
                    contexts.insert(.init(id: .svelte, basePath: basePath, evidence: item.name))
                } else if lowercasedName.hasSuffix(".csproj") || lowercasedName.hasSuffix(".fsproj")
                            || lowercasedName.hasSuffix(".vbproj") || lowercasedName.hasSuffix(".sln") {
                    contexts.insert(.init(id: .dotnet, basePath: basePath, evidence: item.name))
                } else if lowercasedName.hasSuffix(".tf") {
                    contexts.insert(.init(id: .terraform, basePath: basePath, evidence: item.name))
                } else if lowercasedName.hasSuffix(".uproject") {
                    contexts.insert(.init(id: .unreal, basePath: basePath, evidence: item.name))
                } else if lowercasedName.hasSuffix(".gemspec") {
                    contexts.insert(.init(id: .ruby, basePath: basePath, evidence: item.name))
                }
            }
        }

        let directoryNamesByParent = Dictionary(grouping: items.filter(\.isDirectory), by: \.parentPath)
            .mapValues { Set($0.map(\.name)) }
        for (basePath, names) in directoryNamesByParent
        where names.contains("Assets") && names.contains("ProjectSettings") {
            contexts.insert(.init(id: .unity, basePath: basePath, evidence: "Assets + ProjectSettings"))
        }
        return contexts
    }

    private func nodeFrameworks(in packageJSONURL: URL) -> Set<TechnologyID> {
        guard let values = try? packageJSONURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= 1_000_000,
              let data = try? Data(contentsOf: packageJSONURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var packageNames: Set<String> = []
        for key in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
            if let dependencies = object[key] as? [String: Any] {
                packageNames.formUnion(dependencies.keys)
            }
        }
        var result: Set<TechnologyID> = []
        if packageNames.contains("next") { result.insert(.next) }
        if packageNames.contains("nuxt") { result.insert(.nuxt) }
        if packageNames.contains("vite") { result.insert(.vite) }
        if packageNames.contains("@sveltejs/kit") { result.insert(.svelte) }
        return result
    }

    private func candidates(
        for contexts: Set<TechnologyContext>,
        in items: [ScannedItem]
    ) -> [String: Candidate] {
        var candidates: [String: Candidate] = [:]
        let directories = items.filter(\.isDirectory)
        for context in contexts {
            for rule in Self.directoryRules(for: context.id) {
                for directory in directories where rule.matches(directory.name)
                    && Self.isPath(directory.relativePath, within: context.basePath, scope: rule.scope) {
                    Self.mergeCandidate(
                        rule: directory.relativePath + "/",
                        technology: context.id.rawValue,
                        evidence: context.evidence,
                        confidence: rule.confidence,
                        matchedPath: directory.relativePath,
                        into: &candidates
                    )
                }
            }
            if context.id == .python {
                let bytecodePaths = items.filter {
                    !$0.isDirectory && Self.isDescendant($0.relativePath, of: context.basePath)
                        && ["pyc", "pyo", "pyd"].contains($0.url.pathExtension.lowercased())
                }.map(\.relativePath)
                for path in bytecodePaths {
                    Self.mergeCandidate(
                        rule: "*.py[cod]",
                        technology: context.id.rawValue,
                        evidence: context.evidence,
                        confidence: .high,
                        matchedPath: path,
                        into: &candidates
                    )
                }
            }
            if context.id == .cmake {
                for item in items where !item.isDirectory && item.name == "CMakeCache.txt"
                    && Self.isDescendant(item.relativePath, of: context.basePath) {
                    Self.mergeCandidate(
                        rule: item.relativePath,
                        technology: context.id.rawValue,
                        evidence: context.evidence,
                        confidence: .high,
                        matchedPath: item.relativePath,
                        into: &candidates
                    )
                }
            }
        }
        return candidates
    }

    private func addUniversalCandidates(to candidates: inout [String: Candidate], items: [ScannedItem]) {
        for item in items where !item.isDirectory && item.name == ".DS_Store" {
            Self.mergeCandidate(
                rule: ".DS_Store",
                technology: "macOS",
                evidence: ".DS_Store",
                confidence: .high,
                matchedPath: item.relativePath,
                into: &candidates
            )
        }
    }

    private static func directoryRules(for technology: TechnologyID) -> [DirectoryRule] {
        switch technology {
        case .node:
            [DirectoryRule("node_modules", scope: .recursive), DirectoryRule(".npm"),
             DirectoryRule(".parcel-cache"), DirectoryRule(".turbo")]
        case .next:
            [DirectoryRule(".next"), DirectoryRule("out", confidence: .medium)]
        case .nuxt:
            [DirectoryRule(".nuxt"), DirectoryRule(".output")]
        case .vite:
            [DirectoryRule("dist", confidence: .medium)]
        case .svelte:
            [DirectoryRule(".svelte-kit"), DirectoryRule("build", confidence: .medium)]
        case .python:
            [DirectoryRule("__pycache__", scope: .recursive), DirectoryRule(".venv"),
             DirectoryRule("venv"), DirectoryRule(".pytest_cache", scope: .recursive),
             DirectoryRule(".mypy_cache", scope: .recursive), DirectoryRule(".ruff_cache", scope: .recursive),
             DirectoryRule(".tox"), DirectoryRule("htmlcov"), DirectoryRule("build", confidence: .medium),
             DirectoryRule("dist", confidence: .medium),
             DirectoryRule(".egg-info", scope: .recursive, nameMatch: .suffix)]
        case .swift:
            [DirectoryRule(".build")]
        case .xcode:
            [DirectoryRule("DerivedData", scope: .recursive), DirectoryRule("xcuserdata", scope: .recursive)]
        case .rust:
            [DirectoryRule("target")]
        case .gradle:
            [DirectoryRule(".gradle"), DirectoryRule("build", confidence: .medium)]
        case .maven:
            [DirectoryRule("target")]
        case .ruby:
            [DirectoryRule(".bundle")]
        case .php:
            [DirectoryRule("vendor"), DirectoryRule(".phpunit.cache")]
        case .dart:
            [DirectoryRule(".dart_tool"), DirectoryRule("build", confidence: .medium)]
        case .dotnet:
            [DirectoryRule("bin", confidence: .medium), DirectoryRule("obj", confidence: .medium)]
        case .cmake:
            [DirectoryRule("CMakeFiles"), DirectoryRule("build", confidence: .medium)]
        case .bazel:
            [DirectoryRule("bazel-", confidence: .high, nameMatch: .prefix)]
        case .terraform:
            [DirectoryRule(".terraform")]
        case .godot:
            [DirectoryRule(".godot")]
        case .unity:
            [DirectoryRule("Library"), DirectoryRule("Temp"), DirectoryRule("Obj"), DirectoryRule("Logs")]
        case .unreal:
            [DirectoryRule("Binaries"), DirectoryRule("DerivedDataCache"), DirectoryRule("Intermediate")]
        }
    }

    private func readTrackedPaths(repositoryURL: URL) -> TrackedPaths {
        guard fileManager.fileExists(atPath: repositoryURL.appending(path: ".git").path) else {
            return .notGitRepository
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryURL.path, "-c", "core.quotepath=false", "ls-files", "-z"]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return .unavailable }
            let paths = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            return .available(Set(paths))
        } catch {
            return .unavailable
        }
    }

    private func matchesTrackedContent(_ candidate: Candidate, trackedPaths: Set<String>) -> Bool {
        let candidateRules = ExclusionRuleSet([candidate.rule])
        for trackedPath in trackedPaths {
            if candidateRules.excludes(trackedPath) { return true }
            if candidate.matchedPaths.contains(where: { $0.hasPrefix(trackedPath + "/") }) { return true }
        }
        return false
    }

    private static func mergeCandidate(
        rule: String,
        technology: String,
        evidence: String,
        confidence: ExclusionSuggestionConfidence,
        matchedPath: String,
        into candidates: inout [String: Candidate]
    ) {
        if var candidate = candidates[rule] {
            candidate.technologies.insert(technology)
            candidate.evidence.insert(evidence)
            candidate.confidence = max(candidate.confidence, confidence)
            candidate.matchedPaths.insert(matchedPath)
            candidates[rule] = candidate
        } else {
            candidates[rule] = Candidate(
                rule: rule,
                technologies: [technology],
                evidence: [evidence],
                confidence: confidence,
                matchedPaths: [matchedPath]
            )
        }
    }

    private static func conflictsWithExistingNegation(
        _ candidate: Candidate,
        existingRules: [String]
    ) -> Bool {
        let candidateDirectory = candidate.rule.hasSuffix("/")
            ? String(candidate.rule.dropLast())
            : nil
        for rawRule in existingRules where rawRule.hasPrefix("!") && !rawRule.hasPrefix("\\!") {
            let positiveRule = String(rawRule.dropFirst())
            let positiveRuleSet = ExclusionRuleSet([positiveRule])
            if candidate.matchedPaths.contains(where: {
                positiveRuleSet.excludes($0, isDirectory: candidateDirectory != nil)
            }) {
                return true
            }
            guard let candidateDirectory else { continue }
            var negatedPath = positiveRule
            while negatedPath.hasPrefix("/") { negatedPath.removeFirst() }
            while negatedPath.hasSuffix("/") { negatedPath.removeLast() }
            let literalPrefix = String(negatedPath.prefix { !"*?[".contains($0) })
            if literalPrefix.isEmpty || literalPrefix.hasPrefix(candidateDirectory + "/") {
                return true
            }
        }
        return false
    }

    private static func parentPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    private static func isDescendant(_ path: String, of basePath: String) -> Bool {
        basePath.isEmpty || path.hasPrefix(basePath + "/")
    }

    private static func isPath(_ path: String, within basePath: String, scope: MatchScope) -> Bool {
        switch scope {
        case .directChild: parentPath(of: path) == basePath
        case .recursive: isDescendant(path, of: basePath)
        }
    }

    private static func isJavaScriptConfiguration(_ name: String, stem: String) -> Bool {
        name == stem || name.hasPrefix(stem + ".")
    }

    private func detectedTechnologyNames(_ contexts: Set<TechnologyContext>) -> [String] {
        Set(contexts.map(\.id.rawValue)).sorted()
    }
}

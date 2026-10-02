import SwiftUI
import AppKit

struct Repository: Identifiable, Codable, Sendable {
    let url: URL
    let owner: String
    let lastActivityAt: Date?
    let cloneURL: URL?

    init(url: URL, owner: String, lastActivityAt: Date?, cloneURL: URL? = nil) {
        self.url = url
        self.owner = owner
        self.lastActivityAt = lastActivityAt
        self.cloneURL = cloneURL
    }

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var fullName: String { owner + "/" + name }
    var usageKey: String { fullName.lowercased() }
    var isLocal: Bool { cloneURL == nil }
}

enum Discovery {
    static func githubOwner(from remote: String) -> String? {
        let value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if value.hasPrefix("git@github.com:") {
            path = String(value.dropFirst("git@github.com:".count))
        } else if let url = URL(string: value), url.host?.lowercased() == "github.com",
                  ["https", "http", "ssh", "git"].contains(url.scheme?.lowercased() ?? "") {
            path = url.path
        } else { return nil }
        let parts = path.split(separator: "/")
        guard parts.count == 2,
              String(parts[0]).range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { return nil }
        return String(parts[0])
    }

    private static func owner(of repository: URL, fallback: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", repository.path, "config", "--get", "remote.origin.url"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return fallback }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let remote = String(data: data, encoding: .utf8) else { return fallback }
        return githubOwner(from: remote) ?? fallback
    }

    private static func lastCommitDate(of repository: URL) -> Date? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", repository.path, "log", "-1", "--format=%ct"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = Double(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func scan(_ root: URL) throws -> [Repository] {
        let fm = FileManager.default
        func directories(_ url: URL) throws -> [URL] {
            try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        var repos: [Repository] = []
        for owner in try directories(root) {
            if fm.fileExists(atPath: owner.appendingPathComponent(".git").path) {
                let repositoryOwner = self.owner(of: owner, fallback: "Local")
                repos.append(Repository(url: owner, owner: repositoryOwner,
                                        lastActivityAt: lastCommitDate(of: owner)))
            } else {
                for repo in try directories(owner) where fm.fileExists(atPath: repo.appendingPathComponent(".git").path) {
                    let repositoryOwner = self.owner(of: repo, fallback: owner.lastPathComponent)
                    repos.append(Repository(url: repo, owner: repositoryOwner,
                                            lastActivityAt: lastCommitDate(of: repo)))
                }
            }
        }
        return repos
    }

    static func merged(local: [Repository], remote: [Repository]) -> [Repository] {
        let localKeys = Set(local.map(\.usageKey))
        return local + remote.filter { !localKeys.contains($0.usageKey) }
    }
}

struct RepositorySnapshot: Codable, Sendable {
    let root: URL
    let repositories: [Repository]
    let remoteRefreshedAt: Date?
    let remoteOwners: [String]
}

struct RepositoryCache {
    let fileURL: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("studio.repository-launcher", isDirectory: true)) {
        fileURL = directory.appendingPathComponent("repositories.json")
    }

    func load(root: URL) -> RepositorySnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(RepositorySnapshot.self, from: data),
              snapshot.root.standardizedFileURL.path == root.standardizedFileURL.path else { return nil }
        return snapshot
    }

    func save(_ snapshot: RepositorySnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }
}


struct FolderSearchResult: Identifiable, Sendable {
    let url: URL

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var parentPath: String { url.deletingLastPathComponent().path }
    var isRepository: Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) }
}

enum FolderSearchFailure: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Couldn’t search folders with Spotlight."
    }
}

enum FolderSearch {
    static func search(_ rawQuery: String, repositories: [Repository] = [], limit: Int = 16) async throws -> [FolderSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }

        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let predicate = "kMDItemContentType == 'public.folder' && kMDItemFSName == \"*\(escaped)*\"cd"

        return try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = [predicate]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let matchingRepositories = repositories.filter {
                $0.isLocal && $0.fullName.localizedStandardContains(query)
                    && FileManager.default.fileExists(atPath: $0.url.path)
            }.map { FolderSearchResult(url: $0.url) }
            guard process.terminationStatus == 0 else {
                if !matchingRepositories.isEmpty { return Array(matchingRepositories.prefix(limit)) }
                throw FolderSearchFailure.unavailable
            }

            let text = String(decoding: data, as: UTF8.self)
            var seen = Set(matchingRepositories.map(\.id))
            var results = matchingRepositories
            for line in text.split(whereSeparator: \.isNewline) {
                let path = String(line)
                guard seen.insert(path).inserted else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                results.append(FolderSearchResult(url: URL(fileURLWithPath: path, isDirectory: true)))
            }
            return Array(results.sorted { first, second in
                if first.isRepository != second.isRepository { return first.isRepository }
                let firstExact = first.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                let secondExact = second.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                if firstExact != secondExact { return firstExact }
                let comparison = first.name.localizedStandardCompare(second.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return first.id < second.id
            }.prefix(limit))
        }.value
    }
}

struct RepositoryUsage: Codable, Equatable {
    var opens: Int
    var lastOpened: Date?
}

enum RepositoryRanking {
    static func ranked(_ repositories: [Repository], usage: [String: RepositoryUsage],
                       pinned: Set<String> = []) -> [Repository] {
        repositories.sorted { first, second in
            let firstPinned = pinned.contains(first.usageKey)
            let secondPinned = pinned.contains(second.usageKey)
            if firstPinned != secondPinned { return firstPinned }
            if first.isLocal != second.isLocal { return first.isLocal }

            let firstUsage = usage[first.usageKey]
            let secondUsage = usage[second.usageKey]
            let firstOpened = firstUsage?.lastOpened ?? .distantPast
            let secondOpened = secondUsage?.lastOpened ?? .distantPast
            if firstOpened != secondOpened { return firstOpened > secondOpened }

            let firstOpens = firstUsage?.opens ?? 0
            let secondOpens = secondUsage?.opens ?? 0
            if firstOpens != secondOpens { return firstOpens > secondOpens }

            let firstActivity = first.lastActivityAt ?? .distantPast
            let secondActivity = second.lastActivityAt ?? .distantPast
            if firstActivity != secondActivity { return firstActivity > secondActivity }

            return first.fullName.localizedStandardCompare(second.fullName) == .orderedAscending
        }
    }
}

enum PinnedRepositoryOrdering {
    static func ordered(_ repositories: [Repository], keys: [String]) -> [Repository] {
        let byKey = Dictionary(repositories.map { ($0.usageKey, $0) }, uniquingKeysWith: { first, _ in first })
        return keys.compactMap { byKey[$0] }
    }

    static func moving(_ source: String, relativeTo target: String, after: Bool, order: [String]) -> [String] {
        guard source != target,
              let sourceIndex = order.firstIndex(of: source),
              order.contains(target) else { return order }
        var next = order
        next.remove(at: sourceIndex)
        guard let targetIndex = next.firstIndex(of: target) else { return order }
        next.insert(source, at: min(next.count, targetIndex + (after ? 1 : 0)))
        return next
    }
}


struct OwnerProfile: Codable, Sendable {
    let displayName: String
    let avatar: Data
    let fetchedAt: Date

    var isFresh: Bool { Date().timeIntervalSince(fetchedAt) < 7 * 24 * 60 * 60 }
}

actor OwnerCache {
    static let shared = OwnerCache()
    private static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("studio.repository-launcher/owners", isDirectory: true)

    private struct GitHubOwner: Decodable {
        let name: String?
        let avatar_url: URL
    }

    private static func cacheURL(_ owner: String) -> URL {
        // Encode the folder name so it cannot become a cache path.
        let key = Data(owner.lowercased().utf8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }

    nonisolated static func cachedProfile(_ owner: String) -> OwnerProfile? {
        guard let data = try? Data(contentsOf: cacheURL(owner)) else { return nil }
        return try? JSONDecoder().decode(OwnerProfile.self, from: data)
    }

    func cached(_ owner: String) -> OwnerProfile? { Self.cachedProfile(owner) }

    private func download(_ url: URL, isAPI: Bool = false) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("RepositoryLauncher", forHTTPHeaderField: "User-Agent")
        if isAPI {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func profile(_ owner: String, force: Bool = false) async -> OwnerProfile? {
        let old = cached(owner)
        if !force, let old, old.isFresh { return old }
        guard owner != "Local", owner.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { return old }
        do {
            // Organization profiles expose the organization display name.
            // Personal owner folders use the public user profile instead.
            let orgURL = URL(string: "https://api.github.com/orgs/" + owner)!
            let userURL = URL(string: "https://api.github.com/users/" + owner)!
            let data: Data
            do { data = try await download(orgURL, isAPI: true) }
            catch { data = try await download(userURL, isAPI: true) }
            let info = try JSONDecoder().decode(GitHubOwner.self, from: data)
            guard info.avatar_url.scheme == "https" else { return old }
            let avatar = try await download(info.avatar_url)
            guard NSImage(data: avatar) != nil else { return old }
            let name = info.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = OwnerProfile(displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? owner,
                                       avatar: avatar, fetchedAt: Date())
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(profile).write(to: Self.cacheURL(owner), options: .atomic)
            return profile
        } catch {
            // Keep the last successful profile available while offline.
            return old
        }
    }
}



enum GitHubRepositoryFailure: LocalizedError {
    case unavailable
    case request

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Connect GitHub with the GitHub CLI to load repositories that are not local yet."
        case .request: return "Couldn’t refresh connected GitHub repositories."
        }
    }
}

actor GitHubRepositoryCatalog {
    private struct RemoteRepository: Decodable {
        struct Owner: Decodable { let login: String }
        let name: String
        let clone_url: URL
        let pushed_at: String?
        let updated_at: String?
        let owner: Owner
    }

    private let dateFormatter = ISO8601DateFormatter()

    private func request(_ endpoint: String) async throws -> [RemoteRepository] {
        guard let executable = GitHubInbox.executable else { throw GitHubRepositoryFailure.unavailable }
        let arguments = [
            "api", "--hostname", "github.com",
            "-H", "Accept: application/vnd.github+json",
            "-H", "X-GitHub-Api-Version: 2022-11-28",
            endpoint,
        ]
        let result = try await Task.detached { () -> (Data, Int32) in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (data, process.terminationStatus)
        }.value
        guard result.1 == 0 else { throw GitHubRepositoryFailure.request }
        do {
            return try JSONDecoder().decode([RemoteRepository].self, from: result.0)
        } catch {
            throw GitHubRepositoryFailure.request
        }
    }

    private func pages(_ endpoint: (Int) -> String) async throws -> [RemoteRepository] {
        var repositories: [RemoteRepository] = []
        var page = 1
        while true {
            let batch = try await request(endpoint(page))
            repositories += batch
            if batch.count < 100 { break }
            page += 1
        }
        return repositories
    }

    func repositories(root: URL, priorityOwners: [String]) async throws -> [Repository] {
        var repositories = try await pages {
            "/user/repos?affiliation=owner,collaborator,organization_member&sort=updated&direction=desc&per_page=100&page=\($0)"
        }
        let accessibleOwners = Set(repositories.map { $0.owner.login.lowercased() })
        var requestedOwners = Set<String>()
        for owner in priorityOwners {
            let trimmed = owner.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !accessibleOwners.contains(key), requestedOwners.insert(key).inserted else { continue }
            repositories += try await pages {
                "/users/\(trimmed)/repos?sort=updated&direction=desc&per_page=100&page=\($0)"
            }
        }

        var seen = Set<String>()
        return repositories.compactMap { repository in
            let owner = repository.owner.login
            let name = repository.name
            guard owner.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
                  name != ".", name != "..",
                  name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
            let fullName = (owner + "/" + name).lowercased()
            guard seen.insert(fullName).inserted else { return nil }
            let activity = [repository.pushed_at, repository.updated_at]
                .compactMap { $0.flatMap(dateFormatter.date(from:)) }
                .max()
            let destination = root.appendingPathComponent(owner, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            return Repository(url: destination, owner: owner, lastActivityAt: activity,
                              cloneURL: repository.clone_url)
        }
    }
}

enum OwnerOrdering {
    static func ordered(_ owners: [String], preferred: [String]) -> [String] {
        var seen = Set<String>()
        let unique = owners.filter { seen.insert($0).inserted }
        let available = Set(unique)
        var result: [String] = []
        var placed = Set<String>()
        for owner in preferred where available.contains(owner) && placed.insert(owner).inserted {
            result.append(owner)
        }
        result.append(contentsOf: unique.filter { !placed.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        return result
    }

    static func moving(_ source: String, relativeTo target: String, after: Bool,
                       owners: [String], preferred: [String]) -> [String] {
        guard source != target else { return preferred }
        var order = ordered(preferred + owners, preferred: preferred)
        guard let sourceIndex = order.firstIndex(of: source), order.contains(target) else { return preferred }
        order.remove(at: sourceIndex)
        guard let targetIndex = order.firstIndex(of: target) else { return preferred }
        order.insert(source, at: min(order.count, targetIndex + (after ? 1 : 0)))
        return order
    }

    static func normalizedOwner(_ value: String) -> String? {
        let owner = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty,
              owner.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { return nil }
        return owner
    }
}

@MainActor final class OwnerOrderPreferences: ObservableObject {
    @Published private(set) var preferred: [String]
    @Published private(set) var manualOwners: [String]
    private let defaults: UserDefaults
    private static let key = "studio.repository-launcher.owner-order"
    private static let manualKey = "studio.repository-launcher.manual-owners"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferred = defaults.stringArray(forKey: Self.key) ?? []
        manualOwners = defaults.stringArray(forKey: Self.manualKey) ?? []
    }

    func ordered(_ owners: [String]) -> [String] {
        OwnerOrdering.ordered(owners, preferred: preferred)
    }

    func add(_ value: String) -> String? {
        guard let owner = OwnerOrdering.normalizedOwner(value) else { return nil }
        if !manualOwners.contains(where: { $0.caseInsensitiveCompare(owner) == .orderedSame }) {
            manualOwners.append(owner)
            defaults.set(manualOwners, forKey: Self.manualKey)
        }
        return owner
    }

    func isManual(_ owner: String) -> Bool {
        manualOwners.contains { $0.caseInsensitiveCompare(owner) == .orderedSame }
    }

    func removeManual(_ owner: String) {
        manualOwners.removeAll { $0.caseInsensitiveCompare(owner) == .orderedSame }
        defaults.set(manualOwners, forKey: Self.manualKey)
    }

    func move(_ source: String, relativeTo target: String, after: Bool, among owners: [String]) {
        let next = OwnerOrdering.moving(source, relativeTo: target, after: after,
                                        owners: owners, preferred: preferred)
        guard next != preferred else { return }
        preferred = next
        defaults.set(next, forKey: Self.key)
    }
}

@MainActor final class RepositoryUsageStore: ObservableObject {
    @Published private var usage: [String: RepositoryUsage]
    @Published private(set) var pinnedOrder: [String]
    private static let pinKey = "studio.repository-launcher.pinned-repositories"
    private let defaults: UserDefaults
    private static let key = "studio.repository-launcher.repository-usage"

    var pinned: Set<String> { Set(pinnedOrder) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedPins = defaults.stringArray(forKey: Self.pinKey) ?? []
        var seenPins = Set<String>()
        pinnedOrder = savedPins.filter { seenPins.insert($0).inserted }
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: RepositoryUsage].self, from: data) {
            usage = saved
        } else {
            usage = [:]
        }
    }

    func ranked(_ repositories: [Repository]) -> [Repository] {
        RepositoryRanking.ranked(repositories, usage: usage, pinned: pinned)
    }

    func isPinned(_ repository: Repository) -> Bool { pinned.contains(repository.usageKey) }

    func pinnedRepositories(from repositories: [Repository]) -> [Repository] {
        PinnedRepositoryOrdering.ordered(repositories.filter(\.isLocal), keys: pinnedOrder)
    }

    func togglePin(_ repository: Repository) {
        if let index = pinnedOrder.firstIndex(of: repository.usageKey) {
            pinnedOrder.remove(at: index)
        } else {
            pinnedOrder.append(repository.usageKey)
        }
        defaults.set(pinnedOrder, forKey: Self.pinKey)
    }

    func movePinned(_ source: String, relativeTo target: String, after: Bool) {
        let next = PinnedRepositoryOrdering.moving(source, relativeTo: target, after: after, order: pinnedOrder)
        guard next != pinnedOrder else { return }
        pinnedOrder = next
        defaults.set(next, forKey: Self.pinKey)
    }

    func record(_ repository: Repository) {
        var current = usage[repository.usageKey] ?? RepositoryUsage(opens: 0, lastOpened: nil)
        current.opens += 1
        current.lastOpened = Date()
        usage[repository.usageKey] = current
        if let data = try? JSONEncoder().encode(usage) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

@MainActor final class Library: ObservableObject {
    @Published var repos: [Repository] = []
    @Published var profiles: [String: OwnerProfile] = [:]
    @Published var error: String?
    @Published var githubMessage: String?
    @Published private(set) var refreshing = false
    @Published private(set) var cloning = Set<String>()
    private let root = URL(fileURLWithPath: NSHomeDirectory() + "/GitHub")
    private let remoteCatalog = GitHubRepositoryCatalog()
    private let cache = RepositoryCache()
    private var remoteRefreshedAt: Date?
    private var remoteOwners: [String] = []

    init() {
        if let snapshot = cache.load(root: root) {
            repos = snapshot.repositories
            remoteRefreshedAt = snapshot.remoteRefreshedAt
            remoteOwners = snapshot.remoteOwners
        }
        loadCachedProfiles()
    }

    private func loadCachedProfiles(additionalOwners: [String] = []) {
        for owner in Set(owners + additionalOwners) where profiles[owner] == nil {
            if let profile = OwnerCache.cachedProfile(owner) { profiles[owner] = profile }
        }
    }

    private func saveRepositories() {
        try? cache.save(RepositorySnapshot(root: root, repositories: repos,
                                          remoteRefreshedAt: remoteRefreshedAt, remoteOwners: remoteOwners))
    }
    var owners: [String] {
        Array(Set(repos.map(\.owner))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func repositories(for owner: String) -> [Repository] {
        repos.filter { $0.owner == owner }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func refresh(forceProfiles: Bool = false, priorityOwners: [String] = []) async {
        if refreshing {
            guard forceProfiles else { return }
            while refreshing {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        guard !Task.isCancelled else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let scanRoot = root
            let local = try await Task.detached { try Discovery.scan(scanRoot) }.value
            // Publish local changes without waiting for GitHub; retain the last remote catalog.
            let cachedRemote = repos.filter { !$0.isLocal }
            repos = Discovery.merged(local: local, remote: cachedRemote)
            loadCachedProfiles(additionalOwners: priorityOwners)
            saveRepositories()
            let recentRemote = remoteRefreshedAt.map { Date().timeIntervalSince($0) < 5 * 60 } ?? false
            let requestedOwners = Set(priorityOwners.map { $0.lowercased() })
            if forceProfiles || !recentRemote || !requestedOwners.isSubset(of: Set(remoteOwners)) {
                do {
                    let remote = try await remoteCatalog.repositories(root: scanRoot, priorityOwners: priorityOwners)
                    repos = Discovery.merged(local: local, remote: remote)
                    remoteRefreshedAt = Date()
                    remoteOwners = Array(requestedOwners)
                    loadCachedProfiles(additionalOwners: priorityOwners)
                    saveRepositories()
                    githubMessage = nil
                } catch {
                    githubMessage = error.localizedDescription
                }
            }
            error = nil
        }
        catch { self.error = "Couldn’t read \(root.path): \(error.localizedDescription)" }
        profiles = profiles.filter { owners.contains($0.key) }
        loadCachedProfiles(additionalOwners: priorityOwners)
        await withTaskGroup(of: (String, OwnerProfile?).self) { group in
            for owner in owners {
                group.addTask { (owner, await OwnerCache.shared.profile(owner, force: forceProfiles)) }
            }
            for await (owner, profile) in group {
                if let profile { profiles[owner] = profile }
            }
        }
    }
    func clone(_ repo: Repository) async {
        guard !repo.isLocal else { open(repo); return }
        guard let executable = GitHubInbox.executable else {
            githubMessage = GitHubRepositoryFailure.unavailable.localizedDescription
            return
        }
        let key = repo.usageKey
        var next = cloning
        guard next.insert(key).inserted else { return }
        cloning = next
        defer { cloning = cloning.subtracting([key]) }

        let destination = repo.url
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                error = "A folder already exists at \(destination.path)."
                return
            }
            let fullName = repo.fullName
            let status = try await Task.detached { () -> Int32 in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["repo", "clone", fullName, destination.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            guard status == 0 else {
                error = "GitHub couldn’t clone \(repo.fullName). Check repository access and try again."
                return
            }
            await refresh(priorityOwners: owners)
        } catch {
            self.error = "Couldn’t clone \(repo.fullName): \(error.localizedDescription)"
        }
    }

    func open(_ repo: Repository) {
        openInVSCode(repo.url, displayName: repo.name)
    }

    func openFolder(_ url: URL) {
        openInVSCode(url, displayName: url.lastPathComponent)
    }

    private func openInVSCode(_ url: URL, displayName: String) {
        let candidates = ["/Applications/Visual Studio Code.app", NSHomeDirectory() + "/Applications/Visual Studio Code.app"]
        guard let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0 + "/Contents/Resources/app/bin/code") }) else {
            error = "Install Visual Studio Code in Applications to open folders."; return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: app + "/Contents/Resources/app/bin/code")
        task.arguments = ["--new-window", url.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let windows = NSApplication.shared.windows.filter { $0.isVisible && !$0.isMiniaturized }
        task.terminationHandler = { process in
            if process.terminationStatus != 0 {
                Task { @MainActor in
                    self.error = "VS Code couldn’t open \(displayName). Try again."
                    NSApplication.shared.unhide(nil)
                    for window in windows { window.deminiaturize(nil) }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
        }
        do {
            try task.run()
            for window in windows { window.miniaturize(nil) }
            NSApplication.shared.hide(nil)
        } catch { self.error = error.localizedDescription }
    }
}

enum Palette {
    static let accent = Color(red: 67.0 / 255, green: 175.0 / 255, blue: 73.0 / 255)
    static let background = Color(red: 0.065, green: 0.075, blue: 0.095)
    static let column = Color(red: 0.09, green: 0.105, blue: 0.13)
    static let text = Color(red: 0.87, green: 0.90, blue: 0.94)
    static let muted = Color(red: 0.48, green: 0.55, blue: 0.64)
}

struct RepositoryRow: View {
    let repo: Repository
    let pinned: Bool
    let cloning: Bool
    let togglePin: () -> Void
    let open: () -> Void
    let clone: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            if repo.isLocal {
                Button(action: open) {
                    HStack(spacing: 8) {
                        Text(repo.name).font(.system(size: 15, weight: .medium)).lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if hovered { Image(systemName: "arrow.up.right").font(.system(size: 10)) }
                    }
                    .foregroundStyle(hovered ? Color.white : Palette.text)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(hovered ? Color.white.opacity(0.07) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(repo.name)
                .onHover { hovered = $0 }
                .help("Open \(repo.name) in a new VS Code window")
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "cloud")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                    Text(repo.name).font(.system(size: 15, weight: .medium)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Available on GitHub; not cloned locally")
            }

            if repo.isLocal {
                Button(action: togglePin) {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundStyle(pinned ? Palette.text : Palette.muted)
                        .padding(10)
                }
                .buttonStyle(.plain)
                .help(pinned ? "Unpin repository" : "Pin repository to the top")
                .accessibilityLabel(pinned ? "Unpin \(repo.name)" : "Pin \(repo.name)")
            } else {
                Button(action: clone) {
                    if cloning {
                        ProgressView().controlSize(.small).padding(8)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                            .padding(10)
                    }
                }
                .buttonStyle(.plain)
                .disabled(cloning)
                .help("Clone \(repo.fullName) into ~/GitHub/\(repo.owner)/\(repo.name)")
                .accessibilityLabel("Clone \(repo.name)")
            }
        }
        .contextMenu {
            if repo.isLocal {
                Button(pinned ? "Unpin repository" : "Pin repository", action: togglePin)
            } else {
                Button("Clone repository", action: clone).disabled(cloning)
            }
        }
    }
}

struct PinnedRepositoryItem: View {
    let repo: Repository
    let profile: OwnerProfile?
    let open: () -> Void
    let togglePin: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 8) {
                    if let data = profile?.avatar, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5))
                    } else {
                        Text(String(repo.owner.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(repo.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(repo.owner).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(repo.name) in a new VS Code window")

            Button(action: togglePin) {
                Image(systemName: "pin.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .padding(9)
            }
            .buttonStyle(.plain)
            .help("Unpin \(repo.name)")
            .accessibilityLabel("Unpin \(repo.name)")
        }
        .frame(width: 210, height: 42)
        .background(hovered ? Color.white.opacity(0.07) : Palette.column)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu { Button("Unpin repository", action: togglePin) }
    }
}

struct OwnerHeader: View {
    let owner: String
    let profile: OwnerProfile?
    let subtitle: String?
    let showOwnerSlugs: Bool
    var body: some View {
        HStack(spacing: 10) {
            if let data = profile?.avatar, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(String(owner.prefix(1)).uppercased()).font(.system(size: 17, weight: .bold))
                    .frame(width: 34, height: 34).background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(profile?.displayName ?? owner).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                if showOwnerSlugs, let profile, profile.displayName != owner {
                    Text(owner).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                .accessibilityLabel("Drag to reorder organization")
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
    }
}


struct AddOrganizationCard: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 28, weight: .light))
                Text("Add organization").font(.system(size: 16, weight: .semibold))
                Text("Create another organization list")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            .foregroundStyle(hovered ? Color.white : Palette.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hovered ? Color.white.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(hovered ? 0.22 : 0.10),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Add organization")
    }
}


struct FolderSearchBar: View {
    @Binding var query: String
    let results: [FolderSearchResult]
    let searching: Bool
    let message: String?
    let open: (FolderSearchResult) -> Void
    @FocusState private var focused: Bool

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(focused ? Palette.accent : Palette.muted)
            TextField("Repositories and folders", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    if let first = results.first {
                        select(first)
                    }
                }
            if searching {
                ProgressView().controlSize(.small)
            } else if hasQuery {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear folder search")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(Palette.column.overlay(focused ? Palette.accent.opacity(0.10) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(focused ? Palette.accent : Color.white.opacity(0.08),
                        lineWidth: focused ? 2 : 1)
        }
        .overlay(alignment: .top) {
            if focused && hasQuery {
                VStack(spacing: 0) {
                    if searching && results.isEmpty {
                        searchMessage("Searching folders…")
                    } else if let message {
                        searchMessage(message)
                    } else if results.isEmpty {
                        searchMessage("No matching folders")
                    } else {
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                ForEach(results) { result in
                                    Button {
                                        select(result)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: result.isRepository ? "chevron.left.forwardslash.chevron.right" : "folder")
                                                .font(.system(size: 13))
                                                .foregroundStyle(Palette.muted)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(result.name)
                                                    .font(.system(size: 13, weight: .medium))
                                                    .lineLimit(1)
                                                Text(result.parentPath)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(Palette.muted)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                            Spacer(minLength: 8)
                                            Image(systemName: "arrow.up.right.square")
                                                .font(.system(size: 11))
                                                .foregroundStyle(Palette.muted)
                                        }
                                        .padding(.horizontal, 11)
                                        .frame(height: 48)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open \(result.url.path) in VS Code")
                                }
                            }
                        }
                        .frame(height: min(CGFloat(results.count) * 48, 280))
                    }
                }
                .padding(.vertical, 4)
                .frame(width: 440)
                .background(Palette.column)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
                .shadow(radius: 14)
                .offset(y: 36)
            }
        }
        .onExitCommand { focused = false }
        .zIndex(20)
    }

    @ViewBuilder
    private func searchMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
    }

    private func select(_ result: FolderSearchResult) {
        open(result)
        query = ""
        focused = false
    }
}

struct ThinRepositoryScrollbars: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView) }
    }

    private func configure(_ view: NSView) {
        guard let scrollView = view.enclosingScrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.controlSize = .small
    }
}

struct NotificationRow: View {
    let thread: InboxThread
    @ObservedObject var inbox: Inbox
    @State private var hovered = false
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button { NSWorkspace.shared.open(thread.webURL) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: thread.symbol).font(.system(size: 12)).padding(.top, 2).foregroundStyle(Palette.muted)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(thread.subject.title).font(.system(size: 15, weight: .medium)).multilineTextAlignment(.leading)
                        Text(thread.repository.name).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Text(thread.reason.replacingOccurrences(of: "_", with: " ")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(thread.subject.title).help("Open notification on GitHub")
            Button { Task { await inbox.markRead(thread) } } label: {
                Image(systemName: "checkmark").font(.system(size: 10)).padding(4)
            }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                .disabled(inbox.marking.contains(thread.id)).help("Mark as read")
        }
        .padding(12).background(hovered ? Color.white.opacity(0.07) : Color.clear)
        .onHover { hovered = $0 }
    }
}

struct LauncherView: View {
    @StateObject private var library = Library()
    @StateObject private var inbox = Inbox()
    @StateObject private var ownerOrder = OwnerOrderPreferences()
    @StateObject private var repoUsage = RepositoryUsageStore()
    @State private var notifications = false
    @State private var showingAgenda = false
    @State private var settings = false
    @State private var dropTarget: String?
    @State private var pinnedDropTarget: String?
    @AppStorage("studio.repository-launcher.show-repository-counts") private var showRepositoryCounts = true
    @AppStorage("studio.repository-launcher.show-owner-slugs") private var showOwnerSlugs = true
    @State private var addingOrganization = false
    @State private var newOrganization = ""
    @State private var addOrganizationError: String?
    @State private var folderQuery = ""
    @State private var folderResults: [FolderSearchResult] = []
    @State private var folderSearching = false
    @State private var folderSearchMessage: String?
    @Environment(\.scenePhase) private var scenePhase
    private var availableOwners: [String] {
        notifications ? inbox.owners : library.owners + ownerOrder.manualOwners
    }
    private var owners: [String] { ownerOrder.ordered(availableOwners) }
    private var pinnedRepositories: [Repository] {
        repoUsage.pinnedRepositories(from: library.repos)
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 20) {
                    tab("Repositories", selected: !notifications && !settings && !showingAgenda) { notifications = false; settings = false; showingAgenda = false }
                    tab("Agenda", selected: showingAgenda && !settings) { showingAgenda = true; notifications = false; settings = false }
                    Spacer()
                    if library.refreshing || inbox.loading { ProgressView().controlSize(.small) }
                    if notifications && !settings {
                        Button("Connect GitHub", action: inbox.connect).buttonStyle(.plain).font(.system(size: 12))
                    }
                    tab("Notifications", selected: notifications && !settings) { notifications = true; settings = false; showingAgenda = false }
                    Button { settings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: settings ? .semibold : .regular))
                            .foregroundStyle(settings ? Palette.text : Palette.muted)
                            .padding(.bottom, 6)
                            .overlay(alignment: .bottom) {
                                if settings { Rectangle().fill(Palette.text).frame(height: 2) }
                            }
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                    .accessibilityLabel("Settings")
                    .help("Settings")
                }
                FolderSearchBar(query: $folderQuery, results: folderResults,
                                searching: folderSearching, message: folderSearchMessage) { result in
                    folderResults = []
                    folderSearchMessage = nil
                    if let repo = library.repos.first(where: {
                        $0.isLocal && $0.url.standardizedFileURL.path == result.url.standardizedFileURL.path
                    }) {
                        repoUsage.record(repo)
                    }
                    library.openFolder(result.url)
                }
                .frame(width: 440)
            }
            .zIndex(50)
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
            if settings {
                settingsPage
            } else if showingAgenda {
                AgendaView()
            } else {
            if notifications, let message = inbox.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.horizontal, 24).padding(.bottom, 8)
            }
            if !notifications && !pinnedRepositories.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Pinned")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 48, alignment: .leading)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(pinnedRepositories) { repo in
                                    PinnedRepositoryItem(
                                        repo: repo,
                                        profile: library.profiles[repo.owner],
                                        open: {
                                            repoUsage.record(repo)
                                            library.open(repo)
                                        },
                                        togglePin: { repoUsage.togglePin(repo) }
                                    )
                                    .draggable(repo.usageKey)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7)
                                            .stroke(pinnedDropTarget == repo.usageKey ? Palette.text : .clear, lineWidth: 2)
                                    }
                                    .dropDestination(for: String.self) { items, location in
                                        guard let source = items.first,
                                              repoUsage.pinned.contains(source),
                                              source != repo.usageKey else { return false }
                                        repoUsage.movePinned(source, relativeTo: repo.usageKey,
                                                             after: location.x > 105)
                                        return true
                                    } isTargeted: { targeted in
                                        if targeted { pinnedDropTarget = repo.usageKey }
                                        else if pinnedDropTarget == repo.usageKey { pinnedDropTarget = nil }
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 24)
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                }
                .frame(height: 58)
            }
            GeometryReader { geometry in
                let width: CGFloat = notifications ? 320 : 260
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(owners, id: \.self) { owner in
                            VStack(alignment: .leading, spacing: 0) {
                                if notifications {
                                    let threads = inbox.threads.filter { $0.owner == owner }
                                    OwnerHeader(owner: owner, profile: inbox.profiles[owner], subtitle: "\(threads.count) unread", showOwnerSlugs: showOwnerSlugs)
                                        .draggable(owner).help("Drag to reorder organizations")
                                    ScrollView(.vertical) {
                                        LazyVStack(alignment: .leading, spacing: 0) {
                                            ForEach(threads) { thread in NotificationRow(thread: thread, inbox: inbox) }
                                        }.padding(.vertical, 4)
                                    }
                                } else {
                                    let ownerRepositories = library.repositories(for: owner)
                                    let repositories = repoUsage.ranked(ownerRepositories.filter {
                                        !repoUsage.isPinned($0) || !$0.isLocal
                                    })
                                    OwnerHeader(owner: owner, profile: library.profiles[owner], subtitle: showRepositoryCounts ? "\(ownerRepositories.count) repos" : nil, showOwnerSlugs: showOwnerSlugs)
                                        .draggable(owner).help("Drag to reorder organizations")
                                        .contextMenu {
                                            if ownerOrder.isManual(owner) {
                                                Button("Remove organization", role: .destructive) {
                                                    ownerOrder.removeManual(owner)
                                                }
                                            }
                                        }
                                    ScrollView(.vertical) {
                                        LazyVStack(alignment: .leading, spacing: 0) {
                                            ForEach(repositories) { repo in
                                                RepositoryRow(
                                                    repo: repo,
                                                    pinned: repoUsage.isPinned(repo),
                                                    cloning: library.cloning.contains(repo.usageKey),
                                                    togglePin: { repoUsage.togglePin(repo) },
                                                    open: {
                                                        repoUsage.record(repo)
                                                        library.open(repo)
                                                    },
                                                    clone: { Task { await library.clone(repo) } }
                                                )
                                            }
                                        }
                                        .padding(.vertical, 4)
                                        .background(ThinRepositoryScrollbars())
                                    }
                                }
                            }
                            .frame(width: width, height: max(200, geometry.size.height - 48))
                            .background(Palette.column).clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(dropTarget == owner ? Palette.text : .clear, lineWidth: 2)
                            }
                            .dropDestination(for: String.self) { items, location in
                                guard let source = items.first, source != owner, owners.contains(source) else { return false }
                                ownerOrder.move(source, relativeTo: owner, after: location.x > width / 2,
                                                among: availableOwners)
                                return true
                            } isTargeted: { targeted in
                                if targeted { dropTarget = owner }
                                else if dropTarget == owner { dropTarget = nil }
                            }
                        }
                        if !notifications {
                            AddOrganizationCard {
                                newOrganization = ""
                                addOrganizationError = nil
                                addingOrganization = true
                            }
                            .frame(width: width, height: max(200, geometry.size.height - 48))
                        }
                    }.padding(24)
                }
                .overlay {
                    if notifications && owners.isEmpty {
                        VStack(spacing: 12) {
                            if notifications {
                                Text(inbox.loading ? "Loading notifications…" : inbox.needsConnection ? "Connect GitHub to see your inbox" : inbox.message != nil ? "Your inbox is unavailable" : "You’re all caught up")
                                if inbox.needsConnection { Button("Connect GitHub", action: inbox.connect).buttonStyle(.plain) }
                            } else { Text("No repositories found in ~/GitHub") }
                        }.foregroundStyle(Palette.muted)
                    }
                }
            }
            }
        }
        .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
        .tint(Palette.accent)
        .frame(minWidth: 650, minHeight: 400)
        .onDisappear {
            folderQuery = ""
            folderResults = []
            folderSearching = false
            folderSearchMessage = nil
        }
        .task { await library.refresh(priorityOwners: ownerOrder.manualOwners) }
        .task(id: folderQuery) {
            let query = folderQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                folderResults = []
                folderSearchMessage = nil
                folderSearching = false
                return
            }
            folderSearching = true
            folderSearchMessage = nil
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                let results = try await FolderSearch.search(query, repositories: library.repos)
                guard !Task.isCancelled else { return }
                folderResults = results
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                folderResults = []
                folderSearchMessage = error.localizedDescription
            }
            if !Task.isCancelled { folderSearching = false }
        }
        .task(id: settings) {
            guard settings else { return }
            async let repositories: Void = library.refresh(forceProfiles: true, priorityOwners: ownerOrder.manualOwners)
            async let notifications: Void = inbox.refresh()
            _ = await (repositories, notifications)
            for owner in ownerOrder.manualOwners where !library.owners.contains(owner) {
                if let profile = await OwnerCache.shared.profile(owner, force: true) {
                    library.profiles[owner] = profile
                }
            }
        }
        .task(id: notifications) {
            guard notifications else { return }
            while !Task.isCancelled {
                await inbox.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { if notifications { await inbox.refresh() } else { await library.refresh(priorityOwners: ownerOrder.manualOwners) } }
            }
        }
        .sheet(isPresented: $addingOrganization) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add organization").font(.system(size: 18, weight: .semibold))
                Text("Enter a GitHub organization or owner login to create an empty list.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                TextField("GitHub organization or owner", text: $newOrganization)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addOrganization() }
                if let addOrganizationError {
                    Text(addOrganizationError).font(.system(size: 11)).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { addingOrganization = false }
                    Button("Add") { addOrganization() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newOrganization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 390)
        }
        .alert("Repository Launcher", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(.system(size: 22, weight: .semibold))
                Text(library.refreshing || inbox.loading
                     ? "Refreshing local and GitHub repositories, owner profiles, and notifications…"
                     : "Opening Settings refreshes local and GitHub repositories, owner profiles, and notifications.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                if let githubMessage = library.githubMessage {
                    Text(githubMessage).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Toggle("Show repository counts in each category", isOn: $showRepositoryCounts)
                Toggle("Show GitHub owner slugs beneath display names", isOn: $showOwnerSlugs)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Organization order").font(.system(size: 15, weight: .semibold))
                    Text("Drag organization headers on the Repositories or Notifications page, or use the arrows below.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    let orderedOwners = ownerOrder.ordered(library.owners + ownerOrder.manualOwners + inbox.owners)
                    ForEach(Array(orderedOwners.enumerated()), id: \.element) { index, owner in
                        HStack {
                            Text(library.profiles[owner]?.displayName ?? inbox.profiles[owner]?.displayName ?? owner)
                            Spacer()
                            Button {
                                ownerOrder.move(owner, relativeTo: orderedOwners[index - 1], after: false, among: orderedOwners)
                            } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).help("Move \(owner) earlier")
                            .accessibilityLabel("Move \(owner) earlier")
                            Button {
                                ownerOrder.move(owner, relativeTo: orderedOwners[index + 1], after: true, among: orderedOwners)
                            } label: { Image(systemName: "arrow.down") }
                            .disabled(index == orderedOwners.count - 1).help("Move \(owner) later")
                            .accessibilityLabel("Move \(owner) later")
                        }
                    }
                }
                Text("Pinned local repositories move into the draggable bar above the organization columns. A cloud marks a GitHub repository that is not local yet; use its download button to clone it into ~/GitHub. Pin order and organization order are saved automatically.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            .padding(24).frame(maxWidth: 650, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addOrganization() {
        guard let owner = ownerOrder.add(newOrganization) else {
            addOrganizationError = "Use a GitHub owner login containing only letters, numbers, and hyphens."
            return
        }
        newOrganization = ""
        addOrganizationError = nil
        addingOrganization = false
        Task { @MainActor in
            if let profile = await OwnerCache.shared.profile(owner) {
                library.profiles[owner] = profile
            }
            await library.refresh(priorityOwners: ownerOrder.manualOwners)
        }
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Palette.text : Palette.muted)
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) { if selected { Rectangle().fill(Palette.text).frame(height: 2) } }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .accessibilityLabel(title)
    }
}

final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

@main struct RepoLauncherApp: App {
    @NSApplicationDelegateAdaptor(LauncherAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Repository Launcher") { LauncherView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1500, height: 760)
    }
}

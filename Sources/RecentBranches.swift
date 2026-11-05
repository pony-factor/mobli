import Foundation

struct RecentBranch: Identifiable, Sendable {
    let name: String
    let url: URL
    let lastActive: Date

    var id: String { url.standardizedFileURL.path }
}

enum RecentBranches {
    private static let openedKey = "studio.repository-launcher.recent-branches"

    private static func git(_ folder: URL, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseWorktrees(_ output: String) -> [(url: URL, name: String)] {
        output.components(separatedBy: "\n\n").compactMap { entry in
            let lines = entry.components(separatedBy: "\n")
            guard let path = lines.first(where: { $0.hasPrefix("worktree ") })?.dropFirst("worktree ".count),
                  let branch = lines.first(where: { $0.hasPrefix("branch refs/heads/") })?
                    .dropFirst("branch refs/heads/".count),
                  !lines.contains("prunable") else { return nil }
            return (URL(fileURLWithPath: String(path)), String(branch))
        }
    }

    static func active(at url: URL, named branch: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else { return false }
        return git(url, ["symbolic-ref", "--quiet", "--short", "HEAD"]) == branch
    }

    private static func remoteKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("git@github.com:") {
            return "github.com/" + trimmed.dropFirst("git@github.com:".count)
                .replacingOccurrences(of: ".git", with: "").lowercased()
        }
        if let url = URL(string: trimmed), let host = url.host {
            return host.lowercased() + "/" + url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .replacingOccurrences(of: ".git", with: "").lowercased()
        }
        return trimmed.replacingOccurrences(of: ".git", with: "").lowercased()
    }

    private static func lastReflogDate(_ checkout: URL) -> Date? {
        guard let descriptor = git(checkout, ["reflog", "-1", "--date=unix", "--format=%gd", "HEAD"]),
              let start = descriptor.range(of: "@{"),
              let end = descriptor[start.upperBound...].firstIndex(of: "}"),
              let timestamp = TimeInterval(descriptor[start.upperBound..<end]) else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func recordOpened(_ branch: RecentBranch, defaults: UserDefaults = .standard) {
        var dates = defaults.dictionary(forKey: openedKey) as? [String: TimeInterval] ?? [:]
        dates[branch.id] = Date().timeIntervalSince1970
        defaults.set(dates, forKey: openedKey)
    }

    static func recent(for repository: URL, repositoryName: String,
                       workspacesRoot: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Sweetiebot/Workspaces", isDirectory: true),
                       defaults: UserDefaults = .standard) -> [RecentBranch] {
        let fm = FileManager.default
        let sourceURL = repository.standardizedFileURL
        var candidates = [sourceURL]
        if let list = git(sourceURL, ["worktree", "list", "--porcelain"]) {
            candidates += parseWorktrees(list).map(\.url)
        }

        // Sweetiebot creates independent Git clones, which are not in git worktree list.
        let bases = workspacesRoot.appendingPathComponent(repositoryName, isDirectory: true)
        if let folders = try? fm.contentsOfDirectory(at: bases, includingPropertiesForKeys: [.isDirectoryKey]) {
            for folder in folders {
                let clone = folder.appendingPathComponent(repositoryName, isDirectory: true)
                if fm.fileExists(atPath: clone.appendingPathComponent(".git").path) {
                    candidates.append(clone)
                }
            }
        }

        let origin = git(sourceURL, ["config", "--get", "remote.origin.url"]).map(remoteKey)
        let opened = defaults.dictionary(forKey: openedKey) as? [String: TimeInterval] ?? [:]
        var branches: [String: RecentBranch] = [:]
        var seenPaths = Set<String>()

        for url in candidates {
            let checkout = url.standardizedFileURL
            guard seenPaths.insert(checkout.path).inserted,
                  let name = git(checkout, ["symbolic-ref", "--quiet", "--short", "HEAD"]),
                  !name.isEmpty, name != "main" else { continue }
            // Separate clones must belong to the same remote, not merely share a folder name.
            if !checkout.isFileURL { continue }
            if !checkout.standardizedFileURL.path.hasPrefix(sourceURL.path + "/"),
               checkout.path != sourceURL.path,
               !parseWorktreeMembership(checkout, repository: sourceURL) {
                guard let origin, let candidateOrigin = git(checkout, ["config", "--get", "remote.origin.url"]),
                      remoteKey(candidateOrigin) == origin else { continue }
            }
            let date = opened[checkout.path].map(Date.init(timeIntervalSince1970:))
                ?? lastReflogDate(checkout)
                ?? (try? checkout.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let item = RecentBranch(name: name, url: checkout, lastActive: date)
            if let current = branches[name], current.lastActive >= date { continue }
            branches[name] = item
        }
        return branches.values.sorted {
            if $0.lastActive != $1.lastActive { return $0.lastActive > $1.lastActive }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.prefix(6).map { $0 }
    }

    private static func parseWorktreeMembership(_ checkout: URL, repository: URL) -> Bool {
        guard let listed = git(repository, ["worktree", "list", "--porcelain"]) else { return false }
        return parseWorktrees(listed).contains { $0.url.standardizedFileURL == checkout.standardizedFileURL }
    }
}

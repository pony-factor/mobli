import Foundation

@main struct DiscoveryChecks {
    static func main() throws {
        for remote in ["https://github.com/pony-factor/mobli.git", "git@github.com:pony-factor/mobli.git", "ssh://git@github.com/pony-factor/mobli.git"] {
            precondition(Discovery.githubOwner(from: remote) == "pony-factor")
        }
        for remote in ["https://example.com/pony-factor/mobli.git", "https://github.com/pony-factor", "/tmp/local.git"] {
            precondition(Discovery.githubOwner(from: remote) == nil)
        }
        let rankingNow = Date(timeIntervalSince1970: 2_000_000_000)
        let sameActivity = rankingNow.addingTimeInterval(-14 * 86_400.0)
        let orgA = Repository(url: URL(fileURLWithPath: "/tmp/org-a/shared"), owner: "org-a",
                              lastActivityAt: sameActivity)
        let orgB = Repository(url: URL(fileURLWithPath: "/tmp/org-b/shared"), owner: "org-b",
                              lastActivityAt: sameActivity)
        let crossOrgUsage = [
            "org-b/shared": RepositoryUsage(opens: 16, lastOpened: rankingNow)
        ]
        precondition(RepositoryRanking.ranked([orgA, orgB], usage: crossOrgUsage,
                                              now: rankingNow).first?.owner == "org-b")

        let fresh = Repository(url: URL(fileURLWithPath: "/tmp/org-a/fresh"), owner: "org-a",
                               lastActivityAt: rankingNow.addingTimeInterval(-86_400))
        let stale = Repository(url: URL(fileURLWithPath: "/tmp/org-a/stale"), owner: "org-a",
                               lastActivityAt: rankingNow.addingTimeInterval(-365 * 86_400.0))
        precondition(RepositoryRanking.ranked([stale, fresh], usage: [:],
                                              now: rankingNow).first?.name == "fresh")

        precondition(RepositoryRanking.ranked([fresh, stale], usage: [:], now: rankingNow,
                                              pinned: [stale.usageKey]).first?.name == "stale")
        precondition(RepositoryRanking.ranked([orgA, orgB], usage: crossOrgUsage, now: rankingNow,
                                              pinned: [orgA.usageKey]).first?.owner == "org-a")
        precondition(RepositoryRanking.ranked([stale, fresh], usage: [:], now: rankingNow,
                                              pinned: [stale.usageKey, fresh.usageKey]).first?.name == "fresh")

        let remoteDuplicate = Repository(
            url: URL(fileURLWithPath: "/tmp/GitHub/org-a/shared"),
            owner: "org-a",
            lastActivityAt: rankingNow,
            cloneURL: URL(string: "https://github.com/org-a/shared.git")
        )
        let remoteOnly = Repository(
            url: URL(fileURLWithPath: "/tmp/GitHub/org-a/remote-only"),
            owner: "org-a",
            lastActivityAt: rankingNow,
            cloneURL: URL(string: "https://github.com/org-a/remote-only.git")
        )
        let merged = Discovery.merged(local: [orgA], remote: [remoteDuplicate, remoteOnly])
        precondition(merged.count == 2)
        precondition(merged.first(where: { $0.usageKey == orgA.usageKey })?.isLocal == true)
        precondition(merged.first(where: { $0.name == "remote-only" })?.isLocal == false)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("old-owner/mobli")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) throws {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments = ["-C", repo.path] + args
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            precondition(task.terminationStatus == 0)
        }
        try git(["init"])
        try git(["remote", "add", "origin", "https://github.com/pony-factor/mobli.git"])
        var discovered = try Discovery.scan(root)
        precondition(discovered.count == 1 && discovered[0].owner == "pony-factor")
        precondition(discovered[0].url.resolvingSymlinksInPath().path == repo.resolvingSymlinksInPath().path && discovered[0].name == "mobli")
        try git(["remote", "set-url", "origin", "https://github.com/new-owner/mobli.git"])
        discovered = try Discovery.scan(root)
        precondition(discovered[0].owner == "new-owner")
        try git(["remote", "remove", "origin"])
        discovered = try Discovery.scan(root)
        precondition(discovered[0].owner == "old-owner")
        print("Discovery and activity-ranking checks passed")
    }
}

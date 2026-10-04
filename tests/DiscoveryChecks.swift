import Foundation

@main struct DiscoveryChecks {
    static func main() async throws {
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
        precondition(RepositoryRanking.ranked([orgA, orgB], usage: crossOrgUsage).first?.owner == "org-b")

        let fresh = Repository(url: URL(fileURLWithPath: "/tmp/org-a/fresh"), owner: "org-a",
                               lastActivityAt: rankingNow.addingTimeInterval(-86_400))
        let stale = Repository(url: URL(fileURLWithPath: "/tmp/org-a/stale"), owner: "org-a",
                               lastActivityAt: rankingNow.addingTimeInterval(-365 * 86_400.0))
        precondition(RepositoryRanking.ranked([stale, fresh], usage: [:]).first?.name == "fresh")

        precondition(RepositoryRanking.ranked([fresh, stale], usage: [:],
                                              pinned: [stale.usageKey]).first?.name == "stale")
        precondition(RepositoryRanking.ranked([orgA, orgB], usage: crossOrgUsage,
                                              pinned: [orgA.usageKey]).first?.owner == "org-a")
        precondition(RepositoryRanking.ranked([stale, fresh], usage: [:],
                                              pinned: [stale.usageKey, fresh.usageKey]).first?.name == "fresh")

        let pinOrder = [stale.usageKey, fresh.usageKey, orgB.usageKey]
        precondition(PinnedRepositoryOrdering.ordered([fresh, orgB, stale], keys: pinOrder).map(\.usageKey) == pinOrder)
        precondition(PinnedRepositoryOrdering.moving(stale.usageKey, relativeTo: orgB.usageKey,
                                                     after: true, order: pinOrder)
                     == [fresh.usageKey, orgB.usageKey, stale.usageKey])
        precondition(PinnedRepositoryOrdering.moving(orgB.usageKey, relativeTo: stale.usageKey,
                                                     after: false, order: pinOrder)
                     == [orgB.usageKey, stale.usageKey, fresh.usageKey])

        // Opening an older project now must outrank both a new commit and frequent past use.
        let recentUsage = [
            stale.usageKey: RepositoryUsage(opens: 1, lastOpened: rankingNow),
            fresh.usageKey: RepositoryUsage(opens: 500, lastOpened: rankingNow.addingTimeInterval(-86_400))
        ]
        precondition(RepositoryRanking.ranked([fresh, stale], usage: recentUsage).first?.name == "stale")
        precondition(RepositoryRanking.ranked([fresh, stale], usage: [
            stale.usageKey: RepositoryUsage(opens: 1, lastOpened: rankingNow.addingTimeInterval(-90 * 86_400))
        ]).first?.name == "stale")

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
        // A cloud row stays below cloned projects, even if it has newer activity or saved usage.
        precondition(RepositoryRanking.ranked([remoteOnly, stale], usage: [
            remoteOnly.usageKey: RepositoryUsage(opens: 20, lastOpened: rankingNow)
        ]).first?.isLocal == true)
        precondition(RepositoryRanking.ranked([stale, remoteOnly], usage: [:],
                                              pinned: [remoteOnly.usageKey]).first?.name == "remote-only")
        precondition(RepositoryRanking.ranked([orgB, orgA], usage: [:]).first?.owner == "org-a")
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

        // Use a unique name so unrelated Spotlight results cannot crowd out the fixtures.
        let searchName = "cloud-search-" + UUID().uuidString
        let localURL = root.appendingPathComponent("old-owner/" + searchName)
        try FileManager.default.moveItem(at: repo, to: localURL)
        let local = Repository(url: localURL, owner: "old-owner", lastActivityAt: nil)
        let cloud = Repository(url: root.appendingPathComponent("cloud-owner/" + searchName), owner: "cloud-owner",
                               lastActivityAt: nil, cloneURL: URL(string: "https://github.com/cloud-owner/\(searchName).git"))
        let searchCatalog = [cloud, local]
        let searchResults = try await FolderSearch.search(searchName, repositories: searchCatalog)
        let localResult = searchResults.first { $0.id == local.url.path }
        let cloudResult = searchResults.first { $0.id == cloud.url.path }
        precondition(localResult?.isCloud == false && localResult?.isRepository == true)
        precondition(cloudResult?.isCloud == true && cloudResult?.isRepository == true)
        precondition(cloudResult?.parentPath == "GitHub · cloud-owner/\(searchName)")
        precondition(cloudResult?.githubURL?.absoluteString == "https://github.com/cloud-owner/\(searchName)")
        precondition(searchResults.map(\.id) == [local.url.path, cloud.url.path])
        let ownerResults = try await FolderSearch.search(" CLOUD-OWNER/\(searchName.uppercased()) ", repositories: searchCatalog)
        precondition(ownerResults.map(\.id) == [cloud.url.path])
        let limitedResults = try await FolderSearch.search(searchName, repositories: searchCatalog, limit: 1)
        precondition(limitedResults.count == 1 && limitedResults[0].id == local.url.path)
        let emptyResults = try await FolderSearch.search("  ", repositories: searchCatalog)
        precondition(emptyResults.isEmpty)

        let cacheDirectory = root.appendingPathComponent("launcher-cache")
        let cache = RepositoryCache(directory: cacheDirectory)
        precondition(cache.load(root: root) == nil)
        try cache.save(RepositorySnapshot(root: root, repositories: [orgA, remoteOnly],
                                          remoteRefreshedAt: rankingNow, remoteOwners: ["org-a"]))
        // A new cache instance must restore both local and remote rows without Git or network access.
        let restored = RepositoryCache(directory: cacheDirectory).load(root: root)
        precondition(restored?.repositories.count == 2)
        precondition(restored?.repositories.first?.url == orgA.url)
        precondition(restored?.repositories.first?.lastActivityAt == sameActivity)
        precondition(restored?.repositories.last?.cloneURL == remoteOnly.cloneURL)
        precondition(restored?.remoteRefreshedAt == rankingNow)
        precondition(restored?.remoteOwners == ["org-a"])
        precondition(cache.load(root: root.appendingPathComponent("other-root")) == nil)
        // A successful refresh replaces the previous catalog, including removed rows.
        try cache.save(RepositorySnapshot(root: root, repositories: [fresh],
                                          remoteRefreshedAt: nil, remoteOwners: []))
        precondition(cache.load(root: root)?.repositories.map(\.name) == ["fresh"])
        try Data("incomplete cache".utf8).write(to: cache.fileURL)
        precondition(cache.load(root: root) == nil)
        print("Discovery, activity-ranking, and persistent repository-cache checks passed")
    }
}

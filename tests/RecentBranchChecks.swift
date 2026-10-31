import Foundation

@main struct RecentBranchChecks {
    static func main() throws {
        let rows = RecentBranches.parseWorktrees("""
        worktree /tmp/main with spaces
        HEAD abc
        branch refs/heads/main

        worktree /tmp/topic with spaces
        HEAD def
        branch refs/heads/feature/topic

        worktree /tmp/detached
        HEAD ghi
        detached

        """)
        precondition(rows.count == 2)
        precondition(rows[1].name == "feature/topic")
        precondition(rows[1].url.path == "/tmp/topic with spaces")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("mobli")
        let worktree = root.appendingPathComponent("linked-topic")
        let workspaces = root.appendingPathComponent("Workspaces")
        let clone = workspaces.appendingPathComponent("mobli/sample/mobli")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0, "Git fixture failed: \(arguments)")
        }

        try run(["init", "-b", "main", source.path])
        try run(["-C", source.path, "config", "user.email", "test@example.com"])
        try run(["-C", source.path, "config", "user.name", "Test"])
        try run(["-C", source.path, "commit", "--allow-empty", "-m", "Test fixture"])
        try run(["-C", source.path, "remote", "add", "origin", "https://github.com/pony-factor/mobli.git"])
        try run(["-C", source.path, "worktree", "add", "-b", "applejack", worktree.path])
        try FileManager.default.createDirectory(at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run(["clone", "--local", source.path, clone.path])
        try run(["-C", clone.path, "remote", "set-url", "origin", "git@github.com:pony-factor/mobli.git"])
        try run(["-C", clone.path, "switch", "-c", "rarity"])
        let suite = "mobli-recent-branch-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var recent = RecentBranches.recent(for: source, repositoryName: "mobli",
                                           workspacesRoot: workspaces, defaults: defaults)
        precondition(Set(recent.map(\.name)) == Set(["applejack", "rarity"]))
        precondition(recent.allSatisfy { RecentBranches.active(at: $0.url, named: $0.name) })
        let linked = recent.first { $0.name == "applejack" }!
        RecentBranches.recordOpened(linked, defaults: defaults)
        recent = RecentBranches.recent(for: source, repositoryName: "mobli",
                                      workspacesRoot: workspaces, defaults: defaults)
        precondition(recent.first?.name == "applejack", "Most recently opened branch must rank first")
        try run(["-C", clone.path, "switch", "main"])
        recent = RecentBranches.recent(for: source, repositoryName: "mobli",
                                      workspacesRoot: workspaces, defaults: defaults)
        precondition(recent.map(\.name) == ["applejack"], "Main is accessed by the ordinary repository click")
        print("PASS: linked worktrees, Sweetiebot clones, recent ordering, and stale branch exclusion")
    }
}

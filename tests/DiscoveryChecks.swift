import Foundation

@main struct DiscoveryChecks {
    static func main() throws {
        for remote in ["https://github.com/pony-factor/mobli.git", "git@github.com:pony-factor/mobli.git", "ssh://git@github.com/pony-factor/mobli.git"] {
            precondition(Discovery.githubOwner(from: remote) == "pony-factor")
        }
        for remote in ["https://example.com/pony-factor/mobli.git", "https://github.com/pony-factor", "/tmp/local.git"] {
            precondition(Discovery.githubOwner(from: remote) == nil)
        }
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
        print("Discovery checks passed")
    }
}

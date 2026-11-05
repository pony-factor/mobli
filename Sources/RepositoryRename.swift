import Foundation

/// Moves only canonical, standalone clones after GitHub confirms a repository rename.
/// Never moves custom folders, symlinks, linked worktrees, or occupied destinations.
enum RepositoryRename {
    struct Change: Sendable {
        let local: Repository
        let remote: Repository
    }

    enum Failure: LocalizedError {
        case blocked(String)

        var errorDescription: String? {
            if case let .blocked(message) = self { return message }
            return nil
        }
    }

    static func updatedOrigin(_ oldURL: String, owner: String, oldName: String, newName: String) -> String? {
        let value = oldURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Discovery.githubRepository(from: value),
              parsed.owner.caseInsensitiveCompare(owner) == .orderedSame,
              parsed.name.caseInsensitiveCompare(oldName) == .orderedSame,
              newName != ".", newName != "..",
              newName.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              let slash = value.range(of: "/", options: .backwards) else { return nil }
        return String(value[..<slash.upperBound]) + newName + (value.hasSuffix(".git") ? ".git" : "")
    }

    private static func git(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.blocked("Git could not verify or update the checkout.")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func perform(_ change: Change, root: URL) throws -> Bool {
        let old = change.local
        let new = change.remote
        guard old.isLocal, !old.isWorktree, !new.isLocal,
              old.owner.caseInsensitiveCompare(new.owner) == .orderedSame,
              old.name.caseInsensitiveCompare(old.repositoryName) == .orderedSame,
              old.name.caseInsensitiveCompare(new.repositoryName) != .orderedSame else { return false }
        let source = root.appendingPathComponent(old.owner, isDirectory: true)
            .appendingPathComponent(old.name, isDirectory: true).standardizedFileURL
        let destination = root.appendingPathComponent(old.owner, isDirectory: true)
            .appendingPathComponent(new.repositoryName, isDirectory: true).standardizedFileURL
        guard old.url.standardizedFileURL.path == source.path,
              destination.path != source.path,
              let sourceKind = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.type] as? FileAttributeType,
              sourceKind == .typeDirectory else { return false }

        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: destination.path)) == nil else {
            throw Failure.blocked("The new folder \(destination.lastPathComponent) already exists; nothing was moved.")
        }
        let dotGit = source.appendingPathComponent(".git")
        guard let gitKind = (try? fm.attributesOfItem(atPath: dotGit.path))?[.type] as? FileAttributeType,
              gitKind == .typeDirectory else {
            throw Failure.blocked("The checkout uses a linked worktree or nonstandard Git directory.")
        }
        let currentOrigin = try git(["-C", source.path, "config", "--get", "remote.origin.url"])
        guard let nextOrigin = updatedOrigin(currentOrigin, owner: old.owner,
                                             oldName: old.repositoryName, newName: new.repositoryName) else {
            throw Failure.blocked("Origin no longer matches the GitHub repository.")
        }
        let worktrees = try git(["-C", source.path, "worktree", "list", "--porcelain"])
        guard worktrees.components(separatedBy: "\n").filter({ $0.hasPrefix("worktree ") }).count == 1 else {
            throw Failure.blocked("Linked worktrees are registered; leaving the checkout path unchanged.")
        }
        // Recheck immediately before moving, including symlinks and non-directory entries.
        guard (try? fm.attributesOfItem(atPath: destination.path)) == nil else {
            throw Failure.blocked("The destination appeared during refresh; nothing was moved.")
        }
        try fm.moveItem(at: source, to: destination)
        do {
            _ = try git(["-C", destination.path, "remote", "set-url", "origin", nextOrigin])
        } catch {
            do {
                try fm.moveItem(at: destination, to: source)
            } catch {
                throw Failure.blocked("Origin update failed and the folder could not be restored: \(error.localizedDescription)")
            }
            throw Failure.blocked("Origin update failed; the folder was restored.")
        }
        return true
    }
}

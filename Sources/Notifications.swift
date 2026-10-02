import Foundation
import AppKit

struct InboxThread: Decodable, Identifiable, Sendable {
    struct Repo: Decodable, Sendable {
        struct Owner: Decodable, Sendable { let login: String }
        let name: String
        let html_url: URL
        let owner: Owner
    }
    struct Subject: Decodable, Sendable {
        let title: String
        let type: String
        let url: URL?
    }
    let id: String
    let repository: Repo
    let subject: Subject
    let reason: String
    let updated_at: String

    var owner: String { repository.owner.login }
    var symbol: String {
        switch subject.type {
        case "PullRequest": return "arrow.triangle.pull"
        case "Issue": return "circle.inset.filled"
        case "Release": return "tag"
        case "Commit": return "point.topleft.down.to.point.bottomright.curvepath"
        default: return "bell"
        }
    }
    var webURL: URL {
        if let url = subject.url, url.host == "api.github.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count == 5, parts[0] == "repos", ["issues", "pulls", "commits"].contains(parts[3]) {
                let kind = parts[3] == "pulls" ? "pull" : parts[3] == "commits" ? "commit" : "issues"
                return URL(string: "https://github.com/\(parts[1])/\(parts[2])/\(kind)/\(parts[4])")!
            }
        }
        // The inbox URL also covers discussions, releases, and security alerts.
        var url = URLComponents(string: "https://github.com/notifications")!
        url.queryItems = [URLQueryItem(name: "query", value: "repo:" + owner + "/" + repository.name)]
        return url.url!
    }
}

enum InboxFailure: LocalizedError {
    case missingCLI, signIn, request
    var errorDescription: String? {
        switch self {
        case .missingCLI: return "Install GitHub CLI to connect your account."
        case .signIn: return "Connect GitHub to read your notification inbox."
        case .request: return "Couldn’t refresh notifications. Check your connection and try again."
        }
    }
}

actor GitHubInbox {
    static var executable: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private var lastModified: String?
    private var nextRefresh = Date.distantPast
    private var threads: [InboxThread] = []
    private var cachedFailure: InboxFailure?
    private var account: String?

    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    // GitHub CLI owns credentials; the launcher never reads or stores a token.
    private func request(_ endpoint: String, method: String = "GET", conditional: String? = nil) async throws -> Response {
        guard let executable = Self.executable else { throw InboxFailure.missingCLI }
        var arguments = ["api", "--hostname", "github.com", "--include", "--method", method,
                         "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2026-03-10", endpoint]
        if let conditional { arguments += ["-H", "If-Modified-Since: " + conditional] }
        let commandArguments = arguments
        let data = try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = commandArguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            return data
        }.value
        return try Self.parseResponse(data)
    }

    static func parseResponse(_ data: Data) throws -> Response {
        // gh --include emits HTTP headers followed by JSON, using LF or CRLF.
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        guard let separator = text.range(of: "\n\n") else { throw InboxFailure.signIn }
        let lines = text[..<separator.lowerBound].split(separator: "\n")
        guard let first = lines.first, let status = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
            throw InboxFailure.request
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return Response(status: status, headers: headers, body: Data(text[separator.upperBound...].utf8))
    }

    func fetch() async throws -> [InboxThread] {
        guard Date() >= nextRefresh else {
            if let cachedFailure { throw cachedFailure }
            return threads
        }
        let user = try await request("/user")
        guard user.status == 200 else { throw InboxFailure.signIn }
        struct Identity: Decodable { let login: String }
        let login = try JSONDecoder().decode(Identity.self, from: user.body).login
        if account != login {
            account = login
            lastModified = nil
            threads = []
        }
        var result: [InboxThread] = []
        var modified: String?
        var interval = 60.0
        var page = 1
        while true {
            let response = try await request("/notifications?per_page=50&page=\(page)", conditional: page == 1 ? lastModified : nil)
            interval = max(interval, Double(response.headers["x-poll-interval"] ?? "60") ?? 60)
            if response.status == 304 {
                cachedFailure = nil
                nextRefresh = Date().addingTimeInterval(interval)
                return threads
            }
            if [401, 403].contains(response.status) {
                if response.headers["x-ratelimit-remaining"] == "0" {
                    cachedFailure = .request
                    if let reset = Double(response.headers["x-ratelimit-reset"] ?? "") {
                        nextRefresh = Date(timeIntervalSince1970: reset)
                    }
                    throw InboxFailure.request
                }
                if let retry = Double(response.headers["retry-after"] ?? "") {
                    nextRefresh = Date().addingTimeInterval(max(interval, retry))
                    cachedFailure = .signIn
                }
                throw InboxFailure.signIn
            }
            guard response.status == 200 else { throw InboxFailure.request }
            if page == 1 { modified = response.headers["last-modified"] }
            let batch = try JSONDecoder().decode([InboxThread].self, from: response.body)
            result += batch
            if batch.count < 50 { break }
            page += 1
        }
        var seen = Set<String>()
        threads = result.filter { seen.insert($0.id).inserted }
        lastModified = modified
        cachedFailure = nil
        nextRefresh = Date().addingTimeInterval(interval)
        return threads
    }

    func markRead(_ id: String) async throws {
        guard id.allSatisfy(\.isNumber), !id.isEmpty else { throw InboxFailure.request }
        let response = try await request("/notifications/threads/" + id, method: "PATCH")
        guard response.status == 205 else { throw InboxFailure.request }
        threads.removeAll { $0.id == id }
    }
}

@MainActor final class Inbox: ObservableObject {
    @Published var threads: [InboxThread] = []
    @Published var profiles: [String: OwnerProfile] = [:]
    @Published var message: String?
    @Published var needsConnection = false
    @Published var loading = false
    @Published var marking = Set<String>()
    private let api = GitHubInbox()
    var owners: [String] { Array(Set(threads.map(\.owner))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            threads = try await api.fetch()
            message = nil; needsConnection = false
            for owner in owners {
                if let cached = await OwnerCache.shared.cached(owner) { profiles[owner] = cached }
            }
            await withTaskGroup(of: (String, OwnerProfile?).self) { group in
                for owner in owners { group.addTask { (owner, await OwnerCache.shared.profile(owner)) } }
                for await (owner, profile) in group { if let profile { profiles[owner] = profile } }
            }
        } catch {
            message = error.localizedDescription
            needsConnection = (error as? InboxFailure).map { if case .request = $0 { return false }; return true } ?? false
        }
    }
    func markRead(_ thread: InboxThread) async {
        guard !marking.contains(thread.id) else { return }
        marking.insert(thread.id)
        defer { marking.remove(thread.id) }
        do {
            try await api.markRead(thread.id)
            threads.removeAll { $0.id == thread.id }
        } catch { message = error.localizedDescription }
    }
    func connect() {
        guard let executable = GitHubInbox.executable else {
            NSWorkspace.shared.open(URL(string: "https://cli.github.com")!); return
        }
        // A deliberate button click starts GitHub CLI's browser authorization.
        // Terminal shows the one-time code; credential material stays with gh.
        let command = "'" + executable + "' auth login --hostname github.com --web --scopes notifications"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell")
        var scriptError: NSDictionary?
        script?.executeAndReturnError(&scriptError)
        message = scriptError == nil ? "Finish signing in in your browser, then return here." : "Couldn’t start sign-in. Open Terminal and run gh auth login --web --scopes notifications."
    }
}

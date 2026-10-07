import Foundation
import AppKit
import SwiftUI

struct ActivityItem: Identifiable, Sendable {
    enum Kind: Sendable {
        case pullRequest
        case comment
        case review
        case reviewComment
        case merged
        case closed

        var label: String {
            switch self {
            case .pullRequest: return "pull request opened"
            case .comment: return "comment"
            case .review: return "review"
            case .reviewComment: return "review comment"
            case .merged: return "pull request merged"
            case .closed: return "pull request closed"
            }
        }

        var symbol: String {
            switch self {
            case .pullRequest: return "arrow.triangle.pull"
            case .comment: return "bubble.left"
            case .review: return "checkmark.bubble"
            case .reviewComment: return "text.bubble"
            case .merged: return "arrow.triangle.merge"
            case .closed: return "xmark.circle"
            }
        }
    }

    let id: String
    let owner: String
    let repository: String
    let number: Int
    let title: String
    let kind: Kind
    let actor: String?
    let body: String?
    let date: Date
    let url: URL
    let canSquashMerge: Bool

    var preview: String? {
        guard let body else { return nil }
        let value = body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return value.isEmpty ? nil : value
    }
}

enum ActivityFailure: LocalizedError, Equatable, Sendable {
    case missingCLI, signIn, request, merge

    var errorDescription: String? {
        switch self {
        case .missingCLI: return "Install GitHub CLI to load organization activity."
        case .signIn: return "Connect GitHub to load organization activity."
        case .request: return "Couldn’t refresh organization activity. Check your connection and try again."
        case .merge: return "Couldn’t squash and merge this pull request. Check GitHub and try again."
        }
    }
}

actor GitHubActivity {
    static var executable: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private struct Author: Decodable, Sendable {
        let login: String
    }

    private struct RepositoryOwner: Decodable, Sendable {
        let login: String
    }

    private struct RepositoryNode: Decodable, Sendable {
        let name: String
        let owner: RepositoryOwner
    }

    private struct CommentNode: Decodable, Sendable {
        let id: String
        let bodyText: String
        let createdAt: String
        let updatedAt: String
        let url: URL
        let author: Author?
    }

    private struct ReviewNode: Decodable, Sendable {
        let id: String
        let bodyText: String
        let state: String
        let createdAt: String
        let updatedAt: String
        let submittedAt: String?
        let url: URL
        let author: Author?
    }

    private struct CommentConnection: Decodable, Sendable {
        let nodes: [CommentNode?]
    }

    private struct ReviewConnection: Decodable, Sendable {
        let nodes: [ReviewNode?]
    }

    private struct ReviewThreadNode: Decodable, Sendable {
        let comments: CommentConnection
    }

    private struct ReviewThreadConnection: Decodable, Sendable {
        let nodes: [ReviewThreadNode?]
    }

    private struct PullRequestNode: Decodable, Sendable {
        let id: String
        let number: Int
        let title: String
        let url: URL
        let createdAt: String
        let updatedAt: String
        let state: String
        let mergedAt: String?
        let closedAt: String?
        let author: Author?
        let mergedBy: Author?
        let repository: RepositoryNode
        let comments: CommentConnection
        let reviews: ReviewConnection
        let reviewThreads: ReviewThreadConnection
    }

    private struct SearchConnection: Decodable, Sendable {
        let nodes: [PullRequestNode?]
    }

    private struct DataPayload: Decodable, Sendable {
        let search: SearchConnection
    }

    private struct GraphQLError: Decodable, Sendable {
        let message: String
    }

    private struct GraphQLResponse: Decodable, Sendable {
        let data: DataPayload?
        let errors: [GraphQLError]?
    }

    private struct CachedActivity: Sendable {
        let items: [ActivityItem]
        let refreshAfter: Date
    }

    private var cache: [String: CachedActivity] = [:]

    private static let query = """
    query($searchQuery: String!) {
      search(query: $searchQuery, type: ISSUE, first: 25) {
        nodes {
          ... on PullRequest {
            id
            number
            title
            url
            createdAt
            updatedAt
            state
            mergedAt
            closedAt
            author { login }
            mergedBy { login }
            repository {
              name
              owner { login }
            }
            comments(last: 10) {
              nodes {
                id
                bodyText
                createdAt
                updatedAt
                url
                author { login }
              }
            }
            reviews(last: 10) {
              nodes {
                id
                bodyText
                state
                createdAt
                updatedAt
                submittedAt
                url
                author { login }
              }
            }
            reviewThreads(last: 10) {
              nodes {
                comments(last: 5) {
                  nodes {
                    id
                    bodyText
                    createdAt
                    updatedAt
                    url
                    author { login }
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    func fetch(owner: String, force: Bool = false) async throws -> [ActivityItem] {
        let key = owner.lowercased()
        if !force, let cached = cache[key], cached.refreshAfter > Date() {
            return cached.items
        }

        let organizationItems = try await fetchSearch("org:\(owner) is:pr sort:updated-desc")
        let items = organizationItems.isEmpty
            ? try await fetchSearch("user:\(owner) is:pr sort:updated-desc")
            : organizationItems
        cache[key] = CachedActivity(items: items, refreshAfter: Date().addingTimeInterval(60))
        return items
    }

    static func mergeEndpoint(owner: String, repository: String, number: Int) -> String {
        "/repos/\(owner)/\(repository)/pulls/\(number)/merge"
    }

    func squashMerge(_ item: ActivityItem) async throws {
        guard item.canSquashMerge else { return }
        guard let executable = Self.executable else { throw ActivityFailure.missingCLI }
        let arguments = [
            "api", "--hostname", "github.com", "--method", "PUT",
            "-H", "Accept: application/vnd.github+json",
            "-H", "X-GitHub-Api-Version: 2026-03-10",
            Self.mergeEndpoint(owner: item.owner, repository: item.repository, number: item.number),
            "-f", "merge_method=squash"
        ]
        let result = try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            return (data, process.terminationStatus)
        }.value

        guard result.1 == 0 else {
            let text = String(decoding: result.0, as: UTF8.self).lowercased()
            if text.contains("auth login") || text.contains("authentication") || text.contains("http 401") {
                throw ActivityFailure.signIn
            }
            throw ActivityFailure.merge
        }
        cache.removeValue(forKey: item.owner.lowercased())
    }

    private func fetchSearch(_ search: String) async throws -> [ActivityItem] {
        guard let executable = Self.executable else { throw ActivityFailure.missingCLI }
        let arguments = [
            "api", "graphql", "--hostname", "github.com",
            "-H", "X-GitHub-Api-Version: 2026-03-10",
            "-f", "query=" + Self.query,
            "-F", "searchQuery=" + search
        ]
        let result = try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            return (data, process.terminationStatus)
        }.value

        guard result.1 == 0 else {
            let text = String(decoding: result.0, as: UTF8.self).lowercased()
            if text.contains("auth login") || text.contains("authentication") || text.contains("http 401") {
                throw ActivityFailure.signIn
            }
            throw ActivityFailure.request
        }
        return try Self.parse(result.0)
    }

    static func parse(_ data: Data) throws -> [ActivityItem] {
        let response: GraphQLResponse
        do {
            response = try JSONDecoder().decode(GraphQLResponse.self, from: data)
        } catch {
            throw ActivityFailure.request
        }
        guard let payload = response.data else {
            if response.errors?.isEmpty == false { throw ActivityFailure.request }
            throw ActivityFailure.request
        }

        var items: [ActivityItem] = []
        var seen = Set<String>()

        for pullRequest in payload.search.nodes.compactMap({ $0 }) {
            let owner = pullRequest.repository.owner.login
            let repository = pullRequest.repository.name
            let canSquashMerge = pullRequest.state == "OPEN"

            if let created = parseDate(pullRequest.createdAt) {
                items.append(ActivityItem(
                    id: "pr-open-" + pullRequest.id,
                    owner: owner,
                    repository: repository,
                    number: pullRequest.number,
                    title: pullRequest.title,
                    kind: .pullRequest,
                    actor: pullRequest.author?.login,
                    body: nil,
                    date: created,
                    url: pullRequest.url,
                    canSquashMerge: canSquashMerge
                ))
            }

            if let mergedAt = pullRequest.mergedAt.flatMap(parseDate) {
                items.append(ActivityItem(
                    id: "pr-merge-" + pullRequest.id,
                    owner: owner,
                    repository: repository,
                    number: pullRequest.number,
                    title: pullRequest.title,
                    kind: .merged,
                    actor: pullRequest.mergedBy?.login,
                    body: nil,
                    date: mergedAt,
                    url: pullRequest.url,
                    canSquashMerge: false
                ))
            } else if pullRequest.state == "CLOSED", let closedAt = pullRequest.closedAt.flatMap(parseDate) {
                items.append(ActivityItem(
                    id: "pr-close-" + pullRequest.id,
                    owner: owner,
                    repository: repository,
                    number: pullRequest.number,
                    title: pullRequest.title,
                    kind: .closed,
                    actor: nil,
                    body: nil,
                    date: closedAt,
                    url: pullRequest.url,
                    canSquashMerge: false
                ))
            }

            for comment in pullRequest.comments.nodes.compactMap({ $0 }) where seen.insert(comment.id).inserted {
                guard let date = parseDate(comment.updatedAt) ?? parseDate(comment.createdAt) else { continue }
                items.append(ActivityItem(
                    id: "comment-" + comment.id,
                    owner: owner,
                    repository: repository,
                    number: pullRequest.number,
                    title: pullRequest.title,
                    kind: .comment,
                    actor: comment.author?.login,
                    body: comment.bodyText,
                    date: date,
                    url: comment.url,
                    canSquashMerge: false
                ))
            }

            for review in pullRequest.reviews.nodes.compactMap({ $0 }) where seen.insert(review.id).inserted {
                let timestamp = review.submittedAt ?? review.updatedAt
                guard let date = parseDate(timestamp) ?? parseDate(review.createdAt) else { continue }
                let body = review.bodyText.isEmpty ? review.state.lowercased() : review.state.lowercased() + ": " + review.bodyText
                items.append(ActivityItem(
                    id: "review-" + review.id,
                    owner: owner,
                    repository: repository,
                    number: pullRequest.number,
                    title: pullRequest.title,
                    kind: .review,
                    actor: review.author?.login,
                    body: body,
                    date: date,
                    url: review.url,
                    canSquashMerge: false
                ))
            }

            for thread in pullRequest.reviewThreads.nodes.compactMap({ $0 }) {
                for comment in thread.comments.nodes.compactMap({ $0 }) where seen.insert(comment.id).inserted {
                    guard let date = parseDate(comment.updatedAt) ?? parseDate(comment.createdAt) else { continue }
                    items.append(ActivityItem(
                        id: "review-comment-" + comment.id,
                        owner: owner,
                        repository: repository,
                        number: pullRequest.number,
                        title: pullRequest.title,
                        kind: .reviewComment,
                        actor: comment.author?.login,
                        body: comment.bodyText,
                        date: date,
                        url: comment.url,
                        canSquashMerge: false
                    ))
                }
            }
        }

        return Array(items.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }.prefix(100))
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(value)
    }
}

private struct ActivityOwnerResult: Sendable {
    let owner: String
    let items: [ActivityItem]?
    let message: String?
    let needsConnection: Bool
}

@MainActor final class ActivityFeed: ObservableObject {
    @Published private(set) var itemsByOwner: [String: [ActivityItem]] = [:]
    @Published var message: String?
    @Published var needsConnection = false
    @Published var loading = false
    @Published private(set) var merging = Set<String>()
    private let api = GitHubActivity()

    var owners: [String] {
        itemsByOwner.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func items(for owner: String) -> [ActivityItem] {
        itemsByOwner[owner] ?? []
    }

    func squashMerge(_ item: ActivityItem) async {
        guard item.canSquashMerge, !merging.contains(item.id) else { return }
        merging.insert(item.id)
        defer { merging.remove(item.id) }
        do {
            try await api.squashMerge(item)
            itemsByOwner[item.owner] = try await api.fetch(owner: item.owner, force: true)
            message = nil
            needsConnection = false
        } catch {
            message = error.localizedDescription
            let failure = error as? ActivityFailure
            needsConnection = failure == .missingCLI || failure == .signIn
        }
    }

    func refresh(owners: [String], force: Bool = false) async {
        guard !loading else { return }
        var seen = Set<String>()
        let targets = owners.filter { seen.insert($0.lowercased()).inserted }
        guard !targets.isEmpty else {
            itemsByOwner = [:]
            message = nil
            needsConnection = false
            return
        }

        loading = true
        defer { loading = false }
        let api = self.api
        var results: [ActivityOwnerResult] = []
        await withTaskGroup(of: ActivityOwnerResult.self) { group in
            for owner in targets {
                group.addTask {
                    do {
                        return ActivityOwnerResult(owner: owner, items: try await api.fetch(owner: owner, force: force),
                                                   message: nil, needsConnection: false)
                    } catch {
                        let failure = error as? ActivityFailure
                        return ActivityOwnerResult(
                            owner: owner,
                            items: nil,
                            message: error.localizedDescription,
                            needsConnection: failure == .missingCLI || failure == .signIn
                        )
                    }
                }
            }
            for await result in group { results.append(result) }
        }

        var failures: [String] = []
        var requiresConnection = false
        for result in results {
            if let items = result.items {
                itemsByOwner[result.owner] = items
            } else {
                failures.append(result.owner)
                requiresConnection = requiresConnection || result.needsConnection
            }
        }
        itemsByOwner = itemsByOwner.filter { targets.contains($0.key) }
        needsConnection = requiresConnection
        if failures.isEmpty {
            message = nil
        } else if failures.count == targets.count {
            message = results.compactMap(\.message).first ?? ActivityFailure.request.localizedDescription
        } else {
            message = "Couldn’t refresh activity for " + failures.sorted().joined(separator: ", ") + "."
        }
    }

    func connect() {
        guard let executable = GitHubActivity.executable else {
            NSWorkspace.shared.open(URL(string: "https://cli.github.com")!)
            return
        }
        let command = "'" + executable + "' auth login --hostname github.com --web --scopes repo,read:org"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell")
        var scriptError: NSDictionary?
        script?.executeAndReturnError(&scriptError)
        message = scriptError == nil
            ? "Finish signing in in your browser, then return here."
            : "Couldn’t start sign-in. Open Terminal and run gh auth login --web --scopes repo,read:org."
    }
}

struct ActivityRow: View {
    let item: ActivityItem
    let merging: Bool
    let squashMerge: () -> Void
    @State private var hovered = false
    @State private var mergeHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { NSWorkspace.shared.open(item.url) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 12))
                        .padding(.top, 2)
                        .foregroundStyle(Palette.muted)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title)
                            .font(.system(size: 15, weight: .medium))
                            .multilineTextAlignment(.leading)
                        Text("\(item.repository) #\(item.number)")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                        HStack(spacing: 5) {
                            Text(item.kind.label)
                            if let actor = item.actor {
                                Text("by " + actor)
                            }
                            Spacer(minLength: 4)
                            Text(item.date, style: .relative)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        if let preview = item.preview {
                            Text(preview)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.title)
            .help("Open activity on GitHub")

            if item.canSquashMerge {
                Button(action: squashMerge) {
                    HStack(spacing: 6) {
                        if merging {
                            ProgressView().controlSize(.mini)
                        }
                        Text(merging ? "Merging…" : "Squash and merge")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Palette.accent.opacity(mergeHovered ? 0.32 : 0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Palette.accent.opacity(0.75), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(merging)
                .onHover { mergeHovered = $0 }
                .help("Squash and merge pull request #\(item.number) into its base branch")
                .accessibilityLabel("Squash and merge \(item.repository) pull request \(item.number)")
            }
        }
        .padding(12)
        .background(hovered ? Color.white.opacity(0.07) : Color.clear)
        .onHover { hovered = $0 }
    }
}

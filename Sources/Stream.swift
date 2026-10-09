import Foundation
import SwiftUI
import AppKit
import Security

// MARK: - Event decoding and filtering

struct StreamEvent: Identifiable, Sendable {
    let id: String
    let sourceID: String
    let repository: String
    let type: String
    let action: String
    let actor: String
    let summary: String
    let occurredAt: Date
    let url: URL
    let rawJSON: String

    var kind: String {
        let value = type.hasSuffix("Event") ? String(type.dropLast(5)) : type
        return value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }

    func matches(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        return [repository, type, action, actor, summary, rawJSON]
            .contains { $0.localizedCaseInsensitiveContains(term) }
    }
}

enum StreamParsing {
    private struct Actor: Decodable { let login: String }
    private struct Repo: Decodable { let name: String }
    private struct Link: Decodable {
        let html_url: URL?
        let title: String?
        let name: String?
        let body: String?
        let message: String?
    }
    private struct Commit: Decodable { let message: String? }
    private struct Payload: Decodable {
        let action: String?
        let ref: String?
        let head: String?
        let issue: Link?
        let pull_request: Link?
        let comment: Link?
        let release: Link?
        let commits: [Commit]?
    }
    private struct Event: Decodable {
        let id: String
        let type: String
        let actor: Actor?
        let repo: Repo
        let created_at: String?
        let payload: Payload?
    }

    static func decode(_ data: Data, sourceID: String) throws -> [StreamEvent] {
        let events = try JSONDecoder().decode([Event].self, from: data)
        guard let original = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              original.count == events.count else { throw StreamFailure.response }

        let dateFormatter = ISO8601DateFormatter()
        var items: [StreamEvent] = []
        for index in events.indices {
            let event = events[index]
            guard let dateText = event.created_at,
                  let date = dateFormatter.date(from: dateText),
                  let repositoryURL = URL(string: "https://github.com/" + event.repo.name) else { continue }

            let payload = event.payload
            let link: URL
            if let candidate = payload?.pull_request?.html_url {
                link = candidate
            } else if let candidate = payload?.issue?.html_url {
                link = candidate
            } else if let candidate = payload?.comment?.html_url {
                link = candidate
            } else if let candidate = payload?.release?.html_url {
                link = candidate
            } else if let head = payload?.head,
                      let candidate = URL(string: repositoryURL.absoluteString + "/commit/" + head) {
                link = candidate
            } else {
                link = repositoryURL
            }

            let summary: String
            if let title = payload?.pull_request?.title {
                summary = title
            } else if let title = payload?.issue?.title {
                summary = title
            } else if let name = payload?.release?.name {
                summary = name
            } else if let message = payload?.commits?.first?.message {
                summary = message
            } else if let ref = payload?.ref {
                summary = ref
            } else if let body = payload?.comment?.body {
                summary = body
            } else {
                summary = event.type
            }

            let raw = original[index]
            let rawData = (try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            items.append(StreamEvent(
                id: sourceID + ":" + event.id, sourceID: sourceID,
                repository: event.repo.name, type: event.type,
                action: payload?.action ?? "", actor: event.actor?.login ?? "Unknown",
                summary: summary, occurredAt: date, url: link,
                rawJSON: String(decoding: rawData, as: UTF8.self)
            ))
        }
        return items
    }
}

enum StreamWatchKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case repository, organization, user
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct StreamWatch: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: StreamWatchKind
    let value: String
    let accountID: String?

    var name: String { kind.title + ": " + value }

    var endpoint: URL? {
        let loginPattern = "^[A-Za-z0-9-]{1,39}$"
        func validLogin(_ input: String) -> Bool {
            input.range(of: loginPattern, options: .regularExpression) != nil
        }
        switch kind {
        case .repository:
            let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, validLogin(parts[0]),
                  parts[1].range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil else { return nil }
            return URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/events?per_page=100")
        case .organization:
            guard validLogin(value) else { return nil }
            return URL(string: "https://api.github.com/orgs/\(value)/events?per_page=100")
        case .user:
            guard validLogin(value) else { return nil }
            return URL(string: "https://api.github.com/users/\(value)/events?per_page=100")
        }
    }
}

struct StreamAccount: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

enum StreamFailure: LocalizedError {
    case keychain, tokenMissing, unauthorized, rateLimit, response, connection

    var errorDescription: String? {
        switch self {
        case .keychain: return "Couldn’t save or read the key in macOS Keychain."
        case .tokenMissing: return "The saved API key is missing from Keychain. Remove and add it again in Settings."
        case .unauthorized: return "GitHub rejected this key or denied access to the source."
        case .rateLimit: return "GitHub rate limit reached. Try again after the reset."
        case .response: return "GitHub returned an unexpected activity response."
        case .connection: return "Unable to refresh GitHub events. Check your connection."
        }
    }
}

// MARK: - macOS Keychain-backed API keys

enum StreamCredentials {
    private static let service = "studio.repository-launcher.github-stream"

    static func save(_ token: String, id: String) throws {
        guard !token.isEmpty else { throw StreamFailure.tokenMissing }
        let lookup: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: id]
        SecItemDelete(lookup as CFDictionary)
        var attributes = lookup
        attributes[kSecValueData as String] = Data(token.utf8)
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw StreamFailure.keychain
        }
    }

    static func load(id: String) throws -> String {
        let lookup: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: id,
                                     kSecReturnData as String: true,
                                     kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw StreamFailure.tokenMissing
        }
        return value
    }

    static func remove(id: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor final class StreamPreferences: ObservableObject {
    @Published private(set) var accounts: [StreamAccount]
    @Published private(set) var watches: [StreamWatch]
    @Published var message: String?

    private static let accountsKey = "studio.repository-launcher.stream-accounts"
    private static let watchesKey = "studio.repository-launcher.stream-watches"

    init(defaults: UserDefaults = .standard) {
        accounts = (defaults.data(forKey: Self.accountsKey))
            .flatMap { try? JSONDecoder().decode([StreamAccount].self, from: $0) } ?? []
        watches = (defaults.data(forKey: Self.watchesKey))
            .flatMap { try? JSONDecoder().decode([StreamWatch].self, from: $0) } ?? []
    }

    func addAccount(name: String, token: String) -> Bool {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !secret.isEmpty else {
            message = "Enter a label and GitHub personal access token."
            return false
        }
        let account = StreamAccount(id: UUID().uuidString, name: label)
        do {
            try StreamCredentials.save(secret, id: account.id)
            accounts.append(account)
            persist()
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func removeAccount(_ id: String) {
        StreamCredentials.remove(id: id)
        accounts.removeAll { $0.id == id }
        watches = watches.map { watch in
            StreamWatch(id: watch.id, kind: watch.kind, value: watch.value,
                        accountID: watch.accountID == id ? nil : watch.accountID)
        }
        persist()
    }

    func addWatch(kind: StreamWatchKind, value: String, accountID: String?) -> Bool {
        let watch = StreamWatch(id: UUID().uuidString, kind: kind,
                                value: value.trimmingCharacters(in: .whitespacesAndNewlines),
                                accountID: accounts.contains(where: { $0.id == accountID }) ? accountID : nil)
        guard watch.endpoint != nil else {
            message = kind == .repository ? "Enter a repository as owner/name." : "Enter a valid GitHub login."
            return false
        }
        guard !watches.contains(where: {
            $0.kind == watch.kind && $0.value.caseInsensitiveCompare(watch.value) == .orderedSame
                && $0.accountID == watch.accountID
        }) else {
            message = "That source is already being watched with this key."
            return false
        }
        watches.append(watch)
        persist()
        message = nil
        return true
    }

    func removeWatch(_ id: String) {
        watches.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        // Never persist a credential: defaults contain display names and source IDs only.
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: Self.accountsKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(watches), forKey: Self.watchesKey)
    }
}

// MARK: - Polling (GitHub events are not a push/WebSocket stream)

actor StreamAPI {
    private struct Snapshot {
        let events: [StreamEvent]
        let etag: String?
        let nextFetch: Date
    }
    private var snapshots: [String: Snapshot] = [:]

    func fetch(watch: StreamWatch, force: Bool = false) async throws -> [StreamEvent] {
        guard let url = watch.endpoint else { throw StreamFailure.response }
        if !force, let cached = snapshots[watch.id], cached.nextFetch > Date() {
            return cached.events
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Mobli-GitHub-Stream", forHTTPHeaderField: "User-Agent")
        if let account = watch.accountID {
            request.setValue("Bearer " + (try StreamCredentials.load(id: account)), forHTTPHeaderField: "Authorization")
        }
        if let etag = snapshots[watch.id]?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let response: (Data, URLResponse)
        do { response = try await URLSession.shared.data(for: request) }
        catch { throw StreamFailure.connection }
        guard let http = response.1 as? HTTPURLResponse else { throw StreamFailure.response }
        let pollInterval = max(60, Int(http.value(forHTTPHeaderField: "X-Poll-Interval") ?? "") ?? 60)
        if http.statusCode == 304, let cached = snapshots[watch.id] {
            snapshots[watch.id] = Snapshot(events: cached.events, etag: cached.etag,
                                            nextFetch: Date().addingTimeInterval(TimeInterval(pollInterval)))
            return cached.events
        }
        if http.statusCode == 401 || http.statusCode == 404 { throw StreamFailure.unauthorized }
        if http.statusCode == 403 || http.statusCode == 429 {
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let reset = TimeInterval(http.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "") ?? 0
                if let cached = snapshots[watch.id] {
                    snapshots[watch.id] = Snapshot(events: cached.events, etag: cached.etag,
                        nextFetch: max(Date().addingTimeInterval(TimeInterval(pollInterval)),
                                       Date(timeIntervalSince1970: reset)))
                }
                throw StreamFailure.rateLimit
            }
            throw StreamFailure.unauthorized
        }
        guard http.statusCode == 200,
              let events = try? StreamParsing.decode(response.0, sourceID: watch.id) else {
            throw StreamFailure.response
        }
        snapshots[watch.id] = Snapshot(events: events, etag: http.value(forHTTPHeaderField: "ETag"),
                                       nextFetch: Date().addingTimeInterval(TimeInterval(pollInterval)))
        return events
    }
}

@MainActor final class StreamFeed: ObservableObject {
    @Published private(set) var events: [StreamEvent] = []
    @Published private(set) var refreshedAt: Date?
    @Published var loading = false
    @Published var message: String?
    private let api = StreamAPI()

    func refresh(watches: [StreamWatch], force: Bool = false) async {
        guard !loading else { return }
        guard !watches.isEmpty else {
            events = []; message = nil; refreshedAt = nil
            return
        }
        loading = true
        defer { loading = false }
        let api = self.api
        var successes = 0
        var batches: [[StreamEvent]] = []
        var failures: [String] = []
        await withTaskGroup(of: (String, Result<[StreamEvent], StreamFailure>).self) { group in
            for watch in watches {
                group.addTask {
                    do { return (watch.name, .success(try await api.fetch(watch: watch, force: force))) }
                    catch { return (watch.name, .failure(error as? StreamFailure ?? .connection)) }
                }
            }
            for await (name, result) in group {
                switch result {
                case .success(let events): successes += 1; batches.append(events)
                case .failure(let error): failures.append("\(name): \(error.localizedDescription)")
                }
            }
        }
        let active = Set(watches.map(\.id))
        if successes > 0 {
            var unique: [String: StreamEvent] = [:]
            for event in events where active.contains(event.sourceID) { unique[event.id] = event }
            for event in batches.flatMap({ $0 }) { unique[event.id] = event }
            events = Array(unique.values).sorted {
                $0.occurredAt == $1.occurredAt ? $0.id < $1.id : $0.occurredAt > $1.occurredAt
            }.prefix(500).map { $0 }
            refreshedAt = Date()
        }
        message = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
}

// MARK: - Stream explorer

struct StreamView: View {
    @ObservedObject var preferences: StreamPreferences
    @StateObject private var feed = StreamFeed()
    @State private var query = ""
    @State private var source = ""
    @State private var eventType = ""
    @State private var selectedID: String?

    private var filtered: [StreamEvent] {
        feed.events.filter {
            (source.isEmpty || $0.sourceID == source) &&
            (eventType.isEmpty || $0.type == eventType) &&
            $0.matches(query)
        }
    }

    private var types: [String] { Array(Set(feed.events.map(\.type))).sorted() }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("GitHub event stream").font(.system(size: 18, weight: .semibold))
                if feed.loading { ProgressView().controlSize(.small) }
                Spacer()
                if let refreshed = feed.refreshedAt {
                    Text("Checked \(refreshed, style: .relative)")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Button("Refresh") { Task { await feed.refresh(watches: preferences.watches, force: true) } }
                    .disabled(feed.loading || preferences.watches.isEmpty)
                Button("Export JSON") { export(format: "json") }.disabled(filtered.isEmpty)
                Button("Export CSV") { export(format: "csv") }.disabled(filtered.isEmpty)
            }
            HStack(spacing: 10) {
                TextField("Search events, actors, repositories, and JSON…", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Source", selection: $source) {
                    Text("All sources").tag("")
                    ForEach(preferences.watches) { watch in Text(watch.name).tag(watch.id) }
                }
                .frame(width: 230)
                Picker("Event type", selection: $eventType) {
                    Text("All event types").tag("")
                    ForEach(types, id: \.self) { type in Text(type).tag(type) }
                }
                .frame(width: 200)
                Text("\(filtered.count) events")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            if let message = feed.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if preferences.watches.isEmpty {
                ContentUnavailableView("No GitHub sources", systemImage: "dot.radiowaves.left.and.right",
                                       description: Text("Open Settings to add repositories, organizations, or users to watch. API keys are optional for public events."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 12) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered) { event in
                                Button { selectedID = event.id } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 8) {
                                            Text(event.kind).font(.system(size: 12, weight: .semibold))
                                            if !event.action.isEmpty {
                                                Text(event.action).font(.system(size: 11))
                                            }
                                            Spacer()
                                            Text(event.occurredAt, style: .relative).font(.system(size: 11))
                                        }
                                        Text(event.repository).font(.system(size: 12)).foregroundStyle(Palette.accent)
                                        Text(event.summary).font(.system(size: 13)).lineLimit(2)
                                        Text("by " + event.actor).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selectedID == event.id ? Palette.accent.opacity(0.20) : Color.clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                    .frame(minWidth: 280, maxWidth: .infinity)
                    .background(Palette.column)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    if let chosen = filtered.first(where: { $0.id == selectedID }) ?? filtered.first {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(chosen.kind + (chosen.action.isEmpty ? "" : " · " + chosen.action))
                                .font(.system(size: 16, weight: .semibold))
                            Text(chosen.repository + " · " + chosen.actor)
                                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                            Text(chosen.summary).textSelection(.enabled)
                            HStack {
                                Button("Open on GitHub") { NSWorkspace.shared.open(chosen.url) }
                                Button("Copy link") { copy(chosen.url.absoluteString) }
                                Button("Copy JSON") { copy(chosen.rawJSON) }
                            }
                            Text("Event data").font(.system(size: 13, weight: .semibold))
                            ScrollView([.horizontal, .vertical]) {
                                Text(chosen.rawJSON)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                            .padding(10)
                            .background(Palette.columnInterior)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .padding(16)
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Palette.column)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text(feed.loading ? "Loading events…" : "No events match your filters.")
                            .foregroundStyle(Palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 20)
        .task(id: preferences.watches) {
            while !Task.isCancelled {
                await feed.refresh(watches: preferences.watches)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func export(format: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "github-events." + format
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let output: String
        if format == "json" {
            output = "[\n" + filtered.map(\.rawJSON).joined(separator: ",\n") + "\n]\n"
        } else {
            func quoted(_ value: String) -> String {
                "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            let header = "date,repository,type,action,actor,summary,url"
            let rows = filtered.map { event in
                [ISO8601DateFormatter().string(from: event.occurredAt), event.repository,
                 event.type, event.action, event.actor, event.summary, event.url.absoluteString]
                    .map(quoted).joined(separator: ",")
            }
            output = ([header] + rows).joined(separator: "\n") + "\n"
        }
        do { try Data(output.utf8).write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }
}

struct StreamSettingsView: View {
    @ObservedObject var preferences: StreamPreferences
    @State private var label = ""
    @State private var token = ""
    @State private var kind: StreamWatchKind = .repository
    @State private var value = ""
    @State private var accountID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub event stream").font(.system(size: 15, weight: .semibold))
            Text("Add API keys for authenticated access. Keys are stored in macOS Keychain, never in Mobli settings or this repository.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            TextField("Key label (e.g. personal)", text: $label).textFieldStyle(.roundedBorder)
            SecureField("GitHub personal access token", text: $token).textFieldStyle(.roundedBorder)
            Button("Save API key") {
                if preferences.addAccount(name: label, token: token) {
                    label = ""; token = ""
                }
            }.disabled(label.isEmpty || token.isEmpty)
            ForEach(preferences.accounts) { account in
                HStack {
                    Image(systemName: "key.fill")
                    Text(account.name)
                    Spacer()
                    Button(role: .destructive) { preferences.removeAccount(account.id) } label: {
                        Image(systemName: "trash")
                    }.help("Delete key from Keychain")
                }
                .font(.system(size: 12))
            }
            Divider()
            Text("Watched sources").font(.system(size: 14, weight: .semibold))
            Picker("Source type", selection: $kind) {
                ForEach(StreamWatchKind.allCases) { item in Text(item.title).tag(item) }
            }
            TextField(kind == .repository ? "owner/repository" : "GitHub login", text: $value)
                .textFieldStyle(.roundedBorder)
            Picker("Authentication", selection: $accountID) {
                Text("Public (no key)").tag("")
                ForEach(preferences.accounts) { account in Text(account.name).tag(account.id) }
            }
            Button("Watch source") {
                if preferences.addWatch(kind: kind, value: value,
                                        accountID: accountID.isEmpty ? nil : accountID) { value = "" }
            }.disabled(value.isEmpty)
            ForEach(preferences.watches) { watch in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(watch.name).lineLimit(1)
                        Text(preferences.accounts.first(where: { $0.id == watch.accountID })?.name ?? "Public")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button(role: .destructive) { preferences.removeWatch(watch.id) } label: {
                        Image(systemName: "trash")
                    }.help("Remove watched source")
                }
                .font(.system(size: 12))
            }
            if let message = preferences.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.orange)
            }
            Text("Updates are polled about once per minute while Stream is open, subject to GitHub polling limits. Events API history is limited and is not a complete audit log. Organization and user event feeds are public; repository access depends on your key permissions.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        .padding(12)
        .background(Palette.column)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

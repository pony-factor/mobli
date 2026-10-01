import SwiftUI
import AppKit

struct Repository: Identifiable, Sendable {
    let url: URL
    let owner: String
    let lastActivityAt: Date?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var fullName: String { owner + "/" + name }
    var usageKey: String { fullName.lowercased() }
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
}

struct RepositoryUsage: Codable, Equatable {
    var opens: Int
    var lastOpened: Date?
}

enum RepositoryRanking {
    private static let day: TimeInterval = 24 * 60 * 60

    private static func daysSince(_ date: Date?, now: Date) -> Double {
        guard let date else { return 3650 }
        return max(0, now.timeIntervalSince(date) / day)
    }

    static func score(_ repository: Repository, usage: [String: RepositoryUsage],
                      now: Date = Date()) -> Double {
        let repositoryUsage = usage[repository.usageKey] ?? RepositoryUsage(opens: 0, lastOpened: nil)
        let freshness = exp(-daysSince(repository.lastActivityAt, now: now) / 120)
        let frequency = min(1, log2(Double(max(0, repositoryUsage.opens) + 1)) / 4)
        let recentlyOpened = repositoryUsage.lastOpened
            .map { exp(-daysSince($0, now: now) / 30) } ?? 0
        return (freshness * 0.6) + (frequency * 0.27) + (recentlyOpened * 0.13)
    }

    static func ranked(_ repositories: [Repository], usage: [String: RepositoryUsage],
                       now: Date = Date()) -> [Repository] {
        repositories.sorted { first, second in
            let scoreDifference = score(first, usage: usage, now: now)
                - score(second, usage: usage, now: now)
            if abs(scoreDifference) > 0.0001 { return scoreDifference > 0 }

            let firstActivity = first.lastActivityAt ?? .distantPast
            let secondActivity = second.lastActivityAt ?? .distantPast
            if firstActivity != secondActivity { return firstActivity > secondActivity }

            return first.fullName.localizedStandardCompare(second.fullName) == .orderedAscending
        }
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
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("studio.repository-launcher/owners", isDirectory: true)

    private struct GitHubOwner: Decodable {
        let name: String?
        let avatar_url: URL
    }

    private func cacheURL(_ owner: String) -> URL {
        // Encode the folder name so it cannot become a cache path.
        let key = Data(owner.lowercased().utf8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }

    func cached(_ owner: String) -> OwnerProfile? {
        guard let data = try? Data(contentsOf: cacheURL(owner)) else { return nil }
        return try? JSONDecoder().decode(OwnerProfile.self, from: data)
    }

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
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(profile).write(to: cacheURL(owner), options: .atomic)
            return profile
        } catch {
            // Keep the last successful profile available while offline.
            return old
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
    private let defaults: UserDefaults
    private static let key = "studio.repository-launcher.repository-usage"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: RepositoryUsage].self, from: data) {
            usage = saved
        } else {
            usage = [:]
        }
    }

    func ranked(_ repositories: [Repository]) -> [Repository] {
        RepositoryRanking.ranked(repositories, usage: usage)
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
    @Published private(set) var refreshing = false
    private let root = URL(fileURLWithPath: NSHomeDirectory() + "/GitHub")
    var owners: [String] {
        Array(Set(repos.map(\.owner))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func repositories(for owner: String) -> [Repository] {
        repos.filter { $0.owner == owner }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func refresh(forceProfiles: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let scanRoot = root
            repos = try await Task.detached { try Discovery.scan(scanRoot) }.value
        }
        catch { self.error = "Couldn’t read \(root.path): \(error.localizedDescription)" }
        profiles = profiles.filter { owners.contains($0.key) }
        // Show disk-cached names and logos before any network request finishes.
        for owner in owners {
            if let profile = await OwnerCache.shared.cached(owner) { profiles[owner] = profile }
        }
        await withTaskGroup(of: (String, OwnerProfile?).self) { group in
            for owner in owners {
                group.addTask { (owner, await OwnerCache.shared.profile(owner, force: forceProfiles)) }
            }
            for await (owner, profile) in group {
                if let profile { profiles[owner] = profile }
            }
        }
    }
    func open(_ repo: Repository) {
        let candidates = ["/Applications/Visual Studio Code.app", NSHomeDirectory() + "/Applications/Visual Studio Code.app"]
        guard let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0 + "/Contents/Resources/app/bin/code") }) else {
            error = "Install Visual Studio Code in Applications to open repositories."; return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: app + "/Contents/Resources/app/bin/code")
        task.arguments = ["--new-window", repo.url.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { process in
            if process.terminationStatus != 0 {
                Task { @MainActor in self.error = "VS Code couldn’t open \(repo.name). Try again." }
            }
        }
        do {
            try task.run()
        } catch { self.error = error.localizedDescription }
    }
}

enum Palette {
    static let background = Color(red: 0.065, green: 0.075, blue: 0.095)
    static let column = Color(red: 0.09, green: 0.105, blue: 0.13)
    static let text = Color(red: 0.87, green: 0.90, blue: 0.94)
    static let muted = Color(red: 0.48, green: 0.55, blue: 0.64)
}

struct RepositoryRow: View {
    let repo: Repository
    let open: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(repo.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
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
    }
}

struct OwnerHeader: View {
    let owner: String
    let profile: OwnerProfile?
    let subtitle: String
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
                Text(profile?.displayName ?? owner).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                if let profile, profile.displayName != owner {
                    Text(owner).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Add organization").font(.system(size: 14, weight: .semibold))
                Text("Create another organization list")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
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
                        Text(thread.subject.title).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.leading)
                        Text(thread.repository.name).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Text(thread.reason.replacingOccurrences(of: "_", with: " ")).font(.system(size: 10)).foregroundStyle(Palette.muted)
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
    @State private var addingOrganization = false
    @State private var newOrganization = ""
    @State private var addOrganizationError: String?
    @Environment(\.scenePhase) private var scenePhase
    private var availableOwners: [String] {
        notifications ? inbox.owners : library.owners + ownerOrder.manualOwners
    }
    private var owners: [String] { ownerOrder.ordered(availableOwners) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                tab("Repositories", selected: !notifications) { notifications = false }
                tab("Notifications", selected: notifications) { notifications = true }
                Spacer()
                if !notifications {
                    if library.refreshing { ProgressView().controlSize(.small) }
                    Button { Task { await library.refresh(forceProfiles: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).disabled(library.refreshing)
                        .help("Refresh repositories, owner names, and images")
                }
                if notifications {
                    if inbox.loading { ProgressView().controlSize(.small) }
                    Button { Task { await inbox.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).disabled(inbox.loading).help("Refresh inbox")
                    Button("Connect GitHub", action: inbox.connect).buttonStyle(.plain).font(.system(size: 12))
                }
            }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
            if notifications, let message = inbox.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.horizontal, 24).padding(.bottom, 8)
            }
            GeometryReader { geometry in
                let columnCount = owners.count + (notifications ? 0 : 1)
                let width = max(notifications ? 270 : 190, (geometry.size.width - 48 - CGFloat(max(0, columnCount - 1)) * 14) / CGFloat(max(1, columnCount)))
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(owners, id: \.self) { owner in
                            VStack(alignment: .leading, spacing: 0) {
                                if notifications {
                                    let threads = inbox.threads.filter { $0.owner == owner }
                                    OwnerHeader(owner: owner, profile: inbox.profiles[owner], subtitle: "\(threads.count) unread")
                                        .draggable(owner).help("Drag to reorder organizations")
                                    ScrollView(.vertical) {
                                        LazyVStack(alignment: .leading, spacing: 0) {
                                            ForEach(threads) { thread in NotificationRow(thread: thread, inbox: inbox) }
                                        }.padding(.vertical, 4)
                                    }
                                } else {
                                    let repositories = repoUsage.ranked(library.repositories(for: owner))
                                    OwnerHeader(owner: owner, profile: library.profiles[owner], subtitle: "\(repositories.count) repos")
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
                                                RepositoryRow(repo: repo) {
                                                    repoUsage.record(repo)
                                                    library.open(repo)
                                                }
                                            }
                                        }
                                        .padding(.vertical, 4)
                                        .background(ThinRepositoryScrollbars())
                                    }
                                }
                            }
                            .frame(width: width, height: max(200, geometry.size.height - 48))
                            .background(Palette.column).clipShape(RoundedRectangle(cornerRadius: 8))
                            .dropDestination(for: String.self) { items, location in
                                guard let source = items.first, source != owner else { return false }
                                ownerOrder.move(source, relativeTo: owner, after: location.x > width / 2,
                                                among: availableOwners)
                                return true
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
        .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
        .frame(minWidth: 650, minHeight: 400)
        .task { await library.refresh() }
        .task(id: notifications) {
            guard notifications else { return }
            while !Task.isCancelled {
                await inbox.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { if notifications { await inbox.refresh() } else { await library.refresh() } }
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

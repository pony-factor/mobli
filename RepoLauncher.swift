import SwiftUI
import AppKit

struct Repository: Identifiable {
    let url: URL
    let owner: String
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

enum Discovery {
    static func scan(_ root: URL) throws -> [Repository] {
        let fm = FileManager.default
        func directories(_ url: URL) throws -> [URL] {
            try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        var repos: [Repository] = []
        for owner in try directories(root) {
            if fm.fileExists(atPath: owner.appendingPathComponent(".git").path) {
                repos.append(Repository(url: owner, owner: "Local"))
            } else {
                for repo in try directories(owner) where fm.fileExists(atPath: repo.appendingPathComponent(".git").path) {
                    repos.append(Repository(url: repo, owner: owner.lastPathComponent))
                }
            }
        }
        return repos
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

    func profile(_ owner: String) async -> OwnerProfile? {
        let old = cached(owner)
        if let old, old.isFresh { return old }
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

@MainActor final class Library: ObservableObject {
    @Published var repos: [Repository] = []
    @Published var profiles: [String: OwnerProfile] = [:]
    @Published var error: String?
    private var refreshing = false
    private let root = URL(fileURLWithPath: NSHomeDirectory() + "/GitHub")
    var owners: [String] {
        Array(Set(repos.map(\.owner))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func repositories(for owner: String) -> [Repository] {
        repos.filter { $0.owner == owner }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do { repos = try Discovery.scan(root) }
        catch { self.error = "Couldn’t read \(root.path): \(error.localizedDescription)" }
        // Show disk-cached names and logos before any network request finishes.
        for owner in owners {
            if let profile = await OwnerCache.shared.cached(owner) { profiles[owner] = profile }
        }
        await withTaskGroup(of: (String, OwnerProfile?).self) { group in
            for owner in owners {
                group.addTask { (owner, await OwnerCache.shared.profile(owner)) }
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

private enum Palette {
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
        .onHover { hovered = $0 }
        .help("Open \(repo.name) in a new VS Code window")
    }
}

struct LauncherView: View {
    @StateObject private var library = Library()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        GeometryReader { geometry in
            let width = max(190, (geometry.size.width - 48 - CGFloat(max(0, library.owners.count - 1)) * 14) / CGFloat(max(1, library.owners.count)))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(library.owners, id: \.self) { owner in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 10) {
                                if let data = library.profiles[owner]?.avatar, let image = NSImage(data: data) {
                                    Image(nsImage: image).resizable().scaledToFit()
                                        .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    Text(String(owner.prefix(1)).uppercased()).font(.system(size: 17, weight: .bold))
                                        .frame(width: 34, height: 34).background(Color.white.opacity(0.06))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(library.profiles[owner]?.displayName ?? owner)
                                        .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                    Text("\(library.repositories(for: owner).count) repos")
                                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                            ScrollView(.vertical) {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(library.repositories(for: owner)) { repo in
                                        RepositoryRow(repo: repo) { library.open(repo) }
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                        .frame(width: width, height: max(200, geometry.size.height - 48))
                        .background(Palette.column)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(24)
            }
            .overlay {
                if library.repos.isEmpty {
                    Text("No repositories found in ~/GitHub").foregroundStyle(Palette.muted)
                }
            }
        }
        .background(Palette.background).foregroundStyle(Palette.text)
        .preferredColorScheme(.dark)
        .frame(minWidth: 650, minHeight: 400)
        .task { await library.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await library.refresh() } }
        }
        .alert("Repository Launcher", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
}

@main struct RepoLauncherApp: App {
    var body: some Scene {
        WindowGroup("Repository Launcher") { LauncherView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1500, height: 760)
    }
}

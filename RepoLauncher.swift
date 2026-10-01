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

@MainActor final class Library: ObservableObject {
    @Published var repos: [Repository] = []
    @Published var query = ""
    @Published var selectedOwner = "All repositories"
    @Published var error: String?
    @Published var pins: Set<String>
    @Published var recent: [String: Double]
    @Published var root: URL
    private let defaults = UserDefaults.standard
    init() {
        root = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "root") ?? NSHomeDirectory() + "/GitHub")
        pins = Set(UserDefaults.standard.stringArray(forKey: "pins") ?? [])
        recent = UserDefaults.standard.dictionary(forKey: "recent") as? [String: Double] ?? [:]
        refresh()
    }
    var owners: [String] { Array(Set(repos.map(\.owner))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var visible: [Repository] {
        repos.filter {
            (selectedOwner == "All repositories" || (selectedOwner == "Favorites" ? pins.contains($0.id) : $0.owner == selectedOwner)) &&
            (query.isEmpty || ($0.owner + "/" + $0.name).localizedCaseInsensitiveContains(query))
        }.sorted {
            if pins.contains($0.id) != pins.contains($1.id) { return pins.contains($0.id) }
            if recent[$0.id, default: 0] != recent[$1.id, default: 0] { return recent[$0.id, default: 0] > recent[$1.id, default: 0] }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func refresh() {
        do { repos = try Discovery.scan(root) } catch { self.error = "Couldn’t read \(root.path): \(error.localizedDescription)" }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url {
            root = url; defaults.set(url.path, forKey: "root"); selectedOwner = "All repositories"; refresh()
        }
    }
    func togglePin(_ repo: Repository) {
        if pins.contains(repo.id) { pins.remove(repo.id) } else { pins.insert(repo.id) }
        defaults.set(Array(pins), forKey: "pins")
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
            recent[repo.id] = Date().timeIntervalSince1970
            defaults.set(recent, forKey: "recent")
        } catch { self.error = error.localizedDescription }
    }
}

struct LauncherView: View {
    @StateObject private var library = Library()
    var body: some View {
        NavigationSplitView {
            List(selection: $library.selectedOwner) {
                Label("All repositories", systemImage: "square.grid.2x2").tag("All repositories")
                Label("Favorites", systemImage: "star").tag("Favorites")
                Section("Owners") {
                    ForEach(library.owners, id: \.self) { owner in
                        HStack { Label(owner, systemImage: "person.2"); Spacer(); Text("\(library.repos.filter { $0.owner == owner }.count)").foregroundStyle(.secondary) }.tag(owner)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                Button(action: library.chooseFolder) { Label("Choose GitHub folder…", systemImage: "folder") }.buttonStyle(.plain).padding()
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(library.selectedOwner).font(.largeTitle.bold())
                        Text("\(library.visible.count) repositories · Open a project in a new VS Code window").foregroundStyle(.secondary)
                    }
                    if library.visible.isEmpty {
                        ContentUnavailableView("No repositories found", systemImage: "folder", description: Text("Try another search or choose your GitHub folder."))
                    }
                    ForEach(library.owners, id: \.self) { owner in
                        let repos = library.visible.filter { $0.owner == owner }
                        if !repos.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { Image(systemName: "person.2.fill").foregroundStyle(.tint); Text(owner).font(.title2.weight(.semibold)); Text("\(repos.count)").foregroundStyle(.secondary) }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 14)], spacing: 14) {
                                    ForEach(repos) { repo in
                                        HStack(spacing: 12) {
                                            Button { library.open(repo) } label: {
                                                HStack(spacing: 12) {
                                                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.title2).foregroundStyle(.tint)
                                                    VStack(alignment: .leading, spacing: 5) {
                                                        Text(repo.name).font(.headline).lineLimit(2)
                                                        Text(repo.owner).font(.caption).foregroundStyle(.secondary)
                                                    }
                                                    Spacer(minLength: 0)
                                                }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                                            }.buttonStyle(.plain).help("Open \(repo.url.path) in a new VS Code window")
                                            Button { library.togglePin(repo) } label: {
                                                Image(systemName: library.pins.contains(repo.id) ? "star.fill" : "star").foregroundStyle(library.pins.contains(repo.id) ? Color.orange : Color.secondary)
                                            }.buttonStyle(.borderless).help("Toggle favorite")
                                        }
                                        .padding(16)
                                        .background(.background, in: RoundedRectangle(cornerRadius: 14))
                                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08)))
                                        .contextMenu {
                                            Button("Open in VS Code") { library.open(repo) }
                                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([repo.url]) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .windowBackgroundColor))
            .searchable(text: $library.query, prompt: "Find a repository")
            .toolbar { Button(action: library.refresh) { Label("Refresh", systemImage: "arrow.clockwise") }.keyboardShortcut("r") }
        }
        .frame(minWidth: 820, minHeight: 550)
        .alert("Repository Launcher", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
}

@main struct RepoLauncherApp: App {
    var body: some Scene {
        WindowGroup("Repository Launcher") { LauncherView() }
            .defaultSize(width: 1120, height: 760)
    }
}

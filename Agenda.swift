import SwiftUI
import AppKit

struct AgendaProject: Decodable, Identifiable, Sendable {
    let id: String
    let number: Int
    let title: String
    let url: URL
}

struct AgendaItem: Decodable, Identifiable, Sendable {
    struct Content: Decodable, Sendable {
        struct Repository: Decodable, Sendable { let nameWithOwner: String }
        let title: String
        let url: URL?
        let repository: Repository?
    }
    struct Status: Decodable, Sendable { let name: String? }
    let id: String
    let isArchived: Bool
    let content: Content?
    let fieldValueByName: Status?
    var status: String { fieldValueByName?.name ?? "No status" }
}

struct AgendaPage: Decodable {
    struct Project: Decodable {
        struct Fields: Decodable {
            struct Field: Decodable {
                struct Option: Decodable { let name: String }
                let name: String?
                let options: [Option]?
            }
            let nodes: [Field]
        }
        struct Items: Decodable {
            struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
            let nodes: [AgendaItem]
            let pageInfo: PageInfo
        }
        let fields: Fields
        let items: Items
    }
    struct Payload: Decodable { let node: Project? }
    let data: Payload
}

enum AgendaFailure: LocalizedError {
    case connection, request
    var errorDescription: String? {
        switch self {
        case .connection: return "Connect GitHub Projects to give the launcher read access to your agenda."
        case .request: return "Couldn’t load this project. Check its owner, access, and your connection, then refresh."
        }
    }
}

actor GitHubAgenda {
    private func run(_ arguments: [String]) async throws -> Data {
        guard let executable = GitHubInbox.executable else { throw AgendaFailure.connection }
        let result = try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            return (data, process.terminationStatus)
        }.value
        guard result.1 == 0 else { throw AgendaFailure.connection }
        return result.0
    }

    func projects(owner: String) async throws -> [AgendaProject] {
        struct List: Decodable { let projects: [AgendaProject] }
        let data = try await run(["project", "list", "--owner", owner, "--limit", "1000", "--format", "json"])
        return try JSONDecoder().decode(List.self, from: data).projects
    }

    func items(project: AgendaProject) async throws -> ([AgendaItem], [String]) {
        let query = """
        query($id: ID!, $cursor: String) {
          node(id: $id) { ... on ProjectV2 {
            fields(first: 100) { nodes { ... on ProjectV2SingleSelectField { name options { name } } } }
            items(first: 100, after: $cursor) {
              nodes {
                id isArchived
                fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
                content {
                  ... on DraftIssue { title }
                  ... on Issue { title url repository { nameWithOwner } }
                  ... on PullRequest { title url repository { nameWithOwner } }
                }
              }
              pageInfo { hasNextPage endCursor }
            }
          } }
        }
        """
        var items: [AgendaItem] = []
        var statuses: [String] = []
        var cursor: String?
        repeat {
            var arguments = ["api", "graphql", "-f", "query=" + query, "-f", "id=" + project.id]
            if let cursor { arguments += ["-f", "cursor=" + cursor] }
            let page = try JSONDecoder().decode(AgendaPage.self, from: await run(arguments))
            guard let node = page.data.node else { throw AgendaFailure.request }
            statuses = node.fields.nodes.first(where: { $0.name == "Status" })?.options?.map(\.name) ?? []
            items += node.items.nodes.filter { !$0.isArchived && $0.content != nil }
            guard node.items.pageInfo.hasNextPage else { break }
            guard let next = node.items.pageInfo.endCursor, next != cursor else { throw AgendaFailure.request }
            cursor = next
        } while true
        for item in items where !statuses.contains(item.status) { statuses.append(item.status) }
        return (items, statuses)
    }
}

@MainActor final class Agenda: ObservableObject {
    @Published var projects: [AgendaProject] = []
    @Published var items: [AgendaItem] = []
    @Published var statuses: [String] = []
    @Published var loading = false
    @Published var message: String?
    @Published var needsConnection = false
    private let api = GitHubAgenda()
    private var revision = 0

    func refresh(owner: String, selectedID: String) async -> String? {
        revision += 1
        let requestRevision = revision
        loading = true
        defer { if requestRevision == revision { loading = false } }
        items = []; statuses = []; projects = []; message = nil
        do {
            let projects = try await api.projects(owner: owner)
            guard requestRevision == revision else { return nil }
            self.projects = projects
            needsConnection = false
            guard let selected = projects.first(where: { $0.id == selectedID })
                ?? projects.first(where: { $0.title.localizedCaseInsensitiveContains("agenda") })
                ?? projects.first else { return nil }
            let (items, statuses) = try await api.items(project: selected)
            guard requestRevision == revision else { return nil }
            self.items = items; self.statuses = statuses
            return selected.id
        } catch {
            guard requestRevision == revision else { return nil }
            message = error.localizedDescription
            needsConnection = (error as? AgendaFailure).map { if case .connection = $0 { return true }; return false } ?? false
            return nil
        }
    }

    func connect() {
        guard let executable = GitHubInbox.executable else {
            NSWorkspace.shared.open(URL(string: "https://cli.github.com")!); return
        }
        let command = "'" + executable + "' auth refresh --hostname github.com --scopes read:project"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        message = error == nil ? "Finish authorizing in your browser, then refresh Agenda." : "Open Terminal and run gh auth refresh --scopes read:project."
    }
}

struct AgendaView: View {
    @StateObject private var agenda = Agenda()
    @AppStorage("studio.repository-launcher.agenda-owner") private var owner = "@me"
    @AppStorage("studio.repository-launcher.agenda-project") private var selectedID = ""
    @State private var ownerInput = ""
    @State private var refreshID = 0
    @Environment(\.scenePhase) private var scenePhase
    private var selected: AgendaProject? { agenda.projects.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text("Agenda").font(.system(size: 22, weight: .semibold))
                if !agenda.projects.isEmpty {
                    Picker("Project", selection: $selectedID) {
                        ForEach(agenda.projects) { project in Text(project.title).tag(project.id) }
                    }.labelsHidden().frame(maxWidth: 260)
                }
                Spacer()
                if agenda.loading { ProgressView().controlSize(.small) }
                if let selected {
                    Button("Open on GitHub") { NSWorkspace.shared.open(selected.url) }.buttonStyle(.plain)
                }
                Button("Refresh") { refreshID += 1 }.buttonStyle(.plain)
            }
            HStack {
                TextField("Project owner", text: $ownerInput)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit { applyOwner() }
                Button("Load", action: applyOwner).buttonStyle(.plain)
                Text("Your account (@me), or an organization login").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            if let message = agenda.message {
                HStack {
                    Text(message).font(.system(size: 13)).foregroundStyle(Palette.muted)
                    if agenda.needsConnection { Button("Connect GitHub Projects", action: agenda.connect).buttonStyle(.plain) }
                }
            }
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(agenda.statuses, id: \.self) { status in
                            let items = agenda.items.filter { $0.status == status }
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text(status).font(.system(size: 16, weight: .semibold))
                                    Spacer()
                                    Text("\(items.count)").foregroundStyle(Palette.muted)
                                }.padding(16)
                                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                                ScrollView(.vertical) {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(items) { item in
                                            Button {
                                                if let url = item.content?.url ?? selected?.url { NSWorkspace.shared.open(url) }
                                            } label: {
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text(item.content?.title ?? "Untitled").font(.system(size: 15, weight: .medium))
                                                        .multilineTextAlignment(.leading)
                                                    if let repository = item.content?.repository {
                                                        Text(repository.nameWithOwner).font(.system(size: 12)).foregroundStyle(Palette.muted)
                                                    }
                                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                                .contentShape(Rectangle())
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }
                            }.frame(width: 320, height: max(200, geometry.size.height))
                                .background(Palette.column).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.overlay {
                    if agenda.items.isEmpty && !agenda.loading && agenda.message == nil {
                        Text(agenda.projects.isEmpty ? "No open projects found for this owner." : "This project has no active items.")
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
        }.padding(24)
            .onAppear { ownerInput = owner }
            .task(id: "\(owner)|\(selectedID)|\(refreshID)") {
                if let id = await agenda.refresh(owner: owner, selectedID: selectedID), id != selectedID { selectedID = id }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refreshID += 1 } }
    }

    private func applyOwner() {
        let value = ownerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == "@me" || value.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { return }
        if owner != value { selectedID = ""; owner = value }
        else { refreshID += 1 }
    }
}

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

    func assigningStatus(_ name: String?) -> AgendaItem {
        AgendaItem(id: id, isArchived: isArchived, content: content,
                   fieldValueByName: name.map { Status(name: $0) })
    }
}

struct AgendaPage: Decodable {
    struct Project: Decodable {
        struct Fields: Decodable {
            struct Field: Decodable, Sendable {
                struct Option: Decodable, Sendable { let id: String?; let name: String }
                let id: String?
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

enum AgendaEdits {
    static func statusArguments(projectID: String, itemID: String, fieldID: String, optionID: String?) -> [String] {
        let arguments = ["project", "item-edit", "--project-id", projectID, "--id", itemID, "--field-id", fieldID]
        return arguments + (optionID.map { ["--single-select-option-id", $0] } ?? ["--clear"])
    }

    static func commentKind(for url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard url.scheme == "https", url.host == "github.com", parts.count == 4,
              let number = Int(parts[3]), number > 0 else { return nil }
        switch parts[2] {
        case "issues": return "issue"
        case "pull": return "pr"
        default: return nil
        }
    }
}

enum AgendaFailure: LocalizedError {
    case connection, request, write, comment
    var errorDescription: String? {
        switch self {
        case .connection: return "Connect GitHub Projects to give the launcher read access to your agenda."
        case .request: return "Couldn’t load this project. Check its owner, access, and your connection, then refresh."
        case .write: return "Couldn’t move this item. Enable project editing and check that you have write access to this project."
        case .comment: return "Couldn’t confirm your comment was posted. Check the discussion on GitHub before trying again."
        }
    }
}

actor GitHubAgenda {
    private let executable: String?

    init(executable: String? = GitHubInbox.executable) { self.executable = executable }

    private func run(_ arguments: [String], failure: AgendaFailure = .connection) async throws -> Data {
        guard let executable else { throw AgendaFailure.connection }
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
        guard result.1 == 0 else { throw failure }
        return result.0
    }

    func projects(owner: String) async throws -> [AgendaProject] {
        struct List: Decodable { let projects: [AgendaProject] }
        let data = try await run(["project", "list", "--owner", owner, "--limit", "1000", "--format", "json"])
        return try JSONDecoder().decode(List.self, from: data).projects
    }

    func items(project: AgendaProject) async throws -> ([AgendaItem], [String], AgendaPage.Project.Fields.Field?) {
        let query = """
        query($id: ID!, $cursor: String) {
          node(id: $id) { ... on ProjectV2 {
            fields(first: 100) { nodes { ... on ProjectV2SingleSelectField { id name options { id name } } } }
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
        var statusField: AgendaPage.Project.Fields.Field?
        var cursor: String?
        repeat {
            var arguments = ["api", "graphql", "-f", "query=" + query, "-f", "id=" + project.id]
            if let cursor { arguments += ["-f", "cursor=" + cursor] }
            let page = try JSONDecoder().decode(AgendaPage.self, from: await run(arguments))
            guard let node = page.data.node else { throw AgendaFailure.request }
            statusField = node.fields.nodes.first(where: { $0.name == "Status" })
            statuses = statusField?.options?.map(\.name) ?? []
            items += node.items.nodes.filter { !$0.isArchived && $0.content != nil }
            guard node.items.pageInfo.hasNextPage else { break }
            guard let next = node.items.pageInfo.endCursor, next != cursor else { throw AgendaFailure.request }
            cursor = next
        } while true
        for item in items where !statuses.contains(item.status) { statuses.append(item.status) }
        if !statuses.contains("No status") { statuses.append("No status") }
        return (items, statuses, statusField)
    }

    func setStatus(projectID: String, itemID: String, fieldID: String, optionID: String?) async throws {
        _ = try await run(AgendaEdits.statusArguments(projectID: projectID, itemID: itemID,
                                                     fieldID: fieldID, optionID: optionID), failure: .write)
    }

    func comment(item: AgendaItem, body: String) async throws {
        guard let url = item.content?.url, let kind = AgendaEdits.commentKind(for: url),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgendaFailure.comment }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mobli-comment-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(body.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        _ = try await run([kind, "comment", url.absoluteString, "--body-file", file.path], failure: .comment)
    }
}

@MainActor final class Agenda: ObservableObject {
    @Published var projects: [AgendaProject] = []
    @Published var items: [AgendaItem] = []
    @Published var statuses: [String] = []
    @Published var loading = false
    @Published var message: String?
    @Published var needsConnection = false
    @Published var saving = false
    @Published var editMessage: String?
    @Published var statusField: AgendaPage.Project.Fields.Field?
    private let api = GitHubAgenda()
    private var revision = 0

    func refresh(owner: String, selectedID: String) async -> String? {
        revision += 1
        let requestRevision = revision
        loading = true
        defer { if requestRevision == revision { loading = false } }
        items = []; statuses = []; projects = []; statusField = nil; message = nil; editMessage = nil
        do {
            let projects = try await api.projects(owner: owner)
            guard requestRevision == revision else { return nil }
            self.projects = projects
            needsConnection = false
            guard let selected = projects.first(where: { $0.id == selectedID })
                ?? projects.first(where: { $0.title.localizedCaseInsensitiveContains("agenda") })
                ?? projects.first else { return nil }
            let (items, statuses, statusField) = try await api.items(project: selected)
            guard requestRevision == revision else { return nil }
            self.items = items; self.statuses = statuses; self.statusField = statusField
            return selected.id
        } catch {
            guard requestRevision == revision else { return nil }
            message = error.localizedDescription
            needsConnection = (error as? AgendaFailure).map { if case .connection = $0 { return true }; return false } ?? false
            return nil
        }
    }

    func move(_ item: AgendaItem, to option: AgendaPage.Project.Fields.Field.Option?, project: AgendaProject) async {
        guard !saving, !loading, let fieldID = statusField?.id, option == nil || option?.id != nil else { return }
        saving = true
        editMessage = nil
        let currentRevision = revision
        defer { saving = false }
        do {
            try await api.setStatus(projectID: project.id, itemID: item.id, fieldID: fieldID, optionID: option?.id)
            guard revision == currentRevision else { return }
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = items[index].assigningStatus(option?.name)
            }
        } catch {
            guard revision == currentRevision else { return }
            editMessage = error.localizedDescription
        }
    }

    func postComment(item: AgendaItem, body: String) async throws {
        guard !saving else { throw AgendaFailure.comment }
        saving = true
        defer { saving = false }
        try await api.comment(item: item, body: body)
    }

    func connect(editing: Bool = false) {
        guard let executable = GitHubInbox.executable else {
            NSWorkspace.shared.open(URL(string: "https://cli.github.com")!); return
        }
        // Opening a command document does not require Apple Events permission.
        // The document contains only the CLI invocation and deletes itself on launch.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobli-project-access-\(UUID().uuidString).command")
        let scope = editing ? "project" : "read:project"
        let command = """
        #!/bin/zsh
        rm -f -- "$0"
        '\(executable)' auth refresh --hostname github.com --scopes \(scope)
        """
        do {
            try Data((command + "\n").utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration) { _, error in
                Task { @MainActor in
                    if error != nil {
                        try? FileManager.default.removeItem(at: file)
                        self.message = "Couldn’t open Terminal. Run gh auth refresh --scopes \(scope) there."
                    } else {
                        self.message = "Follow the instructions in Terminal to authorize GitHub, then return to Agenda."
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            message = "Couldn’t start authorization. Run gh auth refresh --scopes \(scope) in Terminal."
        }
    }
}

struct AgendaView: View {
    @StateObject private var agenda = Agenda()
    @AppStorage("studio.repository-launcher.agenda-owner") private var owner = "@me"
    @AppStorage("studio.repository-launcher.agenda-project") private var selectedID = ""
    @State private var ownerInput = ""
    @State private var refreshID = 0
    @State private var commentingOn: AgendaItem?
    @State private var dropStatus: String?
    @Environment(\.scenePhase) private var scenePhase
    private var selected: AgendaProject? { agenda.projects.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text("Agenda").font(.system(size: 22, weight: .semibold))
                if !agenda.projects.isEmpty {
                    Picker("Project", selection: $selectedID) {
                        ForEach(agenda.projects) { project in Text(project.title).tag(project.id) }
                    }.labelsHidden().frame(maxWidth: 260).disabled(agenda.saving)
                }
                Spacer()
                if agenda.loading { ProgressView().controlSize(.small) }
                if let selected {
                    Button("Open on GitHub") { NSWorkspace.shared.open(selected.url) }.buttonStyle(.plain)
                }
                Button("Enable editing") { agenda.connect(editing: true) }.buttonStyle(.plain).disabled(agenda.saving)
                Button("Refresh") { refreshID += 1 }.buttonStyle(.plain).disabled(agenda.saving)
            }
            HStack {
                TextField("Project owner", text: $ownerInput)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit { applyOwner() }.disabled(agenda.saving)
                Button("Load", action: applyOwner).buttonStyle(.plain).disabled(agenda.saving)
                Text("Your account (@me), or an organization login").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            if let message = agenda.message {
                HStack {
                    Text(message).font(.system(size: 13)).foregroundStyle(Palette.muted)
                    if agenda.needsConnection { Button("Connect GitHub Projects") { agenda.connect() }.buttonStyle(.plain) }
                }
            }
            if let editMessage = agenda.editMessage {
                Text(editMessage).font(.system(size: 13)).foregroundStyle(Palette.muted)
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
                                            agendaRow(item)
                                        }
                                    }
                                }
                            }.frame(width: 320, height: max(200, geometry.size.height))
                                .background(Palette.column).clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8).stroke(dropStatus == status ? Palette.accent : .clear, lineWidth: 2)
                                }
                                .dropDestination(for: String.self) { identifiers, _ in
                                    guard !agenda.loading, !agenda.saving,
                                          let selected, let identifier = identifiers.first,
                                          let item = agenda.items.first(where: { $0.id == identifier }),
                                          item.status != status else { return false }
                                    let option = agenda.statusField?.options?.first(where: { $0.name == status })
                                    guard agenda.statusField?.id != nil, status == "No status" || option?.id != nil else { return false }
                                    Task { await agenda.move(item, to: option, project: selected) }
                                    return true
                                } isTargeted: { targeted in
                                    if targeted { dropStatus = status }
                                    else if dropStatus == status { dropStatus = nil }
                                }
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
            .onChange(of: scenePhase) { _, phase in if phase == .active && !agenda.saving { refreshID += 1 } }
            .sheet(item: $commentingOn) { item in
                AgendaCommentComposer(item: item, agenda: agenda)
            }
    }

    private func agendaRow(_ item: AgendaItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let url = item.content?.url ?? selected?.url { NSWorkspace.shared.open(url) }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.content?.title ?? "Untitled").font(.system(size: 15, weight: .medium))
                        .multilineTextAlignment(.leading)
                    if let repository = item.content?.repository {
                        Text(repository.nameWithOwner).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack {
                Menu("Move to") {
                    ForEach(agenda.statusField?.options ?? [], id: \.name) { option in
                        Button(option.name) {
                            if let selected { Task { await agenda.move(item, to: option, project: selected) } }
                        }.disabled(option.name == item.status || option.id == nil)
                    }
                    Button("No status") {
                        if let selected { Task { await agenda.move(item, to: nil, project: selected) } }
                    }.disabled(item.fieldValueByName?.name == nil)
                }.menuStyle(.borderlessButton)
                    .disabled(agenda.loading || agenda.saving || agenda.statusField?.id == nil)
                Spacer()
                if let url = item.content?.url, AgendaEdits.commentKind(for: url) != nil {
                    Button("Comment") { commentingOn = item }.buttonStyle(.plain).disabled(agenda.saving)
                }
            }.font(.system(size: 12)).foregroundStyle(Palette.muted)
        }.padding(12)
            .draggable(item.id)
    }

    private func applyOwner() {
        guard !agenda.saving else { return }
        let value = ownerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == "@me" || value.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { return }
        if owner != value { selectedID = ""; owner = value }
        else { refreshID += 1 }
    }
}


struct AgendaCommentComposer: View {
    let item: AgendaItem
    @ObservedObject var agenda: Agenda
    @Environment(\.dismiss) private var dismiss
    @State private var bodyText = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a comment").font(.system(size: 20, weight: .semibold))
            Text(item.content?.title ?? "Issue").font(.system(size: 14, weight: .medium))
            if let url = item.content?.url {
                Link("View discussion on GitHub", destination: url).font(.system(size: 12))
            }
            TextEditor(text: $bodyText).font(.system(size: 14)).frame(minHeight: 180)
                .padding(6).background(Palette.column).clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(agenda.saving)
            if let errorMessage { Text(errorMessage).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(agenda.saving)
                Button(agenda.saving ? "Posting…" : "Post comment") {
                    Task {
                        errorMessage = nil
                        do {
                            try await agenda.postComment(item: item, body: bodyText)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(agenda.saving || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 520)
            .interactiveDismissDisabled(agenda.saving)
    }
}

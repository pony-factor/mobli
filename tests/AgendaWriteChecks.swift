import Foundation

@main struct AgendaWriteChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mobli-agenda-api-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("gh")
        let argumentsFile = directory.appendingPathComponent("arguments")
        let bodyFile = directory.appendingPathComponent("body")
        let script = """
        #!/bin/zsh
        printf '%s\\n' "$@" > '\(argumentsFile.path)'
        if [[ "$2" == "comment" ]]; then
          cp -- "$5" '\(bodyFile.path)'
        fi
        print '{}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let api = GitHubAgenda(executable: executable.path)
        func arguments() throws -> [String] {
            try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        try await api.setStatus(projectID: "project", itemID: "item", fieldID: "status", optionID: "done")
        let statusArguments = try arguments()
        precondition(statusArguments == ["project", "item-edit", "--project-id", "project", "--id", "item", "--field-id", "status", "--single-select-option-id", "done"])
        try await api.setStatus(projectID: "project", itemID: "item", fieldID: "status", optionID: nil)
        let clearArguments = try arguments()
        precondition(clearArguments.last == "--clear")
        let body = "A comment with quotes, `code`, and $literal text.\n\nSecond paragraph."
        for (kind, path) in [("issue", "issues/1"), ("pr", "pull/2")] {
            let url = URL(string: "https://github.com/example/repo/" + path)!
            let item = AgendaItem(id: "item", isArchived: false,
                                  content: AgendaItem.Content(title: "Task", url: url, repository: nil), fieldValueByName: nil)
            try await api.comment(item: item, body: body)
            let captured = try arguments()
            precondition(Array(captured.prefix(4)) == [kind, "comment", url.absoluteString, "--body-file"])
            let capturedBody = try String(contentsOf: bodyFile, encoding: .utf8)
            precondition(capturedBody == body)
            precondition(!FileManager.default.fileExists(atPath: captured[4]))
        }
        try Data("#!/bin/zsh\nexit 1\n".utf8).write(to: executable)
        do {
            try await api.setStatus(projectID: "project", itemID: "item", fieldID: "status", optionID: "done")
            preconditionFailure("A rejected edit must throw")
        } catch AgendaFailure.write { }
        print("PASS: status writes, clearing status, issue and PR comments, multiline bodies, temporary-file cleanup, and rejected writes")
    }
}

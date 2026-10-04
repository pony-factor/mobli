import Foundation

@main struct AgendaChecks {
    static func main() throws {
        let fixture = """
        {"data":{"node":{"fields":{"nodes":[{}, {"id":"status-field","name":"Status","options":[{"id":"todo","name":"Todo"},{"id":"progress","name":"In progress"}]}]},"items":{"nodes":[
          {"id":"issue","isArchived":false,"fieldValueByName":{"name":"Todo"},"content":{"title":"Plan work","url":"https://github.com/example/repo/issues/1","repository":{"nameWithOwner":"example/repo"}}},
          {"id":"draft","isArchived":false,"fieldValueByName":null,"content":{"title":"Draft task"}},
          {"id":"deleted","isArchived":false,"fieldValueByName":{},"content":null},
          {"id":"archived","isArchived":true,"fieldValueByName":{"name":"Todo"},"content":{"title":"Old work"}}
        ],"pageInfo":{"hasNextPage":true,"endCursor":"next-page"}}}}}
        """
        let page = try JSONDecoder().decode(AgendaPage.self, from: Data(fixture.utf8))
        let project = try unwrap(page.data.node)
        precondition(project.items.pageInfo.hasNextPage && project.items.pageInfo.endCursor == "next-page")
        let items = project.items.nodes.filter { !$0.isArchived && $0.content != nil }
        precondition(items.count == 2)
        precondition(items[0].status == "Todo" && items[0].content?.repository?.nameWithOwner == "example/repo")
        precondition(items[1].status == "No status" && items[1].content?.url == nil)
        precondition(project.fields.nodes.first(where: { $0.name == "Status" })?.options?.map(\.name) == ["Todo", "In progress"])
        let statusField = try unwrap(project.fields.nodes.first(where: { $0.name == "Status" }))
        precondition(statusField.id == "status-field" && statusField.options?.last?.id == "progress")
        precondition(items[0].assigningStatus("In progress").status == "In progress")
        precondition(items[0].assigningStatus(nil).status == "No status")
        precondition(items[0].assigningStatus(nil).content?.url == items[0].content?.url)
        precondition(AgendaEdits.commentKind(for: URL(string: "https://github.com/example/repo/issues/1")!) == "issue")
        precondition(AgendaEdits.commentKind(for: URL(string: "https://github.com/example/repo/pull/2")!) == "pr")
        for invalid in ["https://example.com/example/repo/issues/1", "https://github.com/example/repo/projects/1", "https://github.com/example/repo/issues/0"] {
            precondition(AgendaEdits.commentKind(for: URL(string: invalid)!) == nil)
        }
        let missing = try JSONDecoder().decode(AgendaPage.self, from: Data("{\"data\":{\"node\":null}}".utf8))
        precondition(missing.data.node == nil)
        print("PASS: agenda issues, draft items, missing content, archived items, status order, pagination, inaccessible project")
    }

    static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "AgendaChecks", code: 1) }
        return value
    }
}

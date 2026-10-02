import Foundation

@main struct ActivityChecks {
    static func main() throws {
        let fixture = """
        {
          "data": {
            "search": {
              "nodes": [{
                "id": "PR_1",
                "number": 42,
                "title": "Ship activity",
                "url": "https://github.com/example/project/pull/42",
                "createdAt": "2026-10-01T10:00:00Z",
                "updatedAt": "2026-10-02T12:00:00Z",
                "state": "MERGED",
                "mergedAt": "2026-10-02T12:00:00Z",
                "closedAt": "2026-10-02T12:00:00Z",
                "author": {"login": "alice"},
                "mergedBy": {"login": "bob"},
                "repository": {"name": "project", "owner": {"login": "example"}},
                "comments": {"nodes": [{
                  "id": "IC_1",
                  "bodyText": "Top level comment",
                  "createdAt": "2026-10-02T10:00:00Z",
                  "updatedAt": "2026-10-02T10:00:00Z",
                  "url": "https://github.com/example/project/pull/42#issuecomment-1",
                  "author": {"login": "carol"}
                }]},
                "reviews": {"nodes": [{
                  "id": "R_1",
                  "bodyText": "",
                  "state": "APPROVED",
                  "createdAt": "2026-10-02T10:30:00Z",
                  "updatedAt": "2026-10-02T10:30:00Z",
                  "submittedAt": "2026-10-02T10:30:00Z",
                  "url": "https://github.com/example/project/pull/42#pullrequestreview-1",
                  "author": {"login": "dave"}
                }]},
                "reviewThreads": {"nodes": [{
                  "comments": {"nodes": [{
                    "id": "RC_1",
                    "bodyText": "Inline comment",
                    "createdAt": "2026-10-02T11:00:00Z",
                    "updatedAt": "2026-10-02T11:00:00Z",
                    "url": "https://github.com/example/project/pull/42#discussion_r1",
                    "author": {"login": "erin"}
                  }]}
                }]}
              }]
            }
          }
        }
        """
        let items = try GitHubActivity.parse(Data(fixture.utf8))
        precondition(items.count == 5)
        precondition(items.first?.kind.label == "pull request merged")
        precondition(items.first?.actor == "bob")
        precondition(items.contains { $0.kind.label == "pull request opened" && $0.actor == "alice" })
        precondition(items.contains { $0.kind.label == "comment" && $0.preview == "Top level comment" })
        precondition(items.contains { $0.kind.label == "review" && $0.preview == "approved" })
        precondition(items.contains { $0.kind.label == "review comment" && $0.preview == "Inline comment" })
        precondition(items.allSatisfy { $0.owner == "example" && $0.repository == "project" && $0.number == 42 })
        print("PASS: GraphQL PR activity decoding, comments, reviews, inline review comments, and chronology")
    }
}

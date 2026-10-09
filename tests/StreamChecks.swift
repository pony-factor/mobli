import Foundation

@main struct StreamChecks {
    static func main() throws {
        let body = """
        [
          {
            "id": "123",
            "type": "PushEvent",
            "actor": {"login": "alice"},
            "repo": {"name": "pony-factor/mobli"},
            "created_at": "2026-10-09T09:30:00Z",
            "payload": {
              "ref": "refs/heads/main",
              "head": "abcdef123",
              "commits": [{"message": "Ship event explorer"}]
            }
          },
          {
            "id": "124",
            "type": "PullRequestEvent",
            "actor": {"login": "bob"},
            "repo": {"name": "pony-factor/mobli"},
            "created_at": "2026-10-09T10:30:00Z",
            "payload": {
              "action": "opened",
              "pull_request": {
                "html_url": "https://github.com/pony-factor/mobli/pull/99",
                "title": "Add filtering"
              }
            }
          }
        ]
        """
        let items = try StreamParsing.decode(Data(body.utf8), sourceID: "watch-1")
        precondition(items.count == 2)
        precondition(items[0].id == "watch-1:123")
        precondition(items[0].kind == "Push")
        precondition(items[0].actor == "alice")
        precondition(items[0].summary == "Ship event explorer")
        precondition(items[0].url.absoluteString.hasSuffix("/commit/abcdef123"))
        precondition(items[1].kind == "Pull Request")
        precondition(items[1].action == "opened")
        precondition(items[1].url.absoluteString.hasSuffix("/pull/99"))
        precondition(items[1].matches("ADD FILTERING"))
        precondition(items[0].matches("alice"))
        precondition(items[0].matches("refs/heads/main"))
        precondition(!items[0].matches("something else"))
        precondition(items[1].rawJSON.contains("\"pull_request\""))
        let watch = StreamWatch(id: "watch-1", kind: .repository, value: "pony-factor/mobli", accountID: nil)
        precondition(watch.endpoint?.absoluteString == "https://api.github.com/repos/pony-factor/mobli/events?per_page=100")
        precondition(StreamWatch(id: "bad", kind: .repository, value: "pony-factor/mobli/extra", accountID: nil).endpoint == nil)
        precondition(StreamWatch(id: "bad", kind: .organization, value: "bad name", accountID: nil).endpoint == nil)
        precondition(StreamWatch(id: "org", kind: .organization, value: "pony-factor", accountID: nil).endpoint != nil)
        precondition(StreamWatch(id: "user", kind: .user, value: "octocat", accountID: nil).endpoint != nil)
        print("PASS: stream event decoding, searching, detail links, and validated source endpoints")
    }
}

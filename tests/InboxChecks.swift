import Foundation

@main struct InboxChecks {
    static func main() throws {
        let fixture = """
        [{"id":"123","repository":{"name":"project","html_url":"https://github.com/example/project","owner":{"login":"example"}},"subject":{"title":"Review this change","type":"PullRequest","url":"https://api.github.com/repos/example/project/pulls/42"},"reason":"review_requested","updated_at":"2026-10-01T12:00:00Z"}]
        """
        let response = try GitHubInbox.parseResponse(Data(("HTTP/2.0 200 OK\r\nX-Poll-Interval: 120\r\nLast-Modified: Thu, 01 Oct 2026 12:00:00 GMT\r\n\r\n" + fixture).utf8))
        precondition(response.status == 200)
        precondition(response.headers["x-poll-interval"] == "120")
        precondition(response.headers["last-modified"] != nil)
        let threads = try JSONDecoder().decode([InboxThread].self, from: response.body)
        precondition(threads.count == 1 && threads[0].owner == "example")
        precondition(threads[0].webURL.absoluteString == "https://github.com/example/project/pull/42")
        let noURL = fixture.replacingOccurrences(of: "\"https://api.github.com/repos/example/project/pulls/42\"", with: "null")
        let fallback = try JSONDecoder().decode([InboxThread].self, from: Data(noURL.utf8))[0]
        precondition(fallback.webURL.host == "github.com" && fallback.webURL.path == "/notifications")
        precondition(URLComponents(url: fallback.webURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "repo:example/project")
        let unchanged = try GitHubInbox.parseResponse(Data("HTTP/2.0 304 Not Modified\nX-Poll-Interval: 60\n\n".utf8))
        precondition(unchanged.status == 304 && unchanged.body.isEmpty)
        let fresh = OwnerProfile(displayName: "Owner", avatar: Data(), fetchedAt: Date().addingTimeInterval(-6 * 86400))
        let expired = OwnerProfile(displayName: "Owner", avatar: Data(), fetchedAt: Date().addingTimeInterval(-8 * 86400))
        precondition(fresh.isFresh && !expired.isFresh)
        print("PASS: notification decoding, thread links, inbox fallback, HTTP headers, 304 responses, seven-day owner cache")
    }
}

import Foundation

@main struct PinPlacementChecks {
    @MainActor static func main() {
        let suite = "mobli-pin-checks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Repository(url: URL(fileURLWithPath: "/tmp/org/first"), owner: "org", lastActivityAt: nil)
        let second = Repository(url: URL(fileURLWithPath: "/tmp/org/second"), owner: "org", lastActivityAt: nil)
        let ordinary = Repository(url: URL(fileURLWithPath: "/tmp/org/ordinary"), owner: "org", lastActivityAt: .distantFuture)
        defaults.set([first.usageKey], forKey: "studio.repository-launcher.pinned-repositories")
        let store = RepositoryUsageStore(defaults: defaults)
        precondition(store.pinnedRepositories(from: [first, second]).map(\.usageKey) == [first.usageKey])
        store.placeInColumn(first)
        precondition(store.isPinned(first) && store.isColumnPinned(first))
        precondition(store.pinnedRepositories(from: [first]).isEmpty)
        store.togglePin(second)
        precondition(!store.isColumnPinned(second))
        store.placeInColumn(second)
        store.movePinned(second.usageKey, relativeTo: first.usageKey, after: false)
        store.record(first)
        precondition(store.ranked([ordinary, first, second]).map(\.usageKey) == [second.usageKey, first.usageKey, ordinary.usageKey])
        let restored = RepositoryUsageStore(defaults: defaults)
        precondition(restored.isPinned(first) && restored.isColumnPinned(first))
        precondition(restored.isPinned(second) && restored.isColumnPinned(second))
        precondition(restored.ranked([first, second]).map(\.usageKey) == [second.usageKey, first.usageKey])
        restored.togglePin(first)
        precondition(!restored.isPinned(first) && !restored.isColumnPinned(first))
        restored.togglePin(first)
        precondition(restored.isPinned(first) && !restored.isColumnPinned(first))
        precondition(restored.pinnedRepositories(from: [first, second]).map(\.usageKey) == [first.usageKey])
        print("PASS: pin migration, top-to-column placement, explicit column order, persistence, and repinning")
    }
}

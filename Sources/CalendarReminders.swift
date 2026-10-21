import Foundation
import SwiftUI
import AppKit

// Calendar data is read-only. Nothing is written back to the source repository.
struct CalendarDayEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

enum CalendarDayParsing {
    static let filenames = ["birthdays.json", "flights.json", "events.json", "calendar.json"]

    static func dayKey(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func validDate(_ text: String) -> String? {
        let date = String(text.prefix(10))
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] >= 1, (1...12).contains(parts[1]),
              (1...31).contains(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let result = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              dayKey(result, in: calendar.timeZone) == date else { return nil }
        return date
    }

    static func entries(documents: [String: Data], on date: Date, in zone: TimeZone) throws -> [CalendarDayEntry] {
        let today = dayKey(date, in: zone)
        let parts = today.split(separator: "-").compactMap { Int($0) }
        let month = parts[1], day = parts[2]
        var entries: [CalendarDayEntry] = []

        func add(_ id: String, _ title: String, _ detail: String) {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            entries.append(CalendarDayEntry(id: id, title: name, detail: detail))
        }
        func string(_ object: [String: Any], _ key: String) -> String? {
            object[key] as? String
        }
        func dateMatches(_ event: [String: Any]) -> Bool {
            if let month = event["month"] as? Int, let day = event["day"] as? Int {
                return month == parts[1] && day == parts[2]
            }
            if let exact = string(event, "date"), let value = validDate(exact) {
                return value == today
            }
            guard let start = string(event, "start_date").flatMap(validDate) else { return false }
            let end = string(event, "end_date").flatMap(validDate) ?? start
            return start <= today && today <= end
        }
        for filename in filenames {
            guard let data = documents[filename] else { continue }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CalendarSourceError.malformed(filename)
            }
            if let birthdays = object["birthdays"] as? [[String: Any]] {
                for birthday in birthdays {
                    guard let m = birthday["month"] as? Int,
                          let d = birthday["day"] as? Int, m == month, d == day,
                          let name = string(birthday, "name") else { continue }
                    add("birthday:\(m):\(d):\(name)", "\(name)'s birthday", "Birthday · repeats annually")
                }
            }
            if let events = object["events"] as? [[String: Any]] {
                for (index, event) in events where dateMatches(event) {
                    let title = string(event, "title") ?? string(event, "name") ?? string(event, "summary") ?? "Calendar event"
                    let identifier = string(event, "id") ?? "\(filename):\(index):\(title)"
                    add("event:\(identifier)", title, string(event, "description") ?? "Calendar event")
                }
            }
            if let trips = object["trips"] as? [[String: Any]] {
                for (index, trip) in trips {
                    let title = string(trip, "name") ?? string(trip, "title") ?? "Trip"
                    let status = string(trip, "booking_status") ?? ""
                    let flights = trip["flights"] as? [[String: Any]] ?? []
                    if flights.isEmpty {
                        if dateMatches(trip) {
                            add("trip:\(index):\(title)", title, status.isEmpty ? "Trip" : "Trip · \(status)")
                        }
                        continue
                    }
                    for (legIndex, flight) in flights {
                        guard let flightDate = string(flight, "date").flatMap(validDate), flightDate == today else { continue }
                        let origin = (flight["origin"] as? [String: Any])?["airport_code"] as? String ?? "?"
                        let destination = (flight["destination"] as? [String: Any])?["airport_code"] as? String ?? "?"
                        let departure = string(flight, "departure_local")?.dropFirst(11).prefix(5).description ?? ""
                        let flightTitle = "Flight \(origin) → \(destination)"
                        let detail = [title, departure, status].filter { !$0.isEmpty }.joined(separator: " · ")
                        add("flight:\(index):\(legIndex):\(flightDate)", flightTitle, detail)
                    }
                }
            }
        }
        var unique: [String: CalendarDayEntry] = [:]
        for entry in entries { unique[entry.id] = entry }
        return unique.values.sorted { ($0.title.localizedLowercase, $0.id) < ($1.title.localizedLowercase, $1.id) }
    }
}

enum CalendarReminderPolicy {
    static func eligible(key: String, now: Date, done: [String: Double], snoozed: [String: Double]) -> Bool {
        done[key] == nil && (snoozed[key] ?? 0) <= now.timeIntervalSince1970
    }

    static func nextReminder(after now: Date, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return min(now.addingTimeInterval(3600), midnight)
    }
}

enum CalendarSourceError: LocalizedError {
    case invalidSource, noFiles, missingCLI, malformed(String)
    var errorDescription: String? {
        switch self {
        case .invalidSource: return "Enter a GitHub owner/repository or an absolute local folder path."
        case .noFiles: return "No supported calendar JSON files were readable. Check the path and GitHub CLI access."
        case .missingCLI: return "Install and sign into GitHub CLI (gh) to read a GitHub calendar, including private repos."
        case .malformed(let file): return "\(file) must contain a JSON object."
        }
    }
}

actor CalendarDocumentLoader {
    func load(source: String) async throws -> [String: Data] {
        var documents: [String: Data] = [:]
        if source.hasPrefix("/") || source.hasPrefix("~/") {
            let folder = source.hasPrefix("~/") ? NSHomeDirectory() + String(source.dropFirst()) : source
            for filename in CalendarDayParsing.filenames {
                let path = URL(fileURLWithPath: folder).appendingPathComponent(filename).path
                if FileManager.default.fileExists(atPath: path) {
                    documents[filename] = try Data(contentsOf: URL(fileURLWithPath: path))
                }
            }
        } else {
            let names = source.split(separator: "/", omittingEmptySubsequences: false)
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
            guard names.count == 2, names.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { allowed.contains($0) } }),
                  !names.contains("..") else { throw CalendarSourceError.invalidSource }
            guard let executable = GitHubInbox.executable else { throw CalendarSourceError.missingCLI }
            for filename in CalendarDayParsing.filenames {
                let endpoint = "repos/\(names[0])/\(names[1])/contents/\(filename)"
                let result = try await Task.detached(priority: .utility) { () throws -> (Data, Int32) in
                    let process = Process()
                    let pipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = ["api", "--hostname", "github.com",
                                         "-H", "Accept: application/vnd.github.raw+json", endpoint]
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                    process.standardInput = FileHandle.nullDevice
                    try process.run()
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeout.cancel()
                    return (data, process.terminationStatus)
                }.value
                if result.1 == 0 { documents[filename] = result.0 }
            }
        }
        guard !documents.isEmpty else { throw CalendarSourceError.noFiles }
        return documents
    }
}

@MainActor final class CalendarReminderCoordinator: ObservableObject {
    static let enabledKey = "studio.repository-launcher.calendar.enabled"
    static let sourceKey = "studio.repository-launcher.calendar.source"
    static let zoneKey = "studio.repository-launcher.calendar.time-zone"
    private static let doneKey = "studio.repository-launcher.calendar.done"
    private static let snoozedKey = "studio.repository-launcher.calendar.snoozed"

    @Published private(set) var message = "Calendar reminders are off."
    @Published private(set) var checkedAt: Date?
    @Published private(set) var loading = false

    private let loader = CalendarDocumentLoader()
    private var timer: Timer?
    private var documents: [String: Data] = [:]
    private var entries: [CalendarDayEntry] = []
    private var source = ""
    private var zoneID = ""
    private var loadedDay = ""
    private var fetchedAt: Date?
    private var window: NSWindow?
    private var activeEntry: CalendarDayEntry?
    private var activeZone: TimeZone = .current

    func start() {
        guard timer == nil else { return }
        checkNow()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func checkNow() { check(force: true) }

    func check(force: Bool = false) {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: Self.enabledKey)
        let requestedSource = (defaults.string(forKey: Self.sourceKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedZone = (defaults.string(forKey: Self.zoneKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !requestedSource.isEmpty else {
            dismiss()
            documents = []
            entries = []
            fetchedAt = nil
            source = ""
            zoneID = ""
            loadedDay = ""
            message = enabled ? "Choose a calendar repository or folder." : "Calendar reminders are off."
            return
        }
        guard requestedZone.isEmpty || TimeZone(identifier: requestedZone) != nil else {
            dismiss()
            entries = []
            fetchedAt = nil
            source = ""
            zoneID = ""
            loadedDay = ""
            message = "Unknown time zone. Use an IANA identifier such as America/New_York."
            return
        }
        let zone = requestedZone.isEmpty ? TimeZone.current : TimeZone(identifier: requestedZone)!
        let day = CalendarDayParsing.dayKey(Date(), in: zone)
        if source != requestedSource || zoneID != requestedZone || loadedDay != day {
            dismiss()
            documents = []
            entries = []
            fetchedAt = nil
            source = requestedSource
            zoneID = requestedZone
            loadedDay = day
        }
        activeZone = zone
        if !force, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 600 {
            displayNext()
            return
        }
        guard !loading else { return }
        loading = true
        let sourceAtStart = source
        let dayAtStart = loadedDay
        Task {
            do {
                let result = try await loader.load(source: sourceAtStart)
                guard sourceAtStart == self.source && dayAtStart == self.loadedDay else {
                    loading = false
                    check(force: true)
                    return
                }
                let items = try CalendarDayParsing.entries(documents: result, on: Date(), in: zone)
                documents = result
                entries = items
                if let activeEntry, !items.contains(where: { $0.id == activeEntry.id }) {
                    dismiss()
                }
                fetchedAt = Date()
                checkedAt = Date()
                message = items.isEmpty ? "No events scheduled for today." : "\(items.count) event(s) scheduled for today."
            } catch {
                message = "Calendar check failed: \(error.localizedDescription)"
                checkedAt = Date()
            }
            loading = false
            displayNext()
        }
    }

    private func eventKey(_ entry: CalendarDayEntry) -> String {
        "\(source)|\(loadedDay)|\(entry.id)"
    }

    private func state(_ key: String) -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    private func save(_ values: [String: Double], key: String) {
        let threshold = Date().addingTimeInterval(-35 * 86400).timeIntervalSince1970
        UserDefaults.standard.set(values.filter { $0.value >= threshold }, forKey: key)
    }

    private func dismiss() {
        window?.orderOut(nil)
        activeEntry = nil
    }

    private func displayNext() {
        guard activeEntry == nil else { return }
        let done = state(Self.doneKey), snoozed = state(Self.snoozedKey)
        let now = Date()
        guard let entry = entries.first(where: {
            CalendarReminderPolicy.eligible(key: eventKey($0), now: now, done: done, snoozed: snoozed)
        }) else { return }
        activeEntry = entry
        if window == nil {
            let notice = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 258),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            notice.title = "Calendar reminder"
            notice.isReleasedWhenClosed = false
            notice.level = .floating
            notice.collectionBehavior.insert(.moveToActiveSpace)
            window = notice
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeZone = activeZone
        window?.contentView = NSHostingView(rootView: CalendarReminderNotice(
            title: entry.title,
            detail: entry.detail,
            date: formatter.string(from: now),
            snooze: { [weak self] in self?.snooze() },
            done: { [weak self] in self?.markDone() }
        ))
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func snooze() {
        guard let entry = activeEntry else { return }
        var values = state(Self.snoozedKey)
        values[eventKey(entry)] = CalendarReminderPolicy.nextReminder(after: Date(), in: activeZone).timeIntervalSince1970
        save(values, key: Self.snoozedKey)
        dismiss()
        displayNext()
    }

    private func markDone() {
        guard let entry = activeEntry else { return }
        var values = state(Self.doneKey)
        values[eventKey(entry)] = Date().timeIntervalSince1970
        save(values, key: Self.doneKey)
        dismiss()
        displayNext()
    }
}

private struct CalendarReminderNotice: View {
    let title: String
    let detail: String
    let date: String
    let snooze: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Today · \(date)", systemImage: "calendar.badge.clock")
                .font(.system(size: 14, weight: .semibold))
            Text(title).font(.system(size: 24, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("Remind me in 1 hour", action: snooze)
                Spacer()
                Button("Done for today", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 450, height: 250, alignment: .topLeading)
    }
}

struct CalendarReminderSettings: View {
    @ObservedObject var coordinator: CalendarReminderCoordinator
    @AppStorage(CalendarReminderCoordinator.enabledKey) private var enabled = false
    @AppStorage(CalendarReminderCoordinator.sourceKey) private var source = ""
    @AppStorage(CalendarReminderCoordinator.zoneKey) private var zone = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Remind me about today's calendar events", isOn: $enabled)
                .onChange(of: enabled) { _, _ in coordinator.checkNow() }
            Text("Calendar source")
                .font(.system(size: 13, weight: .semibold))
            TextField("owner/repo or ~/path/to/calendar", text: $source)
                .textFieldStyle(.roundedBorder)
                .onSubmit { coordinator.checkNow() }
            Text("Read-only JSON calendar. Uses birthdays.json, flights.json, events.json, or calendar.json. Private GitHub repositories require GitHub CLI sign-in; local folders work offline.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text("Time zone (optional)")
                .font(.system(size: 13, weight: .semibold))
            TextField("System time zone (e.g. America/New_York)", text: $zone)
                .textFieldStyle(.roundedBorder)
                .onSubmit { coordinator.checkNow() }
            HStack {
                Button("Check calendar now") { coordinator.checkNow() }
                if coordinator.loading { ProgressView().controlSize(.small) }
            }
            Text(coordinator.message).font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text("Alerts appear while Mobli is running. Snooze repeats hourly until the end of that calendar day; Done dismisses only that day's occurrence. Settings and choices persist across restarts.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }
}

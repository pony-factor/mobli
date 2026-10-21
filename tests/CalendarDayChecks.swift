import Foundation

@main struct CalendarDayChecks {
    static func main() throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        let utc = TimeZone(secondsFromGMT: 0)!
        let instant = ISO8601DateFormatter().date(from: "2026-10-26T15:00:00Z")!
        let birthdays = Data(#"""
        {"birthdays":[{"name":"Hazel","month":10,"day":26,"year":1959},
                      {"name":"Unknown","month":2,"day":null},
                      {"name":"Not today","month":7,"day":30}]}
        """#.utf8)
        let events = Data(#"""
        {"events":[{"title":"Book club","date":"2026-10-26"},
                   {"id":"annual","name":"Anniversary","month":10,"day":26},
                   {"title":"Three-day conference","start_date":"2026-10-25","end_date":"2026-10-27"},
                   {"title":"Future date","date":"2026-10-27"}]}
        """#.utf8)
        let entries = try CalendarDayParsing.entries(
            documents: ["birthdays.json": birthdays, "events.json": events],
            on: instant, in: newYork
        )
        precondition(entries.count == 4)
        precondition(entries.contains { $0.title == "Hazel's birthday" })
        precondition(entries.contains { $0.title == "Book club" })
        precondition(entries.contains { $0.title == "Anniversary" })
        precondition(entries.contains { $0.title == "Three-day conference" })
        precondition(!entries.contains { $0.title.contains("Unknown") || $0.title == "Future date" })
        precondition(CalendarDayParsing.validDate("2026-02-30") == nil)
        precondition(CalendarDayParsing.validDate("2024-02-29") == "2024-02-29")

        let flights = Data(#"""
        {"trips":[{"name":"Holiday","booking_status":"not_confirmed",
                  "start_date":"2026-12-22","end_date":"2026-12-30",
                  "flights":[{"date":"2026-12-22","origin":{"airport_code":"FLL"},
                              "destination":{"airport_code":"CLT"},
                              "departure_local":"2026-12-22T09:57:00-05:00"},
                             {"date":"2026-12-30","origin":{"airport_code":"CLT"},
                              "destination":{"airport_code":"FLL"}}]}]}
        """#.utf8)
        let flightDay = ISO8601DateFormatter().date(from: "2026-12-22T12:00:00Z")!
        let flightEntries = try CalendarDayParsing.entries(
            documents: ["flights.json": flights], on: flightDay, in: newYork
        )
        precondition(flightEntries.count == 1)
        precondition(flightEntries[0].title == "Flight FLL → CLT")
        let interveningDay = ISO8601DateFormatter().date(from: "2026-12-25T12:00:00Z")!
        let interveningEntries = try CalendarDayParsing.entries(
            documents: ["flights.json": flights], on: interveningDay, in: newYork
        )
        precondition(interveningEntries.isEmpty)

        let late = ISO8601DateFormatter().date(from: "2026-10-27T03:45:00Z")!
        precondition(CalendarDayParsing.dayKey(late, in: utc) == "2026-10-27")
        precondition(CalendarDayParsing.dayKey(late, in: newYork) == "2026-10-26")
        let cutoff = CalendarReminderPolicy.nextReminder(after: late, in: newYork)
        precondition(abs(cutoff.timeIntervalSince(late) - 15 * 60) < 1)
        let morning = ISO8601DateFormatter().date(from: "2026-10-26T14:00:00Z")!
        precondition(abs(CalendarReminderPolicy.nextReminder(after: morning, in: newYork)
                         .timeIntervalSince(morning) - 3600) < 1)

        let key = "example/calendar|2026-10-26|birthday:10:26:Hazel"
        precondition(CalendarReminderPolicy.eligible(key: key, now: morning, done: [:], snoozed: [:]))
        precondition(!CalendarReminderPolicy.eligible(key: key, now: morning,
                                                       done: [key: morning.timeIntervalSince1970], snoozed: [:]))
        precondition(!CalendarReminderPolicy.eligible(key: key, now: morning,
                                                       done: [:], snoozed: [key: morning.timeIntervalSince1970 + 300]))
        precondition(CalendarReminderPolicy.eligible(key: key, now: morning,
                                                     done: [:], snoozed: [key: morning.timeIntervalSince1970 - 1]))
        // A completed occurrence must not hide next year's matching birthday.
        let nextYear = key.replacingOccurrences(of: "2026-10-26", with: "2027-10-26")
        precondition(CalendarReminderPolicy.eligible(key: nextYear, now: morning,
                                                     done: [key: morning.timeIntervalSince1970], snoozed: [:]))
        print("Calendar parsing, recurrence, time-zone cutoff, and reminder-policy checks passed")
    }
}

import Foundation

/// Lightweight per-board/per-account UI preferences. UserDefaults is the
/// right store here: values are tiny, key-scoped, and wanted synchronously
/// at view init (the SQLite store would force an async round-trip through
/// TodoStore for two booleans). Keys are stable and scoped by id.
enum AppPreferences {
    private static let defaults = UserDefaults.standard

    // MARK: "My tickets only" (per Jira space)

    static func mineOnly(spaceID: Int64) -> Bool {
        defaults.object(forKey: "jira-mineOnly-\(spaceID)") as? Bool ?? true
    }

    static func setMineOnly(_ value: Bool, spaceID: Int64) {
        defaults.set(value, forKey: "jira-mineOnly-\(spaceID)")
    }

    // MARK: "Show read" (per mentions page)

    static func showRead(scope: String) -> Bool {
        defaults.object(forKey: "showRead-\(scope)") as? Bool ?? false
    }

    static func setShowRead(_ value: Bool, scope: String) {
        defaults.set(value, forKey: "showRead-\(scope)")
    }

    // MARK: Activity full-refresh bookkeeping (per scope)
    //
    // Delta refreshes (issues updated in the last 15 minutes) are cheap
    // but can't detect removals — a full refresh runs at launch, hourly,
    // and on force-refresh to reap anything that dropped off.

    static func activityLastFull(scope: String) -> Date? {
        let raw = defaults.double(forKey: "activity-lastfull-\(scope)")
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    static func setActivityLastFull(_ date: Date, scope: String) {
        defaults.set(date.timeIntervalSince1970, forKey: "activity-lastfull-\(scope)")
    }
}
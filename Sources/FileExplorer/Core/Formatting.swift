import Foundation

/// Size and date formatting in the style of Windows Explorer.
enum Formatting {
    /// "1,234 KB", "4.2 MB", "12 GB". Base 1024; KB is rounded up like Explorer.
    static func bytes(_ value: Int64) -> String {
        if value <= 0 { return "0 KB" }
        let kb = Double(value) / 1024
        if kb < 1 { return "1 KB" }
        if kb < 1024 { return "\(grouped(Int64(kb.rounded(.up)))) KB" }
        let mb = kb / 1024
        if mb < 1024 { return String(format: mb < 10 ? "%.1f MB" : "%.0f MB", mb) }
        let gb = mb / 1024
        if gb < 1024 { return String(format: gb < 10 ? "%.1f GB" : "%.0f GB", gb) }
        return String(format: "%.2f TB", gb / 1024)
    }

    /// Drive capacity: "234 GB".
    static func capacity(_ value: Int64) -> String {
        let gb = Double(value) / 1_073_741_824
        if gb < 1 { return String(format: "%.0f MB", Double(value) / 1_048_576) }
        if gb < 1024 { return String(format: "%.0f GB", gb) }
        return String(format: "%.2f TB", gb / 1024)
    }

    static func grouped(_ value: Int64) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Short date + time in the user's locale ("6/25/2026, 11:53 AM"); "" for 0.
    static func dateTime(_ epoch: TimeInterval) -> String {
        guard epoch > 0 else { return "" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// "~" for the home directory prefix, to keep Recent rows short.
    static func abbreviatingHome(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

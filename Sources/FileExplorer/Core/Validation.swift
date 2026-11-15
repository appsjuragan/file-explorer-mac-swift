import Foundation

/// Input checks that guard the file system and external tools (OWASP: validate and
/// canonicalise untrusted input before it reaches a path or a process).
enum Validation {
    /// A single path component typed by the user (rename, new folder).
    static func fileName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 255 else {
            throw FileOpError("That name isn't valid.")
        }
        return name
    }

    /// A member name from a zip listing. Rejects absolute paths and `..` components so an
    /// archive can never write outside the extraction folder ("zip slip").
    static func isSafeArchiveEntry(_ entry: String) -> Bool {
        if entry.isEmpty || entry.contains("\0") || entry.hasPrefix("/") || entry.hasPrefix("~") {
            return false
        }
        return !entry.split(separator: "/", omittingEmptySubsequences: true).contains("..")
    }

    /// Only https URLs on hosts we expect are ever opened in the browser.
    static func isTrustedWebURL(_ url: URL, allowedHostSuffixes: [String]) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// "v1.2.3" → [1, 2, 3]; non-numeric parts are ignored.
    static func versionComponents(_ text: String) -> [Int] {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "vV \n"))
        return trimmed.split(separator: ".").compactMap { part in
            Int(part.prefix { $0.isNumber })
        }
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = versionComponents(candidate), b = versionComponents(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

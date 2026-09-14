import Foundation

/// Generates a visible title for a newly opened terminal session without
/// changing the connection profile itself. This keeps simultaneous sessions
/// for one profile distinguishable in the tab strip and broadcast controls.
public enum TerminalSessionTitleAllocator {
    public static func nextTitle(base: String, existingTitles: [String]) -> String {
        let normalizedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = normalizedBase.isEmpty ? "Terminal" : normalizedBase
        let usedTitles = Set(existingTitles.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })

        guard usedTitles.contains(title) else { return title }

        var ordinal = 2
        while usedTitles.contains("\(title) (\(ordinal))") {
            ordinal += 1
        }
        return "\(title) (\(ordinal))"
    }
}

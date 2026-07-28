import Foundation

public struct ANSITextSanitizer: Sendable {
    private var pending = ""

    public init() {}

    public mutating func consume(_ data: Data) -> String {
        guard let decoded = String(data: data, encoding: .utf8) else {
            return ""
        }
        pending.append(decoded)
        return drainCompleteSequences()
    }

    public mutating func finish() -> String {
        defer { pending.removeAll(keepingCapacity: false) }
        return stripControlSequences(from: pending)
    }

    private mutating func drainCompleteSequences() -> String {
        guard !pending.isEmpty else {
            return ""
        }

        var safeEnd = pending.endIndex
        if let escape = pending.lastIndex(of: "\u{001B}") {
            let suffix = pending[escape...]
            if isPossiblyIncompleteSequence(suffix) {
                safeEnd = escape
            }
        }

        let complete = String(pending[..<safeEnd])
        pending = String(pending[safeEnd...])
        return stripControlSequences(from: complete)
    }

    private func isPossiblyIncompleteSequence(_ suffix: Substring) -> Bool {
        guard suffix.count > 1 else {
            return true
        }
        if suffix.hasPrefix("\u{001B}[") {
            return suffix.last?.isLetter != true && suffix.last != "~"
        }
        if suffix.hasPrefix("\u{001B}]") {
            return !suffix.contains("\u{0007}") && !suffix.contains("\u{001B}\\")
        }
        return false
    }

    private func stripControlSequences(from input: String) -> String {
        var result = input
        let patterns = [
            #"\u001B\][^\u0007\u001B]*(?:\u0007|\u001B\\)"#,
            #"\u001B\[[0-?]*[ -/]*[@-~]"#,
            #"\u001B[()][A-Z0-9]"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return result
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

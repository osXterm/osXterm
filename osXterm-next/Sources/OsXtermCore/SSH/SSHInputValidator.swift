import Foundation

enum SSHInputValidator {
    static func host(_ value: String) -> Bool {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = unbracketedIPv6(raw)
        return !host.isEmpty
            && raw == value
            && !host.hasPrefix("-")
            && !host.contains("@")
            && !host.contains(",")
            && !host.contains("\0")
            && bracketsAreBalanced(raw)
            && !host.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
            })
    }

    static func username(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("-")
            && !value.contains("\0")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
            })
    }

    static func localPath(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.contains("\0"),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.newlines.union(.controlCharacters).contains($0)
              })
        else {
            return false
        }
        return value.hasPrefix("/") || value.hasPrefix("~/")
    }

    static func socketPath(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains("\0")
            && !value.contains(":")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.newlines.union(.controlCharacters).contains($0)
            })
            && value.utf8.count < 104
    }

    static func port(_ value: Int, allowsZero: Bool = false) -> Bool {
        (allowsZero && value == 0) || (1 ... 65_535).contains(value)
    }

    static func unbracketedIPv6(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 else {
            return host
        }
        return String(host.dropFirst().dropLast())
    }

    static func bracketedIfNeeded(_ host: String) -> String {
        let unbracketed = unbracketedIPv6(host)
        return unbracketed.contains(":") ? "[\(unbracketed)]" : unbracketed
    }

    static func isLoopback(_ address: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(address.lowercased())
    }

    static func configValue(_ value: String) -> String? {
        guard !value.contains("\0"),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.newlines.union(.controlCharacters).contains($0)
              })
        else {
            return nil
        }
        return "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func bracketsAreBalanced(_ value: String) -> Bool {
        value.hasPrefix("[") == value.hasSuffix("]")
    }
}

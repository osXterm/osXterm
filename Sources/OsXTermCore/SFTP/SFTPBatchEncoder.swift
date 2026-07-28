import Foundation

enum SFTPBatchEncoder {
    static func list(_ remotePath: String) throws -> Data {
        // Long format keeps the file type in the first permission character,
        // which lets the sidebar distinguish folders from regular files.
        // Deliberately omit -a so dot files never enter the user-facing list.
        try encode(command: "ls -1l", paths: [remotePath])
    }

    static func upload(localURL: URL, remotePath: String) throws -> Data {
        guard localURL.isFileURL else {
            throw SFTPError.invalidPath("The upload source must be a file URL")
        }
        return try encode(command: "put", paths: [localURL.path, remotePath])
    }

    static func download(remotePath: String, localURL: URL) throws -> Data {
        guard localURL.isFileURL else {
            throw SFTPError.invalidPath("The download destination must be a file URL")
        }
        return try encode(command: "get", paths: [remotePath, localURL.path])
    }

    static func makeDirectory(_ remotePath: String) throws -> Data {
        try encode(command: "mkdir", paths: [remotePath])
    }

    static func rename(from sourcePath: String, to destinationPath: String) throws -> Data {
        try encode(command: "rename", paths: [sourcePath, destinationPath])
    }

    static func remove(_ remotePath: String) throws -> Data {
        try encode(command: "rm", paths: [remotePath])
    }

    private static func encode(command: String, paths: [String]) throws -> Data {
        let arguments = try paths.map(quoteLiteralPath)
        let line = ([command] + arguments).joined(separator: " ") + "\n"
        return Data(line.utf8)
    }

    /// Quotes a literal path for the OpenSSH sftp batch parser.
    ///
    /// Newlines cannot be represented safely in its line-oriented batch
    /// format. Glob metacharacters need an additional backslash even inside
    /// quotes according to `sftp(1)`.
    static func quoteLiteralPath(_ path: String) throws -> String {
        guard !path.isEmpty else {
            throw SFTPError.invalidPath("A path cannot be empty")
        }
        guard !path.unicodeScalars.contains(where: {
            $0.value == 0 || $0.value == 10 || $0.value == 13
        }) else {
            throw SFTPError.invalidPath("NUL, carriage return, and newline are not supported")
        }

        let optionSafePath = path.first == "-" ? "./\(path)" : path
        var quoted = "\""
        quoted.reserveCapacity(optionSafePath.utf8.count + 2)

        for character in optionSafePath {
            switch character {
            case "\\", "\"", "*", "?", "[", "]":
                quoted.append("\\")
                quoted.append(character)
            default:
                quoted.append(character)
            }
        }

        quoted.append("\"")
        return quoted
    }
}

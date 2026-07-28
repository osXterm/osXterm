import Foundation
import OsXTermCore

let environment = ProcessInfo.processInfo.environment
guard let socketPath = environment["OSXTERM_ASKPASS_SOCKET"], !socketPath.isEmpty else {
    FileHandle.standardError.write(Data("osXtermAskPass: missing session credential socket\n".utf8))
    exit(2)
}

do {
    let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
    let credential = try SessionAskPassClient.readCredential(
        socketPath: socketPath,
        prompt: prompt
    )
    FileHandle.standardOutput.write(credential)
} catch {
    FileHandle.standardError.write(
        Data("osXtermAskPass: session credential is unavailable\n".utf8)
    )
    exit(3)
}

import Darwin
import Foundation
import OsXtermCore

let environment = ProcessInfo.processInfo.environment
let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")

guard !prompt.isEmpty,
      let socketPath = environment["OSXTERM_ASKPASS_SOCKET"],
      let token = environment["OSXTERM_ASKPASS_TOKEN"]
else {
    exit(EXIT_FAILURE)
}

do {
    let response = try AskPassClient.requestResponse(
        socketPath: socketPath,
        token: token,
        prompt: prompt
    )
    FileHandle.standardOutput.write(Data(response.utf8))
    FileHandle.standardOutput.write(Data([0x0A]))
    exit(EXIT_SUCCESS)
} catch {
    // OpenSSH treats a nonzero exit as a cancelled prompt. Do not write
    // diagnostics because prompts and response handling can be sensitive.
    exit(EXIT_FAILURE)
}

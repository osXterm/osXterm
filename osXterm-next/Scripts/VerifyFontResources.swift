import AppKit
import CoreText
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Expected the project directory as the only argument.")
}

let projectDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fontDirectory = projectDirectory.appendingPathComponent(
    "Sources/OsXtermApp/Resources/Fonts",
    isDirectory: true
)
let expectedFonts: [(fileName: String, postScriptName: String)] = [
    ("D2Coding-Regular.ttf", "D2Coding"),
    ("D2Coding-Bold.ttf", "D2CodingBold"),
    ("JetBrainsMono-Regular.ttf", "JetBrainsMono-Regular"),
    ("JetBrainsMono-Bold.ttf", "JetBrainsMono-Bold"),
    ("FiraCode-Regular.ttf", "FiraCode-Regular"),
    ("FiraCode-Bold.ttf", "FiraCode-Bold"),
    ("Hack-Regular.ttf", "Hack-Regular"),
    ("Hack-Bold.ttf", "Hack-Bold")
]

for font in expectedFonts {
    let fontURL = fontDirectory.appendingPathComponent(font.fileName)
    guard FileManager.default.fileExists(atPath: fontURL.path) else {
        fatalError("Missing font resource: \(font.fileName)")
    }

    var error: Unmanaged<CFError>?
    _ = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
    guard NSFont(name: font.postScriptName, size: 13) != nil else {
        fatalError("Unable to resolve expected PostScript name: \(font.postScriptName)")
    }
    print("Verified \(font.fileName) as \(font.postScriptName)")
}

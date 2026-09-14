import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Packaging/AppIcon.iconset")
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first ?? "Packaging/AppIcon.icns")
let chunks: [(String, String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png")
]

func bigEndian(_ value: UInt32) -> Data {
    var number = value.bigEndian
    return Data(bytes: &number, count: MemoryLayout<UInt32>.size)
}

var payload = Data()
for (type, name) in chunks {
    let png = try Data(contentsOf: root.appendingPathComponent(name))
    payload.append(Data(type.utf8))
    payload.append(bigEndian(UInt32(png.count + 8)))
    payload.append(png)
}

var icns = Data("icns".utf8)
icns.append(bigEndian(UInt32(payload.count + 8)))
icns.append(payload)
try icns.write(to: output, options: .atomic)

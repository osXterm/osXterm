# Third-party notices

## SwiftTerm 1.19.0

SwiftTerm is distributed under the MIT License. The packaging script copies
the Swift Package Manager resource bundle and the upstream license text from
the resolved dependency into the app bundle.

## Bundled terminal fonts

The app carries these font files as resources. Their full license texts and
source versions are in `Sources/OsXtermApp/Resources/FontLicenses` and are
copied through the SwiftPM resource bundle during packaging.

- D2 Coding VER1.3.3, SIL Open Font License 1.1
- JetBrains Mono v2.304, SIL Open Font License 1.1
- Fira Code 6.2, SIL Open Font License 1.1
- Hack v3.003, MIT License and Bitstream Vera license terms

OpenSSH is supplied by macOS and is not bundled with osXterm. Its license and
notices remain those distributed by Apple with the operating system.

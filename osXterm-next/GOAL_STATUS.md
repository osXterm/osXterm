# osXterm-next Goal Status

Last updated: 2026-09-15

## Goal state

Not complete. The source implementation and verification harness are substantially in place, but required release evidence cannot be produced in the current environment. No unverified item is marked as passed.

## Completed implementation work

| Area | Status | Evidence |
| --- | --- | --- |
| New isolated project | Implemented | This directory is `osXterm-next`; the legacy parent project was not modified. |
| Swift 6, macOS 26, arm64 metadata | Implemented | [Package.swift](Package.swift), [Packaging/Info.plist](Packaging/Info.plist), and the Xcode project build settings declare macOS 26 and arm64. |
| Fixed terminal dependency | Implemented | `Package.swift` pins SwiftTerm exactly at 1.19.0; `Package.resolved` records revision `464df5207fc2432e16c9a23abe538187196daf5f`. |
| Xcode app and test target scheme | Implemented | [osXterm.xcodeproj](osXterm.xcodeproj) includes `osXterm` and `osXtermCoreTests` targets plus a shared scheme that delegates to the fixed Swift package. |
| Profile persistence and secrets | Implemented | Versioned Codable documents, atomic writes, Keychain references, secret-free profile export, and staged private-file export support are in `Sources/OsXtermCore/Persistence`. |
| SSH route engine | Implemented | Route resolution rejects cycles and invalid proxy placement; the compiler emits private per-session OpenSSH configuration and argument arrays. |
| Authentication and host keys | Implemented | AskPass broker IPC, password, encrypted key, agent, certificate, keyboard-interactive handling, app `known_hosts`, first-key review, and changed-key replacement flow are present. |
| Proxy and jump combinations | Implemented | HTTP CONNECT and SOCKS5 helper, proxy credential broker, ordered jump profiles, and common route configuration are present. |
| Tunnels | Implemented | Local, remote, dynamic, remote dynamic, Unix socket forwarding, process lifetime, verbose listener parsing, remote port allocation parsing, menu-bar controls, and explicit destination checks are present. Local TCP and Unix probes connect through the created listener; remote forwarding checks its local destination separately. |
| Terminal workspace | Implemented | SwiftTerm PTY bridge, local shell, SSH sessions, distinct first-available numbered titles for concurrent copies of a profile, tab close/rename/duplicate/reorder controls, two-pane layouts, localized terminal-buffer search through SwiftTerm's public API, twenty ANSI color themes, four bundled open-license terminal fonts, persisted typography settings with a live appearance preview, restrained macOS 26 Liquid Glass with Reduce Transparency fallback, Reduce Motion aware inspector transitions, OSC 52 preference, explicit ready-session broadcast input with per-session and Select All Connected controls that clears disconnected or failed targets, opt-in logs that record direct, broadcast, and snippet input for each destination session, private session-log export, and workspace persistence are present. |
| SFTP and SCP | Implemented | SFTP v3 frames and transport, structured listing, direct remote-path entry, recursive transfer, symlink and permission operations, selectable overwrite/skip/rename policy, single-file resume guarded by source metadata and a SHA-256 prefix comparison, explicit local-editor save-back, queue state, SFTP-backed SCP, and path validation are present. |
| Profiles and import | Implemented | Profile editor, folder create/rename/delete, tags, favorites, search, recent connections, SSH config preview with explicit profile selection and unsupported-directive diagnostics, export, and stored snippets with create/edit/delete plus one-run variable entry are present. |
| User guide and documentation | Implemented | [README.md](README.md) links to [Docs/USER_GUIDE.md](Docs/USER_GUIDE.md), [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md), and [Docs/TESTING.md](Docs/TESTING.md). The guide identifies current limits without representing unverified release work as complete. |
| Environment preflight | Implemented | [Scripts/check-environment.sh](Scripts/check-environment.sh) checks arm64, Xcode license, Swift, OpenSSH, and optionally Docker Compose before package or integration commands proceed. |
| Package and DMG scripts | Implemented | [Scripts/package-app.sh](Scripts/package-app.sh), [Scripts/create-dmg.sh](Scripts/create-dmg.sh), and [Scripts/verify-dmg.sh](Scripts/verify-dmg.sh) assemble and inspect an ad-hoc signed app and extracted DMG copy. |
| Isolated integration harness | Implemented | [Integration/docker-compose.yml](Integration/docker-compose.yml) and `osXtermIntegrationRunner` cover direct, one-hop and two-hop routes, proxies, auth, 100 MiB resumable SFTP with source metadata and SHA-256 prefix plus final digest checks, SCP, tunnel data, collision, policy rejection, and package helpers. |

## Static validation passed in this workspace

- `swiftc -typecheck` passed for all `OsXtermCore` sources using the Xcode 26 SDK and arm64 macOS 26 target.
- The same direct typecheck passed for all app sources with the fixed SwiftTerm module, plus AskPass, proxy helper, and integration runner source.
- The terminal theme bridge typechecks against SwiftTerm 1.19.0's native color and palette APIs. The checked-in font verifier confirmed all eight font files, their hashes, license files, and Core Text PostScript names. Live visual and packaged-resource verification remain required.
- A standalone arm64 SwiftTerm terminal smoke executable fed a terminal buffer and verified next-match navigation, search clearing, case-sensitive matching, regular-expression matching, and whole-word matching through SwiftTerm's public search API.
- All 56 Swift Testing core tests passed macro expansion and type checking with the Xcode Testing plugin, including broadcast source and recipient routing, disconnected-target pruning, concurrent-session title allocation, OpenSSH feature-baseline checks, and workspace persistence plus version rejection.
- The route compiler test verifies that a target proxy is rendered only on the Mac-facing jump hop while the target receives the complete `ProxyJump` chain.
- A manually linked Swift Testing runner executed all 56 core tests successfully outside the seatbelt sandbox, including the real Unix-domain credential-broker IPC exchange, live loopback TCP and Unix socket destination probes, broadcast routing and disconnected-target pruning checks, concurrent-session title allocation, installed OpenSSH capability checks, atomically persisted workspace settings and layouts, version rejection, and staged session-log export checks for content, replacement cleanup, and mode 0600. This is supplemental direct-compiler evidence, not a substitute for the blocked `swift test` release gate.
- The installed `/usr/bin/ssh` reported `OpenSSH_10.3p1, LibreSSL 3.3.6`. Its version meets osXterm's ProxyJump, remote dynamic forwarding, Unix socket forwarding, and SFTP-backed SCP feature baselines.
- A standalone arm64 smoke executable ran `SFTPResumeIntegrityVerifier` against a deterministic structured SFTP transport. It accepted matching prefix bytes and rejected changed prefix bytes.
- A standalone arm64 smoke executable parsed an SSH config preview and confirmed that a target cannot be imported without its referenced jump profile.
- `Package.resolved` resolved SwiftTerm 1.19.0 at the pinned revision.
- `plutil -lint Packaging/Info.plist`, Xcode project plist syntax, icon-container inspection, all shell-script syntax, Compose YAML parsing, and proxy Python compilation passed.
- `Scripts/prepare-integration-fixture.sh` ran successfully and its generated OpenSSH user certificate was inspected with `ssh-keygen -L`.

## Required release validation still unverified

| Gate | Why it is unverified |
| --- | --- |
| `swift test` | Xcode 26.6 reports that its license has not been accepted. |
| Full SwiftPM Release build | The same Xcode license gate blocks the supported build toolchain. |
| Docker Compose integration | Docker and Docker Compose are not installed on this Mac. |
| Live app interaction and screenshots | No Release app can be built while the Xcode license gate remains. |
| DMG creation and extracted-app verification | Depends on the Release app and Docker-backed package integration suite. |
| Ten-session stability and process-leak inspection | Depends on the live app validation gate. |

## Known implementation limitations

- Verified resume is exposed for interrupted single-file SFTP transfers. Recursive SFTP and SCP transfers restart instead of resuming.
- Local editor working copies are tracked during the current app run and require an explicit remote save. They are not restored as editable records after a restart.
- The existing layout supports a single pane or two panes. Arbitrary nested split trees are stored by the model but not yet exposed in the UI.
- The host-key changed flow is implemented for terminal sessions. A tunnel with a changed key fails closed and instructs the user to review it through a terminal session before restart.

## Next work

1. Run the complete verifier after the machine owner accepts the Xcode license and makes Docker Compose available.
2. Fix any failures found by the real fixture and package run before claiming the corresponding feature as verified.
3. Perform the required human UI pass from the extracted app, capture screenshots, and inspect process cleanup.
4. Extend resume semantics to recursive and SCP work, then add live coverage for local-editor save-back and all conflict actions.

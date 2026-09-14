# osXterm-next

`osXterm-next` is a native macOS 26 SSH workspace for Apple Silicon. It is a new project in a separate directory, so it does not read, migrate, or overwrite settings and credentials from the legacy project beside it.

The app uses SwiftUI and AppKit, SwiftTerm 1.19.0 for its PTY-backed terminal surface, and the system `/usr/bin/ssh` for transport. Profiles contain only Keychain references. Passwords, private-key contents, passphrases, and proxy secrets are not exported to JSON, passed on a command line, or put in logs.

## What is implemented

- Direct SSH and local shell tabs, reconnect policy, host-key review, app-managed `known_hosts`, and per-session AskPass IPC.
- Ordered jump paths, HTTP CONNECT and SOCKS5 proxies with optional credentials, and one shared route compiler for terminals, SFTP, SCP, and tunnels.
- Local, remote, dynamic, remote dynamic, local Unix-socket, and remote Unix-socket forwarding. The tunnel panel keeps listener creation and destination checks separate: local TCP and Unix checks connect through the listener, while remote forwarding checks the local destination separately. Independent tunnels remain visible in the menu bar and are stopped during confirmed app shutdown.
- A SwiftTerm terminal bridge with tabs, two-pane layouts, Unicode input, localized terminal-buffer search with previous, next, case-sensitive, regex, and whole-word controls, paste protection for OSC 52, user-controlled logs, session-log export to a user-selected local file with private permissions, and broadcast input that is off by default. A profile can open more than one independent SSH session. Broadcast offers explicit per-session selection plus Select All Connected, mirrors input only among checked ready sessions, and clears a target when it disconnects so reconnecting does not silently resume replication. Opt-in logs record direct, broadcast, and snippet input for each destination session. Twenty terminal themes apply foreground, background, selection, cursor, and ANSI palette colors through the terminal adapter.
- The terminal typography picker offers four bundled open-license fonts: D2 Coding, JetBrains Mono, Fira Code, and Hack. The settings window previews the selected bundled font with the active terminal palette before saving. The default D2 Coding includes Korean glyph coverage. The font files and licenses are app resources, so this setting does not depend on the user's installed macOS font collection.
- Structured SFTP v3 browsing and transfer operations. Directory listings do not parse `ls` output. The inspector supports direct remote-path entry, folder navigation, upload, download, recursive directory work, symlinks, permissions, selectable overwrite/skip/rename behavior, cancellation, and retry through the transfer queue. Single-file SFTP retries verify source metadata and the already transferred SHA-256 prefix before resuming a partial destination.
- Remote regular files can open as app-managed local editing copies. Editor saves remain local until the user explicitly selects Save to Remote, which fails closed if the remote source changed.
- SCP upload and download use the same generated route and credential policy as SFTP. osXterm forces SCP's SFTP transport mode and rejects unsafe legacy-SCP remote paths.
- Profile editing, tags, favorites, search, recent connections, SSH config import preview with explicit profile selection, safe profile export, tunnel editing, editable snippets, Korean and English presentation strings, app icon, About view, licenses, and an ad-hoc packaging path.

The checked-in project contains `osXterm.xcodeproj` with a shared `osXterm` scheme. Its app and test targets delegate to the pinned Swift package so Xcode and command-line builds use the same source graph and packaging scripts.

## User guide

Read the Korean [user guide](Docs/USER_GUIDE.md) for profiles, authentication, jump hosts, proxies, terminal workspace controls, broadcast input, tunnels, file transfers, session logs, and known validation limits.

## Requirements

- macOS 26 or newer on Apple Silicon.
- Xcode 26.6 or a compatible Xcode installation. The scripts select `/Applications/Xcode.app/Contents/Developer` when it exists.
- Docker Compose only for the isolated integration suite. It is not needed by people running the packaged app.

The current machine has Xcode installed but its license has not been accepted, and Docker is absent. That prevents a full build, live app run, integration run, DMG extraction run, and release artifact from being recorded as complete here. See [GOAL_STATUS.md](GOAL_STATUS.md) for exact evidence.

## Build and run

After the Xcode license has been accepted by the machine owner:

```sh
cd /Users/one393/Workspace/02-Area/osXterm/osXterm-next
Scripts/check-environment.sh
Scripts/package-app.sh
open .build/app/osXterm.app
```

The package script produces an arm64 `osXterm.app` with `osXtermAskPass`, `osXtermProxy`, icon resources, bundled terminal fonts and licenses in the SwiftPM resource bundle, and third-party notices. It signs the bundle ad hoc with `codesign --sign -`.

Create the local installer image with:

```sh
Scripts/create-dmg.sh
```

The output is `dist/osXterm-0.1.0-arm64.dmg`. It is not Developer ID signed or notarized and must not be described as a Gatekeeper-ready public distribution.

To build from Xcode, open `osXterm.xcodeproj` and select the shared `osXterm` scheme. The target runs the same package and bundle process as `Scripts/package-app.sh`.

## Verification

Run the complete release gate with:

```sh
Scripts/check-environment.sh --integration
Scripts/verify.sh
```

The verifier resolves the exact dependency graph, runs unit tests, creates ephemeral SSH credentials, starts the loopback-only Docker Compose fixture, runs core route and transfer integration cases, packages the app, creates the DMG, copies the app from the mounted image to a separate temporary path, verifies its ad-hoc signature and arm64 executable, and repeats the integration path with the packaged helpers.

`Scripts/verify-font-resources.sh` independently checks the checked-in font
hashes, license files, and Core Text PostScript-name registration. The complete
verifier runs it before resolving the package graph.

The fixture covers direct, one-hop, and two-hop routes, proxy-only and proxy-plus-jump routes, HTTP Basic and SOCKS5 user/password proxy authentication, password, encrypted key, agent, certificate, and keyboard-interactive SSH authentication, structured SFTP and SCP transfers, a 100 MiB SFTP resume with source metadata and prefix SHA-256 verification, port collisions, server forwarding rejection, TCP forwarding, SOCKS forwarding, Unix sockets, and remote auto-assigned ports. It only exposes service ports on `127.0.0.1`.

Read [Docs/TESTING.md](Docs/TESTING.md) before treating a release as verified. The user interface still needs a human visual pass for Korean input, interactive terminal applications, window sizes, light and dark appearances, and long-running multi-session use.

## Architecture and security

[Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) describes module boundaries and the process and credential model. The important boundaries are:

- `OsXtermCore` resolves a route once and generates a mode-0600 OpenSSH configuration for that route.
- The app, SFTP subsystem, SCP process, and tunnel process consume that one route configuration.
- `osXtermAskPass` and `osXtermProxy` obtain session-only credentials through a mode-0700 Unix-domain-socket broker with a random token.
- Runtime messages are sanitized before being shown as errors. Logs are opt-in, stored under Application Support with mode 0600, and exported through a staged private-file copy only after the user chooses a destination.

## Current known limitations

- The full integration and UI release gates have not run in this workspace because Docker is unavailable and the Xcode license is unaccepted.
- Resume is available for verified, interrupted single-file SFTP transfers. Recursive SFTP and SCP transfers restart rather than resume.
- Local editing copies are tracked only for the running app and are saved back only by explicit user action. Existing saved snippets run only after explicit user action, and variable values are kept in memory for that one run.
- A restored workspace restores tab and layout metadata only. It never claims that a remote shell survived an app restart.

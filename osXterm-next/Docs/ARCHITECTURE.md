# Architecture

`OsXtermCore` owns data contracts and connection behavior. UI code sends explicit intents to `CoreWorkspaceService`; it does not build separate `ssh`, `sftp`, `scp`, proxy, or tunnel command lines.

## Modules

| Module | Responsibility |
| --- | --- |
| `OsXtermCore` | Profiles, Keychain references, atomic documents, route resolution, OpenSSH argument/configuration generation, host-key records, SFTP v3 messages, transfer planning, tunnel state, and SSH config import. |
| `osXterm` | SwiftUI workspace, AppKit and SwiftTerm PTY surface, state presentation, host-key and credential dialogs, profile and tunnel editors, SFTP inspector, settings, and menu-bar tunnel controls. |
| `osXtermAskPass` | Receives one OpenSSH prompt and returns a session-scoped broker response. It writes no diagnostics. |
| `osXtermProxy` | Establishes HTTP CONNECT or SOCKS5 streams for `ProxyCommand`, including optional proxy authentication over the same broker. |
| `osXtermIntegrationRunner` | Calls the route compiler, SFTP transport and resume verifier, SCP plan, and tunnel compiler against the isolated Compose fixture. |

## Route and process boundary

`SSHRouteResolver` expands ordered jump references once, rejects cycles, missing profiles, duplicate hops, inner-hop proxies, and conflicting local proxy declarations. `OpenSSHCommandCompiler` then validates all route endpoints, writes a 0600 per-session configuration under a 0700 temporary directory, and starts a system executable with an argument array.

The same `ResolvedSSHRoute` and generated configuration are consumed by:

- interactive `/usr/bin/ssh` terminals;
- `ssh -s sftp` used by `SFTPProcessTransport`;
- `/usr/bin/scp -s` for file copies;
- `/usr/bin/ssh -N` for independent and session-owned tunnels.

No UI view independently combines profile data into a shell command. The only string rendered for shell interpretation is OpenSSH's required `ProxyCommand` value. Its helper path and all values are validated and shell-quoted by the compiler before being written into the private configuration file.

## Credential and host-key boundary

Profiles and exports contain `SecretReference` values only. `KeychainSecretStore` uses macOS Keychain for password, passphrase, interactive-secret, and proxy-secret values. At launch, `SessionCredentialBroker` copies only matching values into memory and creates a random-token Unix-domain socket inside a mode-0700 directory. The socket itself is mode 0600. Helpers receive its path and token, never an actual credential.

The app owns `Application Support/osXterm/known_hosts`. First contact is presented to the user through AskPass before `yes` is returned. A changed key produces a separate replacement flow that removes the old endpoint only after explicit approval. SFTP requires a known key once an SSH terminal has established trust.

## Transfer boundary

`SFTPClient` uses binary SFTP v3 frames, attributes, and handles. It does not parse human-readable `ls` output. Transfer planning validates file URLs, root restrictions, remote NUL boundaries, conflict decisions, source fingerprints, and conservative SCP path syntax. `SFTPResumeIntegrityVerifier` compares the SHA-256 digest of a local and remote partial prefix before any single-file retry appends. Recursive SFTP transfer preserves file names, including whitespace and Unicode, and represents symlinks through protocol messages.

SCP forces SFTP transport mode. Its process is retained by the transfer queue so cancellation terminates the actual child process. The queue state reducer distinguishes preparation, transfer, cancellation, retry, completion, and failure.

## State and user interface boundary

`CoreWorkspaceService` runs on the main actor for coherent presentation state while SFTP's actor and process I/O do their work outside the SwiftUI rendering path. A terminal is not marked connected just because a child process launched: OpenSSH output must show successful authentication or an interactive channel. A tunnel listener is tracked separately from a destination probe result.

Workspace restoration restores descriptors and layout metadata. It never restarts commands or macros and never represents a terminated remote shell as recovered. Every connect action creates an independent terminal session, so one profile can have multiple concurrent SSH processes. Broadcast input is empty by default. It activates only when the source session and at least one recipient are explicitly checked and ready, then mirrors the input to the other checked ready sessions.
The service removes a target when its process stops, it disconnects, or it enters
a non-ready authentication or failure state. A reconnect therefore requires an
explicit new broadcast selection.

`TerminalFont` stores a bundled font's PostScript name. At app launch,
`BundledTerminalFontRegistry` registers D2 Coding, JetBrains Mono, Fira Code,
and Hack from the SwiftPM resource bundle. The terminal adapter resolves the
chosen bundled font rather than looking it up in the user's font collection.
`TerminalTheme` offers 20 fixed ANSI palettes, with System dynamically
following the current macOS appearance. The terminal header's Find control
asks the adapter to invoke SwiftTerm's native Finder interface, so matching
and navigation operate on the actual terminal buffer rather than a copied log.
The terminal tab strip and pane header use macOS 26's glass material only for
navigation and control surfaces. `accessibilityReduceTransparency` keeps their
standard bar backgrounds, while inspector transitions honor
`accessibilityReduceMotion`.

Session logging is disabled by default. When enabled, active and future terminal descriptors record to `Application Support/osXterm/Logs` with a mode-0700 directory and mode-0600 files. The visible export action first flushes the current file and then uses `SecureFileExporter` on a utility task to stage a private copy beside the user-selected destination before replacing that destination.

SSH config import first keeps a parsed preview in memory. The preview displays importable profiles, supported route details, unsupported directive names, and parser diagnostics. The app persists only profile IDs explicitly selected from that preview, and the parser never evaluates `Match exec` or `ProxyCommand`.

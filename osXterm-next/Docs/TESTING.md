# Testing

## Complete release gate

Run every release check from the project root:

```sh
Scripts/verify.sh
```

The script selects Xcode when it is installed, resolves the fixed SwiftPM graph, runs the unit suite, starts the isolated Docker Compose environment, runs `osXtermIntegrationRunner`, packages an ad-hoc signed app, creates a DMG, mounts the DMG, copies the app to a separate temporary directory, checks the copied app's signature and arm64 main executable, and repeats integration checks with helpers taken from that copied app.

The generated app is ad-hoc signed only. Developer ID signing and notarization are intentionally outside this release gate.

## Integration fixture

`Scripts/run-integration-tests.sh` creates temporary integration keys under `Integration/fixtures`, which is ignored by Git. Compose exposes only loopback ports:

| Service | Host port |
| --- | --- |
| SSH jump 1 | 2222 |
| SSH jump 2 | 2223 |
| SSH target | 2224 |
| SSH forwarding-denied target | 2225 |
| SSH certificate-only target | 2226 |
| HTTP CONNECT proxy | 3128 |
| SOCKS5 proxy | 1080 |
| HTTP CONNECT Basic proxy | 3129 |
| SOCKS5 username/password proxy | 1081 |
| TCP echo | 18080 |

The runner calls `SSHRouteResolver`, `OpenSSHCommandCompiler`, `SFTPProcessTransport`, `SFTPClient`, `TransferPlanner`, and the generated SCP route. It does not count a hand-written SSH command as application verification.

Expected integration coverage:

- direct SSH, one-hop and two-hop jump routes;
- proxy-only and proxy-plus-two-hop routes;
- HTTP CONNECT and SOCKS5, with no authentication and with Basic or username/password authentication;
- password, encrypted private-key, SSH agent, OpenSSH certificate, and keyboard-interactive authentication;
- SFTP v3 Unicode and quoted file names, SFTP-backed SCP upload/download, and a 100 MiB partial-file resume that verifies source metadata, the partial prefix SHA-256, and the final streamed SHA-256 digest;
- local, remote, dynamic, remote dynamic, local Unix-socket, remote Unix-socket, remote port zero, port conflict, and server forwarding denial;
- data echo through each listener instead of process-launch inference.

## Required human pass

Before release, launch the extracted app and record screenshots for the connection, SFTP, and tunnel panels. Exercise Korean IME, copy and paste, terminal search, terminal resize, `vim`, `less`, and `top`, light and dark appearance, small and large windows, repeated connects and disconnects, and ten simultaneous sessions. Inspect Activity Monitor or equivalent evidence for residual helpers and tunnel processes after shutdown.

Do not record a release as passing from unit tests alone. A running SSH process is not a connected session, and a listener is not proof that the destination service is reachable.

## Current local evidence

- Core, app, helper, and integration-runner source typechecks passed with the installed Xcode toolchain.
- Swift test source syntax, shell script syntax, Compose YAML, Info.plist, icon container, and proxy Python syntax passed local static validation.
- A manually linked Swift Testing runner executed all 39 core tests outside the seatbelt sandbox, including the credential-broker Unix socket exchange. This is supplemental evidence only; the supported `swift test` gate remains unverified.
- The fixture credential preparation script ran and produced ignored test-only keys plus a valid user certificate.
- Full `swift test`, Compose integration, package build, DMG extraction, and UI pass are unverified in this workspace. Xcode reports an unaccepted license and Docker is not installed.

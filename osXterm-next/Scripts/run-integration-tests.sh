#!/bin/zsh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
compose_file="$project_dir/Integration/docker-compose.yml"
fixture_dir="$project_dir/Integration/fixtures"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

"$project_dir/Scripts/check-environment.sh" --integration

"$project_dir/Scripts/prepare-integration-fixture.sh"

cleanup() {
    docker compose -f "$compose_file" down --volumes --remove-orphans
}
trap cleanup EXIT

docker compose -f "$compose_file" up --build --detach

for attempt in {1..30}; do
    if nc -z 127.0.0.1 2222 >/dev/null 2>&1 \
        && nc -z 127.0.0.1 2223 >/dev/null 2>&1 \
        && nc -z 127.0.0.1 2224 >/dev/null 2>&1 \
        && nc -z 127.0.0.1 2225 >/dev/null 2>&1 \
        && nc -z 127.0.0.1 2226 >/dev/null 2>&1 \
        && nc -z 127.0.0.1 3128 >/dev/null 2>&1 \
        && nc -z 127.0.0.1 1080 >/dev/null 2>&1 \
        && nc -z 127.0.0.1 3129 >/dev/null 2>&1 \
        && nc -z 127.0.0.1 1081 >/dev/null 2>&1; then
        break
    fi
    if [[ "$attempt" == "30" ]]; then
        echo "Integration services did not become reachable." >&2
        docker compose -f "$compose_file" logs >&2
        exit 1
    fi
    sleep 1
done

cd "$project_dir"
if [[ -n "${OSXTERM_PROXY_HELPER:-}" ]]; then
    proxy_helper="$OSXTERM_PROXY_HELPER"
    if [[ ! -x "$proxy_helper" ]]; then
        echo "Configured packaged proxy helper is not executable: $proxy_helper" >&2
        exit 2
    fi
else
    swift build --product osXtermProxy
    swift build --product osXtermAskPass
    bin_dir="$(swift build --show-bin-path)"
    proxy_helper="$bin_dir/osXtermProxy"
fi
if [[ -n "${OSXTERM_ASKPASS_HELPER:-}" ]]; then
    askpass_helper="$OSXTERM_ASKPASS_HELPER"
    if [[ ! -x "$askpass_helper" ]]; then
        echo "Configured packaged AskPass helper is not executable: $askpass_helper" >&2
        exit 2
    fi
else
    if [[ -z "${bin_dir:-}" ]]; then
        swift build --product osXtermAskPass
        bin_dir="$(swift build --show-bin-path)"
    fi
    askpass_helper="$bin_dir/osXtermAskPass"
fi
OSXTERM_FIXTURE_DIRECTORY="$fixture_dir" \
OSXTERM_PROXY_HELPER="$proxy_helper" \
OSXTERM_ASKPASS_HELPER="$askpass_helper" \
OSXTERM_SSH1_PORT=2222 \
OSXTERM_SSH2_PORT=2223 \
OSXTERM_TARGET_PORT=2224 \
OSXTERM_RESTRICTED_TARGET_PORT=2225 \
OSXTERM_CERT_TARGET_PORT=2226 \
OSXTERM_HTTP_PROXY_PORT=3128 \
OSXTERM_SOCKS_PROXY_PORT=1080 \
OSXTERM_HTTP_AUTH_PROXY_PORT=3129 \
OSXTERM_SOCKS_AUTH_PROXY_PORT=1081 \
OSXTERM_ECHO_PORT=18080 \
swift run osXtermIntegrationRunner

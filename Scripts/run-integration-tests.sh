#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

SSHD_BIN="/usr/sbin/sshd"

WORK_DIR=""
TARGET_SSHD_PID=""
JUMP_SSHD_PID=""
AGENT_PID=""
AGENT_SOCKET=""
CHOSEN_PORT=""
HOLD_SECONDS="${OSXTERM_HOLD_SECONDS:-0}"

pass() {
    printf '[PASS] %s\n' "$1"
}

dump_diagnostics() {
    local log_file

    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] || return 0
    for log_file in "$WORK_DIR"/*.log; do
        [[ -f "$log_file" ]] || continue
        printf '\n--- %s ---\n' "$(basename "$log_file")" >&2
        tail -n 80 "$log_file" >&2 || true
    done
}

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

stop_process() {
    local process_id="${1:-}"

    [[ -n "$process_id" ]] || return 0
    if kill -0 "$process_id" >/dev/null 2>&1; then
        kill "$process_id" >/dev/null 2>&1 || true
        wait "$process_id" 2>/dev/null || true
    fi
}

cleanup() {
    local status=$?

    set +e
    stop_process "$TARGET_SSHD_PID"
    stop_process "$JUMP_SSHD_PID"
    stop_process "$AGENT_PID"

    if (( status != 0 )); then
        dump_diagnostics
    fi

    if [[ -n "$WORK_DIR" && "$WORK_DIR" == /tmp/osxterm-it.* && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT TERM HUP

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "Required tool is missing: $1"
}

port_is_available() {
    local port="$1"

    ! nc -z -G 1 127.0.0.1 "$port" >/dev/null 2>&1
}

choose_port() {
    local attempts=0
    local candidate
    local excluded
    local is_excluded

    while (( attempts < 200 )); do
        candidate=$((49152 + ((RANDOM + $$ + attempts * 997) % 15000)))
        is_excluded=0

        for excluded in "$@"; do
            if [[ "$candidate" == "$excluded" ]]; then
                is_excluded=1
                break
            fi
        done

        if (( is_excluded == 0 )) && port_is_available "$candidate"; then
            CHOSEN_PORT="$candidate"
            return 0
        fi

        attempts=$((attempts + 1))
    done

    fail "Could not find an unused loopback port in the dynamic port range"
}

wait_for_port() {
    local label="$1"
    local process_id="$2"
    local port="$3"
    local attempts=0

    while (( attempts < 100 )); do
        if nc -z -G 1 127.0.0.1 "$port" >/dev/null 2>&1; then
            return 0
        fi

        if ! kill -0 "$process_id" >/dev/null 2>&1; then
            wait "$process_id" 2>/dev/null || true
            fail "$label exited before listening on 127.0.0.1:$port"
        fi

        sleep 0.05
        attempts=$((attempts + 1))
    done

    fail "$label did not listen on 127.0.0.1:$port within five seconds"
}

write_sshd_config() {
    local output_path="$1"
    local port="$2"
    local host_key="$3"
    local authorized_keys="$4"
    local pid_file="$5"
    local current_user="$6"

    cat >"$output_path" <<EOF
Port $port
ListenAddress 127.0.0.1
AddressFamily inet
HostKey $host_key
PidFile $pid_file
AuthorizedKeysFile $authorized_keys
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
StrictModes no
UsePAM no
UseDNS no
AllowUsers $current_user
AllowTcpForwarding yes
AllowAgentForwarding no
GatewayPorts no
PermitTunnel no
X11Forwarding no
PermitUserEnvironment no
PermitTTY yes
PrintMotd no
LogLevel VERBOSE
Subsystem sftp internal-sftp
EOF
}

write_known_host() {
    local alias_name="$1"
    local public_key_path="$2"
    local output_path="$3"
    local key_type
    local key_data
    local ignored

    IFS=' ' read -r key_type key_data ignored <"$public_key_path"
    [[ -n "$key_type" && -n "$key_data" ]] || fail "Could not read host public key: $public_key_path"
    printf '%s %s %s\n' "$alias_name" "$key_type" "$key_data" >>"$output_path"
}

run_ssh() {
    SSH_AUTH_SOCK="$AGENT_SOCKET" SSH_AGENT_PID="$AGENT_PID" \
        ssh -F "$CLIENT_CONFIG" "$@"
}

run_sftp() {
    SSH_AUTH_SOCK="$AGENT_SOCKET" SSH_AGENT_PID="$AGENT_PID" \
        sftp -F "$CLIENT_CONFIG" "$@"
}

for tool in awk basename cat cmp grep id kill mktemp mkdir nc rm sed sleep ssh ssh-add ssh-agent ssh-keygen sshd sftp tail; do
    require_tool "$tool"
done

CURRENT_UID="$(id -u)"
CURRENT_USER="$(id -un)"
[[ "$CURRENT_UID" != "0" ]] || fail "Run this integration harness as an unprivileged macOS user"

WORK_DIR="$(mktemp -d /tmp/osxterm-it.XXXXXX)"
[[ "$WORK_DIR" == /tmp/osxterm-it.* && -d "$WORK_DIR" ]] || fail "mktemp returned an unexpected path"

TARGET_DIR="$WORK_DIR/target"
JUMP_DIR="$WORK_DIR/jump"
REMOTE_DIR="$WORK_DIR/remote"
mkdir -p "$TARGET_DIR" "$JUMP_DIR" "$REMOTE_DIR"

choose_port
TARGET_PORT="$CHOSEN_PORT"
choose_port "$TARGET_PORT"
JUMP_PORT="$CHOSEN_PORT"

TARGET_HOST_KEY="$TARGET_DIR/ssh_host_ed25519_key"
JUMP_HOST_KEY="$JUMP_DIR/ssh_host_ed25519_key"
CLIENT_KEY="$WORK_DIR/client_ed25519"
TARGET_AUTHORIZED_KEYS="$TARGET_DIR/authorized_keys"
JUMP_AUTHORIZED_KEYS="$JUMP_DIR/authorized_keys"

ssh-keygen -q -t ed25519 -N "" -C "osXterm target host" -f "$TARGET_HOST_KEY"
ssh-keygen -q -t ed25519 -N "" -C "osXterm jump host" -f "$JUMP_HOST_KEY"
ssh-keygen -q -t ed25519 -N "" -C "osXterm integration agent key" -f "$CLIENT_KEY"

cat "$CLIENT_KEY.pub" >"$TARGET_AUTHORIZED_KEYS"
cat "$CLIENT_KEY.pub" >"$JUMP_AUTHORIZED_KEYS"

TARGET_CONFIG="$TARGET_DIR/sshd_config"
JUMP_CONFIG="$JUMP_DIR/sshd_config"
TARGET_LOG="$WORK_DIR/target-sshd.log"
JUMP_LOG="$WORK_DIR/jump-sshd.log"

write_sshd_config \
    "$TARGET_CONFIG" \
    "$TARGET_PORT" \
    "$TARGET_HOST_KEY" \
    "$TARGET_AUTHORIZED_KEYS" \
    "$TARGET_DIR/sshd.pid" \
    "$CURRENT_USER"
write_sshd_config \
    "$JUMP_CONFIG" \
    "$JUMP_PORT" \
    "$JUMP_HOST_KEY" \
    "$JUMP_AUTHORIZED_KEYS" \
    "$JUMP_DIR/sshd.pid" \
    "$CURRENT_USER"

"$SSHD_BIN" -t -f "$TARGET_CONFIG"
"$SSHD_BIN" -t -f "$JUMP_CONFIG"

"$SSHD_BIN" -D -e -f "$TARGET_CONFIG" >"$TARGET_LOG" 2>&1 &
TARGET_SSHD_PID=$!
"$SSHD_BIN" -D -e -f "$JUMP_CONFIG" >"$JUMP_LOG" 2>&1 &
JUMP_SSHD_PID=$!

wait_for_port "target sshd" "$TARGET_SSHD_PID" "$TARGET_PORT"
wait_for_port "jump sshd" "$JUMP_SSHD_PID" "$JUMP_PORT"
pass "Two unprivileged loopback sshd instances are listening"

KNOWN_HOSTS="$WORK_DIR/known_hosts"
: >"$KNOWN_HOSTS"
write_known_host "osxterm-it-target" "$TARGET_HOST_KEY.pub" "$KNOWN_HOSTS"
write_known_host "osxterm-it-jump" "$JUMP_HOST_KEY.pub" "$KNOWN_HOSTS"

AGENT_SOCKET="$WORK_DIR/agent.sock"
AGENT_START_LOG="$WORK_DIR/agent-start.log"
ssh-agent -a "$AGENT_SOCKET" -s >"$AGENT_START_LOG"
AGENT_PID="$(sed -n 's/^SSH_AGENT_PID=\([0-9][0-9]*\);.*/\1/p' "$AGENT_START_LOG")"
[[ "$AGENT_PID" =~ ^[0-9]+$ ]] || fail "Could not determine the dedicated ssh-agent PID"
[[ -S "$AGENT_SOCKET" ]] || fail "Dedicated ssh-agent socket was not created"

SSH_AUTH_SOCK="$AGENT_SOCKET" SSH_AGENT_PID="$AGENT_PID" ssh-add "$CLIENT_KEY" \
    >"$WORK_DIR/ssh-add.log" 2>&1
EXPECTED_FINGERPRINT="$(ssh-keygen -lf "$CLIENT_KEY.pub" | awk '{print $2}')"
AGENT_IDENTITIES="$(SSH_AUTH_SOCK="$AGENT_SOCKET" SSH_AGENT_PID="$AGENT_PID" ssh-add -l)"
[[ "$AGENT_IDENTITIES" == *"$EXPECTED_FINGERPRINT"* ]] \
    || fail "The generated client key is not available from the dedicated ssh-agent"

rm -f -- "$CLIENT_KEY"
[[ ! -e "$CLIENT_KEY" ]] || fail "Could not remove the on-disk client private key after loading the agent"
pass "Dedicated ssh-agent holds the only usable client private key"

CLIENT_CONFIG="$WORK_DIR/ssh_config"
cat >"$CLIENT_CONFIG" <<EOF
Host osxterm-it-jump
    HostName 127.0.0.1
    Port $JUMP_PORT
    User $CURRENT_USER
    HostKeyAlias osxterm-it-jump

Host osxterm-it-target
    HostName 127.0.0.1
    Port $TARGET_PORT
    User $CURRENT_USER
    HostKeyAlias osxterm-it-target

Host osxterm-it-target-via-jump
    HostName 127.0.0.1
    Port $TARGET_PORT
    User $CURRENT_USER
    HostKeyAlias osxterm-it-target
    ProxyJump osxterm-it-jump

Host *
    IdentityAgent $AGENT_SOCKET
    BatchMode yes
    PreferredAuthentications publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    GSSAPIAuthentication no
    AddKeysToAgent no
    ForwardAgent no
    StrictHostKeyChecking yes
    CheckHostIP no
    UserKnownHostsFile $KNOWN_HOSTS
    GlobalKnownHostsFile /dev/null
    ConnectTimeout 5
    ConnectionAttempts 1
    ServerAliveInterval 2
    ServerAliveCountMax 3
    LogLevel ERROR
EOF

DIRECT_OUTPUT="$(run_ssh osxterm-it-target 'printf "%s\n" "osxterm-direct-ok"')"
[[ "$DIRECT_OUTPUT" == "osxterm-direct-ok" ]] || fail "Direct SSH command returned unexpected output"
pass "Direct SSH authenticated through the dedicated ssh-agent"

DIRECT_UPLOAD="$WORK_DIR/direct-upload.txt"
DIRECT_DOWNLOAD="$WORK_DIR/direct-download.txt"
DIRECT_REMOTE="$REMOTE_DIR/direct-remote.txt"
DIRECT_BATCH="$WORK_DIR/direct-sftp.batch"
printf 'osXterm direct SFTP payload %s\n' "$EXPECTED_FINGERPRINT" >"$DIRECT_UPLOAD"
printf 'put %s %s\nget %s %s\n' \
    "$DIRECT_UPLOAD" \
    "$DIRECT_REMOTE" \
    "$DIRECT_REMOTE" \
    "$DIRECT_DOWNLOAD" >"$DIRECT_BATCH"

run_sftp -b "$DIRECT_BATCH" osxterm-it-target >"$WORK_DIR/direct-sftp.log" 2>&1
cmp -s "$DIRECT_UPLOAD" "$DIRECT_DOWNLOAD" || fail "Direct SFTP upload and download content differs"
pass "Direct SFTP upload and download preserved file content"

JUMP_OUTPUT="$(run_ssh osxterm-it-target-via-jump 'printf "%s\n" "osxterm-jump-ok"')"
[[ "$JUMP_OUTPUT" == "osxterm-jump-ok" ]] || fail "ProxyJump SSH command returned unexpected output"
grep -q "Accepted publickey for $CURRENT_USER" "$JUMP_LOG" \
    || fail "The jump sshd log does not show public-key authentication"
pass "ProxyJump reached the target through the jump sshd"

JUMP_UPLOAD="$WORK_DIR/jump-upload.txt"
JUMP_DOWNLOAD="$WORK_DIR/jump-download.txt"
JUMP_REMOTE="$REMOTE_DIR/jump-remote.txt"
JUMP_BATCH="$WORK_DIR/jump-sftp.batch"
printf 'osXterm ProxyJump SFTP payload %s\n' "$EXPECTED_FINGERPRINT" >"$JUMP_UPLOAD"
printf 'put %s %s\nget %s %s\n' \
    "$JUMP_UPLOAD" \
    "$JUMP_REMOTE" \
    "$JUMP_REMOTE" \
    "$JUMP_DOWNLOAD" >"$JUMP_BATCH"

run_sftp -b "$JUMP_BATCH" osxterm-it-target-via-jump >"$WORK_DIR/jump-sftp.log" 2>&1
cmp -s "$JUMP_UPLOAD" "$JUMP_DOWNLOAD" || fail "ProxyJump SFTP upload and download content differs"
pass "SFTP upload and download succeeded through ProxyJump"

printf '\nAll osXterm local integration tests passed.\n'
printf 'Validated ports: target=%s jump=%s\n' \
    "$TARGET_PORT" \
    "$JUMP_PORT"

if [[ "$HOLD_SECONDS" =~ ^[0-9]+$ ]] \
    && (( HOLD_SECONDS > 0 )); then
    printf 'Fixture target: host=127.0.0.1 port=%s user=%s\n' \
        "$TARGET_PORT" \
        "$CURRENT_USER"
    printf 'Fixture jump: host=127.0.0.1 port=%s user=%s\n' \
        "$JUMP_PORT" \
        "$CURRENT_USER"
    printf 'Fixture agent socket: %s\n' "$AGENT_SOCKET"
    printf 'Fixture remote directory: %s\n' "$REMOTE_DIR"
    printf 'Holding fixture for %s seconds.\n' "$HOLD_SECONDS"
    sleep "$HOLD_SECONDS"
fi

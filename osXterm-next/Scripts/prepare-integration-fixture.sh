#!/bin/zsh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$project_dir/Integration/fixtures"
private_key="$fixture_dir/id_ed25519"
encrypted_private_key="$fixture_dir/id_ed25519_encrypted"
user_ca_key="$fixture_dir/user_ca"
certificate_file="$fixture_dir/id_ed25519-cert.pub"

mkdir -p "$fixture_dir"
chmod 700 "$fixture_dir"

if [[ ! -f "$private_key" ]]; then
    ssh-keygen -q -t ed25519 -N "" -f "$private_key" -C "osxterm-integration"
fi

if [[ ! -f "$encrypted_private_key" ]]; then
    ssh-keygen -q -t ed25519 -N "integration-key-passphrase" -f "$encrypted_private_key" -C "osxterm-encrypted-integration"
fi

if [[ ! -f "$user_ca_key" ]]; then
    ssh-keygen -q -t ed25519 -N "" -f "$user_ca_key" -C "osxterm-integration-user-ca"
fi

ssh-keygen -q -s "$user_ca_key" -I "osxterm-integration" -n osxterm "$private_key.pub"

{
    cat "$private_key.pub"
    cat "$encrypted_private_key.pub"
} > "$fixture_dir/authorized_keys"
cp "$user_ca_key.pub" "$fixture_dir/trusted_user_ca_keys"
: > "$fixture_dir/known_hosts"
chmod 600 "$private_key" "$encrypted_private_key" "$user_ca_key" "$fixture_dir/authorized_keys" "$fixture_dir/known_hosts"
chmod 644 "$certificate_file" "$fixture_dir/trusted_user_ca_keys"

echo "Prepared isolated integration fixture credentials in $fixture_dir"

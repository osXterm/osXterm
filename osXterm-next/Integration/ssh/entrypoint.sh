#!/bin/sh
set -eu

allow_tcp_forwarding="${ALLOW_TCP_FORWARDING:-yes}"
allow_authorized_keys="${ALLOW_AUTHORIZED_KEYS:-yes}"

if [ "$allow_authorized_keys" = "yes" ]; then
    authorized_keys_file=".ssh/authorized_keys"
else
    authorized_keys_file="none"
fi

cat > /etc/ssh/sshd_config <<EOF
Port 2222
ListenAddress 0.0.0.0
Protocol 2
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
PermitRootLogin no
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
ChallengeResponseAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile ${authorized_keys_file}
TrustedUserCAKeys /home/osxterm/.ssh/trusted_user_ca_keys
AllowUsers osxterm
AllowTcpForwarding ${allow_tcp_forwarding}
AllowStreamLocalForwarding yes
GatewayPorts clientspecified
PermitOpen any
X11Forwarding no
PrintMotd no
Subsystem sftp /usr/lib/openssh/sftp-server
LogLevel VERBOSE
EOF

chmod 600 /home/osxterm/.ssh/authorized_keys 2>/dev/null || true
chown osxterm:osxterm /home/osxterm/.ssh/authorized_keys 2>/dev/null || true
chmod 600 /home/osxterm/.ssh/trusted_user_ca_keys 2>/dev/null || true
chown osxterm:osxterm /home/osxterm/.ssh/trusted_user_ca_keys 2>/dev/null || true
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config

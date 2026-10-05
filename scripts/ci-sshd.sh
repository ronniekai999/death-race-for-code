#!/bin/bash
# A throwaway sshd for SSHKit's integration tests, on loopback only. Linux CI runs it inside
# its container as root; it also works in a Linux dev container. Never on a Mac.
#
# Two users with passwords, and one server listening on two loopback addresses, so a test
# can jump through "one host" to reach "another":
#
#   127.0.0.1:2222   wrldjump   / jump-pass
#   127.0.0.2:2222   wrldtarget / target-pass
#
# Prints the environment the tests read (DEATHRACE_SSHD…); `eval "$(scripts/ci-sshd.sh)"`
# exports it. Tests that need sshd are skipped without DEATHRACE_SSHD.

set -euo pipefail

if [ "$(uname -s)" != "Linux" ] || [ "$(id -u)" != "0" ]; then
    echo "ci-sshd.sh is for a Linux container, as root." >&2
    exit 1
fi

if ! command -v sshd >/dev/null; then
    apt-get update -qq >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server openssh-client >&2
fi

mkdir -p /run/sshd
ssh-keygen -A >&2
# pam_loginuid fails in containers, and with it every PAM login.
if [ -f /etc/pam.d/sshd ]; then
    sed -i -E 's/^session\s+required\s+pam_loginuid\.so/session optional pam_loginuid.so/' /etc/pam.d/sshd
fi

for pair in wrldjump:jump-pass wrldtarget:target-pass; do
    user="${pair%%:*}"
    id "$user" >/dev/null 2>&1 || useradd -m -s /bin/sh "$user"
    echo "$pair" | chpasswd
done

# A throwaway key authorizing wrldtarget, so Maze's SFTP round-trip test connects with a key
# and needs no askpass. Loopback, root-only, torn down with the container.
testkey=/run/wrld-test-key
[ -f "$testkey" ] || ssh-keygen -t ed25519 -N "" -f "$testkey" -C wrld-sftp-test >&2
install -d -m 700 -o wrldtarget -g wrldtarget /home/wrldtarget/.ssh
install -m 600 -o wrldtarget -g wrldtarget "$testkey.pub" /home/wrldtarget/.ssh/authorized_keys
chmod 600 "$testkey"

config=/run/sshd-wrld.conf
cat >"$config" <<'EOF'
Port 2222
ListenAddress 127.0.0.1
ListenAddress 127.0.0.2
HostKey /etc/ssh/ssh_host_ed25519_key
UsePAM yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin no
AllowTcpForwarding yes
GatewayPorts no
PidFile /run/sshd-wrld.pid
# Parallel test runs open many connections at once.
MaxStartups 100:30:200
MaxSessions 50
# Maze speaks SFTP over this; internal-sftp needs no external binary.
Subsystem sftp internal-sftp
LogLevel VERBOSE
EOF

if [ -f /run/sshd-wrld.pid ] && kill -0 "$(cat /run/sshd-wrld.pid)" 2>/dev/null; then
    kill "$(cat /run/sshd-wrld.pid)" || true
    sleep 0.5
fi
/usr/sbin/sshd -f "$config" -E /tmp/sshd-wrld.log

# Wait until it answers.
for _ in $(seq 1 50); do
    if (exec 3<>/dev/tcp/127.0.0.1/2222) 2>/dev/null; then break; fi
    sleep 0.1
done

echo "export DEATHRACE_SSHD=127.0.0.1:2222"
echo "export DEATHRACE_SSHD_TARGET=127.0.0.2:2222"
echo "export DEATHRACE_SSHD_JUMP_USER=wrldjump DEATHRACE_SSHD_JUMP_PASSWORD=jump-pass"
echo "export DEATHRACE_SSHD_TARGET_USER=wrldtarget DEATHRACE_SSHD_TARGET_PASSWORD=target-pass"
echo "export DEATHRACE_SSHD_KEY=$testkey"
echo "export DEATHRACE_SSHD_LOG=/tmp/sshd-wrld.log"

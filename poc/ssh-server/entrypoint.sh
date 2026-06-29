#!/usr/bin/env bash
# Start sshd in the foreground, logging to stderr so `docker logs ssh-server`
# captures the authentication events the use cases assert on.
set -e

# Default host keys so sshd can start before the certified key is installed.
ssh-keygen -A >/dev/null 2>&1 || true
mkdir -p /run/sshd

exec /usr/sbin/sshd -D -e

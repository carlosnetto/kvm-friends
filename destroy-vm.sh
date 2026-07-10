#!/usr/bin/env bash
# destroy-vm.sh — irreversibly destroy a VM: domain, disk, seed, password.
#
# Usage: ./destroy-vm.sh <vm-name> [--yes]
# Interactive: asks you to retype the VM name. --yes skips the prompt
# (required when running non-interactively).
set -euo pipefail
cd "$(dirname "$0")"
V() { virsh --connect qemu:///system "$@"; }
err() { echo "ERROR: $*" >&2; exit 1; }

NAME=${1:-}; [ -n "$NAME" ] || err "usage: ./destroy-vm.sh <vm-name> [--yes]"
YES=${2:-}

V dominfo "$NAME" >/dev/null 2>&1 || err "no VM named '$NAME'"
STATE=$(V domstate "$NAME" | head -1)

# capture the IP before killing it, to clean known_hosts afterwards
IP=
[ "$STATE" = running ] && \
  IP=$(V domifaddr "$NAME" | awk '/ipv4/ {sub(/\/.*/,"",$4); print $4; exit}')

echo "About to DESTROY '$NAME' (state: $STATE${IP:+, ip: $IP}) — disk, seed"
echo "and console password included. This cannot be undone."
if [ "$YES" != "--yes" ]; then
  [ -t 0 ] || err "non-interactive run: pass --yes to confirm"
  read -rp "Type the VM name to confirm: " CONFIRM
  [ "$CONFIRM" = "$NAME" ] || err "name mismatch — nothing destroyed"
fi

[ "$STATE" = running ] && V destroy "$NAME"
V undefine "$NAME"
rm -f "$NAME.qcow2" "$NAME-seed.img" "$NAME-console-password.txt"
[ -n "$IP" ] && ssh-keygen -R "$IP" >/dev/null 2>&1 || true

echo "Destroyed '$NAME'. If it was on a tailnet, remove it from the"
echo "Tailscale admin console too (it will show as offline)."

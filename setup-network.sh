#!/usr/bin/env bash
# setup-network.sh — one-time network isolation setup (see CLAUDE.md,
# "Network isolation"). Idempotent: safe to re-run to update the filter or
# network definition. Refuses to run while a VM is running, since
# net-destroy would cut its networking.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

V()    { virsh --connect qemu:///system "$@"; }
err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo; echo "==> $*"; }

[ -z "$(V list --name)" ] || err "a VM is running — shut it down first (net-destroy would cut its network)"

# ---- this host's own LAN/public subnet -------------------------------------
# Varies per host: a home router's private range, or (colo/VPS) a public
# /24 directly on the NIC. Computed fresh each run so the filter always
# matches wherever this host actually is.
IFACE=$(ip route show default | awk '{print $5; exit}')
[ -n "$IFACE" ] || err "couldn't determine the default route interface"
CIDR=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')
[ -n "$CIDR" ] || err "couldn't determine $IFACE's IPv4 address"
read -r NET BITS < <(python3 -c "
import ipaddress
n = ipaddress.ip_interface('$CIDR').network
print(n.network_address, n.prefixlen)
")
info "Host subnet on $IFACE: $NET/$BITS — guests will be blocked from it"

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
sed "s|@HOST_LAN_RULE@|<rule action='drop' direction='out' priority='503'><all dstipaddr='$NET' dstipmask='$BITS' state='NEW'/></rule>|" \
  isolate-guest.xml > "$TMP"

info "Defining nwfilter 'isolate-guest'"
# libvirt won't update an existing filter by name alone (it requires a
# matching <uuid>, which this template doesn't carry) — undefine first.
# Fails loudly if a still-defined (even shut-off) VM references it; if so,
# undefine that VM first or leave the old filter in place.
V nwfilter-undefine isolate-guest >/dev/null 2>&1 || true
V nwfilter-define "$TMP"

info "Replacing the default network (host DNS off, public resolvers only)"
V net-destroy default >/dev/null 2>&1 || true
V net-undefine default >/dev/null 2>&1 || true
V net-define default-net.xml
V net-autostart default
V net-start default

info "Done. Verify with the isolation check in CLAUDE.md after creating a VM."

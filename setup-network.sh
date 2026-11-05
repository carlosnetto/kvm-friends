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

usage() {
  cat <<USAGE
usage: ./setup-network.sh [--derp <ip> | --no-derp]
  --derp <ip>  let guests reach a private Tailscale DERP relay at <ip> (tcp/443,
               udp/3478) and nothing else on the LAN; remembered for later runs
  --no-derp    remove that exception (full isolation)
With VMs running, only the filter is updated (live, in place); the network
definition is replaced only when every VM is shut off.
USAGE
}

# The relay is per host, so it is remembered outside the repo (the repo is shared).
DERP_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/kvm-friends/derp-relay"
DERP=""; [ -f "$DERP_FILE" ] && DERP=$(tr -d '[:space:]' < "$DERP_FILE")
while [ $# -gt 0 ]; do
  case "$1" in
    --derp)    [ $# -ge 2 ] || { usage; exit 2; }; DERP="$2"; shift 2 ;;
    --no-derp) DERP=""; rm -f "$DERP_FILE"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         usage; exit 2 ;;
  esac
done
if [ -n "$DERP" ]; then
  python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]).version == 4 else 1)' "$DERP" 2>/dev/null \
    || err "--derp needs an IPv4 address, got '$DERP'"
  mkdir -p "$(dirname "$DERP_FILE")"; echo "$DERP" > "$DERP_FILE"
fi

RUNNING="$(V list --name | sed '/^$/d')"

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
# priority 506: after the blanket private ranges in the template (500-505).
# Redundant when this host's LAN is itself private — the point of the rule is
# the colo/VPS case, where the host sits on a public /24 that no blanket
# RFC1918 rule can cover.
DERP_RULES=""
if [ -n "$DERP" ]; then
  info "DERP relay exception: guests may open tcp/443 and udp/3478 to $DERP only"
  DERP_RULES="<rule action='accept' direction='out' priority='400'><tcp dstipaddr='$DERP' dstportstart='443' dstportend='443' state='NEW'/></rule><rule action='accept' direction='out' priority='401'><udp dstipaddr='$DERP' dstportstart='3478' dstportend='3478'/></rule>"
fi
sed -e "s|@HOST_LAN_RULE@|<rule action='drop' direction='out' priority='506'><all dstipaddr='$NET' dstipmask='$BITS' state='NEW'/></rule>|" \
    -e "s|@DERP_RULES@|$DERP_RULES|" \
  isolate-guest.xml > "$TMP"

info "Defining nwfilter 'isolate-guest'"
# libvirt updates an existing filter only when the definition carries its
# <uuid>. Reusing that uuid updates it IN PLACE, and libvirt re-applies it to
# every running guest — so the filter can change without stopping VMs. (The
# template carries no uuid, to stay portable across hosts.)
UUID=$(V nwfilter-dumpxml isolate-guest 2>/dev/null | sed -n 's|.*<uuid>\(.*\)</uuid>.*|\1|p' | head -1)
if [ -n "$UUID" ]; then
  sed -i "s|<filter name='isolate-guest' chain='root'>|<filter name='isolate-guest' chain='root'>\n  <uuid>$UUID</uuid>|" "$TMP"
fi
V nwfilter-define "$TMP"

if [ -n "$RUNNING" ]; then
  info "VMs running ($(echo $RUNNING)): filter updated live; the default network is left as is"
  echo "    (to replace the network definition too, shut every VM down and re-run)"
  exit 0
fi

info "Replacing the default network (host DNS off, public resolvers only)"
V net-destroy default >/dev/null 2>&1 || true
V net-undefine default >/dev/null 2>&1 || true
V net-define default-net.xml
V net-autostart default
V net-start default

info "Done. Verify with the isolation check in CLAUDE.md after creating a VM."

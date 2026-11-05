#!/usr/bin/env bash
# setup-derper.sh — a private Tailscale DERP relay on this host, for its LAN.
#
# WHY. Guests are isolated (setup-network.sh): they reach each other only over Tailscale, and
# because each sits behind its host's NAT and the site's router, Tailscale cannot open a direct
# path between guests on different hosts — every byte goes through a PUBLIC relay over the
# internet. A relay on the LAN keeps that traffic on the LAN. The guests reach it OUTBOUND only
# (setup-network.sh --derp <this host's LAN ip> on each host); nothing reaches into them.
#
# What it does (idempotent; re-run to update the binary or the allowed networks):
#   - installs derper as a systemd service: TLS on tcp/443 (cert from this host's tailnet name via
#     `tailscale cert`), STUN on udp/3478, --verify-clients (only nodes of this tailnet may use it);
#   - renews the certificate monthly (timer, Persistent=true);
#   - opens tcp/443 and udp/3478 in ufw to the --allow networks only.
#
# Then add the relay to the tailnet policy (admin console → Access controls → JSON editor),
# as a top-level "derpMap" — see CLAUDE.md, "Private DERP relay".
#
#   sudo ./setup-derper.sh                                   # allow this host's LAN + its guests
#   sudo ./setup-derper.sh --allow 192.168.68.0/22 --allow 192.168.122.0/24
#   sudo ./setup-derper.sh --binary /path/to/derper
#
# The binary is not in this repo (26 MB, gitignored). Build it once, matching this host's
# tailscale version, on any machine with Go:
#   GOBIN="$PWD" go install tailscale.com/cmd/derper@v$(tailscale version | head -1)
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo; echo "==> $*"; }
usage() { sed -n '/^#   sudo/,/^#   sudo .*--binary/p' "$0" | sed 's/^# *//'; }

BIN="./derper"; ALLOW=()
while [ $# -gt 0 ]; do
  case "$1" in
    --allow)  [ $# -ge 2 ] || { usage; exit 2; }; ALLOW+=("$2"); shift 2 ;;
    --binary) [ $# -ge 2 ] || { usage; exit 2; }; BIN="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[ "$(id -u)" = 0 ] || err "run with sudo"
command -v tailscale >/dev/null || err "tailscale is not installed on this host"
[ -x "$BIN" ] || err "no derper binary at $BIN — build it (see the header) or pass --binary"

# This host's tailnet name: the certificate and the derpMap entry both use it.
HOST=$(tailscale status --self --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
[ -n "$HOST" ] || err "couldn't read this host's tailnet name (is tailscale up?)"

# Default allow-list: this host's LAN (default-route subnet) + its own guests (libvirt default net).
if [ ${#ALLOW[@]} -eq 0 ]; then
  IFACE=$(ip route show default | awk '{print $5; exit}')
  LAN=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' \
        "$(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')")
  ALLOW=("$LAN" 192.168.122.0/24)
fi
for net in "${ALLOW[@]}"; do
  python3 -c 'import ipaddress,sys; ipaddress.ip_network(sys.argv[1])' "$net" 2>/dev/null \
    || err "--allow needs a network in CIDR form, got '$net'"
done

DIR=/etc/derper
info "derper for $HOST"
install -m 0755 "$BIN" /usr/local/bin/derper
install -d -m 0750 "$DIR"

# TLS from the tailnet. Needs "HTTPS Certificates" enabled in the admin console (DNS page).
# derper --certmode manual reads <hostname>.crt / <hostname>.key from --certdir.
tailscale cert --cert-file "$DIR/$HOST.crt" --key-file "$DIR/$HOST.key" "$HOST"
chmod 0640 "$DIR/$HOST.key"

cat > /etc/systemd/system/derper.service <<UNIT
[Unit]
Description=Tailscale DERP relay (private, LAN)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/derper -hostname $HOST -certmode manual -certdir $DIR -a :443 -stun-port 3478 -verify-clients
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$DIR
# derper keeps its own key in /var/lib/derper; ProtectSystem=strict would make it read-only.
StateDirectory=derper

[Install]
WantedBy=multi-user.target
UNIT

# tailscale certs last 90 days: renew monthly and restart the relay.
cat > /etc/systemd/system/derper-cert.service <<UNIT
[Unit]
Description=Renew the DERP relay certificate
[Service]
Type=oneshot
ExecStart=/usr/bin/tailscale cert --cert-file $DIR/$HOST.crt --key-file $DIR/$HOST.key $HOST
ExecStartPost=/usr/bin/systemctl restart derper.service
UNIT
cat > /etc/systemd/system/derper-cert.timer <<UNIT
[Unit]
Description=Monthly DERP certificate renewal
[Timer]
OnCalendar=monthly
Persistent=true
[Install]
WantedBy=timers.target
UNIT

# ufw (harden-host.sh) denies all inbound: open the relay's two ports to the allowed networks only.
# ufw skips a rule it already has, so re-running adds nothing twice.
if command -v ufw >/dev/null 2>&1; then
  info "ufw: tcp/443 and udp/3478 from ${ALLOW[*]}"
  for SRC in "${ALLOW[@]}"; do
    ufw allow from "$SRC" to any port 443 proto tcp comment 'derper (DERP)'
    ufw allow from "$SRC" to any port 3478 proto udp comment 'derper (STUN)'
  done
fi

systemctl daemon-reload
systemctl enable --now derper.service derper-cert.timer
systemctl restart derper.service
sleep 2
systemctl --no-pager --lines=5 status derper.service || true

LANIP=$(ip -4 -o addr show dev "$(ip route show default | awk '{print $5; exit}')" | awk '{print $4; exit}' | cut -d/ -f1)
info "DERP relay up on $HOST ($LANIP): tcp/443, udp/3478"
echo "    next: on each host whose guests should use it:  ./setup-network.sh --derp $LANIP"
echo "          and the tailnet policy derpMap (CLAUDE.md, \"Private DERP relay\")"

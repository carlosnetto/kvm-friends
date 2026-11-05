#!/usr/bin/env bash
# harden-host.sh — key-only SSH, and ufw default-deny inbound with two ways in:
#   - Tailscale (tailscale0), always;
#   - this host's own LAN, when that LAN is PRIVATE (RFC1918, behind a router):
#     everything inbound from it, so the host is reachable like any machine on
#     the LAN. On a colo/VPS box whose NIC sits on a PUBLIC subnet (other
#     tenants) the LAN rule is skipped and the host stays Tailscale-only, with
#     the provider's out-of-band KVM/IPMI console as the fallback.
# This firewall protects the host from the network. It is NOT what isolates the
# guests: isolate-guest (setup-network.sh) drops every connection a guest opens
# to the host, its LAN and every private range, before it reaches ufw.
# Idempotent: safe to re-run.
#
# Does NOT touch local/console password login (getty+PAM) — only sshd.
# `sudo` and console passwords keep working exactly as before; this only
# stops the network SSH daemon from accepting passwords or reaching the
# public internet.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

info() { echo; echo "==> $*"; }
err()  { echo "ERROR: $*" >&2; exit 1; }

TS_IFACE=tailscale0

# This host's default-route subnet (same computation as setup-network.sh), and
# whether it is a private LAN the host may be reached from.
IFACE=$(ip route show default | awk '{print $5; exit}')
[ -n "$IFACE" ] || err "couldn't determine the default route interface"
CIDR=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')
[ -n "$CIDR" ] || err "couldn't determine $IFACE's IPv4 address"
read -r LAN LAN_PRIVATE < <(python3 -c "
import ipaddress
n = ipaddress.ip_interface('$CIDR').network
private = any(n.subnet_of(ipaddress.ip_network(r)) for r in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'))
print(n, 'yes' if private else 'no')
")

# ---- 0. Safety checks -------------------------------------------------
# Refuse to run at all unless Tailscale is actually up and this very
# session is coming in over it, over the private LAN (which stays open), or
# from the local/KVM console — otherwise this script would sever the session
# running it.
ip link show "$TS_IFACE" >/dev/null 2>&1 \
  || err "no $TS_IFACE interface — run 'tailscale up' first, or this would lock you out"
TS_IP=$(tailscale ip -4 2>/dev/null) \
  || err "tailscale not responding — bring it up first"

CONN_SRC=$(who am i 2>/dev/null | grep -oP '\(\K[^)]+' || true)
if [ -n "$CONN_SRC" ]; then
  ON_TS=$(python3 -c "
import ipaddress
try:
    ip = ipaddress.ip_address('$CONN_SRC')
except ValueError:
    print('no')
else:
    ok = ip in ipaddress.ip_network('100.64.0.0/10') or ('$LAN_PRIVATE' == 'yes' and ip in ipaddress.ip_network('$LAN'))
    print('yes' if ok else 'no')
")
  [ "$ON_TS" = yes ] \
    || err "this session's source ($CONN_SRC) is neither Tailscale nor the private LAN — reconnect via $TS_IP first, or you will lock yourself out"
  info "Session confirmed on Tailscale or the private LAN (source $CONN_SRC)"
else
  info "No remote source detected (local/console session) — proceeding"
fi

# ---- 1. SSH: key-only, no root -----------------------------------------
info "Hardening sshd (key-only, no root login) — console/getty logins untouched"
sudo tee /etc/ssh/sshd_config.d/99-harden.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
sudo systemctl reload ssh

# ---- 2. Firewall: default-deny inbound; SSH on tailscale0; the private LAN
if command -v ufw >/dev/null 2>&1; then
  info "ufw already installed"
else
  info "Installing ufw"
  sudo apt-get update -qq
  sudo apt-get install -y ufw
fi

# libvirt manages its own iptables FORWARD rules for VM NAT; ufw's default
# FORWARD policy is DROP, which fights those rules and can cut VM internet
# access. Force ACCEPT so ufw only governs traffic *to the host itself*.
sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

info "Configuring ufw: default-deny inbound, SSH on $TS_IFACE"
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on "$TS_IFACE" to any port 22 proto tcp
if [ "$LAN_PRIVATE" = yes ]; then
  # Guests never match this: they reach the host from the libvirt bridge
  # (192.168.122.0/24), not from $LAN, and isolate-guest drops them first anyway.
  info "Private LAN $LAN on $IFACE: allowing everything inbound from it"
  sudo ufw allow in on "$IFACE" from "$LAN" comment 'host LAN (private)'
else
  info "$IFACE is on a PUBLIC subnet ($LAN): not opening it — Tailscale only"
fi
sudo ufw --force enable
sudo ufw reload

# ---- 3. Verify -------------------------------------------------------------
info "Verifying"
ok=1
if sudo sshd -T 2>/dev/null | grep -q '^passwordauthentication no'; then
  echo "  ok: sshd password auth disabled"
else
  echo "  MISSING: sshd password auth still enabled" >&2; ok=0
fi
if sudo sshd -T 2>/dev/null | grep -q '^permitrootlogin no'; then
  echo "  ok: sshd root login disabled"
else
  echo "  MISSING: sshd root login still enabled" >&2; ok=0
fi
if sudo ufw status | grep -q "^Status: active"; then
  echo "  ok: ufw active"
else
  echo "  MISSING: ufw not active" >&2; ok=0
fi
if sudo ufw status | grep -qE "22/tcp.*ALLOW IN.*on ${TS_IFACE}|Anywhere on ${TS_IFACE}"; then
  echo "  ok: SSH allowed on $TS_IFACE"
else
  echo "  MISSING: expected ufw rule for SSH on $TS_IFACE not found" >&2; ok=0
fi
if [ "$LAN_PRIVATE" = yes ]; then
  if sudo ufw status | grep -qE "ALLOW IN +${LAN//./\\.}"; then
    echo "  ok: private LAN $LAN allowed"
  else
    echo "  MISSING: expected ufw rule for the private LAN $LAN not found" >&2; ok=0
  fi
fi

if [ "$ok" = 1 ]; then
  if [ "$LAN_PRIVATE" = yes ]; then
    info "Done. Reachable via Tailscale ($TS_IP) and from the private LAN $LAN." \
         "Console/sudo passwords still work."
  else
    info "Done. SSH now reachable only via Tailscale ($TS_IP) or the provider's" \
         "out-of-band KVM/IPMI console. Console/sudo passwords still work."
  fi
  echo "Recommended next step: from a DIFFERENT Tailscale device, confirm you" \
       "can still 'ssh cnetto@$TS_IP' before closing this session."
else
  info "Done, but some items above are still missing — see MISSING lines."
  exit 1
fi

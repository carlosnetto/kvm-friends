#!/usr/bin/env bash
# harden-host.sh — restrict SSH on this host to Tailscale only, leaving the
# hosting provider's out-of-band KVM/IPMI console as the sole fallback if
# Tailscale itself is ever unreachable (see CLAUDE.md / conversation
# history). Idempotent: safe to re-run.
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

# ---- 0. Safety checks -------------------------------------------------
# Refuse to run at all unless Tailscale is actually up and this very
# session is coming in over it (or the local/KVM console) — otherwise this
# script would sever the session running it.
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
    print('yes' if ip in ipaddress.ip_network('100.64.0.0/10') else 'no')
")
  [ "$ON_TS" = yes ] \
    || err "this session's source ($CONN_SRC) isn't on Tailscale — reconnect via $TS_IP first, or you will lock yourself out"
  info "Session confirmed on Tailscale (source $CONN_SRC)"
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

# ---- 2. Firewall: SSH only from tailscale0, default-deny everything else in
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

info "Configuring ufw: allow SSH only on $TS_IFACE, default-deny other inbound"
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on "$TS_IFACE" to any port 22 proto tcp
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
  echo "  ok: SSH allowed only on $TS_IFACE"
else
  echo "  MISSING: expected ufw rule for SSH on $TS_IFACE not found" >&2; ok=0
fi

if [ "$ok" = 1 ]; then
  info "Done. SSH now reachable only via Tailscale ($TS_IP) or the provider's" \
       "out-of-band KVM/IPMI console. Console/sudo passwords still work."
  echo "Recommended next step: from a DIFFERENT Tailscale device, confirm you" \
       "can still 'ssh cnetto@$TS_IP' before closing this session."
else
  info "Done, but some items above are still missing — see MISSING lines."
  exit 1
fi

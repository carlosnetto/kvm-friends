#!/usr/bin/env bash
# create-vm.sh — create a friend VM exactly as documented in CLAUDE.md.
#
# Usage: ./create-vm.sh [vm-name] [login] ['ssh-ed25519 AAAA... comment'] [tskey]
# Missing arguments are prompted for. The 4th (Tailscale pre-auth key) is
# optional: without it, Tailscale is installed over SSH and the login URL
# printed for the friend to approve on their own account.
set -euo pipefail
cd "$(dirname "$0")"

V()    { virsh --connect qemu:///system "$@"; }
err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo; echo "==> $*"; }

BASE_IMG=noble-server-cloudimg-amd64.img
MY_KEY_FILE=$HOME/.ssh/id_ed25519.pub

# ---- preconditions --------------------------------------------------------
[ -f "$BASE_IMG" ]    || err "base image missing — run the bootstrap in CLAUDE.md"
[ -f "$MY_KEY_FILE" ] || err "$MY_KEY_FILE not found"
V nwfilter-dumpxml isolate-guest >/dev/null 2>&1 \
  || err "nwfilter 'isolate-guest' missing — run the one-time setup in CLAUDE.md"
V net-info default >/dev/null 2>&1 || err "libvirt network 'default' missing"

# ---- inputs ----------------------------------------------------------------
NAME=${1:-};       [ -n "$NAME" ]       || read -rp "VM name / hostname (e.g. vm-joao): " NAME
FRIEND=${2:-};     [ -n "$FRIEND" ]     || read -rp "Friend's login (lowercase): " FRIEND
FRIEND_KEY=${3:-}; [ -n "$FRIEND_KEY" ] || read -rp "Friend's SSH PUBLIC key (one line): " FRIEND_KEY
TSKEY=${4:-}
if [ $# -lt 4 ] && [ -t 0 ]; then
  read -rp "Tailscale pre-auth key (optional, Enter to skip): " TSKEY
fi

[[ $NAME   =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || err "VM name: lowercase letters/digits/hyphens only"
[[ $FRIEND =~ ^[a-z][a-z0-9_-]{0,31}$   ]] || err "login: lowercase, must start with a letter"
[[ $FRIEND_KEY == *PRIVATE* ]] && err "that looks like a PRIVATE key — never accept those"
[[ $FRIEND_KEY =~ ^(ssh-ed25519|ssh-rsa|ecdsa-|sk-ssh|sk-ecdsa) ]] \
  || err "that doesn't look like an SSH public key"
V dominfo "$NAME" >/dev/null 2>&1 && err "a VM named '$NAME' already exists"
for f in "$NAME.qcow2" "$NAME-seed.img" "$NAME-console-password.txt"; do
  [ -e "$f" ] && err "$f already exists — clean up first (see 'Destroying a VM')"
done

# ---- disk + cloud-init seed ------------------------------------------------
info "Creating disk (256 GB, thin)"
cp "$BASE_IMG" "$NAME.qcow2"
qemu-img resize "$NAME.qcow2" 256G >/dev/null

PASS=$(openssl rand -base64 9)
(umask 077; echo "$PASS" > "$NAME-console-password.txt")

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/user-data" <<EOF
#cloud-config
hostname: $NAME
users:
  - name: $FRIEND
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - $FRIEND_KEY
      - $(cat "$MY_KEY_FILE")
chpasswd:
  expire: false
  users:
    - name: $FRIEND
      password: $PASS
      type: text
ssh_pwauth: false
write_files:
  # Handoff helper: friend runs it to revoke Carlos's temporary key.
  - path: /home/$FRIEND/REMOVE_TK_SSH_PUB_KEY.sh
    permissions: '0755'
    owner: $FRIEND:$FRIEND
    defer: true
    content: |
      #!/bin/bash
      # Removes Carlos's temporary setup key from this machine, making SSH
      # access exclusively yours. Run once, any time after Tailscale works.
      KEY='$(awk '{print $2}' "$MY_KEY_FILE")'
      grep -vF "\$KEY" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new || true
      mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys
      chmod 600 ~/.ssh/authorized_keys
      echo "Carlos's key removed. Keys still authorized:"
      awk '{print "  " \$1, \$NF}' ~/.ssh/authorized_keys
      echo "Suggestion: also run 'passwd' to set your own console password."
      rm -- "\$0"
EOF
if [ -n "$TSKEY" ]; then
  cat >> "$TMP/user-data" <<EOF
runcmd:
  - ['sh', '-c', 'curl -fsSL https://tailscale.com/install.sh | sh']
  - ['tailscale', 'up', '--auth-key=$TSKEY']
EOF
fi
printf 'instance-id: %s-001\nlocal-hostname: %s\n' "$NAME" "$NAME" > "$TMP/meta-data"
cloud-localds "$NAME-seed.img" "$TMP/user-data" "$TMP/meta-data"

# ---- create ----------------------------------------------------------------
info "Creating VM '$NAME' (8 vCPU, 4/16 GB RAM, isolated network)"
virt-install --connect qemu:///system \
  --name "$NAME" \
  --memory memory=16384,currentMemory=4096 \
  --memballoon model=virtio,autodeflate=on,freePageReporting=on \
  --vcpus 8 \
  --disk "path=$PWD/$NAME.qcow2,format=qcow2,bus=virtio" \
  --disk "path=$PWD/$NAME-seed.img,format=raw,bus=virtio" \
  --import \
  --os-variant ubuntu24.04 \
  --network network=default,model=virtio,filterref=isolate-guest \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole >/dev/null

# ---- wait for IP + SSH -----------------------------------------------------
info "Waiting for IP"
IP=
for _ in $(seq 1 60); do
  IP=$(V domifaddr "$NAME" | awk '/ipv4/ {sub(/\/.*/,"",$4); print $4; exit}')
  [ -n "$IP" ] && break
  sleep 5
done
[ -n "$IP" ] || err "no IP after 5 min — check: virsh console $NAME"
echo "    IP: $IP"

ssh-keygen -R "$IP" >/dev/null 2>&1 || true
SSH=(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 "$FRIEND@$IP")
info "Waiting for SSH"
ok=
for _ in $(seq 1 36); do
  if "${SSH[@]}" true 2>/dev/null; then ok=1; break; fi
  sleep 5
done
[ -n "$ok" ] || err "SSH not answering after 3 min — check: virsh console $NAME"

# ---- isolation smoke test ---------------------------------------------------
info "Isolation check"
GW=$(ip route show default | awk '{print $3; exit}')
"${SSH[@]}" "ping -c1 -W2 $GW >/dev/null 2>&1" \
  && err "VM can reach the LAN gateway ($GW) — filter NOT working, stop here"
"${SSH[@]}" "ping -c1 -W2 192.168.122.1 >/dev/null 2>&1" \
  && err "VM can reach the host — filter NOT working, stop here"
"${SSH[@]}" "curl -sI --max-time 10 https://ubuntu.com >/dev/null" \
  || err "VM has no internet access"
echo "    LAN blocked, host blocked, internet OK"

# ---- tailscale ---------------------------------------------------------------
if [ -n "$TSKEY" ]; then
  info "Tailscale (pre-auth key): waiting for join"
  TSIP=
  for _ in $(seq 1 36); do
    TSIP=$("${SSH[@]}" "tailscale ip -4 2>/dev/null" || true)
    [ -n "$TSIP" ] && break
    sleep 5
  done
  echo "    Tailscale IP: ${TSIP:-not joined yet — check 'sudo tailscale status' in the VM}"
else
  info "Installing Tailscale"
  "${SSH[@]}" "curl -fsSL https://tailscale.com/install.sh | sh" >/dev/null 2>&1
  URL=$("${SSH[@]}" "sudo systemctl enable --now tailscaled >/dev/null 2>&1; \
                     nohup sudo tailscale up >/tmp/ts-up.log 2>&1 & sleep 8; cat /tmp/ts-up.log" \
        | grep -o 'https://login\.tailscale\.com/[A-Za-z0-9/]*' | head -1)
  echo
  echo "  >>> Send this URL to the friend — they approve it on THEIR Tailscale account: <<<"
  echo "      ${URL:-URL not captured — run 'sudo tailscale up' inside the VM}"
fi

# ---- summary -----------------------------------------------------------------
info "Done: $NAME"
cat <<EOF
    login:            ssh $FRIEND@$IP   (your key works until handoff)
    console password: $NAME-console-password.txt
    console:          virsh --connect qemu:///system console $NAME
    autostart:        virsh --connect qemu:///system autostart $NAME   # if wanted

  Handoff checklist (after the friend confirms SSH over Tailscale works):
    1. friend runs: ~/REMOVE_TK_SSH_PUB_KEY.sh   (revokes your key, self-deletes)
    2. friend runs: passwd
    3. optional: sudo rm /etc/sudoers.d/90-cloud-init-users
EOF

# CLAUDE.md — ~/kvm

Folder for headless KVM virtual machines Carlos hosts for friends. Read
`README.md` for the human-facing overview. This file is the operational
recipe for creating a new VM.

## Ground rules

- Everything (disks, seeds, base images) lives in this folder.
- `noble-server-cloudimg-amd64.img` is the pristine Ubuntu 24.04 LTS cloud
  image. Never boot, resize, or modify it — always `cp` it to a new file.
- VMs are headless: `--graphics none`, serial console only. No X, no
  browser, minimal server packages only.
- Disks are 256 GB qcow2, thin-provisioned.
- SSH password auth is always disabled (`ssh_pwauth: false`); access is by
  public key only.
- Use `--connect qemu:///system` for all virsh/virt-install commands.
- VMs are internet-only: they must not reach the home LAN, the host, or
  each other. Every VM NIC gets the `isolate-guest` nwfilter (see
  "Network isolation" below). Never omit the `filterref`.
- This folder is a git repo, portable to any Linux/KVM host. Disks, seeds,
  console passwords and the base image are gitignored — never commit them.

## New host bootstrap (once per machine)

```bash
# 1. Packages (Debian/Ubuntu):
sudo apt install qemu-kvm libvirt-daemon-system virtinst cloud-image-utils

# 2. Clone this repo to ~/kvm and give libvirt access to it:
setfacl -m u:libvirt-qemu:rwx ~/kvm
setfacl -m u:libvirt-qemu:x "$HOME"

# 3. Download the pristine base image (gitignored — too big) and verify it:
cd ~/kvm
curl -fsSL -O https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
curl -fsSL https://cloud-images.ubuntu.com/noble/current/SHA256SUMS \
  | sha256sum -c --ignore-missing

# 4. Apply the network isolation setup (next section).
```

## Inputs required before creating a VM (ask if missing)

1. VM name (also used as hostname), e.g. `vm-joao`.
2. Friend's login name (lowercase).
3. Friend's SSH **public** key.
4. Optional: friend's Tailscale pre-auth key (`tskey-...`). If provided,
   install Tailscale via cloud-init and join automatically; if not, Carlos
   does it manually after first boot (see Tailscale section below).

Also include Carlos's public key (`~/.ssh/id_ed25519.pub`) in the VM —
temporary, removed at handoff.

## Network isolation (one-time host setup, before the first VM)

Goal: a VM can reach the internet through the host's NAT (out via the
site's default gateway), but cannot initiate any connection to the local
LAN, the host itself (any of its addresses, Tailscale included), Docker
bridges, or sibling VMs. The filter blocks all RFC1918 + link-local +
CGNAT space, so it works unchanged on any host/LAN.

Two files in this repo implement it; run once per host, while no VM is
running:

```bash
cd ~/kvm
# 1. Define the per-NIC packet filter (idempotent; redefine to update):
virsh --connect qemu:///system nwfilter-define isolate-guest.xml

# 2. Stop guests talking DNS to the host: dnsmasq serves DHCP only and
#    pushes public resolvers (1.1.1.1, 9.9.9.9) via DHCP option 6.
#    default-net.xml carries no uuid/mac, so replace the stock network:
virsh --connect qemu:///system net-destroy default
virsh --connect qemu:///system net-undefine default
virsh --connect qemu:///system net-define default-net.xml
virsh --connect qemu:///system net-autostart default
virsh --connect qemu:///system net-start default
```

What `isolate-guest.xml` does:

- Allows only the DHCP exchange (UDP 67) toward the host.
- Drops VM-**initiated** (`state='NEW'`) IPv4 to 10.0.0.0/8, 172.16.0.0/12,
  192.168.0.0/16, 169.254.0.0/16 and 100.64.0.0/10 (CGNAT — covers the
  host's Tailscale IP). Everything else is accepted → internet only.
- Drops all IPv6 (the NAT net is v4-only; blocks fe80:: paths to the host).
- Because drops match NEW only, **host → VM SSH still works** (replies are
  ESTABLISHED) — needed for setup and the manual Tailscale path. If a VM
  should not even answer the host, remove `state='NEW'` from the drops and
  use the serial console instead.
- Tailscale inside the VM keeps working: tunnel traffic goes to public
  IPs/DERP relays; direct paths to LAN peers are blocked and fall back to
  relay.

## Recipe

```bash
cd ~/kvm
NAME=vm-joao            # VM name / hostname
FRIEND=joao             # login name
FRIEND_KEY='ssh-ed25519 AAAA... friend'

cp noble-server-cloudimg-amd64.img ${NAME}.qcow2
qemu-img resize ${NAME}.qcow2 256G

PASS=$(openssl rand -base64 9)
echo "$PASS" > ${NAME}-console-password.txt && chmod 600 ${NAME}-console-password.txt

cat > user-data <<EOF
#cloud-config
hostname: ${NAME}
users:
  - name: ${FRIEND}
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - ${FRIEND_KEY}
      - $(cat ~/.ssh/id_ed25519.pub)
chpasswd:
  expire: false
  users:
    - name: ${FRIEND}
      password: ${PASS}
      type: text
ssh_pwauth: false
EOF
# If a Tailscale pre-auth key was provided, append to user-data:
#   runcmd:
#     - ['sh', '-c', 'curl -fsSL https://tailscale.com/install.sh | sh']
#     - ['tailscale', 'up', '--auth-key=tskey-...']

printf 'instance-id: %s-001\nlocal-hostname: %s\n' "$NAME" "$NAME" > meta-data
cloud-localds ${NAME}-seed.img user-data meta-data
rm user-data meta-data

virt-install --connect qemu:///system \
  --name ${NAME} \
  --memory 4096 --vcpus 2 \
  --disk path=$HOME/kvm/${NAME}.qcow2,format=qcow2,bus=virtio \
  --disk path=$HOME/kvm/${NAME}-seed.img,format=raw,bus=virtio \
  --import \
  --os-variant ubuntu24.04 \
  --network network=default,model=virtio,filterref=isolate-guest \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole
```

Critical: each VM needs a **unique** name, hostname, and `instance-id` —
reusing a seed or instance-id makes cloud-init skip first-boot setup.

## After boot

```bash
# Get IP (may take ~30 s):
virsh --connect qemu:///system domifaddr ${NAME}
# Verify SSH:
ssh ${FRIEND}@<ip> 'hostname; df -h /'
# Verify isolation — the two pings must FAIL, the curl must succeed:
GW=$(ip route show default | awk '{print $3; exit}')   # host's LAN gateway
ssh ${FRIEND}@<ip> "ping -c1 -W2 ${GW}; ping -c1 -W2 192.168.122.1; curl -sI https://ubuntu.com | head -1"
```

## Tailscale (manual path, when no pre-auth key)

1. SSH in with Carlos's key, run:
   `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`
2. Send the friend the printed login URL; they approve it in their browser
   against **their own** Tailscale account.

## Handoff checklist

1. Remove Carlos's key line from `~/.ssh/authorized_keys` in the VM.
2. Friend runs `passwd` (their console password; serial console only).
3. Optional: `sudo rm /etc/sudoers.d/90-cloud-init-users` (sudo asks password).

## Destroying a VM (only when Carlos explicitly asks)

```bash
virsh --connect qemu:///system destroy ${NAME}      # if running
virsh --connect qemu:///system undefine ${NAME}
rm ~/kvm/${NAME}.qcow2 ~/kvm/${NAME}-seed.img ~/kvm/${NAME}-console-password.txt
ssh-keygen -R <vm-ip>   # clear stale host key so a reused IP doesn't warn
```

## History

- 2026-07-08: recipe validated end to end with a test VM (`ubuntu-vm`,
  Ubuntu 24.04.4): booted in under a minute, SSH key auth confirmed,
  root fs auto-grew to 247 GB while using ~600 MB on disk. Destroyed after.
- 2026-07-10: added network isolation (`isolate-guest.xml`,
  `default-net.xml`) — staged in the repo, applied per host at bootstrap.
  Not yet validated against a live VM: the first VM created must pass the
  isolation check in "After boot". Folder made portable for GitHub
  (bootstrap section, .gitignore for images/disks/secrets).

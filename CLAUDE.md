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
- RAM: VMs boot at 4 GB (`currentMemory`) with a 16 GB ceiling (`memory`),
  resized live via virtio-balloon — see "Memory management" below.
- CPU: every VM gets 8 vCPUs, fixed (the host has 32 threads).
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

Automated: `./create-vm.sh [name] [login] ['ssh-... key'] [tskey]` runs
everything in this section plus the after-boot checks and Tailscale setup
(prompts for missing inputs). The manual steps below remain the reference.

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
write_files:
  # Handoff helper: friend runs it to revoke Carlos's temporary key.
  - path: /home/${FRIEND}/REMOVE_TK_SSH_PUB_KEY.sh
    permissions: '0755'
    owner: ${FRIEND}:${FRIEND}
    defer: true
    content: |
      #!/bin/bash
      # Removes Carlos's temporary setup key from this machine, making SSH
      # access exclusively yours. Run once, any time after Tailscale works.
      # Key material only (field 2): matching the whole line is fragile —
      # comments/whitespace differ between the .pub file and authorized_keys.
      KEY='$(awk '{print $2}' ~/.ssh/id_ed25519.pub)'
      grep -vF "\$KEY" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new || true
      mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys
      chmod 600 ~/.ssh/authorized_keys
      echo "Carlos's key removed. Keys still authorized:"
      awk '{print "  " \$1, \$NF}' ~/.ssh/authorized_keys
      echo "Suggestion: also run 'passwd' to set your own console password."
      rm -- "\$0"
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
  --memory memory=16384,currentMemory=4096 \
  --memballoon model=virtio,autodeflate=on,freePageReporting=on \
  --vcpus 8 \
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

## Memory management

VMs see 16 GB installed but the balloon keeps them at 4 GB. Growing is a
host-side action (it does NOT happen automatically on guest demand):

```bash
# Grow (or shrink) live, up to the 16 GB ceiling:
virsh --connect qemu:///system setmem ${NAME} 8G --live
# Inspect balloon and guest usage:
virsh --connect qemu:///system dommemstat ${NAME}
```

- `autodeflate=on`: if the guest is about to OOM it may reclaim balloon
  memory by itself — a safety valve, not a sizing mechanism.
- `freePageReporting=on`: memory the guest frees is returned to the host,
  so idle VMs cost roughly what they actually use.
- Raising the 16 GB ceiling needs a shutdown:
  `virsh setmaxmem ${NAME} 24G --config` then start again.
- Don't promise the sum of all ceilings: grow VMs only while the host has
  real free RAM (`free -h`).

## CPU management

Every VM has 8 fixed vCPUs. There is no time cap within them — a VM can
run all 8 at 100%; with 32 host threads that's acceptable. Changing the
count needs a shutdown:

```bash
virsh --connect qemu:///system shutdown ${NAME}    # wait for "shut off"
virsh --connect qemu:///system setvcpus ${NAME} 16 --maximum --config
virsh --connect qemu:///system setvcpus ${NAME} 16 --config
virsh --connect qemu:///system start ${NAME}
```

## Tailscale (manual path, when no pre-auth key)

1. SSH in with Carlos's key, run:
   `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`
2. Send the friend the printed login URL; they approve it in their browser
   against **their own** Tailscale account.

## Handoff checklist

1. Friend runs `~/REMOVE_TK_SSH_PUB_KEY.sh` (revokes Carlos's key and
   deletes itself). Manual equivalent: remove Carlos's line from
   `~/.ssh/authorized_keys`.
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
- 2026-07-10: memory policy — boot at 4 GB, virtio-balloon up to a 16 GB
  ceiling, autodeflate + free-page-reporting on.
- 2026-07-10: isolation + memory validated end to end with VM `tkws`:
  LAN/host/bridge unreachable from guest, internet + public DNS OK,
  balloon grew 4→8 GB instantly and shrank back (~20 s to settle).
  One-time host setup (nwfilter + default network) applied on this host.
- 2026-07-10: CPU policy — fixed 8 vCPUs per VM (hotplug tried first and
  worked — 2→8→2 live with a udev auto-online rule — but dropped for
  simplicity; the host's 32 threads make overcommit a non-issue).
- 2026-07-10: `create-vm.sh` automates the recipe end to end; cloud-init
  now drops `~/REMOVE_TK_SSH_PUB_KEY.sh` in the friend's home for handoff.
  Validated with test VM `vm-demo`, including full handoff (Carlos's key
  revoked, friend retained). Lesson recorded: the remover matches the key
  *material* only — Carlos's .pub has a trailing space that made full-line
  matching fail silently. Serial-console + password recovery also proven.

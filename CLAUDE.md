# CLAUDE.md — the kvm folder

Folder for headless KVM virtual machines Carlos hosts for friends. Read
`README.md` for the human-facing overview. This file is the operational
recipe for creating a new VM.

**This repo is location-independent.** Every script self-locates from its
own path (`cd "$(dirname "$(readlink -f "$0")")"`), so it works correctly
wherever it's cloned, on any host — no path is hardcoded in the tooling.
For running commands by hand, set `KVM_FRIENDS` to wherever you clone it
(e.g. `export KVM_FRIENDS=$HOME/kvm-friends` in your shell rc) — every
command below uses `$KVM_FRIENDS` instead of a literal path, so moving the
folder to another disk or host is just updating that one variable, not
this file.

## Ground rules

- Everything (disks, seeds, base images) lives in this folder.
- Domain XML records **absolute** disk paths. If the folder ever moves,
  the domains must be repointed or they fail to start — see "Moving the
  folder to another disk" below. Do not paper over a move with a symlink
  at the old path: it works at the I/O layer (AppArmor's `virt-aa-helper`
  resolves symlinks correctly), but the XML then permanently records a
  path that does not exist, which breaks the repo's portability promise.
- `noble-server-cloudimg-amd64.img` is the pristine Ubuntu 24.04 LTS cloud
  image. Never boot, resize, or modify it — always `cp` it to a new file.
- VMs are headless: `--graphics none`, serial console only. No X, no
  browser, minimal server packages only.
- Disks are qcow2, thin-provisioned, 256 GB by default (`create-vm.sh`
  accepts a 6th argument to override, in GiB — the TUI offers 128/256/
  512/1024).
- RAM: every VM gets a fixed 16 GB, no ballooning (`--memballoon
  model=none`) — real memory, not overcommitted. See "Memory management"
  below for resizing.
- CPU: every VM gets 8 vCPUs, fixed (the host has 32 threads).
- SSH password auth is always disabled (`ssh_pwauth: false`); access is by
  public key only.
- Use `--connect qemu:///system` for all virsh/virt-install commands.
- VMs are internet-only: they must not reach the local network segment,
  the host, or each other. Every VM NIC gets the `isolate-guest` nwfilter
  (see "Network isolation" below). Never omit the `filterref`.
- This folder is a git repo, portable to any Linux/KVM host. Disks, seeds,
  console passwords and the base image are gitignored — never commit them.

## New host bootstrap (once per machine)

```bash
# 1. Clone this repo somewhere with room for the disks, then point
#    KVM_FRIENDS at it — set this once (e.g. in ~/.bashrc) and every
#    command in this doc works unchanged regardless of where it lives:
export KVM_FRIENDS=/path/to/kvm-friends
cd "$KVM_FRIENDS"
setfacl -m u:libvirt-qemu:rwx .
# Every parent dir must be traversable by libvirt-qemu. Under a mode-750
# dir (e.g. $HOME) that needs an ACL; under a mode-755 parent it is
# already fine:
#   setfacl -m u:libvirt-qemu:x "$(dirname "$KVM_FRIENDS")"

# 2. Run ./setup-host.sh — installs the KVM/libvirt stack (apt), uv/Python
#    3.13 (brew), and downloads + checksum-verifies the pristine base
#    image (gitignored — too big to commit). Idempotent, safe to re-run.
./setup-host.sh

# 3. Apply the network isolation setup (next section).
```

## Inputs required before creating a VM (ask if missing)

1. VM name (also used as hostname), e.g. `vm-joao`.
2. Friend's login name (lowercase).
3. Friend's SSH **public** key.
4. Optional: friend's Tailscale pre-auth key (`tskey-...`). If provided,
   install Tailscale via cloud-init and join automatically; if not,
   `create-vm.sh` still installs Tailscale over SSH, but Carlos has to
   bring it up manually after first boot (see Tailscale section below).

Also include Carlos's public key (`~/.ssh/id_ed25519.pub`) in the VM —
temporary, removed at handoff.

## Network isolation (one-time host setup, before the first VM)

Goal: a VM can reach the internet through the host's NAT (and make its own
outbound tunnels/Tailscale connections — nothing restricts guest-initiated
egress to arbitrary public IPs), but cannot initiate any connection to the
host itself (any of its addresses, Tailscale included), sibling VMs, or
other machines on the host's own local network segment. There is no
inbound path from the public internet either way (no port-forwarding is
configured) — the only ways in are the host itself (setup/maintenance) and
Tailscale, once a VM joins a tailnet.

The host's own "local network segment" varies by deployment: a home
router's private LAN, or — on a colo/VPS box with a public IP straight on
the NIC — that public /24 (other tenants/boxes on the same segment). The
filter template (`isolate-guest.xml`) blocks the libvirt bridge's own
subnet, link-local, and CGNAT (Tailscale) unconditionally, and gets an
extra rule for the host's *actual* local subnet filled in at setup time —
computed fresh from the host's default-route interface, not assumed to be
one of the classic RFC1918 ranges.

Automated: `./setup-network.sh` runs both steps below (idempotent; refuses
to run while a VM is running, since `net-destroy` would cut its
networking). The manual steps remain the reference:

```bash
cd "$KVM_FRIENDS"

# 1. Compute this host's own subnet and fill it into the filter template:
IFACE=$(ip route show default | awk '{print $5; exit}')
CIDR=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')
read -r NET BITS < <(python3 -c "
import ipaddress
n = ipaddress.ip_interface('$CIDR').network
print(n.network_address, n.prefixlen)
")
sed "s|@HOST_LAN_RULE@|<rule action='drop' direction='out' priority='503'><all dstipaddr='$NET' dstipmask='$BITS' state='NEW'/></rule>|" \
  isolate-guest.xml > /tmp/isolate-guest.xml

# 2. Define the per-NIC packet filter. libvirt won't update an existing
#    filter by name alone (needs a matching <uuid>) — undefine first; this
#    fails loudly if a still-defined (even shut-off) VM references it.
virsh --connect qemu:///system nwfilter-undefine isolate-guest || true
virsh --connect qemu:///system nwfilter-define /tmp/isolate-guest.xml

# 3. Stop guests talking DNS to the host: dnsmasq serves DHCP only and
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
- Drops VM-**initiated** (`state='NEW'`) IPv4 to the libvirt bridge's own
  subnet (192.168.122.0/24 — blocks both the host's bridge address and
  sibling VMs), 169.254.0.0/16 (link-local), 100.64.0.0/10 (CGNAT — covers
  the host's Tailscale IP), and the host's own local-network segment
  (computed at setup time, see above). Everything else is accepted —
  internet, Tailscale, and any tunnel a guest sets up are all unrestricted
  egress.
- Drops all IPv6 (the NAT net is v4-only; blocks fe80:: paths to the host).
- Because drops match NEW only, **host → VM SSH still works** (replies are
  ESTABLISHED) — needed for setup and the manual Tailscale path. If a VM
  should not even answer the host, remove `state='NEW'` from the drops and
  use the serial console instead.
- Tailscale inside the VM keeps working: tunnel traffic goes to public
  IPs/DERP relays; direct paths to LAN peers are blocked and fall back to
  relay.

## Recipe

Automated: `./create-vm.sh [name] [login] ['ssh-... key'] [tskey] [mem-mib]
[disk-gib]` runs everything in this section plus the after-boot checks and
Tailscale install (prompts for missing name/login/key; RAM and disk default
to 16384 MiB / 256 GiB; if the base image is missing it runs
`setup-host.sh` first to fetch it rather than erroring out). The manual
steps below remain the reference.

```bash
cd "$KVM_FRIENDS"
NAME=vm-joao            # VM name / hostname
FRIEND=joao             # login name
FRIEND_KEY='ssh-ed25519 AAAA... friend'
MEM=16384               # RAM, MiB
DISK=256                # disk, GiB

cp noble-server-cloudimg-amd64.img ${NAME}.qcow2
qemu-img resize ${NAME}.qcow2 ${DISK}G

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
  --memory ${MEM} \
  --memballoon model=none \
  --vcpus 8 \
  --disk path=$PWD/${NAME}.qcow2,format=qcow2,bus=virtio \
  --disk path=$PWD/${NAME}-seed.img,format=raw,bus=virtio \
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

Every VM gets a fixed amount of real RAM at creation time (16 GB by
default — `create-vm.sh` accepts a 5th argument to override, in MiB).
There is no balloon (`--memballoon model=none`): the guest's memory is
reserved on the host for the VM's whole lifetime, not overcommitted or
grown on demand.

Changing it later needs a shutdown, same pattern as vCPUs:

```bash
virsh --connect qemu:///system shutdown ${NAME}    # wait for "shut off"
virsh --connect qemu:///system setmaxmem ${NAME} 24G --config
virsh --connect qemu:///system setmem ${NAME} 24G --config
virsh --connect qemu:///system start ${NAME}
```

Don't promise the sum of every VM's memory: only size a VM up while the
host has real free RAM (`free -h`) — this is genuinely reserved, not a
soft ceiling.

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

`create-vm.sh` already installs and enables Tailscale over SSH in this
case — it stops short of bringing it up, since `tailscale up` prints an
interactive login URL that isn't reliable to scrape from a backgrounded,
non-pty SSH command. Only the "up" step is manual:

1. SSH in with Carlos's key, run: `sudo tailscale up`
2. Send the friend the printed login URL; they approve it in their browser
   against **their own** Tailscale account.

## Handoff checklist

1. Friend runs `~/REMOVE_TK_SSH_PUB_KEY.sh` (revokes Carlos's key and
   deletes itself). Manual equivalent: remove Carlos's line from
   `~/.ssh/authorized_keys`.
2. Friend runs `passwd` (their console password; serial console only).
3. Optional: `sudo rm /etc/sudoers.d/90-cloud-init-users` (sudo asks password).

## Day-to-day: starting and stopping VMs

`./vm-tui.py` is the interactive front end — a list of every VM with
single-key start (`s`), graceful shutdown (`h`), force off (`f`, confirmed)
and serial console (`c`). It is a Textual app run through uv: the PEP 723
metadata block at the top of the script declares `requires-python` and
`textual`, and `uv run` builds a cached environment on first use, so there
is nothing to pip-install. A new host needs `uv` and Python 3.13
(`brew install uv python@3.13`).

Equivalent one-liners:

```bash
virsh --connect qemu:///system start ${NAME}       # wake a dormant VM
virsh --connect qemu:///system shutdown ${NAME}    # graceful (ACPI)
virsh --connect qemu:///system destroy ${NAME}     # force off, unclean
```

`shutdown` is an ACPI request: a guest that has not finished booting has
nothing listening yet and the request is silently dropped. Wait until the
VM has an IP before shutting it down, or the VM will look stuck.

## Destroying a VM (only when Carlos explicitly asks)

Automated: `./destroy-vm.sh <name>` (retype the name to confirm, or
`--yes`). Overview of all VMs: `./list-vm.sh`, or `./vm-tui.py` for the
interactive view. Manual equivalent:

```bash
virsh --connect qemu:///system destroy ${NAME}      # if running
virsh --connect qemu:///system undefine ${NAME}
rm ./${NAME}.qcow2 ./${NAME}-seed.img ./${NAME}-console-password.txt
ssh-keygen -R <vm-ip>   # clear stale host key so a reused IP doesn't warn
```

## Moving the folder to another disk

Domain XML stores absolute disk paths, so moving the folder without
repointing the domains makes them fail to start ("Cannot access storage
file"). Nothing is lost — it is only a start failure — but the fix is
mandatory. With all VMs shut off:

```bash
SRC="$KVM_FRIENDS"; DST=/new/path/to/kvm-friends
for d in $(virsh --connect qemu:///system list --all --name); do
  virsh --connect qemu:///system dumpxml "$d" > /tmp/$d.bak.xml   # back up first
done
rsync -aHAX --sparse "$SRC"/ "$DST"/
rsync -naHAXc --delete "$SRC"/ "$DST"/        # must print nothing = identical
setfacl -m u:libvirt-qemu:rwx "$DST"          # re-assert; may not survive the copy

# Repoint every domain, then redefine (UUID is in the XML, so it is preserved):
for d in $(virsh --connect qemu:///system list --all --name); do
  virsh --connect qemu:///system dumpxml "$d" | sed "s#$SRC/#$DST/#g" > /tmp/$d.new.xml
  virsh --connect qemu:///system define /tmp/$d.new.xml
done
virsh --connect qemu:///system domblklist <name>   # confirm new paths

# Last step: repoint the variable itself (and its shell rc entry) at $DST —
# every command in this doc, and every script, follows it automatically.
export KVM_FRIENDS="$DST"
```

Verify by renaming the old folder aside *before* starting a VM — if it
boots, there is provably no fallback to the old path. Only then delete
the original. AppArmor needs no manual step: `virt-aa-helper` regenerates
`/etc/apparmor.d/libvirt/libvirt-<uuid>.files` from the XML on each start.

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
- 2026-07-10: `list-vm.sh` and `destroy-vm.sh` added; destroy validated on
  `vm-demo` (domain + files removed, known_hosts cleaned).
- 2026-08-02: folder moved from `/home/cnetto/kvm` to `/disk/1/cnetto/kvm`
  (dedicated 512 GB NVMe) and both domains repointed. Verified by renaming
  the old folder away first: `vm-bruno` and `vm-chisman` both booted and
  got DHCP leases, and the generated AppArmor profiles named the new
  paths. A symlink at the old path was considered and rejected — it is
  transparent to QEMU and AppArmor (`virt-aa-helper` resolves symlinks;
  confirmed with a dry run), but `create-vm.sh` used `cd "$(dirname
  "$0")"`, and bash keeps the *logical* path through a symlink, so every
  future VM would have been registered under the non-existent old path.
  Script hardened with `readlink -f` so `$PWD` is always the real folder
  (`list-vm.sh` and `destroy-vm.sh` too).
- 2026-08-02: `vm-tui.py` added — a Textual TUI listing all VMs with
  single-key start/shutdown/force-off/console, run via uv (PEP 723 inline
  metadata, Python 3.13, no pip install). Verified headlessly with
  `App.run_test()`: table populates from live virsh, action guards hold on
  stopped VMs, the force-off modal opens and cancels, and `s` then `h`
  took `vm-bruno` from `shut off` to `running` and back. Lesson recorded in
  the tool: ACPI `shutdown` sent to a still-booting guest is silently
  dropped, so the TUI warns when a VM has no IP yet.
- 2026-08-03: folder renamed from `/disk/1/cnetto/kvm` to
  `$HOME/kvm-friends` on this host; all hardcoded paths in this file
  updated accordingly. `setup-host.sh` added — installs the KVM/libvirt
  stack (apt) and uv/Python 3.13 (brew, since that's what's already used
  for `vm-tui.py`) on a virgin machine, idempotent, so it's reusable on
  future hosts. Lesson from a real run on this host: `usermod -aG
  libvirt` doesn't take effect in the current shell/session, only on the
  next login — `virsh` failing with "Permission denied" on the socket
  right after setup is expected, not a bug. Later folded the base cloud
  image download + checksum verify into the script too (previously a
  separate manual step), after hitting "base image missing" on a VM
  create right after running it.
- 2026-08-03: memory policy changed — dropped the virtio-balloon
  (`--memballoon model=none`); every VM now gets a fixed amount of real,
  non-overcommitted RAM (16 GB by default) instead of booting small and
  growing live. Disk size made configurable too (256 GB default).
  `create-vm.sh` gained optional 5th/6th arguments (RAM MiB, disk GiB).
  `vm-tui.py` gained `n` (create VM — prompts for name/login/key/optional
  Tailscale key, RAM via a 2/4/8/16/24 GB select, disk via a
  128/256/512 GB/1 TB select, then streams `create-vm.sh`'s progress
  lines as notifications) and `d` (destroy VM — modal requires retyping
  the VM name, then runs `destroy-vm.sh --yes`). Verified headlessly with
  `App.run_test()`: both modals open/cancel correctly, and submitting the
  create form with valid inputs hands off the exact expected arguments.
- 2026-08-03: `setup-host.sh` gained the libvirt-qemu ACL grant (repo dir
  + `$HOME`) — hit "Cannot access storage file" on a real VM create right
  after a fresh `setup-host.sh` run, because that step was still manual.
- 2026-08-03: network isolation redesigned after this host moved off a
  home LAN onto a colo box with a public IP straight on the NIC
  (103.195.102.0/24) — the old filter only blocked RFC1918 + link-local +
  CGNAT, so a real create-vm.sh run failed its own isolation check (guest
  could reach the public gateway). Replaced the static home-LAN rules
  (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) with: an unconditional rule
  for the libvirt bridge's own subnet (192.168.122.0/24 — protects the
  host and sibling VMs regardless of where the host physically sits), and
  a rule for the host's *actual* local subnet computed fresh at setup time
  from its default-route interface (works whether that's a home router's
  private range or a colo/VPS public /24). `setup-network.sh` added to
  automate both nwfilter steps (subnet computation + template fill,
  undefine-before-redefine since libvirt won't update an nwfilter by name
  without a matching `<uuid>`); refuses to run while a VM is running.
  Validated end to end on this host: recreated `vm-tk`, isolation check
  passed (192.168.122.1 and the real public gateway 103.195.102.1 both
  blocked, internet still OK), Tailscale joined and reachable.
- 2026-08-06: three small robustness fixes after an audit turned up gaps
  between the scripts and what had actually been done by hand on this
  host. `setup-host.sh` gained a final verification pass (checks every
  tool, the `libvirt` group, the `libvirt-qemu` ACL, and the base image,
  printing explicit `ok:`/`MISSING:` lines) since every step was
  already guarded to no-op silently, which made real failures easy to
  miss. `create-vm.sh` now runs `setup-host.sh` itself if the base image
  is missing instead of erroring out and pointing at this doc. And the
  no-pre-auth-key Tailscale path was simplified: `create-vm.sh` now only
  installs and enables Tailscale over SSH — it no longer also tries to
  background `tailscale up` and scrape the login URL from the result,
  since that capture was unreliable over a non-pty SSH command; bringing
  it up is now always the documented manual step below.
- 2026-08-06: this doc and README.md stopped hardcoding the folder's
  location. The scripts never actually depended on a fixed path — each
  one already self-locates from its own path (`cd "$(dirname "$(readlink
  -f "$0")")"`) — but the docs still said `$HOME/kvm-friends` or `~/
  kvm-friends` everywhere, which meant editing both files by hand on
  every move (this had already happened three times: `/home/cnetto/kvm`
  → `/disk/1/cnetto/kvm` → `$HOME/kvm-friends`). Every command in both
  docs now uses a `$KVM_FRIENDS` env var instead; moving the folder is
  just re-exporting that variable, not editing prose. Also caught while
  doing this: README's "Where this lives, and why" section still
  described the old home host's dedicated secondary NVMe (a 512 GB
  Bestoss GM888 versus a 1 TB primary) and a `/disk/1`-mount-ordering
  reason for autostart being off — this host (`reliablesite`, a colo
  box) turned out to be a single 1.8 TB NVMe with one LVM root volume,
  no secondary drive at all, so that whole rationale was stale and has
  been rewritten to match.

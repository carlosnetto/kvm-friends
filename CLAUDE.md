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
- RAM: every VM gets a fixed 16 GB by default — the guest boots with all
  of it and nothing ever takes it away. The virtio balloon is present but
  **never inflated**; it is there only for free-page reporting, so an idle
  guest hands genuinely-free pages back to the host on its own
  (`--memballoon model=virtio,freePageReporting=on`). It is a per-domain
  attribute, switchable on an existing VM while it is shut off — `e` in
  `./vm-tui.py`. See "Memory management" below for resizing, overcommit and
  host swap sizing.
- CPU: fixed vCPUs, chosen at creation time (1, 4, 8, 12 or 16 — the host
  has 32 threads). Defaults to 8.
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
sed "s|@HOST_LAN_RULE@|<rule action='drop' direction='out' priority='506'><all dstipaddr='$NET' dstipmask='$BITS' state='NEW'/></rule>|" \
  isolate-guest.xml > /tmp/isolate-guest.xml

# 2. Define the per-NIC packet filter. libvirt won't update an existing
#    filter by name alone (needs a matching <uuid>) — undefine first. A
#    *running* domain using the filter blocks the undefine; a shut-off one
#    does not, even though it still references it (confirmed 2026-09-11
#    with both VMs defined and off).
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
- Drops VM-**initiated** (`state='NEW'`) IPv4 to, in order: the libvirt
  bridge's own subnet (192.168.122.0/24 — blocks both the host's bridge
  address and sibling VMs), all three RFC1918 ranges, 169.254.0.0/16
  (link-local), 100.64.0.0/10 (CGNAT — covers the host's Tailscale IP),
  and the host's own local-network segment (computed at setup time, see
  above). Everything else is accepted — internet, Tailscale, and any tunnel
  a guest sets up are all unrestricted egress.
- The blanket RFC1918 rules and the computed one solve **different**
  problems and both are required. A host owns more private addresses than
  the one on its default-route NIC: `docker0` is typically 172.17.0.0/16,
  and other bridges, VPNs or CNIs add more — all of them host addresses a
  guest must not reach, and none of them discoverable by looking at the
  default route. The computed rule covers the opposite case, which no
  RFC1918 rule can: a colo/VPS box whose NIC carries a **public** /24
  shared with other tenants. Where the host's LAN is itself private the
  computed rule is simply redundant.
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
[disk-gib] [vcpus]` runs everything in this section plus the after-boot
checks and Tailscale install (prompts for missing name/login/key; RAM
defaults to 16384 MiB, disk to 256 GiB, vCPUs to 8; if the base image is
missing it runs `setup-host.sh` first to fetch it rather than erroring
out). The manual steps below remain the reference.

```bash
cd "$KVM_FRIENDS"
NAME=vm-joao            # VM name / hostname
FRIEND=joao             # login name
FRIEND_KEY='ssh-ed25519 AAAA... friend'
MEM=16384               # RAM, MiB
DISK=256                # disk, GiB
VCPUS=8                 # vCPUs (1/4/8/12/16 in the TUI; any positive integer by hand)

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
  --memballoon model=virtio,freePageReporting=on,stats.period=10 \
  --vcpus ${VCPUS} \
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

Every VM gets a fixed amount of RAM at creation time (16 GB by default —
`create-vm.sh` accepts a 5th argument to override, in MiB). `virt-install`
is given `--memory` only, so `<memory>` and `<currentMemory>` come out
equal and **the balloon starts empty**: the guest boots seeing all of its
RAM, and no host action ever reduces it.

The balloon device is still attached
(`--memballoon model=virtio,freePageReporting=on,stats.period=10`) for one
reason: **free page reporting**. The guest's page allocator reports runs of
pages sitting on its own free list, and the host `madvise`-frees them. It
is automatic, guest-driven, and one-way — the host never asks the guest for
anything, so there is no way for it to squeeze a running VM.

What it does and does not buy you:

- It **does** return memory a guest has allocated and freed, without the
  host having to page it out to swap. Most useful right after boot and
  after a big job exits.
- It does **not** return page cache. Cached pages are not free from the
  guest's point of view, and a Linux guest fills everything it is not using
  with cache — so a VM that has been up for days reports little back, and
  its QEMU RSS stays near its full size. Reporting reduces overcommit
  pressure; it does not remove the need for host swap.
- There is no "idle VM releases its RAM" behaviour beyond the above.

**Never inflate the balloon.** Do not run `setmem` below `<memory>` on a
running domain, and never boot with `<currentMemory>` lower than
`<memory>`. Either one hands the guest less RAM than it thinks it has;
the guest then hits its own OOM killer while the host looks fine. That —
not the balloon device itself — is what made the 2026-07-10 "boot at 4 GB,
ceiling 16 GB" policy unstable, and it is why that policy was dropped
entirely on 2026-08-03 before being reintroduced in this safe one-way form.
(If anyone ever does deliberately drive `setmem`, add `autodeflate='on'` as
an emergency valve first. The policy here is simply not to.)

Watch what is actually being returned — `stats.period='10'` makes the guest
publish memory stats every 10 s:

```bash
virsh --connect qemu:///system dommemstat ${NAME}
# actual = what the host has given the guest; unused/available = what the
# guest reports free; rss = what QEMU actually holds on the host.
```

Changing the size later needs a shutdown, same pattern as vCPUs:

```bash
virsh --connect qemu:///system shutdown ${NAME}    # wait for "shut off"
virsh --connect qemu:///system setmaxmem ${NAME} 24G --config
virsh --connect qemu:///system setmem ${NAME} 24G --config
virsh --connect qemu:///system start ${NAME}
```

Both calls, always, and in that order when growing: `setmaxmem` alone
leaves `<currentMemory>` behind and boots the VM with an inflated balloon —
exactly the failure above.

### Adding reporting to a VM created before 2026-09-11

VMs made by the older recipe carry `<memballoon model='none'/>` and will
never report anything back. The device cannot be added to a running domain
here, so this needs a shutdown — but it is a pure XML edit, no reinstall
and nothing inside the guest to change (Ubuntu 24.04's kernel has both
`virtio_balloon` and free page reporting, which needs 5.7+).

Easiest route: shut the VM down (`h` in `./vm-tui.py`), press `e`, and set
**Free-page reporting** to on. The BALLOON column shows each VM's current
mode (`report` / `off`), read from the *inactive* XML — i.e. what the next
boot will use. By hand:

```bash
virsh --connect qemu:///system shutdown ${NAME}    # wait for "shut off"
virsh --connect qemu:///system edit ${NAME}
#   replace:  <memballoon model='none'/>
#   with:     <memballoon model='virtio' freePageReporting='on'>
#               <stats period='10'/>
#             </memballoon>
virsh --connect qemu:///system start ${NAME}
virsh --connect qemu:///system dommemstat ${NAME}  # 'unused' now appears
```

Check `<currentMemory>` equals `<memory>` while you are in there. If an
older VM has them different, fix it in the same edit — that VM has been
running with an inflated balloon.

### Overcommitting the host, and sizing swap for it

Guest RAM is ordinary **anonymous** memory on the host, and QEMU's RSS only
ever grows toward the configured size as the guest touches pages. So the
honest planning number is the **sum of every VM's configured RAM**, not
what `free -h` shows today.

If that sum exceeds host RAM, the difference has to live in swap, and the
host must be set up for it:

- **Swap must cover the gap.** Roughly:
  `swap >= (sum of configured VM RAM) - (host RAM minus a few GB for the
  host itself)`. Undershoot and the OOM killer eventually picks a
  `qemu-system-x86` — which is a VM dying hard, not a slowdown. On a fast
  NVMe a swapfile is cheap: `swapoff /swapfile && fallocate -l <N>G
  /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`
  (the `/etc/fstab` entry names the file, so it needs no edit).
- **Leave `vm.swappiness` at the default 60 — do not lower it.** The usual
  workstation advice (10) is exactly backwards on a VM host: guest RAM *is*
  the anonymous memory that low swappiness protects, so 10 tells the kernel
  to keep idle guest pages resident and throw away page cache instead. 60,
  or higher, is what lets a cold VM drift out to disk.
- **Waking a swapped-out VM is slow** even on NVMe: the guest faults its
  working set back in page by page. Expect a sluggish minute or two, not an
  instant resume. If two VMs genuinely alternate rather than run together,
  shutting the idle one down (`h` in `vm-tui.py`) is faster and free.
- **KSM helps a little.** Guests built from the same base image share
  identical pages; check with
  `grep . /sys/kernel/mm/ksm/pages_sharing /sys/kernel/mm/ksm/run`. Expect
  hundreds of MB, not GB — it is a bonus, not a plan.

### Guests running k3s with Java workloads

The guest-side counterpart to this section — what to change in a Helm chart
so 30-60 JVMs behave inside a 32 GB VM — is written up separately in
[HELMCHARTS.md](HELMCHARTS.md). What follows is the host-side view and the
reasoning behind it.

The 32 GB k3s VMs are the hard case for everything above, and the reason is
worth stating plainly: **free page reporting can only hand back pages that
are on the guest kernel's free list.** For a JVM the chain is GC frees
objects -> the JVM uncommits heap to the guest kernel -> the pages land on
the free list -> reporting gives them to the host. Step two does not happen
by default, and an unattended node breaks it in the worst way: **an idle
JVM never GCs at all** (no allocation, no trigger), so 30-60 pods sit on
fully-committed heaps indefinitely. Left alone, such a VM reports almost
nothing back no matter how idle it looks.

Three guest-side levers, in order of how much they return:

- **Swap inside the guest.** The guest kernel knows which JVM pages are
  cold in a way the host can only approximate, and once it pages them out
  they become free in the guest — so reporting then returns that RAM to the
  host *for real*, instead of the host merely holding them in its own swap.
  kubelet refuses to start with swap enabled unless told otherwise:
  `k3s server --kubelet-arg=fail-swap-on=false` (same flag for `agent`).
  Note this check only sees **guest** swap — host swap is invisible to the
  guest and never trips it.
- **A GC that uncommits.** ZGC (`-XX:+UseZGC`, uncommits after
  `-XX:ZUncommitDelay`, 300 s by default) and Shenandoah (uncommit on by
  default) return heap when idle. G1 — the default — only uncommits at a
  full GC unless `-XX:G1PeriodicGCInterval=300000` is set, which exists
  precisely for idle containers. This flag is what turns the balloon from
  "returns nothing" into "returns most of the heap five minutes after the
  user walks away".
- **Real memory limits on the pods.** This one bites before the host is
  even involved: a JVM with no container limit sees the whole 32 GB node
  and defaults its max heap to 25% of it — 8 GB each. Thirty of those is a
  guest-side OOM with the host still showing free RAM. Set container limits
  and `-XX:MaxRAMPercentage` so the JVMs size themselves to the limit.

On a host with such guests, push `vm.swappiness` to 80-100 rather than
leaving it at 60 (see the overcommit section above) — a VM abandoned for
days is exactly what should drift out to the NVMe.

**Do not plan on KSM here.** Java is close to its worst case: KSM merges by
page *content*, and a mutating heap under a compacting GC either never
holds two pages identical long enough to merge or COW-breaks the merge
immediately. Measured on this host with one 32 GB Java guest running,
~116 MB was actually shared against ~9.7 GB classed `pages_volatile`
(changing too fast to try) for 49 s of ksmd CPU:

```bash
grep . /sys/kernel/mm/ksm/pages_sharing /sys/kernel/mm/ksm/pages_volatile
```

It costs little and needs no setup, so there is no reason to turn it off —
just do not count its savings toward a memory budget.

## CPU management

Every VM gets a fixed vCPU count chosen at creation time (1, 4, 8, 12 or 16
in the TUI; defaults to 8). There is no time cap within them — a VM can run
all of its vCPUs at 100%; with 32 host threads that's acceptable even at 16,
though unlike RAM these are not reserved — vCPUs across VMs may total more
than the host has, and they simply contend. Changing the count later needs a
shutdown:

```bash
virsh --connect qemu:///system shutdown ${NAME}    # wait for "shut off"
virsh --connect qemu:///system setvcpus ${NAME} 16 --maximum --config
virsh --connect qemu:///system setvcpus ${NAME} 16 --config
virsh --connect qemu:///system start ${NAME}
```

## Editing a VM's CPU, RAM and balloon

`./vm-tui.py` does all three in one place: select a VM and press `e`. The
form prefills with the VM's current values and writes CPU and RAM with the
same `--config` virsh calls documented in the two sections above; disk is
shown but not editable (growing it needs `qemu-img resize` plus a
partition/fs grow inside the guest, which is not a one-keystroke
operation).

The balloon is the odd one out, because there is no virsh verb for it: the
TUI dumps the inactive XML, replaces the whole `<memballoon>` element and
redefines the domain. Replacing rather than patching is deliberate —
switching the model invalidates the device's PCI `<address>`, and dropping
it lets libvirt assign a fresh one at define time. It runs **after** the
`setmem`/`setvcpus` steps for the same reason the pairs are ordered: those
calls rewrite the stored XML, so a dump taken before them would define a
stale copy and silently undo the resize.

**The VM must be `shut off`** — `e` refuses otherwise. This is not
squeamishness: the balloon is never inflated and there is no CPU hotplug
here, so a `--config` edit on a running domain applies only at the next
boot and the table would report a size the guest isn't running on. The
balloon device itself cannot be swapped on a live domain at all. Shut down with `h` first; the
change takes effect on the next `s`.

Order matters within each pair, and the TUI picks it based on the
direction: `<memory>` is a ceiling for `<currentMemory>` (likewise
`--maximum` for vCPUs), so it **raises the ceiling before the value** when
growing and **lowers the value before the ceiling** when shrinking. The
other order asks libvirt for a state where the value exceeds its ceiling.
A failing step aborts the rest rather than leaving a half-applied config.

Sizing up is still bounded by real hardware — see the `free -h` warning
under "Memory management". The TUI does not check this for you.

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
single-key start (`s`), graceful shutdown (`h`), force off (`f`, confirmed),
serial console (`c`), resize (`e`, shut-off VMs only — see "Editing a VM's
CPU and RAM" above) and move to another host (`m`, see "Moving a VM to
another host" below). It is a Textual app run through uv: the PEP 723
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

## Moving a VM to another host

Automated: `./move-vm.sh <name> <user@host:/path/to/kvm-friends>`, or press
`m` in `./vm-tui.py`. It runs everything in this section — pre-flight on the
destination, clean shutdown, `tar`-over-ssh stream, sha256 verify, then
redefine there with the disk paths rewritten. It **never deletes anything on
this host**; `--retire-source` only undefines the source domain (the disk
files stay as a cold backup). The manual steps below remain the reference.

Two things it does automatically that are easy to get wrong by hand: it
refuses to start unless the destination already has the `isolate-guest`
nwfilter, the `default` network, the machine type and free space, and it
verifies sha256 on both sides *before* defining the domain — a bad copy
leaves nothing registered on the far side.

The disk set it moves comes from the domain's own block list (`virsh
domblklist`), not an assumed qcow2+seed pair, so it also works for a VM
outside the create-vm.sh cloud-init recipe — e.g. a hand-built guest with a
different disk layout (no seed, an empty cdrom slot). Every disk the domain
actually uses must still live directly in this folder, per "Ground rules"
above; one that doesn't is refused rather than silently skipped.

**The VM keeps its Tailscale identity**, so once booted on the far side it
answers on the same 100.x address and the friend notices nothing but the
downtime. That is preserved by the *disk copy*, not by the XML:
`/var/lib/tailscale/tailscaled.state` (the node key) lives inside the guest
filesystem, so it travels in the qcow2 — which is exactly why the script
verifies sha256 on both sides before defining anything. Confirmed on
`vm-dtw-k3s`: that file sits in `/var/lib/tailscale/` at 0600 root:root,
alongside `profile-data/`.

Separately, the XML is redefined rather than rebuilt, so **name, UUID and
MAC** survive too — the MAC because cloud-init pinned it into the guest's
netplan `match:` rule (a fresh one boots the VM with no network), the rest
because anything keyed on them should still match. The only thing the
script changes in the XML is the two absolute disk paths.

The flip side of a portable identity is that it must not be duplicated: two
copies of the same disk share one node key and would fight over it. That is
why nothing is deleted here and the source is left defined but flagged —
see `--retire-source`.

Different from moving the *folder*: here one VM leaves this host for a
different machine, and everything inside it must survive — same
filesystem, same SSH host keys, same **Tailscale identity**
(`/var/lib/tailscale/tailscaled.state` lives on the disk), so the friend
keeps the same 100.x address and notices nothing but the downtime. What is
*not* preserved is RAM state: running processes, open connections, uptime.

Shut the VM down cleanly — **never move a `virsh save` / `managedsave`
state file.** Saved RAM state is tied to the exact QEMU build, machine type
and CPU flags, and will not restore reliably elsewhere. A cold boot is
precisely what makes this portable, and it is also why `host-passthrough`
(what `virt-install` records here) is harmless across different CPUs: the
guest re-detects the CPU at boot.

Four things travel, not just the disk:

| Item | Why |
|---|---|
| `<name>.qcow2` | The machine itself. |
| `<name>-seed.img` | The domain XML lists it as a **second disk** — the VM will not start without it. Copy it **unchanged**: cloud-init matches the same `instance-id` and skips first-boot setup. A *new* seed would re-run cloud-init and re-add Carlos's key. |
| `<name>-console-password.txt` | Not needed to boot; you just want it on the new host. |
| The domain XML | Not kept anywhere by `create-vm.sh` — dump it. |

**Dump and redefine the XML; do not rebuild the domain with
`virt-install`.** A fresh `virt-install` generates a new MAC, and
cloud-init baked the original MAC into the guest's netplan as a `match:`
rule — a new MAC means the interface does not match and the VM boots with
**no network**, recoverable only from the serial console. The XML carries
the MAC and the UUID (AppArmor regenerates its profile from the XML on
start, so there is nothing to do there).

Check these on the destination *before* copying — each one is a start
failure if missing:

```bash
virsh --connect qemu:///system nwfilter-list | grep isolate-guest  # else: ./setup-network.sh
virsh --connect qemu:///system net-list --all | grep default
virsh --connect qemu:///system capabilities | grep -o 'pc-q35-[a-z0-9.]*' | sort -u
virsh --connect qemu:///system dominfo <name>      # must fail: no name collision
getfacl -p . | grep libvirt-qemu                   # else: setfacl -m u:libvirt-qemu:rwx .
df -h .                                            # vs. qemu-img info on the source
```

The machine type matters: domains here record `pc-q35-noble`, an
**Ubuntu-specific alias**. A destination on another distro or an older
QEMU will not have it, and the domain fails to start — edit `<type
machine=...>` to a supported version from the `capabilities` list above.
Note `setup-network.sh` refuses to run while any VM is running, so if the
destination already hosts VMs, that setup has to predate them.

On the source (VM already `shut off`):

```bash
cd "$KVM_FRIENDS"; NAME=vm-anac
virsh --connect qemu:///system dumpxml --inactive $NAME > /tmp/$NAME.xml
qemu-img info  $NAME.qcow2      # confirm there is NO "backing file:" line
qemu-img check $NAME.qcow2      # cheap insurance before a long copy
```

`--inactive` matters: dumping a *running* domain bakes this host's expanded
CPU features into the XML.

Copy host-to-host rather than via a laptop. Neither host needs standing SSH
trust to the other — forward a throwaway agent, which leaves nothing behind
on either box:

```bash
eval "$(ssh-agent -s)"; ssh-add ~/.ssh/id_ed25519
trap 'ssh-agent -k' EXIT
ssh -A cnetto@<src> "scp -p $NAME.qcow2 $NAME-seed.img \
    $NAME-console-password.txt /tmp/$NAME.xml cnetto@<dst>:/path/to/kvm-friends/"
```

`rsync -aHAX --sparse` is better when it is available on **both** ends
(rsync-over-ssh runs rsync remotely too) — reliablesite does not have it.
`scp -p` is the fallback and preserves the `600` on the password file;
sparseness is not a concern in practice, since these qcow2 files are
compact rather than hole-punched (`du` and `du --apparent-size` agree).
Verify with `sha256sum` on both sides afterwards — that, not the copy tool,
is the integrity guarantee.

On the destination:

```bash
cd "$KVM_FRIENDS"
sed -i "s#/old/path/to/kvm-friends/#$PWD/#g" $NAME.xml   # absolute disk paths
virsh --connect qemu:///system define $NAME.xml
virsh --connect qemu:///system domblklist $NAME          # confirm new paths
virsh --connect qemu:///system start $NAME
```

Resizing while it is off costs nothing — the XML is right there, and a cold
boot means no `setvcpus`/`setmem` dance. Edit `<vcpu placement='static'>`
or `<memory>`/`<currentMemory>` (KiB) before `define`.

Verify: `domifaddr` shows a **new** 192.168.122.x lease (irrelevant —
access is over Tailscale), and from another tailnet node the VM answers on
its *same* Tailscale IP.

### Optional: let the *new* host log in to the guest

`create-vm.sh` put the **old** host's `~/.ssh/id_ed25519.pub` in the
friend's `authorized_keys`. Unless both hosts share a key, the new host
cannot SSH into the VM after the move — sshd answers and then rejects it:

```bash
# From the new host, once the VM has an IP:
ssh -o BatchMode=yes <friend>@<new-192.168.122.x> true && echo "already trusted"
# 'Permission denied (publickey)' = the guest does not know this host's key.
```

This is **optional**, and often the correct answer is to leave it alone:

- **Before handoff**, Carlos still needs a way in for maintenance — worth
  fixing, since otherwise the only access left is the serial console.
- **After handoff** the friend has already run
  `~/REMOVE_TK_SSH_PUB_KEY.sh` and the old key is gone by design. Adding
  the new host's key re-grants Carlos SSH access to a machine that was
  deliberately handed over. Do it only with the friend's agreement, or not
  at all — the VM does not need host SSH to work, and Tailscale is
  unaffected either way.

Do **not** try to fix this by editing the seed: cloud-init sees the same
`instance-id` and never re-reads it, so the old key baked into
`<name>-seed.img` is inert.

The reliable path is the serial console — it needs no key and no network,
and the console password came across with the other files:

```bash
virsh --connect qemu:///system console <name>       # detach: Ctrl+]
# log in as <friend>, password from <name>-console-password.txt, then paste
# the NEW host's ~/.ssh/id_ed25519.pub:
#   echo 'ssh-ed25519 AAAA... cnetto@newhost' >> ~/.ssh/authorized_keys
```

Asking the friend to append it over their own Tailscale session works too,
and is the better route once the machine is theirs.

Two notes: host → guest SSH works at all only because `isolate-guest` drops
`state='NEW'` in the guest→host direction, so the host's connection and its
replies are fine (see "Network isolation"). And if a previous VM on this
host used the same lease, clear the stale entry first — `ssh-keygen -R
<new-ip>` — or ssh refuses with a host-key warning.

**Never run both copies.** Two machines sharing one Tailscale node key
fight over the identity, and they share SSH host keys too. Only once the
new one is verified, on the old host: `virsh undefine <name>`, then move
its files aside as a cold backup rather than leaving them startable.

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
- 2026-08-28: vCPU count made selectable at creation time (1, 4, or 8;
  still defaults to 8) instead of hardcoded — `create-vm.sh` gained a 7th
  positional argument, `vm-tui.py`'s create form gained a vCPU select.
  RAM options in the TUI extended downward (512 MB, 1 GB, 2 GB, 4 GB added
  below the existing 8/16/24/32 GB) for smaller/test VMs.
- 2026-08-31: first host-to-host VM move, and the "Moving a VM to another
  host" section above written from it. `vm-anac` moved from `reliablesite`
  to `msa1-01-ord` (where the repo lives at `$HOME/Git/kvm-friends`, not
  `$HOME/kvm-friends` — the path rewrite is why the domain XML has to be
  edited, not just copied). Cold move: VM shut off first, `dumpxml
  --inactive`, then 8.4 GB of qcow2 + seed + console password + XML copied
  **host to host** with `scp -p` over the tailnet (~5 min). Two practical
  findings: reliablesite has no `rsync` (and rsync-over-ssh needs it on
  both ends), and neither host has SSH trust to the other — solved by
  forwarding a throwaway `ssh-agent` from the laptop (`ssh -A`), which
  moves the bytes directly between the two boxes without a laptop round
  trip and leaves no new `authorized_keys` entry behind. All four files
  verified by matching sha256 on both sides; `scp -p` preserved the 600 on
  the console password. On the destination *only*, vCPUs were reduced 8 → 2
  by editing `<vcpu placement='static'>` before `define` — free while the
  domain is off, no `setvcpus` dance. UUID, MAC (`52:54:00:27:a0:68`),
  8 GiB memory, `pc-q35-noble` and the `isolate-guest` filterref all
  preserved by redefining the dumped XML rather than re-running
  `virt-install`; the MAC matters most, since cloud-init pinned it into the
  guest's netplan `match:` and a fresh `virt-install` MAC would have booted
  the VM with no network at all. Both hosts happened to run identical
  libvirt 10.0.0 / QEMU 8.2.2 on AMD Zen CPUs (EPYC 4545P → Ryzen 9
  9950X), so `host-passthrough` and the Ubuntu-specific `pc-q35-noble`
  alias were both non-issues here — neither is guaranteed on a future move,
  hence the destination pre-flight checks in the section above. Also added
  a narrow `vm-*.xml` gitignore rule, since the documented procedure now
  drops domain XML dumps in the repo folder (`*.xml` would have swallowed
  the tracked `isolate-guest.xml` and `default-net.xml`). vm-anac booted on
  msa1-01-ord first try, taking a fresh lease (192.168.122.171) on the
  preserved MAC — proof the netplan `match:` concern is real and that
  redefining the XML is what avoids it. One gap surfaced only after boot,
  now written up as "Optional: let the new host log in to the guest": the
  two hosts have different `id_ed25519` keys, so the guest's
  `authorized_keys` still trusted only `cnetto@reliablesite` and the new
  host got `Permission denied (publickey)`. Nothing is broken by that —
  the VM and its Tailscale access are unaffected — but it means a moved VM
  silently loses host-side SSH unless the key is added over the serial
  console. Destroying the original left to Carlos.
- 2026-09-07: `vm-tui.py` gained `e` (edit VM) — resize a **shut-off** VM's
  vCPUs and RAM from the same selects the create form uses; disk shown but
  not editable. Gated on `shut off` because there is no balloon and no CPU
  hotplug here, so `--config` edits only land at the next boot. Two details
  worth keeping: the option list folds in the VM's *current* value when it
  isn't one of the menu sizes (Textual's `Select` raises on a value outside
  its options, and real VMs sit on off-menu sizes — `vm-anac` runs 2 vCPUs
  after the host move), and the virsh pairs are ordered by direction, since
  `<memory>`/`--maximum` is a ceiling for the value: ceiling-first when
  growing, value-first when shrinking. Verified headlessly with
  `App.run_test()` (refuses a running VM, prefills off-menu values, no-op
  and cancel do nothing, step ordering correct in both directions, a failed
  step aborts the rest) and end to end against libvirt by round-tripping
  `vm-workspace-demo-circle` 4 vCPU/24 GB -> 1/2 GB -> back, with the
  inactive XML diffing clean against a pre-change dump.
- 2026-09-07: vCPU menu extended with 12 and 16 (was 1/4/8) in both the
  create and edit forms; still defaults to 8. 16 verified against libvirt
  on this host by round-tripping `vm-workspace-demo-circle` 4 -> 16 -> 4
  (host has 32 threads, `virsh maxvcpus kvm` reports 255, so the menu is
  nowhere near a limit). Note the asymmetry with RAM now worth remembering:
  RAM is genuinely reserved and must not be oversubscribed, but vCPUs are
  not — VMs may total more than 32 and simply contend for host threads.
- 2026-09-08: `move-vm.sh` + `m` in `vm-tui.py` automate the whole
  "Moving a VM to another host" section: destination pre-flight, clean
  shutdown, `tar`-over-ssh stream, sha256 verify on both sides, then
  redefine on the destination with the disk paths rewritten. Design points
  worth keeping: (a) **nothing is ever deleted on the source** —
  `--retire-source` at most undefines the domain and leaves the disk as a
  cold backup, because the real hazard here is running both copies, which
  fight over one Tailscale node key and identical SSH host keys; (b) the
  domain XML is redefined, not rebuilt, so name/UUID/MAC survive — verified
  by diffing source against destination XML, where the *only* difference is
  the two absolute disk paths; (c) checksums are compared **before** `virsh define`, so a
  corrupted transfer leaves nothing registered on the far side. Compression
  is negotiated to the best codec both ends have (zstd > pigz > gzip,
  `--no-compress` to skip): measured on these real disks, ratios ran 1.05x
  on `vm-dtw-k3s`'s first 400 MB but 1.45x and 2.48x mid-file on `vm-anac`
  and `vm-workspace-demo-circle`, and zstd's cost is negligible next to
  gzip's (0.35s vs 5.8s per 400 MB), so it is close to free when it helps.
  Verified in a sandbox — a throwaway copy of the repo with real qcow2
  files, real tar/ssh-pipeline/sha256/compression, and stubbed `virsh`/`ssh`
  — since all four VMs on this host were running and there was no second
  host to move to: full clean move, all 10 pre-flight guards refusing
  without defining anything remotely, deliberate mid-transfer corruption
  caught, `--retire-source`, and `--no-compress`. **Not yet exercised
  against a real second host**; the first real run is the proof.
- 2026-09-09: correction to the entry above — the reason the move must
  preserve identity is **Tailscale**, not Terraform (that was a slip in the
  original write-up). The mechanism is different and worth being precise
  about: Tailscale identity is preserved by the *disk copy*, since
  `/var/lib/tailscale/tailscaled.state` lives in the guest filesystem and
  travels inside the qcow2 — verified on the running `vm-dtw-k3s`, where
  that file is 0600 root:root next to `profile-data/`, and the guest answers
  on 100.66.218.42. This is not theory: the 2026-08-31 `vm-anac` move
  (reliablesite -> msa1-01-ord) already proved it end to end — Tailscale
  kept working on the new host with no modifications inside the guest, which
  is the same guest image these scripts produce. That move copied the qcow2
  plus the domain definition (UUID, MAC and all), which is what `move-vm.sh`
  now does — plus the seed image, which the domain lists as a second disk
  and will not start without, and the console password. Preserving
  name/UUID/MAC via the XML is a *separate* guarantee from the Tailscale one
  (the MAC matters because of the netplan `match:` rule). No code changed:
  `move-vm.sh` already copies the disk byte-for-byte and sha256-verifies it
  before defining, which is exactly what a portable Tailscale identity
  needs. It also sharpens why the "never run both copies"
  warning matters — two copies of one node key fight over that identity.
- 2026-09-11: memory policy changed again, and this time the balloon is
  back — but only in the direction that cannot hurt. `create-vm.sh` now
  passes `--memballoon model=virtio,freePageReporting=on,stats.period=10`
  instead of `model=none`, while still passing `--memory` alone so
  `<memory>` and `<currentMemory>` come out equal and the balloon starts
  **empty** (verified with `virt-install --print-xml`, which also confirmed
  libvirt 10.0.0 accepts both attributes — they are in
  `domaincommon.rng`). The guest therefore always sees all of its RAM and
  nothing can take any away; the device exists solely so the guest's
  allocator can hand back pages on its own free list. Prompted by a real
  need on `msa1-01-vcp`: 60 GB of host RAM, `vm-monise` (8 GB) and
  `vm-monise-dtw` (32 GB, already 19 GB resident) running, and two more
  32 GB VMs to create — 104 GB configured against 60 GB of RAM. The
  important correction recorded while working this out: the 2026-07-10
  instability was **not** the balloon device misbehaving. That policy
  booted guests at 4 GB `<currentMemory>` under a 16 GB `<memory>`, i.e.
  with the balloon inflated by 12 GB, and nothing ever ran `setmem` to
  give it back — so guests hit their own OOM killer inside an artificially
  small box, with `autodeflate` firing as an emergency valve. Inflation was
  the bug; reporting is safe and one-way. Also corrected, after nearly
  getting it backwards on this host: **do not lower `vm.swappiness` on a VM
  host.** Guest RAM is host anonymous memory, which is exactly what low
  swappiness protects, so the usual workstation value of 10 tells the
  kernel to keep idle guest pages resident and evict page cache instead —
  the opposite of what an over-subscribed host wants. Left at the default
  60. Host swap on this box grown 512 MB -> 32 GB -> 64 GB on the NVMe to
  cover the gap, since undershooting swap means the OOM killer eventually
  takes a whole `qemu-system-x86` process rather than merely slowing
  things down. KSM was already on here and is worth roughly 116 MB across
  two guests — a bonus, not a plan. Documented but **not applied to the
  two existing VMs**: that needs a shutdown plus the XML edit now written
  up under "Adding reporting to a VM created before 2026-09-11".
  Sharpened once the workload was known — the two new VMs will run k3s with
  30-60 Java pods and sit unattended for days at a time, which is the case
  free page reporting handles *worst*: an idle JVM never GCs, so its heap is
  never uncommitted to the guest kernel and there is nothing on the free
  list to report. The balloon's real value there is as the **return path**
  for guest-side reclaim, not as a mechanism of its own, so "Guests running
  k3s with Java workloads" was added with the three levers that actually
  free memory (guest swap + `--kubelet-arg=fail-swap-on=false`, an
  uncommitting GC or `-XX:G1PeriodicGCInterval`, and pod memory limits with
  `-XX:MaxRAMPercentage`). Host swap stays the primary mechanism for this
  workload, since it needs no cooperation from Java or k3s at all. KSM ruled
  out on measurement rather than theory (~116 MB shared vs ~9.7 GB volatile
  with one Java guest up); Carlos's instinct was right, though the mechanism
  is content mutation under a compacting GC, not JIT address translation.
  Decision taken: host swap only (option 1), no JVM flags, no guest swap, and
  overbooking kept modest.
- 2026-09-11: free-page reporting made a per-VM switch. `<memballoon>` is a
  per-domain attribute, so `vm-tui.py`'s `e` form gained a **Free-page
  reporting** select alongside vCPUs and RAM, and the table gained a BALLOON
  column (`report` / `off`) read from the *inactive* XML — what the next boot
  will use. Same `shut off` gating as the rest of the form: the device cannot
  be swapped on a live domain. There is no virsh verb for this, so the TUI
  dumps the inactive XML, replaces the whole `<memballoon>` element and
  redefines; replacing rather than patching is what drops the now-invalid PCI
  `<address>` so libvirt assigns a fresh one. It runs *after* the
  `setmem`/`setvcpus` steps, since those rewrite the stored XML and a dump
  taken earlier would define a stale copy and undo the resize. Verified
  headlessly with `App.run_test()` and a stubbed `virsh` (24 checks: parsing
  all four `<memballoon>` shapes, both rewrite directions, disk/MAC/filterref/
  memory preserved across the redefine, step ordering in three scenarios, and
  the modal's prefill plus no-op path), then read-only against libvirt — both
  live VMs correctly report `off`.
- 2026-09-11: `isolate-guest.xml` regained the blanket RFC1918 rules that
  the 2026-08-03 rewrite had removed, *alongside* the computed host-subnet
  rule rather than instead of it. Found by auditing this host before
  creating a VM: the filter actually defined here is still the pre-2026-08-03
  static version, and comparing it against what `setup-network.sh` would now
  generate showed that running the script would have **weakened** isolation.
  This host has `docker0` at 172.17.0.1/16 with `ip_forward=1`; the old
  blanket `172.16.0.0/12` rule covers it, while the regenerated filter would
  have blocked only 192.168.122.0/24, the computed 192.168.68.0/22, link-local
  and CGNAT — leaving a guest able to reach 172.17.0.1, which is a host
  address. The 2026-08-03 change was right about the colo case (a public /24
  on the NIC that no RFC1918 rule covers) but wrong to treat breadth and
  precision as alternatives. The generated rule moved from priority 503 to
  506 to sit after the blanket ones (500-505). Also fixed while testing: the
  new template comment originally contained the literal `@HOST_LAN_RULE@`
  token, so `sed` substituted it inside the comment as well — harmless to
  XML parsing but it shipped a nonsense comment into every generated filter.
  The token now appears exactly once in the file, asserted at edit time.
  Verified by rendering the template for this host and parsing the result:
  nine rules in priority order, `172.16.0.0/12` present. **Not applied** —
  `setup-network.sh` refuses to run while a VM is running, and both VMs are
  up; the filter currently defined here remains safe in the meantime because
  its blanket `192.168.0.0/16` covers both this host's LAN (192.168.68.0/22)
  and the bridge.
- 2026-09-15: `move-vm.sh` stopped assuming every VM has exactly a
  `<name>.qcow2` + `<name>-seed.img` pair. It now reads the domain's actual
  disk set from `virsh domblklist` (skipping cdrom slots with no source,
  i.e. `-`), so it also covers a VM outside the create-vm.sh cloud-init
  recipe. Prompted by a real failure: moving `win10` — a hand-built Windows
  guest (no cloud-init, no seed disk, just a qcow2 and an empty cdrom slot)
  — hit the hardcoded `$NAME-seed.img not found` check. Each discovered disk
  must still resolve to a file directly in this folder (refused otherwise,
  per "Ground rules"), and only qcow2-format disks get the backing-file/
  `qemu-img check` pass — a raw disk is copied and hashed but not checked,
  same as the seed image always was. Verified by dry-running the new
  disk-discovery loop against the real `win10` domain on this host: it
  correctly picked up `win10.qcow2` alone, skipped the sourceless cdrom, and
  reported no backing file. Not yet exercised end to end (no second host
  available in this session) — the disk-discovery and integrity-check
  stages were verified directly; the transfer/define stages are unchanged
  from the already-validated `vm-anac` move.

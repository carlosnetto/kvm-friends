# kvm — Virtual Machines for Carlos's Friends

This repo holds the standards and tooling for KVM/libvirt virtual machines
that Carlos hosts for friends. Each VM is a headless Ubuntu Server (no X, no
browser, no SPICE/VNC) that the friend accesses remotely over **Tailscale**.

The repo is host-independent: clone it anywhere on a Linux machine with KVM
and follow the bootstrap in `CLAUDE.md` to reproduce the whole setup. Every
script self-locates from its own path, so nothing here hardcodes where it
lives — set `KVM_FRIENDS` to wherever you clone it (e.g. `export
KVM_FRIENDS=$HOME/kvm-friends` in your shell rc) and every command in this
doc and in `CLAUDE.md` works unchanged. Only recipes and network configs
are versioned — VM disks, cloud-init seeds, console passwords, and the
base image are gitignored and stay local.

## Where this lives, and why

This host (`reliablesite`, a colo box) is a single-disk machine: one 1.8 TB
NVMe, one LVM root volume, nothing else to segregate VMs onto. The folder
is `$KVM_FRIENDS` (`$HOME/kvm-friends` on this particular host), and VM
disks share that same volume with the host OS — there's no dedicated
secondary drive here.

The trade-offs are accepted, not overlooked:

- **Shared capacity.** Disks are thin-provisioned 256 GB each; check `df -h
  /` before adding another VM or letting one grow large — usage is
  typically a few GB per VM, well under the volume's headroom, but it's
  shared with the host, not a reserved slice.
- **No RAID, no backups.** One disk. If it dies, the VMs (and the host)
  are gone. That's acceptable because a VM is reproducible: `create-vm.sh`
  rebuilds one from scratch in a couple of minutes. Friends should not
  keep the only copy of anything they care about inside their VM — tell
  them so at handoff.

If this ever moves to a host with a separate disk worth using, follow
"Moving the folder to another disk" in `CLAUDE.md` — never by symlinking,
which leaves the domain XML pointing at a path that does not exist.

## What's in this folder

Versioned (in git):

| File | Purpose |
|---|---|
| `setup-host.sh` | One-time host setup: installs the KVM/libvirt stack (apt) plus uv/Python 3.13 (brew), assuming a virgin machine. Idempotent. |
| `create-vm.sh` | Creates a VM end to end: prompts for name/login/key (optional Tailscale pre-auth key, RAM, disk size), builds and boots it, runs the isolation check, sets up Tailscale. |
| `vm-tui.py` | **Interactive console — start this if you don't want to remember commands.** Lists every VM and starts/stops them with single keys. Run `./vm-tui.py`; uv builds its environment on first run. |
| `list-vm.sh` | One-line overview per VM: state, IP, vCPUs, RAM current/max, disk used. Same data as `vm-tui.py`, for scripts and pipes. |
| `destroy-vm.sh` | Destroys a VM and all its files (asks you to retype the name; `--yes` to skip). |
| `setup-network.sh` | One-time network isolation setup: defines the nwfilter and replaces the default network. Computes this host's own subnet fresh each run. Refuses to run while a VM is running. |
| `isolate-guest.xml` | libvirt nwfilter applied to every VM's NIC: internet-only egress, no access to the host's local network segment, the host itself, or other VMs. |
| `default-net.xml` | The libvirt NAT network with host DNS disabled — VMs get public DNS (1.1.1.1 / 9.9.9.9) via DHCP. |
| `CLAUDE.md` | The operational recipe: host bootstrap, VM creation, handoff, teardown. |

Local only (gitignored):

| File | Purpose |
|---|---|
| `noble-server-cloudimg-amd64.img` | Base image: Ubuntu Server 24.04 LTS cloud image (downloaded at bootstrap, checksum-verified). **Never boot or modify this file** — always copy it. |
| `<vm-name>.qcow2` | A VM's disk (256 GB virtual by default, thin-provisioned — grows with use). VMs get a fixed 16 GB RAM by default (no ballooning — real memory) and 8 vCPUs. |
| `<vm-name>-seed.img` | The VM's cloud-init seed (user, SSH keys, hostname, console password). Only used on first boot. |
| `<vm-name>-console-password.txt` | Password for local serial-console login (not usable over SSH). |

## How a VM is created (summary)

1. Copy the base cloud image to a new `.qcow2` and resize it to 256 GB
   (thin — it starts at ~600 MB on disk).
2. Build a cloud-init seed that creates the friend's user with **both** SSH
   public keys: the friend's and Carlos's (Carlos's is temporary, for setup).
3. `virt-install` with `--import`, `--graphics none`, serial console only,
   NAT network. The VM boots ready in under a minute — no installer runs.
4. The VM's network is **internet-only**: a packet filter on its virtual NIC
   blocks all access to Carlos's home network and to the host machine. You
   reach the VM over Tailscale; the VM reaches only the outside world.

## What I need from you (the friend) in advance

1. **Login name** you want inside the VM (lowercase, no spaces).
2. **Your SSH public key** (e.g. the content of `~/.ssh/id_ed25519.pub`).
   Never send the private key.
3. Optionally, a **Tailscale pre-auth key** from your Tailscale admin console
   (Settings → Keys → Generate auth key). With this, the VM joins your
   tailnet automatically on first boot and no manual step is needed.

### Finding (or creating) your SSH public key

On Linux/macOS — and on Windows 10/11 in PowerShell — run:

```bash
cat ~/.ssh/id_ed25519.pub      # or id_rsa.pub on older setups
```

The output is one line starting with `ssh-ed25519 AAAA...` — that whole
line is the public key, safe to send over any channel. If the file doesn't
exist, create a key pair first:

```bash
ssh-keygen -t ed25519          # Enter accepts defaults; passphrase optional
```

The file **without** `.pub` is your private key — never send that one.

## Tailscale setup (the chicken-and-egg solution)

The friend can't reach the VM until it's on their tailnet, but joining the
tailnet needs their approval. Two ways:

- **With pre-auth key (preferred):** cloud-init installs Tailscale and runs
  `tailscale up --auth-key=tskey-...` at first boot. The VM appears in the
  friend's tailnet immediately.
- **Manual:** Carlos SSHes in (his temporary key), installs Tailscale, runs
  `sudo tailscale up`, and sends the friend the login URL it prints. The
  friend approves it in the browser against **their own** Tailscale account.

## Handoff — making the machine truly the friend's

Once Tailscale works and the friend can SSH in:

1. Friend runs `~/REMOVE_TK_SSH_PUB_KEY.sh` — it revokes Carlos's temporary
   key and deletes itself. (Manual way: remove Carlos's line from
   `~/.ssh/authorized_keys`.)
2. Friend runs `passwd` to set their own console password.
3. Optional hardening: `sudo rm /etc/sudoers.d/90-cloud-init-users` so sudo
   requires a password.

SSH password authentication is disabled in all VMs — access is by key only.
Note for friends: the VM runs on Carlos's physical machine, so as hypervisor
admin he can always access the disk/console. That's inherent to hosting.

## Managing VMs (run on the host)

The easy way — an interactive list where you pick a VM and press a key:

```bash
cd "$KVM_FRIENDS"
./vm-tui.py
```

| Key | Does |
|---|---|
| `s` | Start the selected VM (this is how you wake a dormant one). |
| `h` | Graceful shutdown — asks the guest to power off cleanly. |
| `f` | Force off. Like pulling the plug; asks for confirmation first. |
| `c` | Attach to the serial console (`Ctrl+]` to detach). |
| `r` | Refresh now (it also refreshes itself every 5 s). |
| `q` | Quit. |

The table refreshes on its own, so after `s` you can watch the state flip to
`running` and an IP appear a few seconds later. Note that `h` only works once
the guest has actually booted — ACPI shutdown sent to a VM that is still
starting is silently discarded, so wait for its IP to show up first (the tool
warns you if you press `h` too early).

`vm-tui.py` needs [uv](https://docs.astral.sh/uv/), which reads the dependency
block at the top of the script and builds a cached, isolated environment on
first run. Nothing is installed into the system Python. On a new host:
`brew install uv python@3.13` (or the distro equivalent).

The underlying commands, if you prefer typing them:

```bash
virsh --connect qemu:///system list --all           # list VMs
virsh --connect qemu:///system start <vm-name>      # wake a dormant VM
virsh --connect qemu:///system shutdown <vm-name>   # graceful stop
virsh --connect qemu:///system console <vm-name>    # serial console (exit: Ctrl+])
virsh --connect qemu:///system autostart <vm-name>  # start on host boot (see note)

# Destroy a VM completely (irreversible):
virsh --connect qemu:///system destroy <vm-name>        # force power-off (if running)
virsh --connect qemu:///system undefine <vm-name>       # remove definition
rm "$KVM_FRIENDS"/<vm-name>.qcow2 \
   "$KVM_FRIENDS"/<vm-name>-seed.img \
   "$KVM_FRIENDS"/<vm-name>-console-password.txt    # delete disk, seed, password
ssh-keygen -R <vm-ip>   # forget its host key, or the next VM reusing the IP
                        # triggers a "HOST IDENTIFICATION CHANGED" warning
```

Autostart is currently **off** for every VM — nothing starts on its own
after a host reboot, by design, so a crash or maintenance reboot doesn't
silently bring VMs back up unattended. Enable it per VM with `virsh
autostart <vm-name>` if you want the opposite.

---

*Process validated on 2026-07-08 with a test VM (created, SSH-verified, and
destroyed).*

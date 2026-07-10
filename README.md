# ~/kvm — Virtual Machines for Carlos's Friends

This repo holds the standards and tooling for KVM/libvirt virtual machines
that Carlos hosts for friends. Each VM is a headless Ubuntu Server (no X, no
browser, no SPICE/VNC) that the friend accesses remotely over **Tailscale**.

The repo is host-independent: clone it to `~/kvm` on any Linux machine with
KVM and follow the bootstrap in `CLAUDE.md` to reproduce the whole setup.
Only recipes and network configs are versioned — VM disks, cloud-init seeds,
console passwords, and the base image are gitignored and stay local.

## What's in this folder

Versioned (in git):

| File | Purpose |
|---|---|
| `isolate-guest.xml` | libvirt nwfilter applied to every VM's NIC: internet-only egress, no access to the host's LAN, the host itself, or other VMs. |
| `default-net.xml` | The libvirt NAT network with host DNS disabled — VMs get public DNS (1.1.1.1 / 9.9.9.9) via DHCP. |
| `CLAUDE.md` | The operational recipe: host bootstrap, VM creation, handoff, teardown. |

Local only (gitignored):

| File | Purpose |
|---|---|
| `noble-server-cloudimg-amd64.img` | Base image: Ubuntu Server 24.04 LTS cloud image (downloaded at bootstrap, checksum-verified). **Never boot or modify this file** — always copy it. |
| `<vm-name>.qcow2` | A VM's disk (256 GB virtual, thin-provisioned — grows with use). VMs get 4 GB RAM (growable live to 16 GB on request) and 8 vCPUs. |
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

1. Friend (or Carlos) removes Carlos's line from `~/.ssh/authorized_keys`.
2. Friend runs `passwd` to set their own console password.
3. Optional hardening: `sudo rm /etc/sudoers.d/90-cloud-init-users` so sudo
   requires a password.

SSH password authentication is disabled in all VMs — access is by key only.
Note for friends: the VM runs on Carlos's physical machine, so as hypervisor
admin he can always access the disk/console. That's inherent to hosting.

## Managing VMs (run on the host)

```bash
virsh --connect qemu:///system list --all           # list VMs
virsh --connect qemu:///system start <vm-name>
virsh --connect qemu:///system shutdown <vm-name>   # graceful stop
virsh --connect qemu:///system console <vm-name>    # serial console (exit: Ctrl+])
virsh --connect qemu:///system autostart <vm-name>  # start on host boot

# Destroy a VM completely (irreversible):
virsh --connect qemu:///system destroy <vm-name>        # force power-off (if running)
virsh --connect qemu:///system undefine <vm-name>       # remove definition
rm ~/kvm/<vm-name>.qcow2 ~/kvm/<vm-name>-seed.img \
   ~/kvm/<vm-name>-console-password.txt                 # delete disk, seed, password
ssh-keygen -R <vm-ip>   # forget its host key, or the next VM reusing the IP
                        # triggers a "HOST IDENTIFICATION CHANGED" warning
```

---

*Process validated on 2026-07-08 with a test VM (created, SSH-verified, and
destroyed).*

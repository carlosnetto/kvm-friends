#!/usr/bin/env bash
# setup-host.sh — install everything this host is missing to run the
# kvm-friends recipe (see CLAUDE.md). Idempotent: safe to re-run, and
# assumes a virgin machine (no brew, no uv, nothing preinstalled).
#
# Covers, in order:
#   1. KVM/libvirt stack (qemu, virsh, virt-install, cloud-localds, setfacl)
#      — Debian/Ubuntu only; KVM needs Linux, there is no macOS equivalent.
#   2. uv + Python 3.13, for vm-tui.py (works on Linux or macOS).
#
# Does NOT download the base cloud image or run the one-time network
# setup — those are separate steps in CLAUDE.md ("New host bootstrap").
set -euo pipefail

info() { echo; echo "==> $*"; }

# ---- 1. KVM / libvirt stack -------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
  info "Installing KVM/libvirt stack (apt)"
  sudo apt update
  sudo apt install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    cloud-image-utils \
    qemu-utils \
    acl \
    curl \
    openssl

  # Own account needs to run virsh/virt-install without sudo.
  if ! id -nG "$USER" | grep -qw libvirt; then
    info "Adding $USER to the libvirt group (log out/in to take effect)"
    sudo usermod -aG libvirt "$USER"
  fi
elif [ "$(uname -s)" = Darwin ]; then
  echo "SKIPPING KVM/libvirt stack: KVM is a Linux kernel feature, there is" >&2
  echo "no macOS equivalent. This step only applies on the Linux host that" >&2
  echo "actually runs the VMs." >&2
else
  echo "ERROR: no apt-get found and not macOS — install the KVM/libvirt" >&2
  echo "stack manually for your distro (qemu-kvm, libvirt daemon + client" >&2
  echo "tools, virt-install, cloud-localds, setfacl)." >&2
  exit 1
fi

# ---- 2. uv + Python 3.13, for vm-tui.py ------------------------------------
# Prefer brew (Homebrew on macOS, Linuxbrew on Linux) — installs on its own
# prefix, no sudo, no distro-package interaction.
if ! command -v brew >/dev/null 2>&1; then
  info "Installing Homebrew (brew not found)"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # first-run PATH: Linuxbrew vs. Apple Silicon vs. Intel Mac prefixes.
  for p in /home/linuxbrew/.linuxbrew/bin /opt/homebrew/bin /usr/local/bin; do
    [ -x "$p/brew" ] && eval "$("$p/brew" shellenv)"
  done
fi

if command -v uv >/dev/null 2>&1; then
  info "uv already installed ($(uv --version))"
else
  info "Installing uv (brew)"
  brew install uv
fi

if uv python list 2>/dev/null | grep -q '^cpython-3\.13'; then
  info "Python 3.13 already available via uv"
else
  info "Installing Python 3.13 (uv)"
  uv python install 3.13
fi

info "Done. vm-tui.py will build its own env on first ./vm-tui.py run."

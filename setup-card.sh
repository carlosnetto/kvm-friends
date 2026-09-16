#!/usr/bin/env bash
# One-shot: make the Alcor AU9540 smartcard reader always accessible headless,
# and let the win10 VM autostart at boot. Run with: sudo bash ~/setup-card.sh
set -e

echo "[1/3] Installing udev rule (plugdev rw access, seat-independent)..."
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="058f", ATTR{idProduct}=="9540", GROUP="plugdev", MODE="0660"' \
  > /etc/udev/rules.d/99-smartcard.rules

echo "[2/3] Reloading udev and re-triggering the device..."
udevadm control --reload-rules
udevadm trigger --attr-match=idVendor=058f

echo "[3/3] Enabling linger for cnetto (so the session VM autostarts at boot)..."
loginctl enable-linger cnetto

echo
echo "Done. Current reader node perms:"
ls -l /dev/bus/usb/001/006 2>/dev/null || ls -l /dev/bus/usb/001/* 2>/dev/null

#!/usr/bin/env bash
# list-vm.sh — one-line overview of every VM: state, IP, CPUs, RAM, disk.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
V() { virsh --connect qemu:///system "$@"; }

printf '%-14s %-10s %-16s %5s %-12s %s\n' NAME STATE IP VCPU "RAM(cur/max)" DISK-USED
V list --all --name | while read -r name; do
  [ -n "$name" ] || continue
  state=$(V domstate "$name" | head -1)
  info=$(V dominfo "$name")
  vcpu=$(awk -F': +' '/^CPU\(s\)/ {print $2}' <<<"$info")
  cur=$(awk '/^Used memory/ {printf "%.0f", $3/1048576}' <<<"$info")
  max=$(awk '/^Max memory/  {printf "%.0f", $3/1048576}' <<<"$info")
  ip=-
  if [ "$state" = running ]; then
    ip=$(V domifaddr "$name" | awk '/ipv4/ {sub(/\/.*/,"",$4); print $4; exit}')
    ip=${ip:--}
  fi
  disk=-
  [ -f "$name.qcow2" ] && disk=$(du -h "$name.qcow2" | cut -f1)
  printf '%-14s %-10s %-16s %5s %-12s %s\n' \
    "$name" "$state" "$ip" "$vcpu" "${cur}G/${max}G" "$disk"
done

#!/usr/bin/env bash
# move-vm.sh — move a VM to another host's kvm-friends folder.
#
# Usage: ./move-vm.sh <vm-name> <user@host:/path/to/kvm-friends> [options]
#   --yes            skip the confirmation prompt (required non-interactively)
#   --no-compress    stream raw instead of negotiating a compressor
#   --retire-source  after a verified move, undefine the source domain so it
#                    cannot be started by accident. Disk files are KEPT as a
#                    cold backup — this script never deletes anything.
#
# This is the "Moving a VM to another host" section of CLAUDE.md, automated.
# A COLD move: the VM is shut down cleanly, its disk + seed + console password
# are streamed over ssh, and its domain XML is redefined on the destination
# with the disk paths rewritten. RAM state is deliberately not preserved —
# a `virsh save` file is tied to the exact QEMU build and would not restore.
#
# The XML is redefined rather than rebuilt with virt-install because it
# carries the MAC, and cloud-init pinned that MAC into the guest's netplan
# `match:` rule — a fresh MAC boots the VM with no network at all.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
SRC_DIR=$PWD

V()    { virsh --connect qemu:///system "$@"; }
err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo; echo "==> $*"; }
human(){ numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

# ---- arguments -------------------------------------------------------------
NAME=${1:-}; DEST=${2:-}
[ -n "$NAME" ] && [ -n "$DEST" ] \
  || err "usage: ./move-vm.sh <vm-name> <user@host:/path/to/kvm-friends> [--yes] [--no-compress] [--retire-source]"
shift 2
YES=; COMPRESS=1; RETIRE=
for arg in "$@"; do
  case "$arg" in
    --yes)           YES=1 ;;
    --no-compress)   COMPRESS= ;;
    --retire-source) RETIRE=1 ;;
    *) err "unknown option: $arg" ;;
  esac
done

# user@host:/path — the path is required, so we never guess where the repo is.
[[ $DEST =~ ^([A-Za-z0-9._-]+)@([A-Za-z0-9._-]+):(/.*)$ ]] \
  || err "destination must be user@host:/absolute/path (got: $DEST)"
RUSER=${BASH_REMATCH[1]}; RHOST=${BASH_REMATCH[2]}; RPATH=${BASH_REMATCH[3]}
RPATH=${RPATH%/}
RTARGET="$RUSER@$RHOST"

# ---- local preconditions ---------------------------------------------------
V dominfo "$NAME" >/dev/null 2>&1 || err "no VM named '$NAME' on this host"
[ "$RHOST" != "$(hostname)" ] || err "destination host is this host"

QCOW=$NAME.qcow2; SEED=$NAME-seed.img; PASSF=$NAME-console-password.txt
[ -f "$QCOW" ] || err "$QCOW not found in $SRC_DIR"
[ -f "$SEED" ] || err "$SEED not found — the domain lists it as a second disk and will not start without it"
FILES=("$QCOW" "$SEED")
if [ -f "$PASSF" ]; then FILES+=("$PASSF"); else
  echo "note: $PASSF not found — moving without it (serial-console login will have no known password)"
fi

# A managed-save file is RAM state tied to this exact QEMU build; it cannot
# travel, and moving the disk out from under it would strand it.
[ "$(V dominfo "$NAME" | awk -F: '/Managed save/{gsub(/ /,"",$2); print $2}')" != yes ] \
  || err "'$NAME' has a managed-save state. Restore and shut it down first: virsh start $NAME && virsh shutdown $NAME"

TOTAL=0; for f in "${FILES[@]}"; do TOTAL=$((TOTAL + $(stat -c%s "$f"))); done

# ---- remote pre-flight -----------------------------------------------------
# One ssh connection, reused by every later step (ControlMaster), so a
# passphrase or 2FA is asked at most once.
CTL=$(mktemp -u /tmp/move-vm-XXXXXX.sock)
SSH=(ssh -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=300 "$RTARGET")
cleanup() { ssh -o ControlPath="$CTL" -O exit "$RTARGET" 2>/dev/null || true; }
trap cleanup EXIT

info "Checking destination $RTARGET:$RPATH"
if ! "${SSH[@]}" -o BatchMode=yes -o ConnectTimeout=10 true 2>/dev/null; then
  err "cannot ssh to $RTARGET non-interactively.
       Establish it by hand first (this also pins the host key):
         ssh $RTARGET true"
fi

MACHINE=$(V dumpxml --inactive "$NAME" | grep -o "machine='[^']*'" | head -1 | cut -d\' -f2)

# Everything the destination must satisfy, gathered in one round trip. Each
# is a start failure (or a silent corruption) if missing.
REMOTE=$("${SSH[@]}" bash -s -- "$RPATH" "$NAME" "$MACHINE" "$TOTAL" <<'EOF'
set -u
RPATH=$1; NAME=$2; MACHINE=$3; NEED=$4
say() { echo "$1=$2"; }
V() { virsh --connect qemu:///system "$@"; }
[ -d "$RPATH" ] || { say fatal "no such directory: $RPATH"; exit 0; }
cd "$RPATH" || { say fatal "cannot cd to $RPATH"; exit 0; }
say rpath "$PWD"
say writable "$([ -w . ] && echo yes || echo no)"
command -v virsh >/dev/null && say virsh yes || { say fatal "virsh not installed on destination"; exit 0; }
V version >/dev/null 2>&1 && say libvirt yes || { say fatal "cannot talk to libvirtd (is the user in the libvirt group?)"; exit 0; }
V nwfilter-dumpxml isolate-guest >/dev/null 2>&1 && say nwfilter yes || say nwfilter no
V net-info default >/dev/null 2>&1 && say network yes || say network no
V dominfo "$NAME" >/dev/null 2>&1 && say collision yes || say collision no
V domcapabilities --machine "$MACHINE" >/dev/null 2>&1 && say machine yes || say machine no
getfacl -p . 2>/dev/null | grep -q '^user:libvirt-qemu:.*x' && say acl yes || say acl no
FREE=$(df -P . | awk 'NR==2{print $4*1024}')
say free "$FREE"
say enough "$([ "$FREE" -gt "$NEED" ] && echo yes || echo no)"
EX=
for f in "$NAME.qcow2" "$NAME-seed.img"; do [ -e "$f" ] && EX="$EX $f"; done
say existing "${EX# }"
command -v tar >/dev/null && say tar yes || say tar no
C=
for c in zstd pigz gzip; do command -v $c >/dev/null && C="$C $c"; done
say compressors "${C# }"
EOF
)
g() { echo "$REMOTE" | grep "^$1=" | head -1 | cut -d= -f2-; }
[ -z "$(g fatal)" ] || err "destination: $(g fatal)"
RPATH=$(g rpath)                       # canonical, ~ and symlinks resolved
[ "$(g writable)" = yes ] || err "destination $RPATH is not writable by $RUSER"
[ "$(g tar)"      = yes ] || err "destination has no tar"
[ "$(g nwfilter)" = yes ] || err "destination has no 'isolate-guest' nwfilter — run ./setup-network.sh there first"
[ "$(g network)"  = yes ] || err "destination has no libvirt network 'default' — run ./setup-network.sh there first"
[ "$(g collision)" = no ] || err "destination already has a domain named '$NAME'"
[ "$(g machine)"  = yes ] || err "destination libvirt does not support machine type '$MACHINE'.
       Pick a supported one there (virsh capabilities) and edit <type machine=...> by hand."
[ "$(g enough)"   = yes ] || err "destination has $(human "$(g free)") free, needs $(human "$TOTAL")"
[ -z "$(g existing)" ]    || err "destination already has: $(g existing)"
[ "$(g acl)" = yes ] || echo "note: destination $RPATH has no libvirt-qemu ACL — if the VM fails to start there with
      'Cannot access storage file', run: setfacl -m u:libvirt-qemu:rwx '$RPATH'"

# Best compressor both ends have. Measured on real disks here: ratios run
# 1.05x-2.5x depending on the guest, and zstd costs almost nothing, so this
# is close to free when it helps and cheap when it does not.
PIPE_C=(cat); PIPE_D=(cat); CNAME=none
if [ -n "$COMPRESS" ]; then
  for c in zstd pigz gzip; do
    if command -v "$c" >/dev/null && [[ " $(g compressors) " == *" $c "* ]]; then
      case $c in
        zstd) PIPE_C=(zstd -3 -T0 -c); PIPE_D=(zstd -dc) ;;
        pigz) PIPE_C=(pigz -3 -c);     PIPE_D=(pigz -dc) ;;
        gzip) PIPE_C=(gzip -3 -c);     PIPE_D=(gzip -dc) ;;
      esac
      CNAME=$c; break
    fi
  done
fi

echo "    destination:  $RTARGET:$RPATH"
echo "    free there:   $(human "$(g free)")"
echo "    to transfer:  $(human "$TOTAL") in ${#FILES[@]} files"
echo "    compression:  $CNAME"

# ---- confirm ---------------------------------------------------------------
STATE=$(V domstate "$NAME" | head -1)
cat <<EOF

About to MOVE '$NAME' (currently: $STATE) to $RTARGET:$RPATH
  1. shut it down cleanly here (it will be off when this finishes)
  2. stream $(human "$TOTAL") over ssh
  3. define the domain there, with disk paths rewritten

Nothing is deleted on this host.$([ -n "$RETIRE" ] && echo "
The source domain WILL be undefined afterwards (--retire-source); its disk
files stay on disk as a cold backup.")
EOF
if [ -z "$YES" ]; then
  [ -t 0 ] || err "non-interactive run: pass --yes to confirm"
  read -rp "Type the VM name to confirm: " CONFIRM
  [ "$CONFIRM" = "$NAME" ] || err "name mismatch — nothing moved"
fi

# ---- shut down -------------------------------------------------------------
if [ "$STATE" = running ]; then
  info "Shutting down '$NAME' (ACPI, waiting up to 3 min)"
  V shutdown "$NAME" >/dev/null
  for _ in $(seq 1 36); do
    [ "$(V domstate "$NAME" | head -1)" = "shut off" ] && break
    sleep 5
  done
fi
[ "$(V domstate "$NAME" | head -1)" = "shut off" ] \
  || err "'$NAME' did not shut down. Log in and stop it, or force it off from the TUI ('f'),
       then re-run. Never move a running or saved VM."

# ---- integrity + XML -------------------------------------------------------
# --inactive matters: dumping a running domain bakes this host's expanded CPU
# features into the XML. (It is off by now, but be explicit.)
info "Dumping domain XML and checking the disk"
V dumpxml --inactive "$NAME" > "$SRC_DIR/$NAME.xml"
qemu-img info "$QCOW" | grep -q '^backing file:' \
  && err "$QCOW has a backing file — flatten it first (qemu-img convert), or the copy is not self-contained"
qemu-img check "$QCOW" >/dev/null || err "qemu-img check failed on $QCOW — do not move a damaged image"
echo "    no backing file, image consistent"

info "Hashing ${#FILES[@]} files locally ($(human "$TOTAL"))"
LOCAL_SUMS=$(sha256sum "${FILES[@]}")

# ---- transfer ---------------------------------------------------------------
info "Streaming to $RTARGET:$RPATH (this is the long part)"
set -o pipefail
tar -cf - "${FILES[@]}" \
  | "${PIPE_C[@]}" \
  | "${SSH[@]}" "cd '$RPATH' && $(printf '%q ' "${PIPE_D[@]}") | tar -xpf -" \
  || err "transfer failed — the destination may hold partial files, clean them up before retrying"

info "Verifying checksums on the destination"
REMOTE_SUMS=$("${SSH[@]}" "cd '$RPATH' && sha256sum $(printf '%q ' "${FILES[@]}")")
if [ "$LOCAL_SUMS" != "$REMOTE_SUMS" ]; then
  echo "--- local ---"; echo "$LOCAL_SUMS"
  echo "--- remote ---"; echo "$REMOTE_SUMS"
  err "checksum mismatch — the copy is NOT good. Nothing was defined there."
fi
echo "    all ${#FILES[@]} files match"

# ---- define on the destination ----------------------------------------------
info "Defining '$NAME' on $RHOST"
# The XML records absolute disk paths; rewrite the folder prefix.
sed "s#$SRC_DIR/#$RPATH/#g" "$SRC_DIR/$NAME.xml" \
  | "${SSH[@]}" "cat > '$RPATH/$NAME.xml' && virsh --connect qemu:///system define '$RPATH/$NAME.xml'" >/dev/null \
  || err "define failed on the destination — files are there, domain is not"
"${SSH[@]}" "virsh --connect qemu:///system domblklist '$NAME'" | sed 's/^/    /'

# ---- retire the source ------------------------------------------------------
if [ -n "$RETIRE" ]; then
  info "Retiring the source domain (files kept)"
  V undefine "$NAME"
  echo "    domain undefined here; $QCOW and friends left in place as a cold backup"
fi

# ---- summary ----------------------------------------------------------------
info "Done: '$NAME' now lives on $RHOST"
cat <<EOF
    It is defined and shut off there. Start it from vm-tui.py on $RHOST,
    or:  ssh $RTARGET "virsh --connect qemu:///system start $NAME"

    It keeps its UUID, MAC, and Tailscale identity, so once booted it
    answers on the SAME Tailscale IP as before. Expect a new
    192.168.122.x lease — that is normal and does not matter.
EOF
if [ -n "$RETIRE" ]; then
  cat <<EOF

    The source domain is undefined. Its files are still here as a backup:
      $SRC_DIR/$QCOW
    Delete them once you trust the move.
EOF
else
  cat <<EOF

    *** The source is still defined here and startable. ***
    NEVER run both copies: they share one Tailscale node key and the same
    SSH host keys, and would fight over that identity. Once you have booted
    it on $RHOST and are happy, retire this one:
      virsh --connect qemu:///system undefine $NAME
    (that leaves the disk files as a cold backup; destroy-vm.sh removes them)
EOF
fi

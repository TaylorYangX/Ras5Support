#!/usr/bin/env bash
# Build an Ubuntu 20.04 image that boots on a Raspberry Pi 5: the boot partition,
# kernel, modules and firmware of the Ubuntu 24.04 Pi image, with the 20.04 root
# filesystem swapped in. Unsupported by Canonical; see README.md.
#
#   ./build-pi5-focal.sh --download-only   # fetch and verify both images (no root needed)
#   sudo ./build-pi5-focal.sh              # build ubuntu-20.04-pi5-hybrid.img
set -euo pipefail

NOBLE_URL=https://cdimage.ubuntu.com/releases/noble/release
FOCAL_URL=https://cdimage.ubuntu.com/releases/focal/release
OUT_NAME=ubuntu-20.04-pi5-hybrid.img
# ext4 features newer than 20.04's e2fsprogs 1.45.5. Its resize2fs (first-boot
# root expansion) and e2fsck refuse a filesystem that has any of them.
NEW_EXT4_FEATURES=(orphan_file fast_commit stable_inodes)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKDIR=$SCRIPT_DIR/work
OUT_DIR=auto
DOWNLOAD_ONLY=0

usage() {
	cat <<EOF
Usage: $0 [--download-only] [--workdir DIR] [--out DIR]

  --download-only  Download and verify the 24.04 and 20.04 Pi images, then stop.
  --workdir DIR    Where images and temporary files go (default: $SCRIPT_DIR/work).
                   Must be on the Linux filesystem, not /mnt/c.
  --out DIR        Copy the finished image here (default: your Windows Desktop
                   if exactly one is found under /mnt/c/Users; "" to skip).
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
		--download-only) DOWNLOAD_ONLY=1 ;;
		--workdir) WORKDIR=${2:?--workdir needs a directory}; shift ;;
		--out) OUT_DIR=${2?--out needs a directory}; shift ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
	shift
done

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

check() {  # $1 = description, rest = command that must succeed
	local what=$1; shift
	if "$@"; then echo "  ok: $what"; else die "check failed: $what"; fi
}

need_tools() {
	local t missing=()
	for t in "$@"; do command -v "$t" >/dev/null || missing+=("$t"); done
	[ ${#missing[@]} -eq 0 ] || die "missing tools: ${missing[*]}
  install with: sudo apt install wget rsync xz-utils zstd cloud-guest-utils fdisk e2fsprogs kmod"
}

require_free_gb() {
	local avail
	avail=$(df -BG --output=avail "$WORKDIR" | tail -n1 | tr -dc 0-9)
	[ "$avail" -ge "$1" ] || die "need about $1 GB free in $WORKDIR, only ${avail} GB available"
}

# Download the newest Pi server image listed in a release's SHA256SUMS and verify it.
# $1 = release URL, $2 = name of the variable that receives the local path
fetch_image() {
	local url=$1 sums file
	sums=$WORKDIR/$(basename "$(dirname "$url")").SHA256SUMS
	wget -q -O "$sums" "$url/SHA256SUMS" || die "cannot download $url/SHA256SUMS"
	file=$(awk '{ f = $2; sub(/^\*/, "", f) } f ~ /-preinstalled-server-arm64\+raspi\.img\.xz$/ { print f }' "$sums" |
		sort -V | tail -n1)
	[ -n "$file" ] || die "no Raspberry Pi server image listed in $url/SHA256SUMS"
	awk -v f="$file" '{ g = $2; sub(/^\*/, "", g) } g == f' "$sums" >"$WORKDIR/$file.sha256"

	if [ -f "$WORKDIR/$file" ] && (cd "$WORKDIR" && sha256sum -c --status "$file.sha256"); then
		echo "  $file: already downloaded, checksum ok"
	else
		echo "  downloading $file"
		wget -c -q --show-progress -P "$WORKDIR" "$url/$file"
		if ! (cd "$WORKDIR" && sha256sum -c --quiet "$file.sha256"); then
			rm -f "$WORKDIR/$file"
			die "$file failed its checksum and was deleted; run the script again"
		fi
		echo "  $file: checksum ok"
	fi
	printf -v "$2" '%s' "$WORKDIR/$file"
}

MNT=$WORKDIR/mnt

# Unmount everything under $MNT and detach every loop device backed by our images,
# including leftovers from an interrupted run.
release() {
	local m img dev
	for m in nboot nroot fboot froot; do
		if mountpoint -q "$MNT/$m"; then umount "$MNT/$m" || warn "could not unmount $MNT/$m"; fi
	done
	for img in focal.img noble.img; do
		[ -f "$WORKDIR/$img" ] || continue
		for dev in $(losetup -j "$WORKDIR/$img" | cut -d: -f1); do
			losetup -d "$dev" || warn "could not detach $dev"
		done
	done
}

# $1 = image, $2 = name of the variable that receives the loop device, rest = extra losetup flags
attach() {
	local dev _
	dev=$(losetup -fP --show "${@:3}" "$1")
	for _ in $(seq 20); do [ -b "${dev}p2" ] && break; sleep 0.5; done
	[ -b "${dev}p2" ] || partx -a "$dev" 2>/dev/null || true
	[ -b "${dev}p2" ] || die "partitions of $1 did not appear as ${dev}p1/${dev}p2"
	printf -v "$2" '%s' "$dev"
}

check_label() {  # $1 = partition, $2 = expected filesystem label
	local label
	label=$(blkid -p -s LABEL -o value "$1" || true)
	[ "$label" = "$2" ] || die "$1 has label '$label', expected '$2'"
}

fsck_ok() {  # e2fsck exit 1 means "errors corrected", which is fine here
	local rc=0
	e2fsck -fy "$1" >/dev/null 2>&1 || rc=$?
	[ $rc -le 1 ] || die "e2fsck could not repair $1 (exit $rc)"
}

ext4_features() {
	dumpe2fs -h "$1" 2>/dev/null | sed -n 's/^Filesystem features:[[:space:]]*//p'
}

# ---------------------------------------------------------------- preflight

need_tools wget sha256sum awk
mkdir -p "$WORKDIR"
WORKDIR=$(cd "$WORKDIR" && pwd)
MNT=$WORKDIR/mnt
case $WORKDIR in
	/mnt/[a-z]/*) die "--workdir is on a Windows drive ($WORKDIR); Linux permissions would be lost. Use a folder under your WSL home." ;;
esac

log "Downloading images into $WORKDIR"
require_free_gb 3
fetch_image "$NOBLE_URL" NOBLE_XZ
fetch_image "$FOCAL_URL" FOCAL_XZ

if [ $DOWNLOAD_ONLY -eq 1 ]; then
	log "Downloads verified. Build with: sudo $0"
	exit 0
fi

[ "$(id -u)" -eq 0 ] || die "the build step needs root (loop devices and mounts): sudo $0"
need_tools rsync xz zstd growpart sfdisk losetup partx blkid blockdev mountpoint \
	e2fsck resize2fs tune2fs dumpe2fs depmod dpkg-divert truncate
require_free_gb 12

trap release EXIT
trap 'exit 130' INT TERM
release

# ---------------------------------------------------------------- unpack and attach

log "Decompressing images"
if [ ! -f "$WORKDIR/focal.img" ] || [ "$FOCAL_XZ" -nt "$WORKDIR/focal.img" ]; then
	xz -T0 -dc "$FOCAL_XZ" >"$WORKDIR/focal.img.part"
	mv "$WORKDIR/focal.img.part" "$WORKDIR/focal.img"
fi
# Always start from a fresh 24.04 image; the .xz is the untouched backup.
xz -T0 -dc "$NOBLE_XZ" >"$WORKDIR/noble.img"

log "Attaching images"
mkdir -p "$MNT"/{fboot,froot,nboot,nroot}
attach "$WORKDIR/focal.img" FOCAL -r
check_label "${FOCAL}p1" system-boot
check_label "${FOCAL}p2" writable
mount -o ro "${FOCAL}p1" "$MNT/fboot"
mount -o ro,noload "${FOCAL}p2" "$MNT/froot"
grep -q '^VERSION_ID="20.04"' "$MNT/froot/etc/os-release" || die "$FOCAL_XZ is not an Ubuntu 20.04 image"

attach "$WORKDIR/noble.img" NOBLE
check_label "${NOBLE}p1" system-boot
check_label "${NOBLE}p2" writable
mount "${NOBLE}p2" "$MNT/nroot"

# ---------------------------------------------------------------- stash the 24.04 kernel pieces

mapfile -t kvers < <(ls "$MNT/nroot/usr/lib/modules")
[ ${#kvers[@]} -eq 1 ] || die "expected one kernel in the 24.04 image, found: ${kvers[*]}"
KVER=${kvers[0]}
log "Stashing kernel $KVER modules and firmware"
STASH=$WORKDIR/stash
rm -rf "$STASH"
mkdir -p "$STASH/modules" "$STASH/firmware"
rsync -aHAX "$MNT/nroot/usr/lib/modules/$KVER" "$STASH/modules/"
rsync -aHAX "$MNT/nroot/usr/lib/firmware/" "$STASH/firmware/"
umount "$MNT/nroot"

# 24.04 ships zstd-compressed modules; 20.04's kmod 27 can't load them.
nzst=$(find "$STASH/modules" -name '*.ko.zst' | wc -l)
if [ "$nzst" -gt 0 ]; then
	echo "  decompressing $nzst .ko.zst modules for 20.04's kmod"
	find "$STASH/modules" -name '*.ko.zst' -exec zstd -q -d --rm {} +
fi

# ---------------------------------------------------------------- make room, fix ext4 features

need_mb=$(( $(du -sxm "$MNT/froot" | cut -f1) + $(du -sm "$STASH" | cut -f1) ))
need_mb=$(( need_mb * 110 / 100 + 512 ))
have_mb=$(( $(blockdev --getsize64 "${NOBLE}p2") / 1048576 ))
if [ $have_mb -lt $need_mb ]; then
	log "Growing the root partition from ${have_mb} MB to ${need_mb} MB"
	losetup -d "$NOBLE"
	truncate -s +$(( need_mb - have_mb ))M "$WORKDIR/noble.img"
	growpart "$WORKDIR/noble.img" 2
	attach "$WORKDIR/noble.img" NOBLE
	fsck_ok "${NOBLE}p2"
	resize2fs "${NOBLE}p2" >/dev/null
fi

for f in "${NEW_EXT4_FEATURES[@]}"; do
	if [[ " $(ext4_features "${NOBLE}p2") " == *" $f "* ]]; then
		log "Removing ext4 feature $f (too new for 20.04's e2fsprogs)"
		fsck_ok "${NOBLE}p2"
		tune2fs -O "^$f" "${NOBLE}p2" >/dev/null || die "could not remove ext4 feature $f"
	fi
done

# ---------------------------------------------------------------- swap in the 20.04 root

mount "${NOBLE}p1" "$MNT/nboot"
mount "${NOBLE}p2" "$MNT/nroot"
ROOT=$MNT/nroot

log "Replacing the 24.04 root filesystem with 20.04"
rsync -aHAX --numeric-ids --delete --exclude=/lost+found "$MNT/froot/" "$ROOT/"

log "Restoring the 24.04 kernel modules and firmware"
libdir=$ROOT/lib
[ "$(readlink "$ROOT/lib")" = usr/lib ] && libdir=$ROOT/usr/lib
mkdir -p "$libdir/modules" "$libdir/firmware"
rsync -aHAX "$STASH/modules/$KVER" "$libdir/modules/"
# Merged over 20.04's firmware, not replacing it.
rsync -aHAX "$STASH/firmware/" "$libdir/firmware/"
depmod -b "$ROOT" "$KVER"

log "Using 20.04's cloud-init seed files"
# 20.04 runs cloud-init 22.2, which may not understand 24.04's user-data;
# 20.04's own files give the usual ubuntu/ubuntu first login.
for f in user-data network-config; do
	if [ ! -f "$MNT/fboot/$f" ]; then
		warn "the 20.04 image has no $f; keeping the 24.04 one"
		continue
	fi
	[ -f "$MNT/nboot/$f" ] && mv "$MNT/nboot/$f" "$MNT/nboot/$f.noble"
	cp "$MNT/fboot/$f" "$MNT/nboot/$f"
done
grep -rqs 'fs_label: *system-boot' "$ROOT/etc/cloud/cloud.cfg.d/" ||
	warn "20.04's cloud-init isn't configured to read the system-boot partition; first-boot setup may not run"

log "Protecting the Pi 5 boot files from 20.04's kernel tooling"
# Kernel and initramfs updates call flash-kernel, which would copy a 5.4 kernel
# (no Pi 5 support) over /boot/firmware. Divert it to a stub.
if [ -e "$ROOT/usr/sbin/flash-kernel" ]; then
	dpkg-divert --root="$ROOT" --local --rename \
		--divert /usr/sbin/flash-kernel.focal --add /usr/sbin/flash-kernel >/dev/null
	cat >"$ROOT/usr/sbin/flash-kernel" <<'EOF'
#!/bin/sh
# Installed by build-pi5-focal.sh. This Pi 5 boots the Ubuntu 24.04 kernel in
# /boot/firmware; 20.04's flash-kernel would replace it with one that can't boot
# a Pi 5. The original is /usr/sbin/flash-kernel.focal.
echo "flash-kernel: disabled on this Pi 5 hybrid, /boot/firmware left unchanged" >&2
exit 0
EOF
	chmod 755 "$ROOT/usr/sbin/flash-kernel"
else
	warn "no flash-kernel in the 20.04 root; nothing to divert"
fi

# Hold the 20.04 kernel packages on every boot, before apt's timers can upgrade them.
mkdir -p "$ROOT/usr/local/sbin"
cat >"$ROOT/usr/local/sbin/pi5-hold-kernel" <<'EOF'
#!/bin/sh
# Installed by build-pi5-focal.sh: stop apt from replacing the Pi 5 kernel setup.
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-*raspi*' 'linux-firmware' 'flash-kernel' 2>/dev/null |
	awk '$1 == "ii" { print $2 }' | xargs -r apt-mark hold >/dev/null
EOF
chmod 755 "$ROOT/usr/local/sbin/pi5-hold-kernel"
cat >"$ROOT/etc/systemd/system/pi5-hold-kernel.service" <<'EOF'
[Unit]
Description=Hold kernel packages so apt cannot replace the Raspberry Pi 5 boot setup
Before=apt-daily.service apt-daily-upgrade.service unattended-upgrades.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pi5-hold-kernel

[Install]
WantedBy=multi-user.target
EOF
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/pi5-hold-kernel.service \
	"$ROOT/etc/systemd/system/multi-user.target.wants/pi5-hold-kernel.service"

# ---------------------------------------------------------------- verify

log "Verifying the image"
check "root filesystem is Ubuntu 20.04" grep -q '^VERSION_ID="20.04"' "$ROOT/etc/os-release"
check "modules.dep exists for $KVER" test -f "$ROOT/lib/modules/$KVER/modules.dep"
check "no zstd-compressed modules left" test -z "$(find "$ROOT/lib/modules/$KVER" -name '*.ko.zst' -print -quit)"
check "fstab mounts LABEL=writable on /" grep -Eq '^LABEL=writable[[:space:]]+/[[:space:]]' "$ROOT/etc/fstab"
check "fstab mounts LABEL=system-boot on /boot/firmware" \
	grep -Eq '^LABEL=system-boot[[:space:]]+/boot/firmware[[:space:]]' "$ROOT/etc/fstab"
check "cmdline.txt has root=LABEL=writable" grep -q 'root=LABEL=writable' "$MNT/nboot/cmdline.txt"
for f in vmlinuz initrd.img bcm2712-rpi-5-b.dtb; do
	check "boot partition has $f" test -f "$MNT/nboot/$f"
done
if [ -e "$ROOT/usr/sbin/flash-kernel.focal" ]; then
	check "flash-kernel is diverted" grep -qx /usr/sbin/flash-kernel "$ROOT/var/lib/dpkg/diversions"
fi
check "kernel hold service is enabled" test -L "$ROOT/etc/systemd/system/multi-user.target.wants/pi5-hold-kernel.service"

umount "$MNT/nboot" "$MNT/nroot"
if ! e2fsck -fn "${NOBLE}p2" >"$WORKDIR/e2fsck.log" 2>&1; then
	die "e2fsck found problems in the root filesystem, see $WORKDIR/e2fsck.log"
fi
echo "  ok: root filesystem passes e2fsck"
for f in "${NEW_EXT4_FEATURES[@]}"; do
	[[ " $(ext4_features "${NOBLE}p2") " != *" $f "* ]] || die "ext4 feature $f is still enabled"
done
echo "  ok: no ext4 features newer than 20.04's e2fsprogs"

release
mv "$WORKDIR/noble.img" "$WORKDIR/$OUT_NAME"
rm -rf "$STASH"

# ---------------------------------------------------------------- copy out

if [ "$OUT_DIR" = auto ]; then
	OUT_DIR=
	mapfile -t desks < <(ls -d /mnt/c/Users/*/Desktop 2>/dev/null |
		grep -Ev '/Users/(Public|Default|Default User|All Users)/Desktop$' || true)
	[ ${#desks[@]} -eq 1 ] && OUT_DIR=${desks[0]}
fi
IMG=$WORKDIR/$OUT_NAME
if [ -n "$OUT_DIR" ]; then
	log "Copying the image to $OUT_DIR"
	cp "$IMG" "$OUT_DIR/"
	IMG=$OUT_DIR/$OUT_NAME
fi
command -v wslpath >/dev/null && IMG_WIN=$(wslpath -w "$IMG" 2>/dev/null) || IMG_WIN=$IMG

cat <<EOF

Done: $IMG_WIN

Flash it with Raspberry Pi Imager: Choose OS -> Use custom -> $OUT_NAME, then your
SD card or USB drive. Answer "No" to OS customisation; the image uses 20.04's own
cloud-init settings. Keep $(basename "$NOBLE_XZ") as your fallback.

First boot: log in as ubuntu / ubuntu (you'll be asked for a new password), then check
  uname -r                        # $KVER
  grep VERSION= /etc/os-release   # 20.04
  apt-mark showhold               # linux-*raspi*, flash-kernel, ...
EOF

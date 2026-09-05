#!/bin/bash
# Turn the already-published Armada container into a fastboot-flashable
# plain rootfs. The file tree is EXACTLY the container's (no rebuild, no
# repackaging, no bootc/BIB): same Fedora 44 base, same armada packages,
# same Steam/FEX/Proton/gamescope/decky/device services/splash.
#
# The only change vs the container is that OTA is removed: steamos-update
# / steamos-select-branch are replaced by a notice (no bootc deployment to
# update; re-flash to upgrade) — everything else stays identical.
#
# Boot chain (debian-sheng style, verified on this device):
#   boot_b.img (header-v0, kernel+initramfs+DTB, cmdline root=PARTLABEL=<p>)
#   -> single ext4 root (growfs), /boot inside the root
#
# Single-system only: the root partition is the Android 'userdata' partition
# (Android erased); no dual-boot support.
#
# Runs on the runner as root. Usage:
#   armada-export-flashable.sh <ghcr-ref> <output-dir> <root-partition> <quiet|verbose>
set -euxo pipefail

REF="${1:?container ref}"
OUT="${2:?output dir}"
ROOT_PART="${3:?root partition name}"
MODE="${4:-quiet}"
IMG_SIZE="${IMG_SIZE:-22G}"

ROOTFS="$OUT/rootfs.img"
MNT="$OUT/mnt"
mkdir -p "$OUT" "$MNT"

echo "==> [1/7] Pull the Armada container"
podman pull "${REF}"
CID=$(podman create "${REF}")
trap 'podman rm -f "$CID" 2>/dev/null || true' EXIT

echo "==> [2/7] Create ext4 rootfs image (${IMG_SIZE})"
truncate -s "$IMG_SIZE" "$ROOTFS"
mkfs.ext4 -F -L armada "$ROOTFS"
mount -o loop "$ROOTFS" "$MNT"

echo "==> [3/7] Export container tree verbatim"
podman export "$CID" | tar -x -C "$MNT" --xattrs --selinux 2>/dev/null || \
podman export "$CID" | tar -x -C "$MNT" --xattrs
podman rm "$CID"; CID=""

echo "==> [4/7] De-bootc the rootfs (keep everything else identical)"
# /boot inside the root (plain rootfs, no separate boot partition).
rm -rf "$MNT/boot"; mkdir -p "$MNT/boot"
cat > "$MNT/etc/fstab" <<EOF
PARTLABEL=${ROOT_PART} / ext4 defaults,x-systemd.growfs 0 1
EOF
# OTA disabled: plain rootfs has no bootc deployment to update.
for svc in steamos-update steamos-select-branch; do
  cat > "$MNT/usr/bin/$svc" <<'EOF'
#!/bin/bash
echo "OTA is not available in this build (plain rootfs). Re-flash the image to upgrade." >&2
exit 1
EOF
  chmod 0755 "$MNT/usr/bin/$svc"
done
# bootc update paths that would fail loudly: keep the binaries but they are
# unused now; armada's own timer is already masked in the image.

echo "==> [4b] SELinux sanity (container labels vs real hardware)"
if [ -f "$MNT/etc/selinux/config" ]; then
  grep -E '^SELINUX=' "$MNT/etc/selinux/config" || true
  # Container-built files carry container_file_t; enforcing on real hardware
  # would deny most services. Drop to permissive (functional, still auditable;
  # users can relabel later and re-enable enforcing).
  if grep -qE '^SELINUX=enforcing' "$MNT/etc/selinux/config"; then
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' "$MNT/etc/selinux/config"
    echo "SELINUX: enforcing -> permissive (container labels)"
  else
    echo "SELINUX: left as-is"
  fi
fi

echo "==> [5/7] Bake boot_b.img from the installed kernel"
KVER=$(ls "$MNT/usr/lib/modules" | head -1)
[ -n "$KVER" ] || { echo "no kernel under /usr/lib/modules"; exit 1; }
VMLINUZ="$MNT/usr/lib/modules/$KVER/vmlinuz"
INITRD="$MNT/usr/lib/modules/$KVER/initramfs.img"
DTB="$MNT/usr/lib/modules/$KVER/dtb/qcom/sm8550-xiaomi-sheng.dtb"
[ -f "$VMLINUZ" ] || VMLINUZ=$(find "$MNT/boot" -maxdepth 1 -name 'vmlinuz-*' | head -1)
[ -f "$INITRD" ] || INITRD=$(find "$MNT/boot" -maxdepth 1 -name 'initramfs-*.img' | head -1)
[ -f "$DTB" ] || { echo "DTB missing ($DTB)"; find "$MNT/usr/lib/modules/$KVER" -name '*.dtb' | head; exit 1; }

echo "==> [5b] Touchscreen chain audit (for MANIFEST/diagnosis)"
( cd "$MNT/usr/lib/modules/$KVER" && \
  echo "--- goodix/berlin modules:"; find . -iname '*goodix*' -o -iname '*berlin*' | head; \
  echo "--- touch firmware:"; find "$MNT"/lib/firmware -iname '*gt9*' -o -iname '*shen*' | head -12; \
  echo "--- dts touch node:"; strings "$DTB" | grep -i -E 'goodix|touch|berlin' | head -8; \
  echo "--- usb gadget modules:"; find . -path '*gadget*' -name '*.ko*' | head -8 ) 2>&1 | tee "$OUT/touchchain.log"

echo "==> [5c] Firmware guaranteed-injection (novatek/cirrus/sheng, verbatim)"
git clone --depth 1 -q https://github.com/ianchb/sheng-firmware /tmp/sheng-fw
cp -a /tmp/sheng-fw/. "$MNT/usr/lib/firmware/"
rm -rf /tmp/sheng-fw
# nt36532e driver's BOOT_UPDATE_FIRMWARE_NAME is hardcoded to
# "novatek/nt36532e.bin" while the DTS firmware-name points at the csot bin;
# provide both names so the auto-firmware-recovery path finds its file.
if [ -f "$MNT/usr/lib/firmware/novatek/novatek_nt36532_n81a_fw_csot.bin" ]; then
  cp "$MNT/usr/lib/firmware/novatek/novatek_nt36532_n81a_fw_csot.bin" \
     "$MNT/usr/lib/firmware/novatek/nt36532e.bin"
  echo "alias firmware: novatek/nt36532e.bin created"
fi
echo "firmware files: $(find "$MNT/usr/lib/firmware" -type f | wc -l)"
ls "$MNT/usr/lib/firmware/novatek" "$MNT/usr/lib/firmware/cirrus" 2>&1 | head -8

echo "==> [5d] sheng ALSA UCM2 inject + audio audit"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$MNT/usr/share/alsa/ucm2"
cp -a "$REPO/system_files/usr/share/alsa/ucm2/." "$MNT/usr/share/alsa/ucm2/"
{
  echo "--- sheng UCM2:"; ls "$MNT/usr/share/alsa/ucm2/Xiaomi/sheng/" 2>&1 | head;
  echo "--- sm8550 firmware dirs:"; ls "$MNT/usr/lib/firmware/qcom/sm8550/" 2>&1 | head;
  echo "--- sheng-specific firmware:"; ls "$MNT/usr/lib/firmware/qcom/sm8550/sheng" 2>&1 | head;
  echo "--- adsp blobs:"; find "$MNT/usr/lib/firmware" -name 'adsp.b00' | head;
  echo "--- audio codec/amp modules:"; find "$MNT/usr/lib/modules/$KVER" -iname '*wsa88*' -o -iname '*wcd93*' | head -8;
} 2>&1 | tee -a "$OUT/touchchain.log"

echo "==> [5f] Steam offline fallback wrapper"
cat > "$MNT/usr/local/bin/steam-now" <<'EOF'
#!/bin/bash
# Launch Steam big picture; probe the Steam CDN briefly and fall back to
# offline mode so a blocked/slow network never strands the user at a
# download screen. The client tree is fully pre-staged in the image.
set -u
if curl -m 3 -sI https://store.steampowered.com >/dev/null 2>&1; then
    exec /usr/bin/steam -steamdeck "$@"
else
    logger -t steam-now "Steam CDN unreachable; starting offline"
    exec /usr/bin/steam -steamdeck -offline "$@"
fi
EOF
chmod 0755 "$MNT/usr/local/bin/steam-now"

echo "==> [5g] xiaomi-sheng-thp: NT36532E userspace touch -> uinput"
# The in-kernel nt36532e driver only downloads firmware and publishes raw THP
# frame streams (/proc/nvt_thp_raw, /proc/nvt_thp_stream, ...); it registers
# NO input device. ianchb/xiaomi-sheng-thp consumes that stream and creates
# standard uinput devices (multitouch / Focus Pen). Vendored here as the
# official arm64 .deb pair (thp + libssc, which provides libssc.so.2).
THP_VEND="$REPO/build_files/vendor/xiaomi-sheng-thp"
THP_DEB="$THP_VEND/xiaomi-sheng-thp_0.3.9_arm64.deb"
LIBSSC_DEB="$THP_VEND/libssc_0.4.2-1_arm64.deb"
echo "94ABB9436FCAF848553A7C556C582BA039EC8152DA0F83618377E9B41F37060C  ${THP_DEB}" | sha256sum -c - >/dev/null || { echo "ERROR: thp deb checksum mismatch"; exit 1; }
echo "8E97BE9775FE0326B4D090A60C088D9D22E84941B4C61865F1A662339DE0263D  ${LIBSSC_DEB}" | sha256sum -c - >/dev/null || { echo "ERROR: libssc deb checksum mismatch"; exit 1; }
THPW=$(mktemp -d)
dpkg-deb -x "$THP_DEB" "$THPW/thp"
dpkg-deb -x "$LIBSSC_DEB" "$THPW/libssc"
install -Dm755 "$THPW/thp/usr/libexec/xiaomi-sheng-thp/xiaomi-sheng-thp" \
    "$MNT/usr/libexec/xiaomi-sheng-thp/xiaomi-sheng-thp"
install -Dm644 "$THPW/thp/usr/lib/systemd/system/xiaomi-sheng-thp.service" \
    "$MNT/usr/lib/systemd/system/xiaomi-sheng-thp.service"
# Debian ships libssc.so.2 under /usr/lib/aarch64-linux-gnu; Fedora aarch64
# uses /usr/lib64. (thp links the soname directly, so no .so symlink needed.)
install -Dm755 "$THPW/libssc/usr/lib/aarch64-linux-gnu/libssc.so.2" \
    "$MNT/usr/lib64/libssc.so.2"
rm -rf "$THPW"
# libssc.so.2's Fedora-side deps (verified DT_NEEDED chain):
#   libqmi-glib.so.5  <- libmbim-glib.so.4
#   libqrtr-glib.so.0
#   libprotobuf-c.so.1
# (glib2/bluez already present in the container.)
# NOTE: no dnf --installroot here. The bootc-exported tree's rpmdb does not
# match the filesystem (dnf5 fails with phantom "coreutils is needed by ..."),
# so we install into a CLEAN fedora:44 container (its own rpmdb) and copy the
# libraries out — soname symlinks preserved by cp -P.
podman run --rm -v "$MNT:/mnt" quay.io/fedora/fedora:44 bash -c '
  set -e
  dnf5 -y --setopt=install_weak_deps=False install \
      libmbim libqmi libqrtr-glib protobuf-c >/dev/null 2>&1
  for so in libmbim-glib.so.4 libqmi-glib.so.5 \
            libqrtr-glib.so.0 libprotobuf-c.so.1; do
    cp -P /usr/lib64/${so}* /mnt/usr/lib64/
  done
'
# CONFIG_INPUT_UINPUT=m: load the module so /dev/uinput exists for thp.
mkdir -p "$MNT/etc/modules-load.d"
echo uinput > "$MNT/etc/modules-load.d/uinput.conf"
systemctl --root "$MNT" enable xiaomi-sheng-thp.service 2>/dev/null || true
echo "xiaomi-sheng-thp: $(ls -l "$MNT/usr/libexec/xiaomi-sheng-thp/" | tail -1)"
ls "$MNT/usr/lib64/libssc.so.2" "$MNT/usr/lib64/libqmi-glib.so.5" \
   "$MNT/usr/lib64/libqrtr-glib.so.0" "$MNT/usr/lib64/libprotobuf-c.so.1" 2>&1

echo "==> [5e] Enable remote access (sshd; USB gadget network if supported)"
systemctl --root "$MNT" enable sshd.service 2>/dev/null || true
if ls "$MNT/usr/lib/modules/$KVER/kernel/drivers/usb/gadget" 2>/dev/null | grep -q .; then
  mkdir -p "$MNT/etc/systemd/system" "$MNT/usr/local/sbin"
  cat > "$MNT/etc/systemd/system/armada-usbgadget.service" <<'EOF'
[Unit]
Description=USB Ethernet gadget (ECM) for host access
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/armada-usbgadget up
ExecStop=/usr/local/sbin/armada-usbgadget down

[Install]
WantedBy=multi-user.target
EOF
  cat > "$MNT/usr/local/sbin/armada-usbgadget" <<'EOF'
#!/bin/bash
set -e
GADGET=/sys/kernel/config/usb_gadget/armada
up() {
  modprobe libcomposite || true
  mkdir -p "$GADGET"
  echo 0x1d6b > "$GADGET/idVendor"; echo 0x0104 > "$GADGET/idProduct"
  mkdir -p "$GADGET/strings/0x409"; echo armada > "$GADGET/strings/0x409/manufacturer"
  echo armada > "$GADGET/strings/0x409/product"
  mkdir -p "$GADGET/configs/c.1/strings/0x409"; echo armada > "$GADGET/configs/c.1/strings/0x409/configuration"
  mkdir -p "$GADGET/functions/ecm.usb0"
  ln -s "$GADGET/functions/ecm.usb0" "$GADGET/configs/c.1/"
  ls /sys/class/udc > "$GADGET/UDC"
  ip link set usb0 up 2>/dev/null || true
  ip addr add 192.168.42.1/24 dev usb0 2>/dev/null || true
}
down() {
  [ -d "$GADGET" ] || return 0
  echo "" > "$GADGET/UDC" || true
  rm -f "$GADGET/configs/c.1/ecm.usb0" || true
  rmdir "$GADGET/functions/ecm.usb0" "$GADGET/configs/c.1/strings/0x409" \
        "$GADGET/configs/c.1" "$GADGET/strings/0x409" "$GADGET" 2>/dev/null || true
}
case "$1" in up) up;; down) down;; esac
EOF
  chmod +x "$MNT/usr/local/sbin/armada-usbgadget"
  systemctl --root "$MNT" enable armada-usbgadget.service 2>/dev/null || true
  echo "usb gadget: enabled"
else
  echo "usb gadget: no kernel modules -> skipped"
fi

CMDLINE="root=PARTLABEL=${ROOT_PART} rw rootwait console=tty0"
[ "$MODE" = "quiet" ] && CMDLINE="$CMDLINE quiet" || CMDLINE="$CMDLINE loglevel=7"
gzip -c "$VMLINUZ" > /tmp/kernel.gz
cat "$DTB" >> /tmp/kernel.gz
python3 "$(dirname "$0")/../../build_files/vendor/mkbootimg/mkbootimg.py" \
    --kernel /tmp/kernel.gz --ramdisk "$INITRD" \
    --base 0x00000000 --pagesize 4096 --kernel_offset 0x00008000 \
    --tags_offset 0x01e00000 --header_version 0 \
    --os_patch_level "$(date '+%Y-%m')" --cmdline "$CMDLINE" \
    -o "$OUT/boot_b.img"
rm -f /tmp/kernel.gz
echo "boot cmdline: $CMDLINE"

echo "==> [6/7] Unmount + shrink to actual size + align + fsck"
sync
umount "$MNT" || true
# Shrink the filesystem to the actual used size (resize2fs -M), then truncate
# the image file to match. The 22G default was only a ceiling; shipping a
# 22G logical image means ~12 split chunks / ~7G upload for ~6.6G of real
# data. resize2fs -M loses the growfs headroom, so re-enable it afterwards
# on first boot via fstab's x-systemd.growfs and keep `resize2fs -M`'d
# minimum as the floor. (growfs runs at boot, up to the partition size.)
e2fsck -f -y "$ROOTFS" >/dev/null 2>&1 || true
if command -v resize2fs >/dev/null 2>&1; then
  echo "--- shrink to actual size ---"
  resize2fs -M "$ROOTFS" 2>&1 | tail -2 || true
fi
# Align the file back up to 4096 and cap unneeded preallocation.
sz=$(stat -c %s "$ROOTFS")
pad=$(( (sz + 4095) / 4096 * 4096 ))
[ "$pad" -gt "$sz" ] && truncate -s "$pad" "$ROOTFS"
e2fsck -f -y "$ROOTFS" >/dev/null 2>&1 || true
echo "rootfs.img logical size: $(stat -c %s "$ROOTFS") bytes ($(du -h "$ROOTFS" | cut -f1))"

echo "==> [7/7] flash.sh + checksums"
cat > "$OUT/flash.sh" <<SH
#!/bin/bash
# Flash Armada (exported container, no-OTA) to the Xiaomi Pad 6S Pro.
# Single-system: root goes into the Android 'userdata' partition (Android erased).
set -euo pipefail
cd "\$(dirname "\$0")"
sha256sum -c SHA256SUMS
echo "==> using partition ${ROOT_PART} (single-system, Android erased)"
fastboot erase dtbo_b
fastboot flash boot_b boot_b.img
fastboot erase ${ROOT_PART}
fastboot flash ${ROOT_PART} rootfs.img
fastboot reboot
SH
chmod +x "$OUT/flash.sh"
cd "$OUT"
sha256sum boot_b.img rootfs.img flash.sh > SHA256SUMS
{
  echo "Armada (container-exported, no OTA) — ${REF}"
  echo "root: PARTLABEL=${ROOT_PART} ext4 growfs (single partition)"
  echo "boot: boot_b.img header-v0; cmdline: ${CMDLINE}"
  echo "kernel: ${KVER}"
  echo "touch: xiaomi-sheng-thp 0.3.9 (userspace NT36532E -> uinput) + libssc 0.4.2-1"
} > MANIFEST.txt
ls -lh "$OUT"
echo "==> DONE"

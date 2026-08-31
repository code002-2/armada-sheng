#!/bin/bash
# Export fastboot-flashable images for an Armada device that boots from the
# Android internal-storage partitions via the vendor ABL (no UEFI/ESP, no
# ROCKNIX /KERNEL) — currently the Xiaomi Pad 6S Pro (sheng).
#
# Input  : the BIB raw disk image from `just build-raw`:
#            p1 = vfat ESP (ignored here), p2 = ext4 /boot, p3 = btrfs /
# Output : <out>/
#            boot_b.img       Android boot.img (gzip Image + DTBs + initramfs,
#                             sheng header-v0 geometry) -> fastboot flash boot_b
#            linux_boot.img   ext4 /boot filesystem (incl. ostree layout)
#                             -> fastboot flash linux_boot
#            linux.img        btrfs root filesystem (rebaked fstab)
#                             -> fastboot flash linux
#            flash.sh         one-shot flashing/verification script
#            SHA256SUMS / MANIFEST.txt
#
# Usage:
#   post_process/export-fastboot-images.sh [--device sm8550-xiaomi-sheng] \
#       [--raw output/raw/disk.raw] [--out output/fastboot]

set -euxo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DEVICE=sm8550-xiaomi-sheng
RAW=""
OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --raw)    RAW="$2"; shift 2 ;;
        --out)    OUT="$2"; shift 2 ;;
        *) echo "ERROR: unknown arg $1" >&2; exit 1 ;;
    esac
done

: "${OUT:=output/fastboot}"
if [ -z "${RAW}" ]; then
    for cand in output/image/disk.raw output/raw/disk.raw; do
        [ -f "${cand}" ] && RAW="${cand}" && break
    done
    : "${RAW:=output/image/disk.raw}"
fi

DEV_CONF="${ROOT}/system_files/usr/lib/armada/devices/${DEVICE}.conf"
DTB_LIST_SRC="${ROOT}/system_files/usr/lib/armada/supported-dtbs.${DEVICE}"
ARGS_SRC="${ROOT}/system_files/usr/lib/armada/bootimg-args.${DEVICE}"
MKBOOTIMG="${MKBOOTIMG:-${ROOT}/build_files/vendor/mkbootimg/mkbootimg.py}"
LOOP=""

[ -r "${RAW}" ] || { echo "ERROR: raw image not found: ${RAW} (run build-raw first)" >&2; exit 1; }
[ -r "${DEV_CONF}" ] || { echo "ERROR: device profile not found: ${DEV_CONF}" >&2; exit 1; }
[ -r "${DTB_LIST_SRC}" ] || { echo "ERROR: DTB list not found: ${DTB_LIST_SRC}" >&2; exit 1; }
[ -r "${ARGS_SRC}" ] || { echo "ERROR: bootimg args not found: ${ARGS_SRC}" >&2; exit 1; }
[ -x "${MKBOOTIMG}" ] || { echo "ERROR: mkbootimg not executable: ${MKBOOTIMG}" >&2; exit 1; }

# Load the device profile for its boot variables (see device conf).
# shellcheck source=/dev/null
. "${DEV_CONF}"
PARTLABEL_ROOT="${PARTLABEL_ROOT:-linux}"
PARTLABEL_BOOT="${PARTLABEL_BOOT:-linux_boot}"

# Source the shared bootimg helpers (armada_bootimg_cmdline,
# armada_default_bls_entry) from the GLOBAL args file, but keep the DEVICE
# geometry: the global file also assigns the ROCKNIX ABL's ARMADA_BOOTIMG_ARGS.
# shellcheck source=/dev/null
. "${ARGS_SRC}"
device_args="${ARMADA_BOOTIMG_ARGS}"
device_cmdline_max="${ARMADA_CMDLINE_MAX}"
# shellcheck source=/dev/null
. "${ROOT}/system_files/usr/lib/armada/bootimg-args"
ARMADA_BOOTIMG_ARGS="${device_args}"
ARMADA_CMDLINE_MAX="${device_cmdline_max}"

WORK="$(mktemp -d)"
trap 'sudo umount "${WORK}/bootfs" 2>/dev/null || true; sudo umount "${WORK}/rootfs" 2>/dev/null || true; [ -n "${LOOP}" ] && sudo losetup -d "${LOOP}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

# ---------------------------------------------------------------------------
# 1. Attach the raw image and validate the partition layout
# ---------------------------------------------------------------------------
LOOP=$(sudo losetup -fP --show "${RAW}")
[ -n "${LOOP}" ] || { echo "ERROR: losetup failed" >&2; exit 1; }
sleep 1

TABLE=$(sudo sfdisk -J "${LOOP}")
mapfile -t PARTS < <(jq -r '.partitiontable.partitions[] | "\(.start) \(.size)"' <<<"${TABLE}")

if [ "${#PARTS[@]}" -ne 3 ]; then
    echo "ERROR: expected 3 partitions, got ${#PARTS[@]}" >&2
    sudo sfdisk -l "${LOOP}"
    exit 1
fi
read -r P2_START P2_SIZE <<<"${PARTS[1]}"
read -r P3_START P3_SIZE <<<"${PARTS[2]}"

sudo blkid "${LOOP}p1" | grep -q 'TYPE="vfat"' || { echo "ERROR: p1 is not vfat (BIB layout changed?)" >&2; sudo blkid "${LOOP}"*; exit 1; }
sudo blkid "${LOOP}p2" | grep -q 'TYPE="ext4"' || { echo "ERROR: p2 is not ext4 /boot" >&2; sudo blkid "${LOOP}"*; exit 1; }
sudo blkid "${LOOP}p3" | grep -q 'TYPE="btrfs"' || { echo "ERROR: p3 is not btrfs root" >&2; sudo blkid "${LOOP}"*; exit 1; }

# ---------------------------------------------------------------------------
# 2. Bake boot_b.img from the next-boot ostree deployment (/boot)
# ---------------------------------------------------------------------------
sudo mkdir -p "${WORK}/bootfs"
sudo mount "${LOOP}p2" "${WORK}/bootfs"

entry=$(armada_default_bls_entry "${WORK}/bootfs")
[ -n "${entry}" ] || { echo "ERROR: no BLS entry in ${WORK}/bootfs/loader/entries" >&2; exit 1; }
LINUX_LINE=$(sudo sed -n 's/^linux //p' "${entry}" | head -1)
INITRD_LINE=$(sudo sed -n 's/^initrd //p' "${entry}" | head -1)
OPTIONS_LINE=$(sudo sed -n 's/^options //p' "${entry}" | head -1)

# The BLS linux line names the deployment it owns; use that (not a directory
# scan) so the baked image always matches the entry actually booting.
deploy=$(sed -n 's#^/boot/ostree/\([^/]*\)/.*#\1#p' <<<"${LINUX_LINE}")
[ -n "${deploy}" ] || { echo "ERROR: unexpected linux path in BLS: ${LINUX_LINE}" >&2; exit 1; }
BOOTDIR="${WORK}/bootfs/ostree/${deploy}"
KPATH="${WORK}/bootfs${LINUX_LINE}"
IPATH="${WORK}/bootfs${INITRD_LINE}"

cmdline=$(armada_bootimg_cmdline "${OPTIONS_LINE}") || { echo "ERROR: no ostree= karg in ${entry}" >&2; exit 1; }
if [ "${#cmdline}" -gt "${ARMADA_CMDLINE_MAX}" ]; then
    echo "ERROR: cmdline is ${#cmdline}B, over the ${ARMADA_CMDLINE_MAX}B limit" >&2
    exit 1
fi

# DTB set for this device (from the vendored per-device list).
DTBS_ABS=()
while read -r name; do
    [ -n "${name}" ] || continue
    d="${BOOTDIR}/dtb/qcom/${name}.dtb"
    sudo test -f "${d}" || { echo "ERROR: DTB missing: ${d}" >&2; exit 1; }
    DTBS_ABS+=("${d}")
done < "${DTB_LIST_SRC}"

sudo gzip -c "${KPATH}" > "${WORK}/kernel.gz"
for d in "${DTBS_ABS[@]}"; do
    sudo cat "${d}" >> "${WORK}/kernel.gz"
done

mkdir -p "${OUT}"
echo "==> Building ${OUT}/boot_b.img (deploy=${deploy})"
sudo python3 "${MKBOOTIMG}" \
    --kernel "${WORK}/kernel.gz" --ramdisk "${IPATH}" \
    ${ARMADA_BOOTIMG_ARGS} --os_patch_level "$(date '+%Y-%m')" \
    --cmdline "${cmdline}" \
    -o "${WORK}/boot_b.img"

# ---------------------------------------------------------------------------
# 3. Re-bake the root fstab for fastboot partitions (no /boot/efi, growfs)
# ---------------------------------------------------------------------------
sudo mkdir -p "${WORK}/rootfs"
sudo mount "${LOOP}p3" "${WORK}/rootfs"

sudo awk -v root="${PARTLABEL_ROOT}" -v boot="${PARTLABEL_BOOT}" '
    $2 == "/" && $1 !~ /^PARTLABEL=/ {
        $1 = "PARTLABEL=" root
        if ($4 !~ /x-systemd.growfs/) $4 = $4 ",x-systemd.growfs"
        print; next
    }
    $2 == "/boot" && $1 !~ /^PARTLABEL=/ {
        $1 = "PARTLABEL=" boot
        print; next
    }
    $2 == "/boot/efi" { next }      # no ESP on this device
    { print }
' "${WORK}/rootfs/etc/fstab" | sudo tee "${WORK}/rootfs/etc/fstab.new" >/dev/null
sudo mv "${WORK}/rootfs/etc/fstab.new" "${WORK}/rootfs/etc/fstab"
sudo sync
sudo umount "${WORK}/rootfs"

# ---------------------------------------------------------------------------
# 4. Export filesystem images (whole-partition dd, sparse)
# ---------------------------------------------------------------------------
echo "==> Exporting ${OUT}/linux_boot.img (${P2_SIZE} sectors)"
sudo dd if="${RAW}" of="${OUT}/linux_boot.img" bs=512 skip="${P2_START}" count="${P2_SIZE}" \
    conv=sparse status=progress

echo "==> Exporting ${OUT}/linux.img (${P3_SIZE} sectors)"
sudo dd if="${RAW}" of="${OUT}/linux.img" bs=512 skip="${P3_START}" count="${P3_SIZE}" \
    conv=sparse status=progress

mv "${WORK}/boot_b.img" "${OUT}/boot_b.img"

# ---------------------------------------------------------------------------
# 5. Verify + manifest + one-shot flash script
# ---------------------------------------------------------------------------
sudo blkid "${OUT}/linux_boot.img" | grep -q 'TYPE="ext4"' || { echo "ERROR: linux_boot.img verify failed" >&2; exit 1; }
sudo blkid "${OUT}/linux.img" | grep -q 'TYPE="btrfs"' || { echo "ERROR: linux.img verify failed" >&2; exit 1; }

(
    cd "${OUT}"
    sha256sum boot_b.img linux_boot.img linux.img > SHA256SUMS
    {
        echo "Armada flashable images (${DEVICE}) — built $(date -u '+%Y-%m-%d %H:%M:%SZ')"
        echo "boot_b.img     $(stat -c %s boot_b.img) bytes"
        echo "linux_boot.img $(stat -c %s linux_boot.img) bytes"
        echo "linux.img      $(stat -c %s linux.img) bytes"
        echo "cmdline: ${cmdline}"
        echo "kernel: $(sudo basename "${KPATH}")"
    } > MANIFEST.txt
)

cat > "${OUT}/flash.sh" <<'SH'
#!/bin/bash
# Flash Armada (Xiaomi Pad 6S Pro / sheng) to internal storage.
# Prereqs: unlocked bootloader + TWRP installed, tablet in fastboot mode,
# and the target partitions created (see docs/flashing-xiaomi-sheng.md):
#   linux_boot  ext4  (>= 1 GiB)   /boot, ostree deployments
#   linux       btrfs (>= 16 GiB)  rootfs
# Running this erases everything on those partitions.
set -euo pipefail
cd "$(dirname "$0")"

sha256sum -c SHA256SUMS

echo "[1/4] flash boot_b (Android boot image)"
fastboot erase dtbo_b
fastboot flash boot_b boot_b.img

echo "[2/4] flash linux_boot (ext4 /boot)"
fastboot flash linux_boot linux_boot.img

echo "[3/4] flash linux (btrfs rootfs)"
fastboot flash linux linux.img

echo "[4/4] reboot"
fastboot reboot
echo "Done. First boot takes a few minutes (ostree deployment initializes)."
SH
chmod 0755 "${OUT}/flash.sh"

# The images were written by root (loop devices); hand them to the caller.
if [ "$(id -u)" != 0 ]; then
    sudo chown -R "$(id -u):$(id -g)" "${OUT}"
fi

sudo umount "${WORK}/bootfs" || true
sudo losetup -d "${LOOP}"
LOOP=""

echo "Built:"
ls -lh "${OUT}"

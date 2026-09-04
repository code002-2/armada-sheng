#!/bin/bash
# Export fastboot-flashable images for an Armada device that boots from the
# Android internal-storage partitions via the vendor ABL (no UEFI/ESP, no
# ROCKNIX /KERNEL) 鈥?currently the Xiaomi Pad 6S Pro (sheng).
#
# SINGLE-PARTITION LAYOUT: the BIB raw image (ESP + /boot + root) is merged
# into one rootfs 鈥?the /boot payload (ostree deployments, vmlinuz,
# initramfs, DTBs, BLS entries) moves into <root>/boot, matching bootc's
# "Allow /boot to be missing in target" (aboot/automotive) support. There is
# NO separate linux_boot partition anymore.
#
# Input  : the BIB raw disk image from `just build-raw`:
#            p1 = vfat ESP (discarded), p2 = ext4 /boot (merged), p3 = ext4 /
# Output : <out>/
#            boot_b.img   Android boot.img (gzip Image + DTBs + initramfs,
#                         sheng header-v0 geometry) -> fastboot flash boot_b
#            linux.img    ext4 rootfs (includes /boot; fstab bound by UUID,
#                         x-systemd.growfs) -> fastboot flash <root-partition>
#            flash.sh     one-shot flashing/verification script
#            SHA256SUMS / MANIFEST.txt
#
# Usage:
#   post_process/export-fastboot-images.sh [--device sm8550-xiaomi-sheng] \
#       [--raw output/raw/disk.raw] [--out output/fastboot] \
#       [--root-partition linux|userdata]
#
# --root-partition selects the device partition the single rootfs lands on:
#   linux     (default) dual-boot layout: created by the user (see docs)
#   userdata  single-boot: the vendor's userdata partition (sda29 on every
#             sheng device) replaces Android entirely

set -euxo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DEVICE=sm8550-xiaomi-sheng
RAW=""
OUT=""
ROOT_PARTITION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --raw)    RAW="$2"; shift 2 ;;
        --out)    OUT="$2"; shift 2 ;;
        --root-partition) ROOT_PARTITION="$2"; shift 2 ;;
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
# --root-partition overrides the target root partition (e.g. the vendor's
# 'userdata' partition in single-boot mode; 'linux' is the default dual-boot).
[ -n "${ROOT_PARTITION}" ] && PARTLABEL_ROOT="${ROOT_PARTITION}"

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
sudo blkid "${LOOP}p3" | grep -qE 'TYPE="(ext4|btrfs)"' || { echo "ERROR: p3 is not an ext4/btrfs root" >&2; sudo blkid "${LOOP}"*; exit 1; }

# ---------------------------------------------------------------------------
# 2. Merge the /boot payload into the root filesystem (single-partition
#    layout 鈥?no separate linux_boot needed: bootc supports /boot as a plain
#    directory inside the root, see bootc "install-to-filesystem: Allow /boot
#    to be missing in target"). The flatten vmlinuz/initramfs/dtbs + BLS +
#    ostree deployments all move to <root>/boot, and the boot.img is baked
#    from there. Only boot_b.img + the root image are exported.
# ---------------------------------------------------------------------------
sudo mkdir -p "${WORK}/bootfs"
sudo mount "${LOOP}p2" "${WORK}/bootfs"

sudo mkdir -p "${WORK}/rootfs"
# ext4 root (sheng variant): plain mount. Only fall back to a btrfs subvol
# mount for older images that still used the upstream btrfs layout.
if ! sudo mount "${LOOP}p3" "${WORK}/rootfs"; then
    sudo mount -o subvol=/root "${LOOP}p3" "${WORK}/rootfs"
fi

# The boot payload is now part of the rootfs tree.
sudo rm -rf "${WORK}/rootfs/boot"
sudo mkdir -p "${WORK}/rootfs/boot"
sudo cp -a "${WORK}/bootfs/." "${WORK}/rootfs/boot/"
echo "==> /boot merged into rootfs"

# The BLS was generated for a separate /boot partition: drop boot=UUID kargs
# (nothing to mount) so the initramfs finds the deployment under the root's
# own /boot directory. Rewrite every BLS entry in place.
for b in "${WORK}/rootfs"/boot/loader/entries/*.conf; do
    [ -f "${b}" ] || continue
    sudo sed -i 's/ boot=UUID=[^ ]*//g' "${b}"
done

# ---------------------------------------------------------------------------
# 3. Bake boot_b.img from the next-boot ostree deployment (now inside rootfs)
# ---------------------------------------------------------------------------
entry=$(armada_default_bls_entry "${WORK}/rootfs/boot")
[ -n "${entry}" ] || { echo "ERROR: no BLS entry in ${WORK}/rootfs/boot/loader/entries" >&2; exit 1; }
LINUX_LINE=$(sudo sed -n 's/^linux //p' "${entry}" | head -1)
INITRD_LINE=$(sudo sed -n 's/^initrd //p' "${entry}" | head -1)
OPTIONS_LINE=$(sudo sed -n 's/^options //p' "${entry}" | head -1)

# The BLS linux line names the deployment it owns; use that (not a directory
# scan) so the baked image always matches the entry actually booting.
deploy=$(sed -n 's#^/boot/ostree/\([^/]*\)/.*#\1#p' <<<"${LINUX_LINE}")
[ -n "${deploy}" ] || { echo "ERROR: unexpected linux path in BLS: ${LINUX_LINE}" >&2; exit 1; }
BOOTDIR="${WORK}/rootfs/boot/ostree/${deploy}"
KPATH="${WORK}/rootfs${LINUX_LINE}"
IPATH="${WORK}/rootfs${INITRD_LINE}"

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
# 4. Re-bake the root fstab (single-partition: /boot lives inside the root,
#    no /boot entry, no /boot/efi). Bind by filesystem UUID: the flattened
#    image keeps its UUID, so mounting works regardless of user partition
#    naming. x-systemd.growfs resolves the device from the UUID.
# ---------------------------------------------------------------------------
ROOT_UUID=$(sudo blkid -s UUID -o value "${LOOP}p3")
[ -n "${ROOT_UUID}" ] || { echo "ERROR: could not read rootfs UUID" >&2; exit 1; }

sudo mkdir -p "${WORK}/rootfs/etc"
sudo tee "${WORK}/rootfs/etc/fstab" <<EOF >/dev/null
UUID=${ROOT_UUID} / ext4 defaults,x-systemd.growfs 0 1
EOF
echo "==> fstab baked (root UUID=${ROOT_UUID}; ext4, growfs; no /boot entry 鈥?merged into root)"
sudo sync

# ---------------------------------------------------------------------------
# 5. Export the root filesystem (whole-partition dd, no conv=sparse: fastboot
#    misdetects holes as Android sparse images and the device then rejects
#    them). Single output 鈥?/boot is inside this image now.
# ---------------------------------------------------------------------------
echo "==> Exporting ${OUT}/linux.img (${P3_SIZE} sectors)"
sudo dd if="${RAW}" of="${OUT}/linux.img" bs=512 skip="${P3_START}" count="${P3_SIZE}" \
    status=progress
# Force 4096 alignment: a size that is only 512-aligned makes fastboot's
# sparse chunking emit non-4096-multiple skip chunks and the ABL rejects
# them ('don't care size ... not a multiple of the block size', then
# 'Bad Buffer Size'). Padding the file end is harmless (zeros).
P3_BYTES=$((P3_SIZE * 512))
P3_PAD=$(( (P3_BYTES + 4095) / 4096 * 4096 ))
if [ "${P3_PAD}" -gt "${P3_BYTES}" ]; then
    sudo truncate -s "${P3_PAD}" "${OUT}/linux.img"
    echo "==> linux.img padded to ${P3_PAD} bytes (4096-aligned)"
fi

mv "${WORK}/boot_b.img" "${OUT}/boot_b.img"

sudo umount "${WORK}/bootfs" 2>/dev/null || true
sudo umount "${WORK}/rootfs" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. Verify + manifest + one-shot flash script
# ---------------------------------------------------------------------------
sudo blkid "${OUT}/linux.img" | grep -qE 'TYPE="(ext4|btrfs)"' || { echo "ERROR: linux.img verify failed" >&2; exit 1; }

(
    cd "${OUT}"
    sha256sum boot_b.img linux.img > SHA256SUMS
    {
        echo "Armada flashable images (${DEVICE}) 鈥?built $(date -u '+%Y-%m-%d %H:%M:%SZ')"
        echo "root partition: PARTLABEL=${PARTLABEL_ROOT} (single partition; /boot merged into root)"
        echo "boot_b.img     $(stat -c %s boot_b.img) bytes"
        echo "linux.img      $(stat -c %s linux.img) bytes"
        echo "cmdline: ${cmdline}"
        echo "kernel: $(sudo basename "${KPATH}")"
    } > MANIFEST.txt
)

cat > "${OUT}/flash.sh" <<SH
#!/bin/bash
# Flash Armada (Xiaomi Pad 6S Pro / sheng) to internal storage.
# Single-partition layout: NO separate /boot partition 鈥?the ostree
# deployments and boot files live inside the rootfs (/boot directory).
# Prereqs: unlocked bootloader + TWRP installed, tablet in fastboot mode,
# and the target partition exists (see docs/flashing-xiaomi-sheng.md).
#   ${PARTLABEL_ROOT}  ext4 (>= 24 GiB)  rootfs (includes /boot)
#
# NOTE: binding to the vendor's userdata partition erases Android data.
#
# Running this erases everything on the target partition.
set -euo pipefail
cd "\$(dirname "\$0")"

sha256sum -c SHA256SUMS

# Sanity: the exported images are sector-aligned (multiple of 512, and of 4096
# in practice). A size that is not 4096-aligned means the file was truncated or
# rewritten by a downloader/tool 鈥?fastboot then refuses it with
# 'write_sparse_skip_chunk ... not a multiple of the block size'.
for img in boot_b.img linux.img; do
    sz=\$(stat -c %s "\${img}" 2>/dev/null || stat -f %z "\${img}")
    if [ \$((sz % 4096)) -ne 0 ]; then
        echo "ERROR: \${img} is not 4096-byte aligned (\${sz} bytes) 鈥?the file was" >&2
        echo "damaged/rewritten. Re-flatten it:  dd if=\${img} of=\${img}.flat bs=4096 conv=sync" >&2
        echo "then flash the .flat file." >&2
        exit 1
    fi
done

# The GPT partition name is the only thing flash.sh relies on. Users create
# their partition however they like (usually a 'linux' partition at the last
# free slot = sda30); probe for it so a slightly different name (Linux,
# armada, ...) still works. Only the *flash* step cares about the name 鈥?# booting afterwards is bound by filesystem UUID.
detect_partition() {
    local cand
    for cand in ${PARTLABEL_ROOT} Linux linux armada sheng userdata; do
        if fastboot getvar "partition-type:\${cand}" 2>/dev/null | grep -q "partition-type:\${cand}"; then
            echo "\${cand}"
            return 0
        fi
    done
    return 1
}

ROOT_PART=\$(detect_partition) || {
    echo "ERROR: no root partition found on the device." >&2
    echo "  1) reboot to TWRP and create one at the end of the disk:" >&2
    echo "       parted /dev/block/sda" >&2
    echo "       (parted) mkpart linux ext4 <start> <end>" >&2
    echo "       (parted) name <n> linux" >&2
    echo "  2) reboot to fastboot and re-run this script." >&2
    exit 1
}
echo "==> Using partition '\${ROOT_PART}' for the rootfs"

echo "[1/3] flash boot_b (Android boot image)"
fastboot erase dtbo_b
fastboot flash boot_b boot_b.img

echo "[2/3] flash \${ROOT_PART} (ext4 rootfs, includes /boot)"
fastboot flash "\${ROOT_PART}" linux.img

echo "[3/3] reboot"
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

#!/usr/bin/env bash
# Tests for the sheng (Xiaomi Pad 6S Pro) internal-storage build path:
# pipeline files exist, device profile wires up, and the boot.img arg/DTB
# selection picks the vendor-ABL geometry shared with debian-sheng.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_DIR="$ROOT/system_files/usr/lib/armada/devices"
DEVICE=sm8550-xiaomi-sheng
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Pipeline files exist
# ---------------------------------------------------------------------------
for f in \
    "system_files/usr/lib/armada/devices/${DEVICE}.conf" \
    "system_files/usr/lib/armada/supported-dtbs.${DEVICE}" \
    "system_files/usr/lib/armada/bootimg-args.${DEVICE}" \
    "system_files/usr/libexec/armada/armada-bootimg-update" \
    "system_files/usr/libexec/armada/device-env" \
    "post_process/export-fastboot-images.sh" \
    "disk_config/disk-sheng.toml" \
    "kernel-sheng/BUILD.env" \
    "kernel-sheng/build.sh" \
    "kernel-sheng/Containerfile" \
    "kernel-sheng/sheng-armada.config.overrides" \
    "kernel-sheng/sm8550.config" \
    ".github/workflows/build-sheng-disk.yml" \
    "docs/flashing-xiaomi-sheng.md"; do
    [ -e "$ROOT/$f" ] || fail "missing pipeline file: $f"
done

# Kernel source points at ianchb/sm8550-mainline, branch sheng-7.2.2.
. "$ROOT/kernel-sheng/BUILD.env"
[[ "$KERNEL_REPO" == *sm8550-mainline* ]] || fail "KERNEL_REPO not the sheng tree: $KERNEL_REPO"
[[ "$KERNEL_BRANCH" == "sheng-7.2.2" ]] || fail "KERNEL_BRANCH drift: $KERNEL_BRANCH"
[ -f "$ROOT/kernel-sheng/$KERNEL_CONFIG" ] || fail "kernel config missing: $KERNEL_CONFIG"
grep -q '^CONFIG_DRM_MSM=y' "$ROOT/kernel-sheng/$KERNEL_CONFIG" || fail "sheng config lost DRM_MSM=y"
grep -q 'TOUCHSCREEN_GOODIX_BERLIN_SPI' "$ROOT/kernel-sheng/$KERNEL_CONFIG" || fail "sheng config lost Goodix Berlin"
grep -q '^CONFIG_EXT4_FS=y' "$ROOT/kernel-sheng/$KERNEL_CONFIG" || fail "sheng config lost EXT4 (initramfs-less boot)"

# ---------------------------------------------------------------------------
# 2. device-env picks the sheng profile from the DTB model string
# ---------------------------------------------------------------------------
for model in "Xiaomi Pad 6S Pro" "Xiaomi Pad 6S Pro 12.4"; do
    ARMADA_MODEL="$model" ARMADA_DEVICE_DIR="$DEV_DIR" \
        bash "$ROOT/system_files/usr/libexec/armada/device-env" \
        > "$WORK/env.out"
    grep -q 'ARMADA_DEVICE_ID=sm8550-xiaomi-sheng' "$WORK/env.out" \
        || fail "device-env did not map model '$model'"
    grep -q 'ARMADA_SOC_CLASS=SM8550' "$WORK/env.out" \
        || fail "device-env lost SoC class for '$model'"
done

# ---------------------------------------------------------------------------
# 3. Boot.img inputs: device DTB list + vendor-ABL geometry
# ---------------------------------------------------------------------------
grep -qx 'sm8550-xiaomi-sheng' "$ROOT/system_files/usr/lib/armada/supported-dtbs.$DEVICE" \
    || fail "DTB list does not name sm8550-xiaomi-sheng"

# Same source order as export-fastboot-images.sh: device args first, then the
# global helpers (which also carry the ROCKNIX geometry — must be restored).
# shellcheck disable=SC1090
. "$ROOT/system_files/usr/lib/armada/bootimg-args.$DEVICE"
device_args="${ARMADA_BOOTIMG_ARGS}"
device_max="${ARMADA_CMDLINE_MAX}"
# shellcheck disable=SC1090
. "$ROOT/system_files/usr/lib/armada/bootimg-args"
ARMADA_BOOTIMG_ARGS="${device_args}"
ARMADA_CMDLINE_MAX="${device_max}"

[[ "$(type -t armada_bootimg_cmdline)" == "function" ]] || fail "global bootimg helper missing"
[[ "$ARMADA_BOOTIMG_ARGS" == *"--base 0x00000000"* ]] \
    || fail "vendor-ABL base 0x0 lost: $ARMADA_BOOTIMG_ARGS"
[[ "$ARMADA_BOOTIMG_ARGS" == *"--header_version 0"* ]] || fail "header-v0 lost"
[[ "$ARMADA_CMDLINE_MAX" == "512" ]] || fail "cmdline cap drift: $ARMADA_CMDLINE_MAX"

# Cmdline assembly must keep ostree= first and drop the console karg.
out=$(armada_bootimg_cmdline \
    "console=ttyS0 ostree=/ostree/boot.0/abc rootflags=noatime,space_cache=v2 quiet")
[[ "$out" == ostree=/ostree/boot.0/abc* ]] || fail "ostree= not first: $out"
[[ "$out" != *ttyS0* ]] || fail "console=ttyS0 leaked into /KERNEL cmdline: $out"
[[ "$out" == *rootflags=noatime* ]] || fail "rootflags dropped: $out"

# ---------------------------------------------------------------------------
# 4. Device profile carries the boot-partition (no ESP /KERNEL) mode
# ---------------------------------------------------------------------------
grep -q 'ARMADA_BOOTIMG_OUT=.*boot_b' "$ROOT/system_files/usr/lib/armada/devices/$DEVICE.conf" \
    || fail "profile does not declare the boot_b partition target"
grep -q 'ARMADA_BOOTIMG_ARGS_FILE=.*bootimg-args.sm8550-xiaomi-sheng' \
    "$ROOT/system_files/usr/lib/armada/devices/$DEVICE.conf" \
    || fail "profile does not pin the device bootimg args"

# armada-bootimg-update honors the partition mode variables.
grep -q 'BOOTIMG_MODE=partition' "$ROOT/system_files/usr/libexec/armada/armada-bootimg-update" \
    || fail "armada-bootimg-update lost partition mode"
grep -q 'ARMADA_BOOTIMG_OUT' "$ROOT/system_files/usr/libexec/armada/armada-bootimg-update" \
    || fail "armada-bootimg-update lost ARMADA_BOOTIMG_OUT handling"

echo "OK: sheng flashable pipeline"

#!/bin/bash
# Build the sheng (Xiaomi Pad 6S Pro) kernel from ianchb/sm8550-mainline
# (default branch sheng-7.2.2, per BUILD.env) into the exact tarball layout
# armada's 20-install-kernel.sh consumes, so the existing Containerfile
# kernel stage (KERNEL_PKG arg) works unchanged:
#
#   /usr/lib/modules/<KVER>/{vmlinuz, dtb/qcom/*.dtb, modules, .armada-source}
#
# The config is the repo's own sheng board config (sm8550.config) merged with
# the Armada runtime fragment; symbols the sheng config does not know about
# are skipped rather than failing the merge.
#
# Usage: kernel-sheng/build.sh [OUT_DIR]
#   Outputs OUT_DIR/armada-kernel-<KVER>.tar.zst + .sha256 (+ Image.gz-dtb_sheng)
#   Native on aarch64; cross-compiles with aarch64-linux-gnu-gcc on x86_64.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/BUILD.env"

OUT_DIR="${1:-${SCRIPT_DIR}/out}"
WORK_DIR="${WORK_DIR:-/var/tmp/armada-sheng-kernel}"
JOBS=$(nproc)

HOST_ARCH=$(uname -m)
MAKE_ARGS=(-j"${JOBS}")
if [[ "${HOST_ARCH}" == "aarch64" ]]; then
    echo "==> Native aarch64 build (${JOBS} jobs)"
else
    command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || {
        echo "ERROR: cross toolchain missing: sudo apt install gcc-aarch64-linux-gnu" >&2
        exit 1
    }
    MAKE_ARGS+=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
    echo "==> Cross-compiling from ${HOST_ARCH} to aarch64 (${JOBS} jobs)"
fi

mkdir -p "${WORK_DIR}" "${OUT_DIR}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-armada}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-sheng-builder}"

# ---- 1. Fetch the sheng tree ------------------------------------------------
echo "==> Fetching ${KERNEL_REPO} @ ${KERNEL_BRANCH}"
SRC="${WORK_DIR}/linux-${KERNEL_BRANCH#sheng-}"
if [ -n "${FAST:-}" ] && [ -d "${SRC}" ]; then
    echo "==> FAST=1: reusing ${SRC}"
else
    rm -rf "${SRC}"
    git clone --depth 1 --branch "${KERNEL_BRANCH}" "${KERNEL_REPO}" "${SRC}"
fi
cd "${SRC}"

# ---- 2. Config: sheng board config + armada fragment -------------------------
[[ -f "${SCRIPT_DIR}/${KERNEL_CONFIG}" ]] || {
    echo "ERROR: ${KERNEL_CONFIG} missing; ship it alongside kernel-sheng/" >&2
    exit 1
}
cp "${SCRIPT_DIR}/${KERNEL_CONFIG}" .config

# Merge only symbols the sheng config already defines (a sheng-only tree may
# predate a fragment option; merge_config.sh would abort on "not in final
# .config" otherwise). Symbols the sheng config does not define yet are
# pre-set via scripts/config (olddefconfig drops any that no Kconfig entry
# backs, so pre-setting unknown symbols is harmless); truly unknown symbols
# land in .config only if their Kconfig entry exists.
fragment=$(mktemp)
preset=$(mktemp)
while IFS= read -r line; do
    [[ -z "${line:-}" || "${line}" == \#* ]] && continue
    sym="${line%%=*}"
    [[ "${sym}" == CONFIG_* ]] || continue
    # defined as =y/=m/=n or explicitly "# CONFIG_X is not set"
    if grep -qE "^(# )?${sym}=|^# ${sym} is not set" .config; then
        printf '%s\n' "${line}" >> "${fragment}"
    else
        echo "  preset ${sym} (not in sheng config; Kconfig decides)"
        value="${line#*${sym}=}"
        case "${value}" in
            y)   printf '%s\n' "scripts/config --enable ${sym}" >> "${preset}" ;;
            m)   printf '%s\n' "scripts/config --module ${sym}" >> "${preset}" ;;
            *)   printf '%s\n' "scripts/config --set-val ${sym} \"${value}\"" >> "${preset}" ;;
        esac
    fi
done < "${SCRIPT_DIR}/${KERNEL_OVERRIDES}"

if [ -s "${preset}" ]; then
    echo "==> Pre-setting symbols absent from the sheng config"
    bash "${preset}"
fi

if [ -s "${fragment}" ]; then
    export ARCH="${ARCH:-arm64}"
    [[ "${HOST_ARCH}" == "aarch64" ]] || export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
    echo "==> Merging armada fragment ($(wc -l < "${fragment}") symbols)"
    bash scripts/kconfig/merge_config.sh .config "${fragment}"
fi
make "${MAKE_ARGS[@]}" olddefconfig
rm -f "${fragment}" "${preset}"

# ---- 3. Build ----------------------------------------------------------------
echo "==> Build Image + Image.gz + dtbs + modules"
make "${MAKE_ARGS[@]}" Image Image.gz dtbs modules

KVER=$(make "${MAKE_ARGS[@]}" -s kernelrelease)
echo "==> Kernel version: ${KVER}"

# ---- 4. Stage into armada's kernel tarball layout ----------------------------
STAGE="${WORK_DIR}/staging-${KVER}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/lib/modules/${KVER}/dtb/qcom"

echo "==> Staging vmlinuz + modules + DTBs"
cp arch/arm64/boot/Image "${STAGE}/lib/modules/${KVER}/vmlinuz"
make "${MAKE_ARGS[@]}" INSTALL_MOD_PATH="${STAGE}" INSTALL_MOD_STRIP=1 modules_install
rm -f "${STAGE}/lib/modules/${KVER}/build" "${STAGE}/lib/modules/${KVER}/source"

# Board DTBs the sheng DTB set needs (armada's export + on-device regen read
# them from /boot/ostree/<deploy>/dtb/qcom).
dtb_count=0
for dts in arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng*.dts; do
    [ -f "${dts}" ] || continue
    base=$(basename "${dts}" .dts)
    dtb="arch/arm64/boot/dts/qcom/${base}.dtb"
    if [ -f "${dtb}" ]; then
        cp "${dtb}" "${STAGE}/lib/modules/${KVER}/dtb/qcom/"
        dtb_count=$((dtb_count + 1))
    else
        echo "  WARN: built DTB missing: ${dtb}" >&2
        exit 1
    fi
done
[[ "${dtb_count}" -ge 1 ]] || { echo "ERROR: no sheng DTB built" >&2; exit 1; }

cat > "${STAGE}/lib/modules/${KVER}/.armada-source" <<EOF
Source: ${KERNEL_REPO} @ ${KERNEL_BRANCH}
Base config: ${KERNEL_CONFIG} (+ merged armada fragment)
Built: sheng-builder on ${HOST_ARCH}
DTBs included: ${dtb_count} (sm8550-xiaomi-sheng*)
EOF

# Split image (gzip(Image) + DTB), for convenience/debugging; the flash
# pipeline reads from the boot deployment.
# `make Image.gz` is normally enough; gzip fallback keeps this step robust.
if [ ! -f arch/arm64/boot/Image.gz ]; then
    gzip -9 -c arch/arm64/boot/Image > arch/arm64/boot/Image.gz
fi
cat arch/arm64/boot/Image.gz \
    arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb \
    > "${OUT_DIR}/Image.gz-dtb_sheng"

# ---- 5. Package --------------------------------------------------------------
cd "${STAGE}"
OUT_NAME="armada-kernel-${KVER}.tar.zst"
mkdir -p "${OUT_DIR}"
tar --owner=0 --group=0 -cf - lib | zstd -f -10 -T0 -o "${OUT_DIR}/${OUT_NAME}"
cd "${OUT_DIR}"
sha256sum "${OUT_NAME}" > "${OUT_NAME}.sha256"

echo ""
echo "==> Done."
ls -lh "${OUT_DIR}/${OUT_NAME}" "${OUT_DIR}/${OUT_NAME}.sha256" "${OUT_DIR}/Image.gz-dtb_sheng"

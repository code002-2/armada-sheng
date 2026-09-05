#!/bin/bash
# Sheng extra device features from the debian-sheng ecosystem (ianchb).
# All four ship as official arm64 .deb releases; we extract the payloads
# (no dpkg — this is a Fedora/bootc-export rootfs, not Debian):
#
#   xiaomi-mipps-auth       — 120W MiPPS/PPS charger auth (fast charge)
#   xiaomi-charger-mode     — charger display when booted in charger mode
#   xiaomi-pen-status       — Focus Pen tray (Qt)
#   xiaomi-sheng-keyboard-helper — official keyboard helper (mic LED, hinge)
#
# Everything here is optional; failures only warn, the tablet boots without.
set -euxo pipefail

EXTRA=/tmp/sheng-extra
mkdir -p "${EXTRA}"

fetch_deb() {  # fetch_deb <repo> <tag> <debname> <destdir> -> echoes deb path
    local repo="$1" tag="$2" debname="$3" dest="$4"
    mkdir -p "${dest}"
    curl --retry 3 -fsSL -o "${dest}/${debname}" \
        "https://github.com/ianchb/${repo}/releases/download/${tag}/${debname}"
    echo "  fetched ${debname}" >&2
    echo "${dest}/${debname}"
}

unpack_deb() {  # unpack_deb <debpath> <destdir>
    local deb="$1" dest="$2"
    mkdir -p "${dest}"
    # ar + tar (no dpkg here). bsdtar reads the ar archive directly on the
    # runner (Ubuntu), so plain tar is enough; data.tar.* inside is handled
    # by tar's auto-compress detection.
    tar -xf "${deb}" -C "${dest}" 2>/dev/null || {
        # fallback: ar-style manual extraction
        ( cd "${dest}" && ar x "${deb}" && tar -xf data.tar.* ) 
    }
    rm -f "${deb}"
}

# ---------- xiaomi-mipps-auth (fast charge) ----------
echo "==> xiaomi-mipps-auth (MiPPS 120W fast charge)"
unpack_deb "$(fetch_deb xiaomi-mipps-auth 0.21 xiaomi-mipps-auth.deb "${EXTRA}")" "${EXTRA}/mipps" || true
if [ -f "${EXTRA}/mipps/usr/libexec/xiaomi-mipps-auth" ]; then
    install -m 0755 "${EXTRA}/mipps/usr/libexec/xiaomi-mipps-auth" /usr/libexec/xiaomi-mipps-auth
    install -m 0644 "${EXTRA}/mipps/usr/lib/systemd/system/xiaomi-mipps-auth.service" /usr/lib/systemd/system/ 2>/dev/null || true
    [ -f "${EXTRA}/mipps/usr/lib/udev/rules.d/90-xiaomi-mipps-auth.rules" ] && \
        install -m 0644 "${EXTRA}/mipps/usr/lib/udev/rules.d/90-xiaomi-mipps-auth.rules" /usr/lib/udev/rules.d/ 2>/dev/null || true
    systemctl enable xiaomi-mipps-auth.service 2>/dev/null || true
    echo "  mipps-auth installed"
else
    echo "  WARN: mipps-auth deb extraction failed, falling back to raw fetch"
    curl --retry 3 -fsSL -o /usr/libexec/xiaomi-mipps-auth \
        https://raw.githubusercontent.com/ianchb/xiaomi-mipps-auth/master/xiaomi-mipps-auth || true
    curl --retry 3 -fsSL -o /usr/lib/systemd/system/xiaomi-mipps-auth.service \
        https://raw.githubusercontent.com/ianchb/xiaomi-mipps-auth/master/xiaomi-mipps-auth.service || true
    curl --retry 3 -fsSL -o /usr/lib/udev/rules.d/90-xiaomi-mipps-auth.rules \
        https://raw.githubusercontent.com/ianchb/xiaomi-mipps-auth/master/90-xiaomi-mipps-auth.rules || true
    chmod 0755 /usr/libexec/xiaomi-mipps-auth 2>/dev/null || true
    systemctl enable xiaomi-mipps-auth.service 2>/dev/null || true
fi

# ---------- xiaomi-charger-mode (charger display) ----------
echo "==> xiaomi-charger-mode (charger boot display)"
unpack_deb "$(fetch_deb xiaomi-charger-mode 0.20 xiaomi-charger-mode.deb "${EXTRA}")" "${EXTRA}/charger" || true
if [ -f "${EXTRA}/charger/usr/libexec/xiaomi-charger-mode" ]; then
    install -m 0755 "${EXTRA}/charger/usr/libexec/xiaomi-charger-mode" /usr/libexec/xiaomi-charger-mode
    install -m 0644 "${EXTRA}/charger/usr/lib/systemd/system/xiaomi-charger-mode.service" /usr/lib/systemd/system/ 2>/dev/null || true
    systemctl enable xiaomi-charger-mode.service 2>/dev/null || true
    echo "  charger-mode installed"
else
    echo "  WARN: charger-mode deb extraction failed, falling back to raw fetch"
    curl --retry 3 -fsSL -o /usr/libexec/xiaomi-charger-mode \
        https://raw.githubusercontent.com/ianchb/xiaomi-charger-mode/master/xiaomi-charger-mode || true
    curl --retry 3 -fsSL -o /usr/lib/systemd/system/xiaomi-charger-mode.service \
        https://raw.githubusercontent.com/ianchb/xiaomi-charger-mode/master/xiaomi-charger-mode.service || true
    chmod 0755 /usr/libexec/xiaomi-charger-mode 2>/dev/null || true
    systemctl enable xiaomi-charger-mode.service 2>/dev/null || true
fi

# ---------- xiaomi-pen-status (Focus Pen tray) ----------
echo "==> xiaomi-pen-status (Focus Pen tray)"
unpack_deb "$(fetch_deb xiaomi-pen-status v0.2.3 xiaomi-pen-status.deb "${EXTRA}")" "${EXTRA}/pen" || true
if [ -f "${EXTRA}/pen/usr/bin/xiaomi-pen-status" ]; then
    install -m 0755 "${EXTRA}/pen/usr/bin/xiaomi-pen-status" /usr/bin/xiaomi-pen-status
    find "${EXTRA}/pen/usr/share" -type f 2>/dev/null | while read -r f; do
        install -Dm 0644 "${f}" "/usr/share/${f##*/usr/share/}" 2>/dev/null || true
    done
    echo "  pen-status installed"
else
    echo "  WARN: pen-status deb extraction failed (skipped)"
fi

# ---------- xiaomi-sheng-keyboard-helper ----------
echo "==> xiaomi-sheng-keyboard-helper (official keyboard)"
unpack_deb "$(fetch_deb xiaomi-sheng-keyboard-helper v0.2.0 xiaomi-sheng-keyboard-helper.deb "${EXTRA}")" "${EXTRA}/kb" || true
if [ -f "${EXTRA}/kb/usr/libexec/xiaomi-sheng-keyboard-helper" ]; then
    install -m 0755 "${EXTRA}/kb/usr/libexec/xiaomi-sheng-keyboard-helper" /usr/libexec/xiaomi-sheng-keyboard-helper
    [ -f "${EXTRA}/kb/usr/lib/systemd/system/xiaomi-sheng-keyboard-helper-angle.service" ] && \
        install -m 0644 "${EXTRA}/kb/usr/lib/systemd/system/xiaomi-sheng-keyboard-helper-angle.service" /usr/lib/systemd/system/ 2>/dev/null || true
    [ -f "${EXTRA}/kb/usr/lib/systemd/user/xiaomi-sheng-keyboard-helper-micmute.service" ] && \
        install -m 0644 "${EXTRA}/kb/usr/lib/systemd/user/xiaomi-sheng-keyboard-helper-micmute.service" /usr/lib/systemd/user/ 2>/dev/null || true
    [ -f "${EXTRA}/kb/usr/lib/udev/rules.d/90-xiaomi-sheng-keyboard-helper.rules" ] && \
        install -m 0644 "${EXTRA}/kb/usr/lib/udev/rules.d/90-xiaomi-sheng-keyboard-helper.rules" /usr/lib/udev/rules.d/ 2>/dev/null || true
    systemctl enable xiaomi-sheng-keyboard-helper-angle.service 2>/dev/null || true
    systemctl --global enable xiaomi-sheng-keyboard-helper-micmute.service 2>/dev/null || true
    echo "  keyboard-helper installed"
else
    echo "  WARN: keyboard-helper deb extraction failed (skipped)"
fi

rm -rf "${EXTRA}"
echo "==> sheng extra features done"

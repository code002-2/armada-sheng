#!/bin/bash
# Sheng (Xiaomi Pad 6S Pro) device fixes.
#
# These used to be injected by the container-export post-processing script
# (.github/scripts/armada-export-flashable.sh) straight into an unpacked
# rootfs. That is impossible on the bootc/ostree path: a deployment's /usr is
# immutable (composefs/fs-verity would reject tampering with it outright), so
# every fix has to be baked into the CONTAINER image before BIB deploys it.
#
#   touch   xiaomi-sheng-thp + libssc. The in-kernel nt36532e driver only
#           downloads firmware and publishes raw THP frame streams
#           (/proc/nvt_thp_raw, ...); it registers NO input device. The
#           userspace daemon consumes that stream and creates standard uinput
#           devices (multitouch + Focus Pen).
#   usb     sshd + an RNDIS USB gadget. The tablet has no serial console and
#           Windows enumerates RNDIS natively, while it rejects ECM.
#   steam   steam-now: probe the Steam CDN and fall back to offline mode so a
#           blocked or slow network never strands the user at a download
#           screen.
#   selinux permissive for this variant; see the note at the bottom.
#
# NOTE: everything here installs into /usr/bin or /usr/libexec, never
# /usr/local. On ostree /usr/local is a symlink into /var, so files placed
# there at image build time do not survive deployment.
set -euxo pipefail

VENDOR=/ctx/build_files/vendor/xiaomi-sheng-thp

# ---------------------------------------------------------------------------
# 1. Userspace touch panel: xiaomi-sheng-thp + libssc
# ---------------------------------------------------------------------------
THP_DEB="${VENDOR}/xiaomi-sheng-thp_0.3.9_arm64.deb"
LIBSSC_DEB="${VENDOR}/libssc_0.4.2-1_arm64.deb"
echo "94ABB9436FCAF848553A7C556C582BA039EC8152DA0F83618377E9B41F37060C  ${THP_DEB}" | sha256sum -c -
echo "8E97BE9775FE0326B4D090A60C088D9D22E84941B4C61865F1A662339DE0263D  ${LIBSSC_DEB}" | sha256sum -c -

# realpath is not installed in the minimal image, but sha256sum -c printed the
# path we already know; nothing to resolve.
#
# libssc.so.2's Fedora-side DT_NEEDED chain: libqmi-glib.so.5 <-
# libmbim-glib.so.4, plus libqrtr-glib.so.0 and libprotobuf-c.so.1. The export
# path had to run a throwaway fedora container for these because the exported
# tree's rpmdb does not match its filesystem; a real image build can just
# install them.
dnf5 -y --setopt=install_weak_deps=False install \
    binutils libmbim libqmi libqrtr-glib protobuf-c

# The payload sits inside the .deb's ar archive as data.tar.*. Fedora has no
# dpkg, and GNU tar cannot read an ar archive, so unpack it explicitly.
extract_deb() {
    local deb="$1" dest="$2"
    mkdir -p "${dest}"
    ( cd "${dest}" && ar x "${deb}" && tar -xf data.tar.* )
}

THPW="$(mktemp -d)"
extract_deb "${THP_DEB}" "${THPW}/thp"
extract_deb "${LIBSSC_DEB}" "${THPW}/libssc"

install -Dm0755 "${THPW}/thp/usr/libexec/xiaomi-sheng-thp/xiaomi-sheng-thp" \
    /usr/libexec/xiaomi-sheng-thp/xiaomi-sheng-thp
install -Dm0644 "${THPW}/thp/usr/lib/systemd/system/xiaomi-sheng-thp.service" \
    /usr/lib/systemd/system/xiaomi-sheng-thp.service
# Debian ships libssc.so.2 under /usr/lib/aarch64-linux-gnu; Fedora aarch64
# uses /usr/lib64. The daemon links the bare soname, so no .so symlink is
# needed.
install -Dm0755 "${THPW}/libssc/usr/lib/aarch64-linux-gnu/libssc.so.2" \
    /usr/lib64/libssc.so.2
rm -rf "${THPW}"

# CONFIG_INPUT_UINPUT=m: load it so /dev/uinput exists for the daemon.
install -d /etc/modules-load.d
echo uinput > /etc/modules-load.d/uinput.conf
systemctl enable xiaomi-sheng-thp.service

# ---------------------------------------------------------------------------
# 2. Remote access: sshd + RNDIS USB gadget
# ---------------------------------------------------------------------------
systemctl enable sshd.service

cat > /usr/libexec/armada-usbgadget <<'GADGET'
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
  # RNDIS: Windows enumerates this as a native network adapter (no driver
  # install); ECM is not supported by Windows.
  mkdir -p "$GADGET/functions/rndis.usb0"
  ln -s "$GADGET/functions/rndis.usb0" "$GADGET/configs/c.1/"
  ls /sys/class/udc > "$GADGET/UDC"
  ip link set usb0 up 2>/dev/null || true
  ip addr add 192.168.42.1/24 dev usb0 2>/dev/null || true
}
down() {
  [ -d "$GADGET" ] || return 0
  echo "" > "$GADGET/UDC" || true
  rm -f "$GADGET/configs/c.1/rndis.usb0" || true
  rmdir "$GADGET/functions/rndis.usb0" "$GADGET/configs/c.1/strings/0x409" \
        "$GADGET/configs/c.1" "$GADGET/strings/0x409" "$GADGET" 2>/dev/null || true
}
case "$1" in up) up;; down) down;; esac
GADGET
chmod 0755 /usr/libexec/armada-usbgadget

cat > /usr/lib/systemd/system/armada-usbgadget.service <<'UNIT'
[Unit]
Description=USB Ethernet gadget (RNDIS) for host access
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/armada-usbgadget up
ExecStop=/usr/libexec/armada-usbgadget down

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable armada-usbgadget.service

# ---------------------------------------------------------------------------
# 3. Steam launcher with an offline fallback
# ---------------------------------------------------------------------------
cat > /usr/bin/steam-now <<'STEAM'
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
STEAM
chmod 0755 /usr/bin/steam-now

# ---------------------------------------------------------------------------
# 4. SELinux
#
# The sheng variant boots from a baked Android boot image with no ESP and no
# bootupd, and the image carries container-style labels. Relaxing to
# permissive keeps the tablet functional while still logging every denial:
# `ausearch -m avc -ts recent`. To go back to enforcing, relabel the tree on
# the device (`touch /.autorelabel` + reboot) and flip this back.
# ---------------------------------------------------------------------------
if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    grep '^SELINUX=' /etc/selinux/config || true
fi

echo "==> sheng device fixes done"

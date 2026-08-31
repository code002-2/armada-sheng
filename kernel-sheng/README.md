# sheng kernel source (Xiaomi Pad 6S Pro)

The sheng variant of Armada does **not** use armada-packages' kernel.org build.
The kernel is built straight from the community mainline tree that carries the
touchscreen/board support for the Xiaomi Pad 6S Pro (codename "sheng"):

- Repo: <https://github.com/ianchb/sm8550-mainline>
- Branch: `sheng-7.2.2` (see `BUILD.env`)

This is deliberate: the sheng board DTS (`sm8550-xiaomi-sheng.dts`), Goodix
Berlin touch controller, keyboard-authentication (devauth) driver and other
device quirks live in that tree, not in kernel.org or in armada-packages.

## Layout

| File | Purpose |
|---|---|
| `BUILD.env` | Kernel repo / branch / config selection (single source of truth) |
| `sm8550.config` | Base config shipped by build.yml — copied from the debian-sheng project (this IS the sheng board config used by ianchb's tree) |
| `sheng-armada.config.overrides` | Armada runtime fragment merged on top; symbols unknown to the sheng config are skipped silently |
| `build.sh` | Clone → merge config → `make Image dtbs modules` → package into the exact tarball layout `build_files/20-install-kernel.sh` consumes |

## How the kernel is wired into Armada

The existing `Containerfile` kernel stage is untouched: it mounts the
`KERNEL_PKG` image stage at `/packages/kernel` and `20-install-kernel.sh`
installs `armada-kernel-*.tar.zst` from there into `/usr/lib/modules`.
The sheng kernel image is exactly the same shape:

```dockerfile
FROM scratch
COPY kernel-out/ /kernel/   # armada-kernel-<KVER>.tar.zst + .sha256
```

so the sheng pipeline only overrides the `KERNEL_PKG` build arg (and sets
`ARMADA_DTB_LIST`/`ARMADA_BOOTIMG_ARGS_FILE` in the device profile); nothing
in the Containerfile or the build steps changes.

## Building locally

```console
$ kernel-sheng/build.sh            # native aarch64, or cross via gcc-aarch64-linux-gnu
$ ls kernel-sheng/out/             # armada-kernel-<KVER>.tar.zst (+sha256, Image.gz-dtb_sheng)
```

To consume it as an overlay image and build a local sheng Armada image:

```console
$ podman build --platform linux/arm64 -f kernel-sheng/Containerfile -t localhost/armada-sheng-kernel:7.2.2 .
$ ARMADA_LOCAL_PKGS=kernel podman build ...  # see Justfile build (ARMADA_LOCAL_PKGS)
```

or, most simply, run the dedicated workflow:
`.github/workflows/build-sheng-disk.yml` (builds kernel → builds container →
BIB raw → export fastboot images).

## Updating to a newer sheng branch

Change `KERNEL_BRANCH` in `BUILD.env` and refresh `sm8550.config` from the
matching tree. The merge filter in `build.sh` keeps the armada fragment from
breaking when the sheng config drops a symbol.

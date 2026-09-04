<p align="center">
  <a href="https://armadaos.dev/">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset=".github/assets/armada-mark-white.svg">
      <img src=".github/assets/armada-mark-black.svg" alt="Armada" width="112">
    </picture>
  </a>
</p>

<h1 align="center">Armada (sheng)</h1>

<p align="center"><strong>面向小米平板 6S Pro 的 SteamOS 类 Linux 系统</strong></p>

<p align="center">
  在小米平板 6S Pro(<code>sheng</code>,SM8550)上运行 Armada——Steam、FEX、Proton 与完整桌面,
  直接刷入设备内部存储,**不含 bootc/OSTree/OTA**。
</p>

<p align="center">
  <a href="https://github.com/armada-os/armada/actions/workflows/build.yml"><img alt="Build status" src="https://github.com/armada-os/armada/actions/workflows/build.yml/badge.svg?branch=main"></a>
  <a href="https://armadaos.dev/"><img alt="Documentation" src="https://img.shields.io/badge/docs-armadaos.dev-18181a?style=flat"></a>
  <a href="LICENSE.md"><img alt="GPL-2.0-or-later license" src="https://img.shields.io/badge/license-GPL--2.0--or--later-18181a?style=flat"></a>
</p>

> [!WARNING]
> 本项目为开发中的原型软件。安装需要**已解锁的 bootloader**,并会刷写 Android 分区——
> 可能导致设备变砖、分区损坏或数据丢失。**请先备份数据。**操作前请阅读
> [刷写至小米平板 6S Pro](docs/flashing-xiaomi-sheng.md)。

## 关于本构建

这是**面向小米平板 6S Pro(`sheng`)的 Armada 修改版**,与上游 Armada 有两处刻意差异:

1. **无 bootc / OSTree / OTA。** 移除了上游基于镜像的系统更新链路。根文件系统是
   **普通 ext4 分区**,通过 `fastboot` 刷写——升级方式为**重新刷写**,而非原地更新。
2. **设备专属内核**,来自
   [ianchb/sm8550-mainline](https://github.com/ianchb/sm8550-mainline) @
   `sheng-7.2.2` 分支,并烘焙了设备修复(见下文)。

其余均与 Armada 相同:ARM64 Steam(FEX 翻译 + Proton 兼容)、游戏模式、KDE Plasma
桌面、Decky 插件、Waydroid,以及 Armada 设备服务。

### sheng 已实测可用的功能

| 组件 | 状态 |
|---|---|
| 启动(原厂 ABL、`boot_b.img`、header-v0 cmdline `root=PARTLABEL=`) | ✅ 可进入 Steam |
| 触摸屏(Novatek NT36532E) | ✅ 通过 `xiaomi-sheng-thp`(用户态 THP → uinput) |
| 音频(6× CS35L43 + WCD938X,经 QDSP6) | ✅ 通过 sheng UCM2(`alsa-ucm-conf`) |
| USB gadget ECM 网络(sshd) | ✅ |
| WiFi / KDE Plasma 桌面 / Steam 离线回退 | ✅ |

已知限制:Steam 客户端更新与游戏下载需要可用的代理/网络访问 Valve CDN
(开发中使用的代理配置见 [故障排查](docs/flashing-xiaomi-sheng.md))。

## 构建可刷镜像

运行**容器导出**流水线(无 bootc、无 BIB):

- **GitHub Actions:** [`build-armada-export.yml`](.github/workflows/build-armada-export.yml)
  —— 拉取已构建的 Armada 容器(`ghcr.io/code002-2/armada-sheng:sheng-latest`),
  逐字节导出为 `rootfs.img`,烘焙 `boot_b.img`,上传制品
  `armada-flashable-no-ota`。
- **本地:** `.github/scripts/armada-export-flashable.sh`(需要
  `podman`、配套 `mkbootimg.py` 与 `e2fsprogs`)。

产物(位于制品目录 / `output/`):

```
boot_b.img     内核 + initramfs + DTB(header-v0,Android boot image)
rootfs.img     22 GB ext4 根文件系统(单分区、growfs、/boot 并入根分区)
flash.sh       fastboot 包装脚本(校验 → 擦除 → 刷写 → 重启)
SHA256SUMS     上述所有文件的校验和
MANIFEST.txt   构建元数据
```

脚本同时会把 sheng 专属修复烘焙进导出的根文件系统:

- `xiaomi-sheng-thp` 0.3.9 + `libssc` 0.4.2(用户态触摸 → uinput)及其
  Fedora 运行时库(`libqmi-glib`、`libqrtr-glib`、`libmbim-glib`、
  `libprotobuf-c`)、`modules-load.d/uinput.conf`、启用 `xiaomi-sheng-thp.service`
- sheng 的 ALSA UCM2(`/usr/share/alsa/ucm2/Xiaomi/sheng/`),含
  `conf.d/sm8550/Xiaomi-Pad6SPro.conf` 的驱动目录映射修复
- sheng 设备固件(来自 `ianchb/sheng-firmware`)+ 驱动硬编码的
  `novatek/nt36532e.bin` 别名
- SELinux 防护(容器标签 → permissive)
- `steam-now` 启动器(探测 CDN,离线回退)
- sshd + `armada-usbgadget.service`(USB 以太网,便于远程访问)
- `steamos-update` / `steamos-select-branch` 替换为提示(本构建无 OTA)

## 刷写

**单系统模式**(占用/擦除 Android 的 `userdata` 分区,不支持双系统):

```console
$ fastboot flash boot_b boot_b.img
$ fastboot erase userdata
$ fastboot flash userdata rootfs.img
$ fastboot reboot
```

也可以直接运行自带的 `flash.sh`(固定刷 `userdata`)。
完整流程与故障排查见
[docs/flashing-xiaomi-sheng.md](docs/flashing-xiaomi-sheng.md)。

## 开发

开发配方需要 [just](https://just.systems/) 与
[Podman](https://podman.io/):

```console
$ just --list                       # 查看镜像与 sheng 配方
$ just build-sheng-kernel           # 从 ianchb/sm8550-mainline @ sheng-7.2.2 构建内核镜像
$ just build-sheng-image <kernel>   # 使用 sheng 内核构建 Armada 容器
```

sheng 路径说明:

- 内核镜像(`.github/workflows/build-sheng-disk.yml` 仍保留旧版 BIB 步骤;
  **当前有效**的可刷写路径是上面的容器导出流水线)。
- `kernel-sheng/BUILD.env` 固定了 `KERNEL_REPO`/`KERNEL_BRANCH`/`KERNEL_CONFIG`。

欢迎提交 Issue 与 PR。

## 致谢

项目上游见[项目致谢页](https://armadaos.dev/project/credits/)。`sheng` 的
内核、固件与 ALSA UCM 配置源自 [ianchb](https://github.com/ianchb)
(sm8550-mainline / sheng-firmware / xiaomi-sheng-thp)。

## 许可

Armada 自有代码采用 **GPL-2.0-or-later** 许可。捆绑组件保留其上游许可。
详见 [LICENSE.md](LICENSE.md)。

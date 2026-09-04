# sheng 内核源码(小米平板 6S Pro)

Armada 的 sheng 变体**不使用** armada-packages 的 kernel.org 构建。内核直接
从承载小米平板 6S Pro(codename "sheng")触摸屏/板级支持的社区 mainline
代码树构建:

- 仓库:<https://github.com/ianchb/sm8550-mainline>
- 分支:`sheng-7.2.2`(见 `BUILD.env`)

这是有意为之:sheng 板级 DTS(`sm8550-xiaomi-sheng.dts`)、Goodix Berlin
触摸控制器、键盘鉴权(devauth)驱动及其他设备特性都位于该代码树,而非
kernel.org 或 armada-packages。

## 目录结构

| 文件 | 用途 |
|---|---|
| `BUILD.env` | 内核仓库 / 分支 / 配置选择(唯一事实来源) |
| `sm8550.config` | build.yml 使用的 sheng 板级配置(ianchb 代码树所用) |
| `sheng-armada.config.overrides` | 叠加的 Armada 运行配置片段;与 sheng config 冲突的符号被静默跳过 |
| `build.sh` | 克隆 → 合并配置 → `make Image dtbs modules` → 打包为 `build_files/20-install-kernel.sh` 消费的精确 tarball 布局 |

## 内核如何接入 Armada

现有 `Containerfile` 内核阶段保持不变:挂载 `KERNEL_PKG` 镜像阶段到
`/packages/kernel`,`20-install-kernel.sh` 从中将 `armada-kernel-*.tar.zst`
安装到 `/usr/lib/modules`。sheng 内核镜像形状完全相同:

```dockerfile
FROM scratch
COPY kernel-out/ /kernel/   # armada-kernel-<KVER>.tar.zst + .sha256
```

因此 sheng 流水线仅覆盖 `KERNEL_PKG` 构建参数(并在设备配置中设置
`ARMADA_DTB_LIST` / `ARMADA_BOOTIMG_ARGS_FILE`);Containerfile 或构建
步骤无需任何改动。

## 本地构建

```console
$ kernel-sheng/build.sh            # 原生 aarch64,或经 gcc-aarch64-linux-gnu 交叉编译
$ ls kernel-sheng/out/             # armada-kernel-<KVER>.tar.zst(+sha256, Image.gz-dtb_sheng)
```

作为叠加镜像消费并构建本地 sheng Armada 镜像:

```console
$ podman build --platform linux/arm64 -f kernel-sheng/Containerfile -t localhost/armada-sheng-kernel:7.2.2 .
$ ARMADA_LOCAL_PKGS=kernel podman build ...  # 见 Justfile build(ARMADA_LOCAL_PKGS)
```

或最简单地运行专用工作流:
`.github/workflows/build-sheng-disk.yml`(构建内核 → 构建容器 →
BIB raw → 导出 fastboot 镜像)。

## 更新到更新的 sheng 分支

修改 `BUILD.env` 中的 `KERNEL_BRANCH`,并从对应代码树刷新 `sm8550.config`。
`build.sh` 中的合并过滤器保证 sheng 配置删除某个符号时不会破坏 armada 片段。

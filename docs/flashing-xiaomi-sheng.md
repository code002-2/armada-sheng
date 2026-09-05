# 刷写 Armada 至小米平板 6S Pro(sheng)— 内部存储(单系统)

这是 Armada 面向小米平板 6S Pro(codename `sheng`,SM8550)的内部存储构建路径。
与 SD 卡镜像(ROCKNIX ABL + `/KERNEL`)以及 bootc/OSTree 磁盘布局不同,本变体:

- 通过**原厂小米 ABL** 从 **Android 分区**启动;
- 使用不同内核 — [ianchb/sm8550-mainline](https://github.com/ianchb/sm8550-mainline)
  的 `sheng-7.2.2` 分支(自带 DTS / 触摸屏 / 板级特性);
- 根文件系统为**普通 ext4** — **无 bootc、无 OSTree、无 OTA**,升级即重新刷写;
- **仅支持单系统**:直接刷入 Android 的 `userdata` 分区,不保留 Android 数据,
  不支持多分区双系统。

镜像来自**容器导出**流水线(非 BIB):

```
.github/workflows/build-armada-export.yml     # 在 GitHub Actions 上运行
.github/scripts/armada-export-flashable.sh    # 本地(podman + mkbootimg)
```

## 产物

| 文件 | 说明 |
|---|---|
| `boot_b.img` | Android 启动镜像(header-v0):内核 + initramfs + DTB;启动参数 `root=PARTLABEL=userdata rw rootwait` |
| `rootfs.img` | **ext4** 根文件系统(构建上限 8 GB,导出时缩至实际大小),单分区,`x-systemd.growfs`,`/boot` 并入根分区 |
| `flash.sh` | fastboot 包装脚本(校验 → 擦除 dtbo_b → 刷 boot_b → 擦除+刷 userdata → 重启) |
| `SHA256SUMS` | 上述所有文件的校验和 |
| `MANIFEST.txt` | 构建元数据(容器引用、内核版本、根分区绑定) |

导出脚本会同时把 sheng 专属修复烘焙进根文件系统:

- **触摸屏**:`xiaomi-sheng-thp` 0.3.9(用户态 THP 读取器 → uinput)+
  `libssc` 0.4.2,含 Fedora 运行时库
  (`libqmi-glib`、`libqrtr-glib`、`libmbim-glib`、`libprotobuf-c`)、
  `modules-load.d/uinput.conf`,并启用 `xiaomi-sheng-thp.service`。
  (内核态 `nt36532e_ts` 驱动只负责下载固件、发布原始 THP 帧流——输入设备
  由该用户态守护进程创建。)
- **音频**:sheng 的 ALSA UCM2(`/usr/share/alsa/ucm2/Xiaomi/sheng/`),含
  驱动目录映射修复(`conf.d/sm8550/Xiaomi-Pad6SPro.conf` 必须是完整 UCM
  片段而非裸路径,alsa-lib 1.2.16 拒绝裸路径)。
- **固件**:`ianchb/sheng-firmware`(adsp / cdsp / CS35L43 / ath12k / ... 与
  DTB),外加驱动硬编码的 `novatek/nt36532e.bin` 别名。
- **SELinux**:容器文件带 `container_file_t` 标签;导出时 enforcing → permissive
  (仍可审计;需要的话可重新标记后再开启 enforcing)。
- **SSH / USB 网络**:`sshd.service` + `armada-usbgadget.service`
  (ECM 以太网,主机端 `192.168.42.1`)。
- **Steam 启动器**:`steam-now`(探测 Steam CDN,不通则回退 `-offline`)。
- **OTA 入口**:`steamos-update` / `steamos-select-branch` 替换为提示
  (本构建无 OTA;升级需重新刷写)。

## 前置条件

- 已**解锁 bootloader** 的小米平板 6S Pro(必须保留原厂 ABL —— 本流程
  **不要**刷入其他 ABL);
- 电脑端安装 `fastboot`;
- USB 数据线。**请先备份数据 —— 本流程会擦除 `userdata` 分区。**

无需 TWRP、无需创建分区 —— 直接使用 Android 的 `userdata` 分区。

## 刷写

下载 `armada-flashable-no-ota` 制品,解压,运行其中脚本(自动校验和,并固定
使用 `userdata` 分区):

```
cd armada-flashable-no-ota/
./flash.sh
```

等价命令(分区固定为 `userdata`):

```
fastboot erase dtbo_b
fastboot flash boot_b  boot_b.img
fastboot erase userdata
fastboot flash userdata rootfs.img
fastboot reboot
```

先校验镜像(`sha256sum -c SHA256SUMS`;flash.sh 会自动执行)。
`MANIFEST.txt` 记录根分区绑定。

> [!IMPORTANT]
> 必须刷**同一次构建**的 `boot_b.img` 与 `rootfs.img` —— initramfs 与
> 根文件系统通过文件系统 UUID 绑定。混用不同构建的镜像会导致启动时
> 卡在 "Preparing Armada"(经典现象)。

## 首次启动

- 首次启动需几分钟(ext4 扩容;Steam 引导已预制,`xiaomi-sheng-thp` 与
  ALSA UCM2 已安装)。
- 登录:用户 `armada` / `armada`(修改密码:`passwd armada`)。
- Steam 大屏(游戏模式)或 KDE Plasma 桌面:在会话切换器中选择
  (`armada-session-select` 或菜单栏图标)。
- 挂起:`mem` 已在 sheng 设备配置中启用。

## 设备说明(已在真机验证)

- **触摸屏**:必须运行 `xiaomi-sheng-thp` 才会出现输入设备
  (`systemctl status xiaomi-sheng-thp`)。它需要 `/proc/nvt_thp_raw` 与
  `/dev/uinput`;无触控笔也可触摸。
- **音频**:声卡名为 `XiaomiPad6SPro`(驱动 `snd-sc8280xp`)。若重启后
  `aplay -l` 无声卡,说明 QDSP6 音频域未就绪(见故障排查)。
- **WiFi IP 每次启动可能变化**(DHCP):用 `ip addr` 或路由器查看,
  然后 `ssh armada@<ip>`(密码 `armada`)。
- **磁盘交换**:镜像未内置 swap 文件;需要时自行创建
  (`fallocate -l 8G /swapfile && mkswap /swapfile && swapon /swapfile`)。

## 尚未移植的功能

| 功能 | 状态 |
|---|---|
| 传感器(方向/光照,libssc + iio-sensor-proxy) | 镜像未包含(内核 QRTR/fastrpc 已开启;用户态需打包) |
| 小米键盘鉴权(devauth) | 仅内核驱动;无用户态服务 |
| 指纹(TEE) | 不支持(专有 TEE 栈) |
| 触控笔 / 笔状态 | 触控笔 THP 经 `xiaomi-sheng-thp` 可用;`xiaomi-pen-status` 未安装 |
| 120W MIPPS 充电 | 未移植(稳压器工作,充电功率为原厂) |

以上均为增量项 —— 平板本身已可正常启动运行。

## 故障排查

- **Steam 提示"无法下载所需更新"** — Valve CDN
  (`client-update.steamstatic.com`) 在国内直连不稳定。请使用 HTTP 代理:
  Steam 设置 → 下载 → HTTP 代理 →
  `http://<主机IP>:7897`(Clash/verge 开启 Allow-LAN)。验证:
  `curl -x http://<主机IP>:7897 -sI https://client-update.steamstatic.com`。
  离线使用:`steam-now`(即 `steam -steamdeck -offline`)。
- **重启后无声** — QDSP6 音频域与 ADSP 启动存在竞态。查看
  `dmesg | grep -E 'qcom-apm|fsgen'`:出现 `CMD timeout` / `unable to get
  fsgen clock` 说明音频时钟提供过早。可用内核级修复,或在 ADSP 就绪后
  重启 `snd_soc_sc8280xp`;通常普通重启即可解决。
- **启动循环 / 无法启动** — 单独重刷 `boot_b.img`
  (`fastboot flash boot_b boot_b.img`)。若仍失败,重刷两个镜像并检查
  分区名(`fastboot getvar current-slot`)。
- **停在 ABL 菜单** — `boot_b` 被擦除(运行过 `fastboot erase boot_b`)
  或 `dtbo_b` 损坏 — 重刷 `boot_b.img`。
- **其他发行版的 recovery 劫持 ABL 回退** — `fastboot erase recovery`
  (曾在 sheng 上观察到 Armbian recovery 分区抢占 ABL 回退)。
- **首次启动黑屏** — 烘焙的 initramfs 可能早于根文件系统;干净重建后
  重新导出镜像。

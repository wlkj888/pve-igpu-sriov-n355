# PVE 核显 SR-IOV 实战指南（Intel N355 / Alder Lake-N）

把 Proxmox VE 宿主机上的 **Intel 核显切成 1 个物理卡 + 7 个虚拟显卡（VF）**，分给多台虚拟机同时使用硬件编解码。

本文是**一次真实完整部署的全流程记录**（2026-09-22，从零到跑通，含所有踩过的坑），不是理论文档。

> 涉及的 IP、主机名已脱敏，请替换成你自己的实际值。

---

## 一、成果

| 项目 | 结果 |
|---|---|
| 宿主机 | Proxmox VE 9.2（内核由 6.8.12-43-pve 升到 **7.0.14-16-pve**） |
| CPU | Intel Core 3 **N355**（Twin Lake / Alder Lake-N，核显设备 ID **8086:46d3**，32 EU） |
| 切分结果 | `00:02.0` 物理卡 + `00:02.1`～`00:02.7` 共 **7 个 VF** |
| 分配情况 | `00:02.1` → fnOS 类 NAS 虚拟机；其余留空待用 |
| 客户机驱动 | Linux 客户机（内核 ≥ 6.18）**原生识别，无需装任何额外驱动** |

核心工具：社区项目 [strongtz/i915-sriov-dkms](https://github.com/strongtz/i915-sriov-dkms)

---

## 二、30 秒原理

- **整卡直通（vfio）**：核显整个交给一台 VM，宿主机不能碰 → 只能给 1 台用。
- **SR-IOV**：宿主机自己用 i915 驱动接管核显，把它切成 1 个 PF（物理功能）+ 7 个 VF（虚拟功能），每个 VF 可以独立分给一台 VM → **一台核显多台虚拟机同时用**。
- 一句话区别：**整卡直通是"独占"，SR-IOV 是"分时共享"**。

⚠️ 铁律：**只能把 VF（02.1～02.7）分给虚拟机，永远不要把 PF（00:02.0）挂给任何 VM**，否则所有 VF 一起崩溃。

---

## 三、先确认你的硬件能不能做

```bash
lspci -nn | grep -iE 'vga|display'      # 记下 [8086:xxxx] 设备 ID
cat /sys/devices/pci0000:00/0000:00:02.0/device
uname -r
mokutil --sb-state                       # 必须是 disabled
dmesg | grep -e DMAR -e IOMMU | head     # IOMMU 是否开启
```

- 支持：11 代及以后的 Xe / Xe-LP 核显（Tiger / Alder / Raptor Lake，以及 **Alder Lake-N、Twin Lake**：N100 / N305 / N355 等）
- 走 **i915** 驱动（不是 xe）。xe 驱动不支持 Meteor Lake / Lunar Lake，Xe_LP 平台另有坑。
- **Secure Boot 必须是 disabled**，否则第三方内核模块加载不了。

---

## 四、内核版本决定用哪个驱动包（第一个大坑）

| 运行内核 | 必须使用的 release |
|---|---|
| 6.18 ~ 7.2 | **2026.09.16** |
| 6.12 ~ 6.19 | 2026.03.05.7 |
| 6.8 ~ 6.12 | 2025.07.22 |
| 6.1 ~ 6.7 | intel-lts-v6.1 分支 |

deb 包名形如：`i915-sriov-dkms_2025.07.22_amd64.deb`

**实录**：PVE 的 `6.8.12-43-pve` 装 2025.07.22 会报

```
redefinition of 'mem_is_zero'
```

原因是 PVE 往 6.8 内核里回移了新函数，与老版本兼容层冲突。**不要去改源码打补丁**——正确做法是换新内核 + 新版驱动。

---

## 五、换默认内核：PVE 9 必须查 `proxmox-boot-pin`（第二个大坑，最隐蔽）

改完 `/etc/default/grub` 跑 `update-grub`，菜单里 7.0.14 明明排第一，**重启后却还是进旧内核**。

原因：PVE 9 的默认内核由文件 `/etc/kernel/proxmox-boot-pin` 固定，grub.cfg 里会生成

```
set default="gnulinux-advanced-...>gnulinux-6.8.12-43-pve-advanced-..."
```

优先级高于 `GRUB_DEFAULT=0`。

```bash
cat /etc/kernel/proxmox-boot-pin                 # 查看当前固定值
proxmox-boot-tool kernel pin 7.0.14-16-pve       # 改成新内核（会自动 update-grub）
reboot
uname -r                                          # 验证
```

排查顺序：`uname -r` → `uptime -s`（确认真的重启过）→ `cat /etc/kernel/proxmox-boot-pin` → 再怀疑 grub 本身。

---

## 六、完整操作步骤

### 第 0 步：清理历史残留（失败过或整卡直通过的机器必做）

```bash
# 宿主机要自己接管核显，不能再 blacklist i915
sed -i '/blacklist i915/d' /etc/modprobe.d/pve-blacklist.conf

# 解除 vfio 对核显的绑定（整卡直通时期留下的），否则开机就被 vfio-pci 抢走
echo "#options vfio-pci ids=8086:46d3,8086:54c8" > /etc/modprobe.d/vfio.conf

# 开机自动切出 7 个 VF（sysfsutils）。注意：多次尝试会堆积重复行，建议先覆盖写
echo "devices/pci0000:00/0000:00:02.0/sriov_numvfs = 7" > /etc/sysfs.conf

# 删掉 VM 上的核显整卡直通（只删核显那一项！其他 hostpci、硬盘直通别动）
qm set <VMID> --delete hostpci0
```

> `sed` 偶发失效（文件可能有特殊字符），`echo >` 覆盖写入是最稳的写法。

### 第 1 步：设置内核启动参数

GRUB 启动（LVM 根分区的常见情况）：

```
/etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on i915.enable_guc=3 i915.max_vfs=7 i915.xelp_enable_ccs=1 module_blacklist=xe"
```

- `i915.force_probe=<设备ID>`：老内核不认识新核显时才需要加
- **`i915.xelp_enable_ccs=1`**：2026.09.16 起 Xe_LP 平台默认关闭 CCS0，跑 **Windows 客户机必须加**
- systemd-boot（ZFS 根）改 `/etc/kernel/cmdline`，然后 `proxmox-boot-tool refresh`

```bash
update-grub
update-initramfs -u -k all
```

### 第 2 步：重启并确认内核（⚠️ 重启 PVE 会连带重启路由 VM，导致断网）

```bash
reboot
uname -r        # 必须是 7.0.14-16-pve
```

### 第 3 步：安装驱动（内核已换好之后）

```bash
apt update
apt install -y build-essential dkms sysfsutils pve-headers-$(uname -r)
wget -O /root/i915-sriov-dkms.deb "https://github.com/strongtz/i915-sriov-dkms/releases/download/2026.09.16/i915-sriov-dkms_2026.09.16_amd64.deb"
dpkg -i /root/i915-sriov-dkms.deb
```

- **deb 包别放 `/tmp`**：Debian 重启会清空 /tmp，包会消失
- GitHub 下载 TLS 中断时，URL 前加镜像前缀：`https://ghfast.top/https://github.com/...`
- 编译报错看日志第一个 error（后面成片的 `Error 1` 都是连锁反应）：
  ```bash
  grep -n -m3 -iE 'fatal error|error:' /var/lib/dkms/i915-sriov-dkms/<版本>/build/make.log
  ```

### 第 4 步：换载新驱动模块

装完 deb 后，当前运行的仍是开机时加载的内核自带 i915：

```bash
modprobe -r i915 && modprobe i915
modinfo i915 | head -5        # filename 应为 /lib/modules/<内核>/updates/dkms/i915.ko
lspci -nnk -s 00:02.0         # 看 Kernel driver in use 是谁
```

**若显示 `Kernel driver in use: vfio-pci`**（vfio 残留绑定的典型现象），手动把设备交给 i915：

```bash
echo 0000:00:02.0 > /sys/bus/pci/devices/0000:00:02.0/driver/unbind
echo 0000:00:02.0 > /sys/bus/pci/drivers/i915/bind
```

### 第 5 步：切出虚拟显卡

```bash
echo 7 > /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs
lspci | grep -i graphics
```

成功输出：

```
00:02.0 VGA compatible controller: Intel Corporation Alder Lake-N [Intel Graphics]
00:02.1 VGA compatible controller: Intel Corporation Alder Lake-N [Intel Graphics]
00:02.2 ...（一直到 00:02.7）
```

### 第 6 步：把 VF 分给虚拟机

```bash
qm shutdown <VMID> && qm wait <VMID>
qm set <VMID> --hostpci0 0000:00:02.1,pcie=1,x-vga=1    # Windows 加 x-vga
qm start <VMID>
```

- 每台 VM 用**不同编号**，不要重复
- 也可以用 PVE 网页端：虚拟机 → 硬件 → 添加 → PCI 设备 → 选 `0000:00:02.x`

### 第 7 步：客户机内验证

```bash
ls -l /dev/dri/        # 出现 renderD128 说明驱动已接管，硬解可用
```

- **Linux 客户机**：内核 ≥ 6.18 的发行版（如 fnOS 6.18.18）**原生支持 VF，无需装任何驱动**
- **Windows 客户机**：装 Intel 官方显卡驱动；报 Code 43 时需要对应平台的 GOP romfile（放到 `/usr/share/kvm`，配置里写 `romfile=xxx.efi`）

---

## 七、排障速查表

| 现象 | 原因 / 解法 |
|---|---|
| 编译报 `redefinition of 'mem_is_zero'` | 老驱动 + 新 PVE 内核 → 换内核和新版驱动，别 patch |
| 重启后内核没变 | `/etc/kernel/proxmox-boot-pin` 固定住了 → `proxmox-boot-tool kernel pin` |
| 装完驱动没有 VF | 模块没换载 → `modprobe -r i915 && modprobe i915` |
| 设备被 vfio-pci 占用 | `lspci -nnk` 确认 → unbind 后 bind 到 i915 |
| `sriov_numvfs: No such file or directory` | 加载的不是 DKMS 模块，或设备未被 i915 接管 |
| 开机后 VF 全部消失 | vfio.conf 的 ids 又生效了 / i915 被 blacklist / initramfs 没刷新 |
| dkms 报旧版本残留 | `dkms status` 查看 → `dkms remove ... --all` + `rm -rf /var/lib/dkms/i915-sriov-dkms` |
| 系统起不来 | GRUB 启动项加 `module_blacklist=i915,xe` 临时禁用驱动 |

---

## 八、回滚方案

```bash
# 1. 去掉 VM 上的 VF 直通
qm set <VMID> --delete hostpci0

# 2. 卸载驱动
dpkg -P i915-sriov-dkms
rm -rf /var/lib/dkms/i915-sriov-dkms

# 3. 恢复内核启动参数（去掉 i915.max_vfs 等）
nano /etc/default/grub
update-grub && update-initramfs -u -k all

# 4. 想恢复整卡直通：把 vfio.conf 那行的 # 去掉即可
```

---

## 九、性能预期

7 个 VF 共享同一个核显（N355 是 32 EU）的算力，**是分时复用，不是 7 份独立性能**：

- 轻负载、各自转码：完全够用
- 多台同时重压转码：会互相抢速，总吞吐仍受限于一颗核显

---

## 十、命令速查

```bash
lspci -nn | grep -iE 'vga|display'                  # 看核显
lspci | grep -i graphics                            # 看虚拟显卡
lspci -nnk -s 00:02.0                               # 看核显被哪个驱动占用
cat /etc/kernel/proxmox-boot-pin                    # 看 PVE 固定的默认内核
proxmox-boot-tool kernel pin <版本>                  # 改默认内核
dkms status                                         # 看 DKMS 模块状态
modinfo i915 | head -5                              # 确认加载的是 DKMS 模块
echo 7 > /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs   # 切 7 个 VF
ls -l /dev/dri/                                     # 客户机内验证硬解
```

---

## 附：本次部署环境（脱敏参考）

```
宿主机：Proxmox VE 9.2，内核 7.0.14-16-pve
CPU：Intel Core 3 N355（Twin Lake，核显 8086:46d3，32 EU）
引导方式：UEFI + GRUB（根分区 LVM）
虚拟机：ikuai 主路由 / immop / fnOS NAS / win11 / Portainer / CellBridge
内存：31 GB（已分配约 27 GB）
```

⚠️ 特别提醒：如果 PVE 里跑着软路由（如 iKuai），**重启 PVE = 全家断网**，务必挑没人在用网的时候操作，并确认路由 VM 已设开机自启。

---

*本指南由一次真实部署整理，所有命令均在实际机器上验证通过。*

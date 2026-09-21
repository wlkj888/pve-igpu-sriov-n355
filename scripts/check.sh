#!/usr/bin/env bash
# PVE Intel 核显 SR-IOV 环境自检脚本
# 用法：sudo bash check.sh
# 只读检查，不修改任何配置

set -u
GRN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; NC='\033[0m'
ok()   { echo -e "${GRN}[OK]${NC} $1"; }
bad()  { echo -e "${RED}[!!]${NC} $1"; }
warn() { echo -e "${YEL}[--]${NC} $1"; }
hr()   { echo "------------------------------------------------------------"; }

hr; echo "1. 内核版本"; hr
KVER=$(uname -r); echo "当前内核: $KVER"
case "$KVER" in
  6.18*|6.19*|7.0*|7.1*|7.2*) ok "内核在 6.18~7.2 区间 → 用驱动 2026.09.16" ;;
  6.12*|6.13*|6.14*|6.15*|6.16*|6.17*) ok "内核在 6.12~6.19 区间 → 用驱动 2026.03.05.7" ;;
  6.8*|6.9*|6.10*|6.11*) ok "内核在 6.8~6.12 区间 → 用驱动 2025.07.22" ;;
  *) warn "内核不在常见支持区间，请到项目 README 确认版本" ;;
esac
cat /etc/kernel/proxmox-boot-pin 2>/dev/null \
  && warn "PVE 内核被固定为以上版本（优先级高于 GRUB 菜单顺序）" \
  || warn "未找到 /etc/kernel/proxmox-boot-pin（PVE 8 或更早无此机制）"

hr; echo "2. 核显与设备 ID"; hr
lspci -nn | grep -iE 'vga|display' || bad "没找到 VGA 设备"
DEVID=$(cat /sys/devices/pci0000:00/0000:00:02.0/device 2>/dev/null)
echo "核显设备 ID: ${DEVID:-未知}"
[ -f /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs ] \
  && ok "sriov_numvfs 存在 → PF 已具备 SR-IOV 能力" \
  || bad "sriov_numvfs 不存在 → 当前驱动不支持 SR-IOV 或设备未被 i915 接管"

hr; echo "3. 虚拟显卡（VF）"; hr
VF=$(lspci | grep -c "00:02\.[1-7]")
echo "已切出的 VF 数量: $VF"
[ "$VF" -gt 0 ] && ok "VF 已存在" || bad "还没有 VF，需执行 echo 7 > .../sriov_numvfs"

hr; echo "4. 核显当前被哪个驱动占用"; hr
DRV=$(lspci -nnk -s 00:02.0 2>/dev/null | grep -i "kernel driver in use" | awk -F': ' '{print $2}')
echo "Kernel driver in use: ${DRV:-（无）}"
case "$DRV" in
  i915) ok "i915 已接管核显" ;;
  vfio-pci) bad "核显被 vfio-pci 占用（整卡直通残留），需 unbind 并 bind 到 i915" ;;
  *) warn "未识别的驱动状态" ;;
esac

hr; echo "5. 驱动模块来源"; hr
MOD=$(modinfo i915 2>/dev/null | awk -F': ' '/^filename/{print $2}')
echo "i915 模块路径: ${MOD:-未加载}"
case "$MOD" in
  *updates/dkms*) ok "加载的是 DKMS（SR-IOV）版本" ;;
  *kernel/drivers*) bad "加载的是内核自带 i915，需 modprobe -r i915 && modprobe i915" ;;
  *) warn "i915 未加载或路径异常" ;;
esac

hr; echo "6. 关键配置检查"; hr
grep -qE "^[[:space:]]*blacklist[[:space:]]+i915" /etc/modprobe.d/*.conf 2>/dev/null \
  && bad "发现 blacklist i915（宿主机将无法接管核显）" \
  || ok "未发现 blacklist i915"
grep -qE "^[[:space:]]*options[[:space:]]+vfio-pci.*ids=" /etc/modprobe.d/*.conf 2>/dev/null \
  && bad "发现生效的 vfio-pci ids（核显会被直通驱动抢走）" \
  || ok "未发现生效的 vfio-pci ids"
grep -q "sriov_numvfs" /etc/sysfs.conf 2>/dev/null \
  && ok "sysfs.conf 已配置开机切 VF" \
  || warn "sysfs.conf 未配置，重启后需手动 echo 7"
grep -q "i915.max_vfs" /proc/cmdline \
  && ok "内核参数含 i915.max_vfs" \
  || bad "内核参数缺少 i915.max_vfs，请改 /etc/default/grub 后 update-grub"
grep -q "intel_iommu=on" /proc/cmdline \
  && ok "IOMMU 已开启" \
  || bad "内核参数缺少 intel_iommu=on"

hr; echo "7. 安全启动"; hr
if command -v mokutil >/dev/null 2>&1; then
  mokutil --sb-state 2>/dev/null | grep -qi "disabled" \
    && ok "Secure Boot 已关闭" \
    || bad "Secure Boot 未关闭，DKMS 模块将无法加载"
else
  warn "未安装 mokutil，无法判断"
fi

hr; echo "检查完毕"; hr

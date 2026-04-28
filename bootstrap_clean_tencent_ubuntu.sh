#!/usr/bin/env bash
# =============================================================================
# gui-tu — 腾讯云 Ubuntu 节点彻底清理 + 准备脚本（root 模式幂等）
#
# 用途：拿到一台新装 Ubuntu 的腾讯云机器，清掉所有腾讯定制（YunJing/tat-agent/
#       cloud-init Tencent datasource / 自启 cron / 网卡 udev / nv 驱动 helper），
#       开 root 密码登录 + 重启 sshd，留一台**干净的 Ubuntu** 给我们部 agent。
#
# 用法（在本机调用）：
#   bash bootstrap_clean.sh <IP> <ubuntu-password> <new-root-password>
#
# 内部以 ubuntu 登录 + sudo -i bash -s 把自身脚本传到对端以 root 执行（等效 su -）。
# 重复执行幂等：所有动作 idempotent，可以放心多跑。
# =============================================================================
set -euo pipefail

IP="${1:?usage: $0 <IP> <ubuntu-password> <new-root-password>}"
UBPASS="${2:?usage: $0 <IP> <ubuntu-password> <new-root-password>}"
ROOTPASS="${3:?usage: $0 <IP> <ubuntu-password> <new-root-password>}"

command -v sshpass >/dev/null || { echo "需要 sshpass: apt install sshpass"; exit 1; }

# 清掉本地 known_hosts 老条目（系统重装会换 host key）
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$IP" 2>/dev/null || true

echo "==[ 阶段 1: SSH 通过 ubuntu 登录 + sudo bash 升 root（等效 su - 但 stdin 可 pipe）]=="
echo "==[ 阶段 2: 远端 root 执行清剿脚本（heredoc 传输，不落 /tmp 文件）]=="

# 在本地用 sed 把 ROOTPASS placeholder 替换成实际密码，再 pipe 给远端 sudo bash -s 执行。
# 不走 env 转发（ssh 默认不传 env，sudo -i 又跟 -E 互斥）— 直接内容注入最稳。
REMOTE_BODY=$(sed "s|@@ROOTPASS@@|${ROOTPASS//|/\\|}|g" <<'REMOTE_SCRIPT'
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# -- 检查身份（应是 root 0）
if [[ "$(id -u)" -ne 0 ]]; then
  echo "FATAL: not root (uid=$(id -u))"; exit 1
fi
echo "✓ now running as $(whoami) (uid=0) on $(hostname)"

step() { echo; echo "=== $* ==="; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }

# --------------------------------------------------------------------------
step "[1/12] 设 root 密码 + 开 root 登录 + 删 cloud-init 默认 dropin"
echo "root:@@ROOTPASS@@" | chpasswd
ok "root 密码已设"

# 主 sshd_config
sed -ri 's/^#?\s*PermitRootLogin.*/PermitRootLogin yes/'  /etc/ssh/sshd_config
sed -ri 's/^#?\s*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
ok "sshd_config: PermitRootLogin yes + PasswordAuthentication yes"

# cloud-init / 安装时的 dropin 会反向覆盖，全删
shopt -s nullglob
for f in /etc/ssh/sshd_config.d/*.conf; do
  if grep -qE "PasswordAuthentication\s+no|PermitRootLogin\s+(no|prohibit-password)" "$f" 2>/dev/null; then
    rm -f "$f" && ok "rm dropin $f（含 deny 规则）"
  fi
done

# --------------------------------------------------------------------------
step "[2/12] 切断 cloud-init TencentCloud datasource + 全程禁用 cloud-init"
if [[ -f /etc/cloud/cloud.cfg ]]; then
  cp -n /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.before-detencent.bak
  # datasource_list 改 None
  sed -i 's/^datasource_list:.*/datasource_list: [ None ]/' /etc/cloud/cloud.cfg
  # 删 datasource: 块下的 TencentCloud 子配置
  sed -i '/^datasource:/,/^[a-z]/{/TencentCloud/,/^  [A-Z]/{/^  TencentCloud:/d; /^    /d}}' /etc/cloud/cloud.cfg
  ok "cloud.cfg datasource_list = [ None ]"
fi
touch /etc/cloud/cloud-init.disabled
for u in cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service; do
  systemctl mask "$u" 2>/dev/null && ok "mask $u" || warn "$u not present"
done

# --------------------------------------------------------------------------
step "[3/12] 干掉腾讯云所有 systemd unit / 自启脚本"
for unit in tat_install tat_agent YDService YDLive yunjing barad stargate nv_gpu_shutdown_pm; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}"; then
    systemctl disable --now "${unit}" 2>/dev/null && ok "disabled ${unit}" || true
  fi
done
rm -f \
  /etc/systemd/system/tat_install.service \
  /etc/systemd/system/tat_agent.service \
  /etc/systemd/system/YDService.service \
  /etc/systemd/system/YDLive.service \
  /etc/systemd/system/multi-user.target.wants/tat_install.service \
  /etc/systemd/system/multi-user.target.wants/nv_gpu_shutdown_pm.service \
  /lib/systemd/system/nv_gpu_shutdown_pm.service \
  /lib/systemd/system/YDService.service \
  /lib/systemd/system/YDLive.service \
  /etc/init.d/YDService /etc/init.d/YDLive 2>/dev/null
systemctl daemon-reload
ok "systemd unit 清理"

# --------------------------------------------------------------------------
step "[4/12] 删 cron / rc.local / udev 里的腾讯入口"
rm -f /etc/cron.d/yunjing /etc/cron.daily/qcloud* /etc/cron.hourly/qcloud* 2>/dev/null
ok "cron 清理"

if [[ -f /etc/rc.local ]]; then
  if grep -qE "qcloud|tencent" /etc/rc.local; then
    cp -n /etc/rc.local /etc/rc.local.before-detencent.bak
    : > /etc/rc.local      # 清空内容
    chmod -x /etc/rc.local
    ok "/etc/rc.local 清空（备份 .before-detencent.bak）"
  fi
fi

rm -f /etc/udev/rules.d/80-qcloud-nic.rules /lib/udev/rules.d/80-qcloud-nic.rules 2>/dev/null
ok "udev 腾讯定制规则删除"

# --------------------------------------------------------------------------
step "[5/12] kill 残留腾讯云进程 + 删二进制"
for proc in YDService YDLive tat_agent nv_driver_install_helper cvm_init "/usr/local/qcloud" "/qcloud_init"; do
  pkill -9 -f "$proc" 2>/dev/null && ok "killed pattern: $proc" || true
done
sleep 1

rm -f /usr/local/bin/tat_agent /usr/local/bin/tat_install* /usr/local/sbin/tat_agent 2>/dev/null
ok "tat_agent / tat_install binary 删除"

# --------------------------------------------------------------------------
step "[6/12] 清 cloud-init 缓存（vendor-data + 一次性脚本）"
rm -rf /var/lib/cloud/instance /var/lib/cloud/instances/* /var/lib/cloud/scripts/vendor 2>/dev/null
ok "cloud-init 缓存清"

# --------------------------------------------------------------------------
step "[7/12] /qcloud_init/ + /usr/local/qcloud 整目录清剿 + 重锁"
chattr -i /usr/local/qcloud 2>/dev/null || true
rm -rf /qcloud_init /usr/local/qcloud /etc/qcloudzone /etc/qcloud /var/log/qcloud 2>/dev/null
mkdir -p /usr/local/qcloud
chattr +i /usr/local/qcloud 2>/dev/null && ok "/usr/local/qcloud 已 chattr +i (immutable)" || warn "chattr +i 失败 — 可能 fs 不支持"

# --------------------------------------------------------------------------
step "[8/12] 卸残留 deb 包（ignore 失败）"
QPKGS=$(dpkg -l 2>/dev/null | awk '/^ii/ && (/qcloud|tencent|tat-|stargate|yunjing|barad|aegis/) {print $2}' | xargs -r echo)
if [[ -n "$QPKGS" ]]; then
  apt-get remove -y --purge $QPKGS 2>&1 | tail -2 || true
  ok "remove $QPKGS"
else
  ok "没有腾讯 deb 包残留"
fi

# --------------------------------------------------------------------------
step "[9/12] 重启 sshd 让 PermitRootLogin / PasswordAuthentication 生效"
if systemctl is-active --quiet ssh; then
  systemctl restart ssh
  ok "ssh.service 重启"
elif systemctl is-active --quiet ssh.socket; then
  systemctl restart ssh.socket
  ok "ssh.socket 重启"
fi

# --------------------------------------------------------------------------
step "[10/12] 复查清单"
echo "[A] 腾讯云相关进程:"
ps -ef | grep -iE "qcloud|yunjing|tat_agent|YDService|YDLive|cvm_init|nv_driver|stargate|barad" | grep -v grep || echo "  (无)"
echo
echo "[B] cloud-init datasource 配置:"
grep -E "datasource_list|^datasource:" /etc/cloud/cloud.cfg 2>/dev/null || echo "  (无)"
echo
echo "[C] cloud-init 服务状态:"
for s in cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service; do
  echo "  $s = $(systemctl is-enabled $s 2>&1) / $(systemctl is-active $s 2>&1)"
done
echo
echo "[D] /usr/local/qcloud:"
ls -la /usr/local/qcloud 2>&1 | head -3
lsattr -d /usr/local/qcloud 2>&1
echo
echo "[E] sshd 配置:"
grep -E "^Port|^PermitRootLogin|^PasswordAuthentication" /etc/ssh/sshd_config
echo
echo "[F] 当前 sshd 监听端口:"
ss -tlnp 2>/dev/null | grep -E "sshd|:22" | head -3
echo
echo "[G] /etc/cron.d 全清单（应只剩 e2scrub_all + sysstat）:"
ls /etc/cron.d/

# --------------------------------------------------------------------------
step "[11/12] 锁定测试 — 写一个文件到 /usr/local/qcloud 看是否被 immutable 拒"
if touch /usr/local/qcloud/test_write 2>/dev/null; then
  warn "/usr/local/qcloud 没锁住！touch 成功了 — 检查 chattr +i 是否生效"
  rm -f /usr/local/qcloud/test_write
else
  ok "/usr/local/qcloud 写入测试被拒（immutable 生效）"
fi

step "[12/12] 完成 — root SSH 准备就绪"
echo "  → ssh root@$(hostname -I | awk '{print $1}') (用 ROOTPASS 登录)"
echo "  → 重启验证可选：reboot 后再跑这个脚本，应当报告所有项已是清洁态"
REMOTE_SCRIPT
)

# 把替换好的脚本 pipe 给远端 sudo bash -s 执行
echo "$REMOTE_BODY" | sshpass -p "$UBPASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  ubuntu@"$IP" 'sudo bash -s'

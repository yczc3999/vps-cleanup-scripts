#!/usr/bin/env bash
# =============================================================================
# gui-tu — 通用云厂商插件清剿脚本（腾讯/阿里/华为/裸机均可）
#
# 设计要点：
#   1. detect 阶段：扫所有已知云厂商定制痕迹，输出报告（不动系统）
#   2. clean 阶段：按层次清剿（service → binary → cron → udev → cloud-init datasource → /usr/local/<vendor> → chattr +i 锁）
#   3. verify 阶段：包括重启自检（可选）
#
# 用法（在节点上以 root 运行）：
#   bash clean_cloud_plugins.sh detect           # 只扫描，不动
#   bash clean_cloud_plugins.sh clean            # 全清剿
#   bash clean_cloud_plugins.sh verify           # 重启后自检（不再重生）
#
# 远程一行调用（admin 后台 agent_ops/exec 通道）：
#   curl ... -d '{"command":"echo <BASE64_OF_THIS_SCRIPT> | base64 -d > /tmp/c.sh && bash /tmp/c.sh clean","timeout_sec":120}'
# =============================================================================
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ACTION="${1:-detect}"

# ---------- 检测函数 ----------
section() { echo; echo "==[ $* ]=="; }
ok() { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# 已知云厂商定制目录（凡是出现就是污染）
KNOWN_VENDOR_DIRS=(
    /usr/local/qcloud           # 腾讯云
    /qcloud_init                # 腾讯云 cvm_init
    /usr/local/aegis            # 阿里云盾
    /usr/local/aliyun           # 阿里云通用
    /aliyun_init                # 阿里云
    /usr/local/cloudmonitor     # 阿里云 CMS
    /etc/qcloud                 # 腾讯云
    /etc/qcloudzone             # 腾讯云
    /etc/aliyun                 # 阿里云
    /etc/cloudmonitor           # 阿里云
)

# 已知云厂商 systemd unit（关键字匹配）
KNOWN_VENDOR_UNIT_KEYWORDS=(
    tat_install tat_agent       # 腾讯运维助手
    YDService YDLive yunjing    # 腾讯云镜
    sgagent stargate            # 腾讯 stargate
    barad nv_gpu_shutdown_pm    # 腾讯
    aegis aegis_quartz          # 阿里云盾
    cloudmonitor argusagent     # 阿里 CMS
    aliyun_assist               # 阿里运维助手
    cwagent                     # 华为云监控
)

# 已知云厂商 cron 文件
KNOWN_VENDOR_CRONS=(
    /etc/cron.d/yunjing
    /etc/cron.d/sgagenttask
    /etc/cron.d/aegis
    /etc/cron.d/aliyun
    /etc/cron.d/argusagent
)

# 已知云厂商 udev 规则
KNOWN_VENDOR_UDEV=(
    /etc/udev/rules.d/80-qcloud-nic.rules
    /lib/udev/rules.d/80-qcloud-nic.rules
    /etc/udev/rules.d/70-aliyun-nic.rules
)

# 已知 cloud-init datasource（保留 ConfigDrive；移除厂商专属）
VENDOR_DATASOURCES_TO_REMOVE=(
    "TencentCloud"
    "AliYun"
    "Aliyun"
    "HuaweiCloud"
)

# ---------- 检测 ----------
detect() {
    section "[1] 已知云厂商目录"
    for d in "${KNOWN_VENDOR_DIRS[@]}"; do
        if [[ -e "$d" ]]; then
            local sz
            sz=$(du -sh "$d" 2>/dev/null | cut -f1)
            warn "$d ($sz)"
        fi
    done

    section "[2] 已知云厂商 systemd unit"
    for kw in "${KNOWN_VENDOR_UNIT_KEYWORDS[@]}"; do
        local found
        found=$(systemctl list-unit-files --no-pager 2>/dev/null | grep -E "^${kw}" | head -3)
        [[ -n "$found" ]] && warn "$kw → $found"
    done

    section "[3] 已知云厂商 cron"
    for c in "${KNOWN_VENDOR_CRONS[@]}"; do
        [[ -e "$c" ]] && warn "$c"
    done

    section "[4] 已知云厂商 udev"
    for u in "${KNOWN_VENDOR_UDEV[@]}"; do
        [[ -e "$u" ]] && warn "$u"
    done

    section "[5] /etc/rc.local 是否含厂商脚本"
    if [[ -f /etc/rc.local ]] && grep -qE "qcloud|aliyun|aegis|cloudmonitor" /etc/rc.local 2>/dev/null; then
        warn "/etc/rc.local 含云厂商调优脚本"
        grep -E "qcloud|aliyun|aegis|cloudmonitor" /etc/rc.local | sed 's/^/      /'
    fi

    section "[6] cloud-init datasource"
    if [[ -f /etc/cloud/cloud.cfg ]]; then
        if grep -qE "(TencentCloud|AliYun|Aliyun|HuaweiCloud)" /etc/cloud/cloud.cfg 2>/dev/null; then
            warn "datasource_list 含厂商专属："
            grep -E "datasource_list|TencentCloud|AliYun|Aliyun|HuaweiCloud" /etc/cloud/cloud.cfg | sed 's/^/      /'
        fi
    fi

    section "[7] 当前运行进程"
    ps -ef 2>/dev/null | grep -iE "qcloud|tencent|tat_agent|YDService|YDLive|sgagent|stargate|aegis|aliyun_assist|cloudmonitor|argusagent|cwagent" | grep -v grep | sed 's/^/      /'

    section "[8] dpkg 包"
    dpkg -l 2>/dev/null | awk '/^ii/ && (/qcloud|tencent|tat-|stargate|yunjing|barad|aegis|aliyun|cwagent/) {print "  "$2,$3}'

    section "[9] /var/lib 下云数据"
    ls -d /var/lib/cloud /var/lib/aegis /var/lib/aliyun 2>/dev/null | sed 's/^/      /'
}

# ---------- 清剿 ----------
clean() {
    section "[1/9] 强 kill 所有云厂商进程"
    for proc in tat_agent YDService YDLive sgagent stargate nv_driver_install_helper aegis_cli aegis_qua cloudmonitor argusagent aliyun-service cwagent; do
        if pgrep -f "$proc" >/dev/null 2>&1; then
            pkill -9 -f "$proc" 2>/dev/null
            ok "killed: $proc"
        fi
    done
    pkill -9 -f "/usr/local/qcloud" 2>/dev/null || true
    pkill -9 -f "/usr/local/aegis" 2>/dev/null || true
    pkill -9 -f "/usr/local/aliyun" 2>/dev/null || true
    sleep 1

    section "[2/9] 关闭 + 删除 systemd unit"
    for kw in "${KNOWN_VENDOR_UNIT_KEYWORDS[@]}"; do
        for unit in $(systemctl list-unit-files --no-pager 2>/dev/null | awk -v kw="$kw" '$1 ~ "^"kw {print $1}'); do
            systemctl stop "$unit" 2>/dev/null || true
            systemctl disable "$unit" 2>/dev/null || true
            ok "stop/disable $unit"
        done
    done
    for f in /etc/systemd/system/{tat_install,tat_agent,YDService,YDLive,yunjing,sgagent,stargate,aegis*,aliyun_assist,cloudmonitor,argusagent,cwagent,nv_gpu_shutdown_pm}.service \
             /lib/systemd/system/{nv_gpu_shutdown_pm,YDService,YDLive,sgagent,aegis*,argusagent}.service \
             /etc/systemd/system/multi-user.target.wants/{tat_install,nv_gpu_shutdown_pm,sgagent,aegis*}.service; do
        [[ -e "$f" ]] && rm -f "$f" && ok "rm $f"
    done

    section "[3/9] 删除 cron 入口"
    for c in "${KNOWN_VENDOR_CRONS[@]}"; do
        [[ -e "$c" ]] && rm -f "$c" && ok "rm $c"
    done

    section "[4/9] 删除 udev 规则"
    for u in "${KNOWN_VENDOR_UDEV[@]}"; do
        [[ -e "$u" ]] && rm -f "$u" && ok "rm $u"
    done

    section "[5/9] 清空 /etc/rc.local 厂商调优"
    if [[ -f /etc/rc.local ]] && grep -qE "qcloud|aliyun|aegis" /etc/rc.local 2>/dev/null; then
        cp -n /etc/rc.local /etc/rc.local.before-clean.bak
        : > /etc/rc.local
        chmod -x /etc/rc.local
        ok "/etc/rc.local 清空（备份 .before-clean.bak）"
    fi

    section "[6/9] cloud-init datasource 切断厂商专属"
    if [[ -f /etc/cloud/cloud.cfg ]]; then
        cp -n /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.before-clean.bak
        # datasource_list: [ ConfigDrive, TencentCloud ] → [ None ]
        sed -i 's/^datasource_list:.*/datasource_list: [ None ]/' /etc/cloud/cloud.cfg
        # 删 datasource: 块下的厂商子配置
        for ds in "${VENDOR_DATASOURCES_TO_REMOVE[@]}"; do
            sed -i "/^datasource:/,/^[a-z]/{/${ds}/d}" /etc/cloud/cloud.cfg
        done
        ok "datasource_list = [ None ]"
    fi
    # 整体禁 cloud-init（首次部署后没必要每次开机跑）
    touch /etc/cloud/cloud-init.disabled
    for u in cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service; do
        systemctl mask "$u" 2>/dev/null && ok "mask $u" || true
    done

    section "[7/9] 删除 binary + 厂商目录"
    rm -f /usr/local/bin/tat_agent /usr/local/bin/tat_install* /usr/local/sbin/tat_agent 2>/dev/null
    rm -f /usr/local/bin/aliyun-service /usr/local/sbin/aliyun-service 2>/dev/null
    rm -rf /var/lib/cloud/instance /var/lib/cloud/instances/* /var/lib/cloud/scripts/vendor 2>/dev/null
    rm -rf /var/lib/aegis /var/lib/aliyun 2>/dev/null

    section "[8/9] 厂商目录强删 + chattr +i 锁住"
    for d in "${KNOWN_VENDOR_DIRS[@]}"; do
        if [[ -e "$d" ]]; then
            chattr -i "$d" 2>/dev/null || true
            rm -rf "$d" 2>/dev/null
            mkdir -p "$d"
            chattr +i "$d" 2>/dev/null && ok "$d → empty + chattr +i" || warn "$d 没法 chattr +i (fs 不支持？)"
        fi
    done

    section "[9/10] 卸 dpkg 残留"
    QPKGS=$(dpkg -l 2>/dev/null | awk '/^ii/ && (/qcloud|tencent|tat-|stargate|yunjing|barad|aegis|aliyun|cwagent|argusagent/) {print $2}' | xargs -r echo)
    if [[ -n "$QPKGS" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge $QPKGS 2>&1 | tail -3 || true
        ok "remove $QPKGS"
    fi

    section "[10/10] 清残留厂商 iptables-nft 链 + cgroup"
    # YunJing 残留链（杀进程不会清规则）
    for ch in YJ-FIREWALL-INPUT YJ-FIREWALL-OUTPUT YJ-FIREWALL-FORWARD; do
        # 解引（INPUT/OUTPUT/FORWARD 上的 jump）
        for parent in INPUT OUTPUT FORWARD; do
            iptables -D "$parent" -j "$ch" 2>/dev/null && ok "解引 $parent → $ch" || true
        done
        iptables -F "$ch" 2>/dev/null && ok "flush $ch" || true
        iptables -X "$ch" 2>/dev/null && ok "drop  $ch" || true
    done
    # 阿里云盾 / 监控可能的链名（保险起见）
    for ch in AEGIS-INPUT CMS-FIREWALL; do
        for parent in INPUT OUTPUT FORWARD; do
            iptables -D "$parent" -j "$ch" 2>/dev/null && ok "解引 $parent → $ch" || true
        done
        iptables -F "$ch" 2>/dev/null && ok "flush $ch" || true
        iptables -X "$ch" 2>/dev/null && ok "drop  $ch" || true
    done
    # cgroup 残留
    for cg in /sys/fs/cgroup/YunJing /sys/fs/cgroup/aegis; do
        [[ -d "$cg" ]] && rmdir "$cg" 2>/dev/null && ok "rm $cg" || true
    done

    systemctl daemon-reload 2>/dev/null || true
}

# ---------- 验证 ----------
verify() {
    section "VERIFY — 复查"
    detect
    echo
    section "VERIFY — 锁定测试"
    for d in "${KNOWN_VENDOR_DIRS[@]}"; do
        if [[ -d "$d" ]]; then
            if touch "$d/test_write_$$" 2>/dev/null; then
                warn "$d 没锁住！"
                rm -f "$d/test_write_$$"
            else
                ok "$d immutable 生效（写入被拒）"
            fi
        fi
    done
}

# ---------- 主 ----------
case "$ACTION" in
    detect) detect ;;
    clean)  clean; echo; section "POST-CLEAN 复查"; detect ;;
    verify) verify ;;
    *)      echo "Usage: $0 {detect|clean|verify}"; exit 1 ;;
esac

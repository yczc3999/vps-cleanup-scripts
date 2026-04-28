#!/usr/bin/env bash
# =============================================================================
# fix_iptables.sh — 一键修复 iptables-legacy 不可用问题
#
# 适用场景：
#   - 腾讯云 Ubuntu 24.04（YunJing 残留 + iptables-legacy 卡死）
#   - gui-tu agent 强依赖 iptables-legacy，必须保证这个二进制能用
#
# 策略（按 if-then 顺序）：
#   1) 清掉 YJ-FIREWALL-INPUT 等云厂商定制 nft 链
#   2) 重装 iptables 包 + 重设 alternatives
#   3) 测试 iptables-legacy --version
#      ✓ 可用 → 退出
#      ✗ 卡死 → 进入 fallback 模式
#   4) Fallback: 把 /usr/sbin/iptables-legacy symlink 重指向 xtables-nft-multi
#      （让 gui-tu agent 调用 iptables-legacy 实际走 nft 后端）
#   5) 最终验证：iptables-legacy -L INPUT -n / -A / -F 都要能在 5s 内返回
#
# 用法：
#   bash fix_iptables.sh                  # 默认全跑
#   bash fix_iptables.sh diagnose         # 只诊断，不修
# =============================================================================
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ACTION="${1:-fix}"

section() { echo; echo "==[ $* ]=="; }
ok()      { echo "  ✓ $*"; }
warn()    { echo "  ⚠ $*"; }
err()     { echo "  ✗ $*" >&2; }

# ----------------------------------------------------------------------------
# 0) 诊断
# ----------------------------------------------------------------------------
diagnose() {
    section "[0] 内核 + 模块"
    uname -r
    lsmod | grep -E "^(ip_tables|x_tables|nf_tables|iptable_filter|nft_compat)\b" | sed 's/^/  /'

    section "[1] iptables-legacy 健康度"
    if timeout 3 iptables-legacy --version >/dev/null 2>&1; then
        ok "iptables-legacy --version OK ($(iptables-legacy --version 2>&1))"
    else
        err "iptables-legacy --version 卡住或报错（exit=$?）"
    fi
    if timeout 3 iptables-legacy -L INPUT -n >/dev/null 2>&1; then
        ok "iptables-legacy -L INPUT OK"
    else
        err "iptables-legacy -L INPUT 卡住或报错（exit=$?）"
    fi

    section "[2] iptables-nft 健康度"
    if timeout 3 iptables -L INPUT -n >/dev/null 2>&1; then
        ok "iptables (nft) -L INPUT OK"
    else
        err "iptables-nft 也挂了"
    fi

    section "[3] 残留厂商链"
    iptables -nL 2>/dev/null | grep -E "YJ-|YunJing|qcloud|aliyun|aegis|cloudmonitor" | sed 's/^/  /' || ok "无残留厂商链"

    section "[4] Symlink 状态"
    ls -la /usr/sbin/iptables-legacy /usr/sbin/iptables 2>&1 | sed 's/^/  /'
    update-alternatives --display iptables 2>&1 | head -10 | sed 's/^/  /'
}

# ----------------------------------------------------------------------------
# 1) 清残留厂商 nft 链
# ----------------------------------------------------------------------------
purge_vendor_chains() {
    section "[A] 清残留厂商 nft 链"
    # YunJing
    iptables -D INPUT  -j YJ-FIREWALL-INPUT  2>/dev/null && ok "INPUT 解引 YJ-FIREWALL-INPUT" || true
    iptables -D OUTPUT -j YJ-FIREWALL-OUTPUT 2>/dev/null && ok "OUTPUT 解引 YJ-FIREWALL-OUTPUT" || true
    iptables -F YJ-FIREWALL-INPUT  2>/dev/null && ok "flush YJ-FIREWALL-INPUT"  || true
    iptables -F YJ-FIREWALL-OUTPUT 2>/dev/null && ok "flush YJ-FIREWALL-OUTPUT" || true
    iptables -X YJ-FIREWALL-INPUT  2>/dev/null && ok "drop YJ-FIREWALL-INPUT"   || true
    iptables -X YJ-FIREWALL-OUTPUT 2>/dev/null && ok "drop YJ-FIREWALL-OUTPUT"  || true
    # cgroup leftover
    [[ -d /sys/fs/cgroup/YunJing ]] && rmdir /sys/fs/cgroup/YunJing 2>/dev/null && ok "rm /sys/fs/cgroup/YunJing" || true
}

# ----------------------------------------------------------------------------
# 2) 重装 iptables + 修 alternatives
# ----------------------------------------------------------------------------
reinstall_iptables() {
    section "[B] 重装 iptables 包"
    DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -qy iptables 2>&1 | tail -3 | sed 's/^/  /' || true

    section "[C] alternatives 默认指向 legacy（gui-tu 要求）"
    # 先安装两个 alternative
    update-alternatives --set iptables  /usr/sbin/iptables-legacy  2>/dev/null || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
    update-alternatives --display iptables 2>&1 | head -5 | sed 's/^/  /'
}

# ----------------------------------------------------------------------------
# 3) 测试 legacy 是否复活
# ----------------------------------------------------------------------------
test_legacy() {
    if timeout 3 iptables-legacy -L INPUT -n >/dev/null 2>&1 && \
       timeout 3 iptables-legacy -t filter -N __TEST_HEALTH 2>/dev/null && \
       timeout 3 iptables-legacy -t filter -X __TEST_HEALTH 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ----------------------------------------------------------------------------
# 4) Fallback: 把 iptables-legacy 重指向 nft 后端
# ----------------------------------------------------------------------------
fallback_to_nft() {
    section "[D] FALLBACK: iptables-legacy → nft 后端"
    if [[ -f /usr/sbin/xtables-nft-multi ]]; then
        # 备份原 symlink（如果还没备份）
        if [[ ! -e /usr/sbin/iptables-legacy.orig-link ]]; then
            cp -P /usr/sbin/iptables-legacy /usr/sbin/iptables-legacy.orig-link 2>/dev/null || \
                ln -sf xtables-legacy-multi /usr/sbin/iptables-legacy.orig-link
            ok "备份原 symlink 到 .orig-link"
        fi
        # 重指 symlink
        ln -sf xtables-nft-multi /usr/sbin/iptables-legacy
        ln -sf xtables-nft-multi /usr/sbin/iptables-legacy-save
        ln -sf xtables-nft-multi /usr/sbin/iptables-legacy-restore
        ok "/usr/sbin/iptables-legacy → xtables-nft-multi"
        ok "（gui-tu agent 调用 iptables-legacy 实际走 nft 后端，对 agent 透明）"
    else
        err "/usr/sbin/xtables-nft-multi 不存在，无法 fallback"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# 5) 最终验证
# ----------------------------------------------------------------------------
verify_final() {
    section "[E] 最终验证 — gui-tu 调用模式"
    # 模拟 agent 的初始化序列
    iptables-legacy -t filter -N __GUITU_PROBE 2>&1 | sed 's/^/  /'
    iptables-legacy -t filter -A __GUITU_PROBE -i lo -j ACCEPT 2>&1 | sed 's/^/  /'
    iptables-legacy -t filter -A __GUITU_PROBE -p tcp --dport 22 -j ACCEPT 2>&1 | sed 's/^/  /'
    iptables-legacy -t filter -A __GUITU_PROBE -j DROP 2>&1 | sed 's/^/  /'
    iptables-legacy -nvL __GUITU_PROBE 2>&1 | sed 's/^/  /'
    iptables-legacy -t filter -F __GUITU_PROBE 2>&1
    iptables-legacy -t filter -X __GUITU_PROBE 2>&1
    if timeout 3 iptables-legacy -L INPUT -n >/dev/null 2>&1; then
        echo
        ok "iptables-legacy 健康，gui-tu agent 可用"
        return 0
    else
        echo
        err "iptables-legacy 仍不健康，需要人工介入"
        return 2
    fi
}

# ----------------------------------------------------------------------------
# 主
# ----------------------------------------------------------------------------
case "$ACTION" in
    diagnose)
        diagnose
        ;;
    fix)
        diagnose
        # 加载内核模块
        modprobe ip_tables       2>/dev/null || true
        modprobe iptable_filter  2>/dev/null || true
        modprobe nf_tables       2>/dev/null || true
        modprobe nft_compat      2>/dev/null || true
        purge_vendor_chains
        reinstall_iptables
        if test_legacy; then
            section "iptables-legacy 重装后已恢复"
            ok "无需 fallback"
        else
            warn "iptables-legacy 重装后仍异常，进入 fallback 模式"
            fallback_to_nft
        fi
        verify_final
        ;;
    rollback)
        section "回滚到原 iptables-legacy symlink"
        if [[ -e /usr/sbin/iptables-legacy.orig-link ]]; then
            ln -sf xtables-legacy-multi /usr/sbin/iptables-legacy
            ok "rollback /usr/sbin/iptables-legacy → xtables-legacy-multi"
        fi
        ;;
    *)
        echo "Usage: $0 {fix|diagnose|rollback}"
        exit 1
        ;;
esac

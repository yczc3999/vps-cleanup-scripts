# vps-cleanup-scripts

VPS 部署前置脚本集合：清剿云厂商定制插件（腾讯云/阿里云/华为云）+ 修复 iptables-legacy 不可用。

## 脚本

### `clean_cloud_plugins.sh`
通用云厂商插件清剿。三种模式：

- `bash clean_cloud_plugins.sh detect` — 仅扫描，不动系统
- `bash clean_cloud_plugins.sh clean` — 全清剿（kill 进程、disable systemd unit、删 cron / udev / cloud-init datasource、`chattr +i` 锁住厂商目录、清 iptables-nft 残留厂商链）
- `bash clean_cloud_plugins.sh verify` — 重启后自检（验证 immutable 锁仍生效）

支持厂商：
- **腾讯云**：tat_agent / YunJing / sgagent / stargate / barad / nv_gpu_shutdown_pm / qcloudzone
- **阿里云**：aegis / aliyun / cloudmonitor / argusagent / aliyun_assist
- **华为云**：cwagent

### `fix_iptables.sh`
iptables-legacy 卡死/不可用一键修。

- `bash fix_iptables.sh diagnose` — 仅诊断（输出 iptables-legacy / iptables-nft 健康度 + 残留厂商链 + alternatives 状态）
- `bash fix_iptables.sh fix` — 完整修复链路：清残留 nft 厂商链 + 重装 iptables 包 + alternatives 切到 legacy + 测试；若仍不可用自动 fallback 到 nft 后端
- `bash fix_iptables.sh rollback` — 回滚 fallback（symlink 切回原始）

## 一行下载（jsdelivr CDN，国内可用）

```bash
# 下载 + 跑 detect
curl -fsSL https://cdn.jsdelivr.net/gh/yczc3999/vps-cleanup-scripts@main/clean_cloud_plugins.sh -o /tmp/c.sh && bash /tmp/c.sh detect

# 下载 + 跑 clean（root 权限）
curl -fsSL https://cdn.jsdelivr.net/gh/yczc3999/vps-cleanup-scripts@main/clean_cloud_plugins.sh -o /tmp/c.sh && bash /tmp/c.sh clean

# fix iptables-legacy
curl -fsSL https://cdn.jsdelivr.net/gh/yczc3999/vps-cleanup-scripts@main/fix_iptables.sh -o /tmp/fi.sh && bash /tmp/fi.sh fix
```

## 备用 CDN

如 jsdelivr 失效，可换：

```bash
# Statically (jsdelivr 兜底)
https://cdn.statically.io/gh/yczc3999/vps-cleanup-scripts/main/clean_cloud_plugins.sh

# ghproxy
https://mirror.ghproxy.com/https://raw.githubusercontent.com/yczc3999/vps-cleanup-scripts/main/clean_cloud_plugins.sh
```

## 实测平台

- 腾讯云 Lighthouse Ubuntu 24.04：detect/clean/verify ✓ + chattr +i 锁定生效
- iptables-legacy 修复：YJ-FIREWALL-INPUT 残留 + alternatives 错位场景已验证

## 安全注意

- 清剿是**单向**操作：chattr +i 锁住厂商目录后，厂商通过云控制台的"重置/重装系统"才能恢复
- 必须 root 运行
- 跑 `clean` 之前建议先跑 `detect` 看清剿对象

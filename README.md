<div align="center">
  <a href="https://github.com/se-tang/NexusNode">
    <img src="./assets/logo.svg" alt="NexusNode" width="520" />
  </a>

  <h2>NexusNode v2.0</h2>
  <p>
    无面板 · 纯 Shell 双核代理部署与运维引擎 — 支持 <strong>Xray-core</strong> 与 <strong>sing-box</strong> 主流抗封锁协议。<br/>
    支持 TUI 交互与非交互式 CLI、WARP AI 分流、BBR 自愈诊断及跨机无缝迁移。
  </p>

  <p>
    <img src="https://img.shields.io/badge/Core-Xray%20%7C%20sing--box-5964C9?style=for-the-badge" alt="Cores" />
    <img src="https://img.shields.io/badge/Shell-Pure%20Bash-31C5D8?style=for-the-badge" alt="Pure Bash" />
    <img src="https://img.shields.io/badge/CLI-nexus%20%7C%20nx-A78BFA?style=for-the-badge" alt="CLI nexus" />
    <img src="https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu%20%7C%20Alpine%20%7C%20RHEL-1E293B?style=for-the-badge" alt="Linux" />
  </p>

  <p>
    <a href="#-快速开始">快速开始</a> ·
    <a href="#-支持协议">支持协议</a> ·
    <a href="#-cli-与进阶运维">CLI 与进阶运维</a> ·
    <a href="#-cloudflare-cdn-指南">CF CDN 指南</a> ·
    <a href="#-项目结构">项目结构</a>
  </p>
</div>

---

## 🚀 快速开始

以 root 身份在 Linux VPS 上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/se-tang/NexusNode/main/install.sh)
```

> [!TIP]
> 首次运行会自动安装到 `/opt/NexusNode` 并注册全局快捷指令 **`nexus`**（兼容 **`nx`**）。<br/>
> 之后输入 `nexus` 或 `nx` 即可秒开双层 TUI 面板；重复执行一键命令时仅在远端有新提交时自动更新。

---

## 🧩 支持协议

### Xray-core
- ✅ **VLESS - XTLS-Reality** — 免域名首选，支持 `/24` 同段净网扫描与同区高校/科研基地伪装优选
- ✅ **VLESS - XHTTP+Reality** — 新一代抗 DPI 传输层，免域名直连
- ✅ **VLESS - TCP+TLS+Vision** — 自有域名灰云直连最强，消除 TLS-in-TLS 指纹
- ✅ **VLESS - WS + TLS** — 支持 Cloudflare CDN 与优选 IP 中转
- ✅ **VLESS - gRPC + TLS** — 多路复用抗干扰（支持 CF CDN）
- ✅ **Trojan - gRPC / TLS** — gRPC 支持 CF CDN，TCP 限灰云直连

### sing-box
- ✅ **VLESS - XTLS-Reality** — sing-box 内核版 Reality 主力
- ✅ **Hysteria 2 (Hy2)** — 晚高峰 QUIC 加速，支持 UDP 端口跳跃与 pinSHA256
- ✅ **TUIC v5** — 极致低延迟 QUIC 方案
- ✅ **AnyTLS** — 缓解传统 TLS-in-TLS 握手特征
- ✅ **Shadowsocks-2022** — 弱协议，低 CPU 开销转发
- ✅ **SOCKS5 / HTTP** — 单端口双协议账号代理

> [!NOTE]
> **零域名推荐**：Reality、XHTTP、Hy2、TUIC 或 AnyTLS。<br/>
> **自有域名**：自动探测灰云（acme.sh 签发正式证书）或 CF 小黄云（优先分配 443 端口）。

---

## ⚡ CLI 与进阶运维

除交互面板外，支持全非交互式命令行（`nexus --help` 查看完整参数）：

```bash
nexus add xray vision                       # 一键静默部署 Xray Reality (默认同段+同区高校科研优选)
nexus add xray vision --sni-mode edu        # 跳过同段邻居，仅优选同地区高校/科研基地伪装域名
nexus add singbox reality --sni-region jp   # 指定日本地区高校/科研网优选部署 sing-box Reality
nexus add xray xhttp                        # 一键静默部署 Xray XHTTP Reality
nexus add hy2 --hop 30000:40000             # 一键部署 Hysteria 2 并开启 UDP 端口跳跃
nexus warp enable                           # 开启 WARP (127.0.0.1:40000) 解锁 ChatGPT / Netflix
nexus doctor                                # 校准 NTP 时间、开启 BBR、调优 UDP 缓冲并自愈服务
nexus migrate push root@1.2.3.4             # 通过 SSH 一键将密钥/UUID/端口无缝迁移到新机
nexus links                                 # 汇总打印当前所有已部署节点链接
```

- 🧭 **三级 Reality SNI 智能优选**：`/24` 同网段净网扫描（DNS 回指校验 + 机构后缀加权）→ 按出口国家自动匹配高校/科研骨干网/公共机构 → 全球非 CF 开源基建兜底，统一校验 `TLS 1.3 + X25519 + H2 + 短证书链`

- 🪶 **沙盒与双 init 兼容**：低权限 `nexus` 用户沙盒运行，同时适配 systemd 与 Alpine OpenRC
- 🧰 **零噪静默执行**：异常时自动输出 `/var/log/nexusnode/install.log` 关键日志摘要
- 🌐 **全自动环境兜底**：自动放行 ufw / firewalld、365 天合规证书、兼容 IPv4 与纯 IPv6

---

## ☁️ Cloudflare CDN 指南

> [!TIP]
> 配合 CF 小黄云使用 **Xray WS+TLS / gRPC+TLS**，只需在 CF 添加一条灰云 A 记录，无需手动拷贝证书。

<details>
<summary>点击展开：4 步完成配置与优选 IP</summary>

1. 在 Cloudflare 添加一条灰云 A 记录指向 VPS IP。
2. 运行 nx 选择 Xray 的 WS+TLS 或 gRPC+TLS，输入域名后脚本会自动申请证书（建议选 443 端口）。
3. 将 Cloudflare 的 SSL 模式设为 Full（或 Full Strict）；如用 gRPC，在网络设置中开启 gRPC。
4. 打开小黄云即可使用，客户端可将节点地址替换为 CF 优选 IP 或优选域名。

</details>

---

## 📁 项目结构

```text
NexusNode/
├── install.sh        # 入口引导、版本比对更新、注册 nexus / nx 命令
├── nexus.sh          # CLI 解析与双层 TUI 交互主控
├── core/
│   ├── xray.sh       # Xray-core 6 协议部署与 WARP 路由注入
│   └── singbox.sh    # sing-box 6 协议部署、端口跳跃与 WARP 路由注入
├── lib/
│   ├── ui.sh         # 零噪旋转任务引擎与卡片 UI
│   ├── env.sh        # systemd / OpenRC 沙盒、防火墙与双栈 IP
│   └── net.sh        # TLS 1.3+H2 SNI 测速、域名探测、acme.sh 与 port hopping
├── modules/
│   ├── warp.sh       # wgcf + wireproxy AI/流媒体分流
│   ├── doctor.sh     # BBR、UDP 缓冲、NTP 校准与服务自愈
│   └── migrate.sh    # 一键导出备份与 SSH 跨机迁移
└── assets/
    └── logo.svg
```

### 📱 推荐客户端

* **全平台**：[v2rayN](https://github.com/2dust/v2rayN) · [Karing](https://github.com/KaringX/karing) · [Hiddify](https://github.com/hiddify/hiddify-app) · [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)
* **iOS / macOS**：Shadowrocket · Stash · Surge

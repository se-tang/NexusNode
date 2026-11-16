<div align="center">
  <img src="./assets/logo.svg" alt="NexusNode" width="520" />

  <h3>Zero-Panel · 纯 Shell 多协议代理部署引擎</h3>
  <p>
    为极简测试与生产级防封锁而生 — 自动探测域名与 CDN 状态、自动签发证书、一键直出标准客户端链接
  </p>

  <p>
    <img src="https://img.shields.io/badge/Core-Xray%20%7C%20sing--box-38BDF8?style=for-the-badge" alt="Cores" />
    <img src="https://img.shields.io/badge/Shell-Pure%20Bash-6366F1?style=for-the-badge" alt="Pure Bash" />
    <img src="https://img.shields.io/badge/CLI-nx-22D3EE?style=for-the-badge" alt="CLI nx" />
    <img src="https://img.shields.io/badge/Zero--Panel-Systemd-A855F7?style=for-the-badge" alt="Systemd" />
  </p>
</div>

---

## 快速开始

在具有 `root` 权限的 Linux VPS（Debian / Ubuntu / CentOS / Fedora）上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/se-tang/NexusNode/main/install.sh)
```

> [!TIP]
> 首次运行会自动部署到 `/opt/NexusNode` 并注册全局命令 **`nx`**。<br/>
> 之后随时在终端输入 **`nx`** 即可秒开交互面板；再次执行上方一键命令时，仅在远端存在新提交时才会自动同步更新。

---

## 协议矩阵

### 1. 免域名 · 开箱即用（主力推荐）

| 核心 | 协议 | 传输 / 特性 | 适用场景 |
| :--- | :--- | :--- | :--- |
| **Xray-core** | **VLESS - XTLS-Reality** | `TCP` + `Vision` | **综合首选**，借壳大厂 TLS 证书，免域名防主动探测 |
| **Xray-core** | **VLESS - XHTTP+Reality** | `XHTTP` (`auto`) | **新一代抗 DPI**，免域名伪装现代 HTTP 流式传输 |
| **sing-box** | **VLESS - XTLS-Reality** | `TCP` + `Vision` | sing-box 内核版 Reality 主力 |
| **sing-box** | **Hysteria 2 (Hy2)** | `UDP / QUIC` | 晚高峰 / 高丢包线路加速（自带 `pinSHA256`，可选 Salamander 混淆） |
| **sing-box** | **TUIC v5** | `UDP / QUIC` + `BBR` | 极致低延迟交互与网页秒开 |
| **sing-box** | **AnyTLS** | `TCP + TLS` | 缓解传统 TLS-in-TLS 指纹特征 |

### 2. 自有域名 / Cloudflare CDN 专用 & 轻量转发

| 核心 | 协议 | 说明 |
| :--- | :--- | :--- |
| **Xray-core** | **VLESS - WS + TLS** | 完美适配 Cloudflare 小黄云代理，支持优选 IP / 优选域名中转 |
| **Xray-core** | **VLESS - gRPC + TLS** | 多路复用抗干扰（使用 CF 小黄云需在后台开启 `gRPC`） |
| **Xray-core** | **Trojan - gRPC / TLS** | `gRPC+TLS` 支持 CF 小黄云；原生 `TLS(TCP)` 仅限灰云直连 |
| **sing-box** | **Shadowsocks-2022** | `2022-blake3-aes-128-gcm`，低 CPU 开销（适合中转/落地） |
| **sing-box** | **SOCKS5 / HTTP** | `mixed` 单端口双协议账号代理 |

---

## 为什么选择 NexusNode？

* **CDN 与证书全自动闭环**：配置域名协议时，**先探测解析状态再选端口与证书**。
  * **灰云直连**：自动通过 `acme.sh` 向 Let's Encrypt 申请/复用正式 ECC 证书并自动续期，零手动配置。
  * **小黄云 CDN**：自动优先分配 `443`（或 `8443` / `2053` / `2083` 等 CF 支持端口）并自动生成回源证书，配合 CF `Full` 模式即开即用。
* **TLS 1.3 + H2 智能测速优选**：内置纯净大厂直连域名池（不碰 Apple 与 Cloudflare），自动筛选握手最快的可用 SNI。
* **移动端与新内核友好**：自签证书严格控制在 `365` 天合规期内并包含 `SAN` 扩展，Hysteria 2 自动附带 `pinSHA256` 指纹。
* **真·开箱即用**：自动补齐缺失依赖、自动放行 `ufw` / `firewalld` 端口、兼容 IPv4 与纯 IPv6 双栈、一键查看日志与清理卸载。

---

<details>
<summary><strong>Cloudflare CDN（小黄云）最佳实践速查</strong></summary>

1. 在 Cloudflare `DNS` 添加一条 `A` 记录指向 VPS IP（先保持**灰云**）。
2. 运行 `nx` → 选择 `Xray-core` → `3. VLESS - WS + TLS`（或 `4. gRPC`），输入域名后脚本会自动申请好 Let's Encrypt 正式证书（端口建议选 **`443`**，方便后续搭配优选 IP）。
3. 确认 Cloudflare `SSL/TLS → 概述` 为 **`完全 (Full)`** 或 **`完全(严格)`**；若用 gRPC，在 `网络 (Network)` 打开 **`gRPC`** 开关。
4. 在 Cloudflare 开启**小黄云**即可，客户端可直接导入原链接或替换节点地址为 CF 优选 IP / 优选域名。

</details>

<details>
<summary><strong>推荐客户端</strong></summary>

* **全平台**：[v2rayN](https://github.com/2dust/v2rayN) · [Karing](https://github.com/KaringX/karing) · [Hiddify](https://github.com/hiddify/hiddify-app) · [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)
* **iOS / macOS**：Shadowrocket · Stash · Surge

</details>

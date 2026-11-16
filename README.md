<div align="center">
  <img src="./assets/logo.svg" alt="NexusNode" width="540" />

  <p><strong>极简、无面板的 VPS 多协议代理部署引擎</strong></p>

  <p>
    <img src="https://img.shields.io/badge/Core-Xray%20%7C%20sing--box-38BDF8?style=flat-square" alt="Cores" />
    <img src="https://img.shields.io/badge/Stack-Pure%20Bash-6366F1?style=flat-square" alt="Pure Bash" />
    <img src="https://img.shields.io/badge/Shortcut-nx-A855F7?style=flat-square" alt="Shortcut nx" />
  </p>
</div>

---

## 快速开始

在具有 Root 权限的 Linux VPS 上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/se-tang/NexusNode/main/install.sh)
```

> 安装完成后，随时在终端输入 **`nx`** 即可再次呼出交互面板。

---

## 支持协议

| 后端核心 | 已支持协议 | 适用场景 |
| :--- | :--- | :--- |
| **Xray-core** | `VLESS-XTLS-Reality` / `VLESS-XHTTP+Reality` / `VLESS-WS+TLS` / `VLESS-gRPC+TLS` / `Trojan` | 免域名抗封锁、抗 DPI、CDN 中转 |
| **sing-box** | `VLESS-XTLS-Reality` / `Hysteria 2` / `TUIC v5` / `AnyTLS` / `Shadowsocks-2022` / `SOCKS5 & HTTP` | 高丢包加速、低时延、抗 TLS 指纹 |

---

## 核心特性

* **Zero-Panel**：纯 Shell + systemd 托管，零常驻面板内存占用。
* **TLS 1.3 + H2 智能优选**：Reality 伪装域名留空时自动测速优选（内置纯净直连域名池，不碰 Apple 与 Cloudflare）。
* **开箱即用**：自动校验配置、自动生成自签 ECC 证书（支持自定义证书）、自动放行 `ufw` / `firewalld` 端口。
* **双栈兼容**：自动识别 IPv4 / 纯 IPv6 环境并输出标准客户端分享链接，内置服务状态、日志查看与一键卸载。

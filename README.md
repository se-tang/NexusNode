<div align="center">
  <img src="./assets/logo.svg" alt="NexusNode" width="480" />
  <p><strong>Zero-Panel 纯 Shell 双核代理部署脚本</strong></p>
  <p>
    <img src="https://img.shields.io/badge/Xray--core-sing--box-5964C9?style=flat-square" alt="Cores" />
    <img src="https://img.shields.io/badge/Bash-Systemd-31C5D8?style=flat-square" alt="Bash" />
    <img src="https://img.shields.io/badge/CLI-nx-A78BFA?style=flat-square" alt="nx" />
  </p>
</div>

## 安装与使用

在 Linux VPS（`root`）运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/se-tang/NexusNode/main/install.sh)
```

安装后在终端输入 **`nx`** 即可随时呼出面板（重复执行一键命令仅在远端有新提交时更新）。

---

## 支持内核与协议

* **Xray-core**：`VLESS-Reality` · `VLESS-XHTTP+Reality` · `VLESS-WS+TLS` · `VLESS-gRPC+TLS` · `Trojan`
* **sing-box**：`VLESS-Reality` · `Hysteria 2` · `TUIC v5` · `AnyTLS` · `Shadowsocks-2022` · `SOCKS5 / HTTP`

> 无域名直接选 **Reality / XHTTP / Hy2 / TUIC / AnyTLS** 即可；使用自有域名时会自动检测灰云（`acme.sh` 签发正式证书）或 Cloudflare 小黄云（自动匹配 `443` 等 CDN 端口）。

---

## 特性

* **无面板零驻留**：纯 Bash + `systemd` 托管，直接输出标准客户端分享链接。
* **智能 SNI 与证书**：内置纯净直连域名池自动测速优选；自签证书合规 365 天并附带 `pinSHA256`。
* **开箱即用**：自动补齐依赖、校验配置、放行 `ufw` / `firewalld` 端口，兼容 IPv4 与纯 IPv6。

---

<details>
<summary>Cloudflare CDN（小黄云）用法 & 推荐客户端</summary>

* **CF CDN**：先在 CF 添加**灰云** `A` 记录指向 VPS → 用 `nx` 选 `443` 端口部署 `Xray WS+TLS` 或 `gRPC+TLS`（自动拿到 Let's Encrypt 证书）→ 回 CF 打开小黄云（SSL 设为 `Full`；若用 gRPC 需在 CF `网络` 开启 `gRPC`）。
* **推荐客户端**：[v2rayN](https://github.com/2dust/v2rayN) · [Karing](https://github.com/KaringX/karing) · [Hiddify](https://github.com/hiddify/hiddify-app) · [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) · Shadowrocket

</details>

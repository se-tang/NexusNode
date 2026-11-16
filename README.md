# NexusNode (纽克斯节点)

一款专为 VPS 测试与极速代理部署打造的纯 Shell 终端交互脚本，支持 **Xray-core** 与 **sing-box** 双后端，提供多协议一键直出节点链接。

## 核心特性
- **Zero-Panel (无面板)**：纯命令终端交互，极速轻量。
- **智能默认兜底**：端口直接回车自动生成安全高位端口。
- **动态延迟优选**：伪装域名支持留空自动测速优选（内置纯净大厂直连域名池，不碰苹果、不碰 Cloudflare，杜绝回源偷流量与暴雷风险）。
- **标准直出**：一键生成标准订阅与分享链接，完美对接 v2rayN、sing-box、Shadowrocket 等客户端。

## 快速安装与运行
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/se-tang/NexusNode/main/install.sh)
```

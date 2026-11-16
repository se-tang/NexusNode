#!/usr/bin/env bash

if [[ -z "${NEXUS_COMMON_LOADED:-}" ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../utils/common.sh"
fi

configure_singbox() {
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}      NexusNode - sing-box Protocol Menu  ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo " 1. VLESS - XTLS-Reality (推荐，高性能)"
    echo " 2. Hysteria 2 (Hy2)     (暂未开放)"
    echo " 3. TUIC v5              (暂未开放)"
    echo " 4. Shadowsocks-2022     (暂未开放)"
    echo " 5. SOCKS5 / HTTP        (暂未开放)"
    echo "------------------------------------------"
    read -p " 请选择协议 [1-5] (默认 1): " proto_choice
    proto_choice=${proto_choice:-1}

    case "$proto_choice" in
        1)
            echo -e "\n${CYAN}--- 配置 sing-box VLESS-XTLS-Reality ---${NC}"
            read -p " └─ 监听端口 [1-65535] (留空随机): " input_port
            local port
            port="$(get_valid_port "$input_port")" || return 1

            read -p " └─ 伪装域名 SNI (留空自动优选): " input_sni
            local sni
            sni="$(get_target_sni "$input_sni")" || return 1

            if ! command -v sing-box &>/dev/null; then
                echo -e "${CYAN}[Info]${NC} 正在安装 sing-box 内核..."
                curl -fsSL https://sing-box.app/install.sh | sh || true
                if ! command -v sing-box &>/dev/null; then
                    echo -e "${RED}[Error] 未能自动安装 sing-box 内核，请检查网络或系统源。${NC}"
                    return 1
                fi
            fi

            local sb_bin
            sb_bin="$(command -v sing-box)"

            local uuid short_id pub_ip url_ip
            uuid="$(cat /proc/sys/kernel/random/uuid)"
            short_id="$(openssl rand -hex 4)"
            pub_ip="$(get_public_ip)"
            if [[ -z "$pub_ip" ]]; then
                echo -e "${RED}[Error] 无法获取服务器公网 IP。${NC}"
                return 1
            fi
            url_ip="$(format_ip_for_url "$pub_ip")"

            local key_pair priv_key pub_key
            key_pair="$("$sb_bin" generate reality-keypair 2>/dev/null)" || {
                echo -e "${RED}[Error] 生成 Reality 密钥对失败。${NC}"
                return 1
            }
            priv_key="$(echo "$key_pair" | awk -F': ' '/PrivateKey/ {print $2}' | tr -d ' "\r\n')"
            pub_key="$(echo "$key_pair" | awk -F': ' '/PublicKey/ {print $2}' | tr -d ' "\r\n')"

            if [[ -z "$priv_key" || -z "$pub_key" ]]; then
                echo -e "${RED}[Error] 解析 sing-box Reality 密钥失败。${NC}"
                return 1
            fi

            mkdir -p /etc/sing-box
            cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": $port,
      "users": [
        { "name": "nexus", "uuid": "$uuid", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$sni",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$sni",
            "server_port": 443
          },
          "private_key": "$priv_key",
          "short_id": [ "$short_id" ]
        }
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

            if ! "$sb_bin" check -c /etc/sing-box/config.json; then
                echo -e "${RED}[Error] sing-box 配置文件校验失败。${NC}"
                return 1
            fi

            # 避免官方自带的 sing-box.service 占用相同配置或端口
            if systemctl is-active --quiet sing-box.service 2>/dev/null; then
                systemctl disable --now sing-box.service &>/dev/null || true
            fi

            cat <<EOF > /etc/systemd/system/nexus-singbox.service
[Unit]
Description=NexusNode sing-box Service
After=network.target

[Service]
ExecStart=${sb_bin} run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

            open_firewall_port "$port" "tcp"
            restart_and_verify_service "nexus-singbox.service" || return 1

            local share_link="vless://$uuid@$url_ip:$port?encryption=none&security=reality&sni=$sni&fp=chrome&pbk=$pub_key&sid=$short_id&type=tcp&flow=xtls-rprx-vision#NexusNode-Singbox-Reality"

            echo -e "\n${GREEN}==========================================${NC}"
            echo -e "${GREEN}        节点部署成功 (sing-box Reality)    ${NC}"
            echo -e "${GREEN}==========================================${NC}"
            echo -e " 地址 (Address): ${pub_ip}"
            echo -e " 端口 (Port):    ${port}"
            echo -e " UUID:           ${uuid}"
            echo -e " SNI:            ${sni}"
            echo -e " Public Key:     ${pub_key}"
            echo -e " ShortId:        ${short_id}"
            echo -e "------------------------------------------"
            echo -e "${CYAN}分享链接:${NC}\n${share_link}"
            echo -e "${GREEN}==========================================${NC}"
            ;;
        *)
            echo -e "${YELLOW}该协议分支暂未实现，敬请期待！${NC}"
            ;;
    esac
}

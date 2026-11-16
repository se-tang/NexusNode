#!/usr/bin/env bash

if [[ -z "${NEXUS_COMMON_LOADED:-}" ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../utils/common.sh"
fi

configure_xray() {
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}       NexusNode - Xray Protocol Menu     ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo " 1. VLESS - XTLS-Reality (推荐，免域名/防封锁)"
    echo " 2. VLESS - WS + TLS     (暂未开放)"
    echo " 3. VLESS - gRPC + TLS   (暂未开放)"
    echo " 4. Trojan - gRPC / TLS  (暂未开放)"
    echo " 5. VMess - WS           (暂未开放)"
    echo "------------------------------------------"
    read -p " 请选择协议 [1-5] (默认 1): " proto_choice
    proto_choice=${proto_choice:-1}

    case "$proto_choice" in
        1)
            echo -e "\n${CYAN}--- 配置 VLESS-XTLS-Reality ---${NC}"
            read -p " └─ 监听端口 [1-65535] (留空随机): " input_port
            local port
            port="$(get_valid_port "$input_port")" || return 1

            read -p " └─ 伪装域名 SNI (留空自动优选): " input_sni
            local sni
            sni="$(get_target_sni "$input_sni")" || return 1

            if ! command -v xray &>/dev/null; then
                echo -e "${CYAN}[Info]${NC} 正在安装 Xray-core 内核..."
                bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || true
                if ! command -v xray &>/dev/null; then
                    echo -e "${RED}[Error] 未能自动安装 Xray-core 内核，请检查网络。${NC}"
                    return 1
                fi
            fi

            local xray_bin
            xray_bin="$(command -v xray)"

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
            key_pair="$("$xray_bin" x25519 2>/dev/null)" || {
                echo -e "${RED}[Error] 生成 X25519 密钥对失败。${NC}"
                return 1
            }
            # 兼容 Xray 旧版 (Private key / Public key) 与新版 (PrivateKey / Password) 输出格式
            priv_key="$(echo "$key_pair" | awk -F': ' '/Private[[:space:]]*[Kk]ey/ {print $2}' | tr -d ' "\r\n')"
            pub_key="$(echo "$key_pair" | awk -F': ' '/(Public[[:space:]]*[Kk]ey|Password)/ {print $2}' | head -n 1 | tr -d ' "\r\n')"

            if [[ -z "$priv_key" || -z "$pub_key" ]]; then
                echo -e "${RED}[Error] 解析 Xray X25519 密钥失败。${NC}"
                return 1
            fi

            mkdir -p /usr/local/etc/xray
            cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$uuid", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$sni:443",
          "xver": 0,
          "serverNames": [ "$sni" ],
          "privateKey": "$priv_key",
          "shortIds": [ "$short_id" ]
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

            if ! "$xray_bin" run -test -c /usr/local/etc/xray/config.json; then
                echo -e "${RED}[Error] Xray 配置文件校验失败。${NC}"
                return 1
            fi

            # 避免官方自带的 xray.service 占用相同配置或端口
            if systemctl is-active --quiet xray.service 2>/dev/null; then
                systemctl disable --now xray.service &>/dev/null || true
            fi

            cat <<EOF > /etc/systemd/system/nexus-xray.service
[Unit]
Description=NexusNode Xray Service
After=network.target

[Service]
ExecStart=${xray_bin} run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

            open_firewall_port "$port" "tcp"
            restart_and_verify_service "nexus-xray.service" || return 1

            local share_link="vless://$uuid@$url_ip:$port?encryption=none&security=reality&sni=$sni&fp=chrome&pbk=$pub_key&sid=$short_id&type=tcp&flow=xtls-rprx-vision#NexusNode-Xray-Reality"

            echo -e "\n${GREEN}==========================================${NC}"
            echo -e "${GREEN}          节点部署成功 (Xray-Reality)      ${NC}"
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

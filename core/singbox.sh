#!/usr/bin/env bash

if [[ -z "${NEXUS_COMMON_LOADED:-}" ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../utils/common.sh"
fi

ensure_singbox() {
    if ! command -v sing-box &>/dev/null; then
        echo -e "${CYAN}[Info]${NC} 正在安装 sing-box 内核..."
        curl -fsSL https://sing-box.app/install.sh | sh || true
        if ! command -v sing-box &>/dev/null; then
            echo -e "${RED}[Error] 未能自动安装 sing-box 内核，请检查网络或系统源。${NC}"
            return 1
        fi
    fi
    SB_BIN="$(command -v sing-box)"
}

deploy_singbox_config() {
    local port="$1"
    shift
    local fw_protos=("$@")
    [[ ${#fw_protos[@]} -eq 0 ]] && fw_protos=("tcp")

    if ! "$SB_BIN" check -c /etc/sing-box/config.json; then
        echo -e "${RED}[Error] sing-box 配置文件校验失败。${NC}"
        return 1
    fi

    if systemctl is-active --quiet sing-box.service 2>/dev/null; then
        systemctl disable --now sing-box.service &>/dev/null || true
    fi

    cat <<EOF > /etc/systemd/system/nexus-singbox.service
[Unit]
Description=NexusNode sing-box Service
After=network.target

[Service]
ExecStart=${SB_BIN} run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    for p in "${fw_protos[@]}"; do
        open_firewall_port "$port" "$p"
    done
    restart_and_verify_service "nexus-singbox.service"
}

print_singbox_result() {
    local title="$1"
    local share_link="$2"
    shift 2
    echo -e "\n${GREEN}==========================================${NC}"
    echo -e "${GREEN}   节点部署成功 (${title})   ${NC}"
    echo -e "${GREEN}==========================================${NC}"
    for line in "$@"; do
        echo -e " $line"
    done
    echo -e "------------------------------------------"
    echo -e "${CYAN}分享链接:${NC}\n${share_link}"
    echo -e "${GREEN}==========================================${NC}"
}

configure_singbox() {
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}      NexusNode - sing-box Protocol Menu  ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo " 1. VLESS - XTLS-Reality (推荐，高性能)"
    echo " 2. Hysteria 2 (Hy2)     (恶劣网络/晚高峰加速)"
    echo " 3. TUIC v5              (极致低时延)"
    echo " 4. AnyTLS               (新一代抗 TLS 指纹)"
    echo " 5. Shadowsocks-2022     (弱协议，低CPU开销转发)"
    echo " 6. SOCKS5 / HTTP        (纯净账号代理)"
    echo "------------------------------------------"
    read -p " 请选择协议 [1-6] (默认 1): " proto_choice
    proto_choice=${proto_choice:-1}

    local input_port port pub_ip url_ip
    read -p " └─ 监听端口 [1-65535] (留空随机): " input_port
    port="$(get_valid_port "$input_port")" || return 1

    ensure_singbox || return 1
    pub_ip="$(get_public_ip)"
    if [[ -z "$pub_ip" ]]; then
        echo -e "${RED}[Error] 无法获取服务器公网 IP。${NC}"
        return 1
    fi
    url_ip="$(format_ip_for_url "$pub_ip")"
    mkdir -p /etc/sing-box

    case "$proto_choice" in
        1)
            echo -e "\n${CYAN}--- 配置 sing-box VLESS-XTLS-Reality ---${NC}"
            read -p " └─ 伪装域名 SNI (留空自动优选): " input_sni
            local sni uuid short_id key_pair priv_key pub_key
            sni="$(get_target_sni "$input_sni")" || return 1
            uuid="$(cat /proc/sys/kernel/random/uuid)"
            short_id="$(openssl rand -hex 4)"

            key_pair="$("$SB_BIN" generate reality-keypair 2>/dev/null)" || {
                echo -e "${RED}[Error] 生成 Reality 密钥对失败。${NC}"
                return 1
            }
            priv_key="$(echo "$key_pair" | awk -F': ' '/PrivateKey/ {print $2}' | tr -d ' "\r\n')"
            pub_key="$(echo "$key_pair" | awk -F': ' '/PublicKey/ {print $2}' | tr -d ' "\r\n')"
            if [[ -z "$priv_key" || -z "$pub_key" ]]; then
                echo -e "${RED}[Error] 解析 sing-box Reality 密钥失败。${NC}"
                return 1
            fi

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
            deploy_singbox_config "$port" "tcp" || return 1
            local link="vless://$uuid@$url_ip:$port?encryption=none&security=reality&sni=$sni&fp=chrome&pbk=$pub_key&sid=$short_id&type=tcp&flow=xtls-rprx-vision#NexusNode-Singbox-Reality"
            print_singbox_result "sing-box Reality" "$link" \
                "地址 (Address): ${pub_ip}" \
                "端口 (Port):    ${port}" \
                "UUID:           ${uuid}" \
                "SNI:            ${sni}" \
                "Public Key:     ${pub_key}" \
                "ShortId:        ${short_id}"
            ;;
        2)
            echo -e "\n${CYAN}--- 配置 sing-box Hysteria 2 ---${NC}"
            prompt_tls_cert "/etc/sing-box/certs" "www.bing.com" || return 1
            read -p " └─ 开启 Salamander 混淆抗 UDP 阻断 [y/N] (默认 N): " use_obfs
            use_obfs="${use_obfs:-N}"

            local password obfs_block="" obfs_query="" obfs_info="关闭"
            password="$(openssl rand -hex 12)"
            if [[ "$use_obfs" =~ ^[Yy]$ ]]; then
                local obfs_pass
                obfs_pass="$(openssl rand -hex 8)"
                obfs_block="      \"obfs\": { \"type\": \"salamander\", \"password\": \"${obfs_pass}\" },"
                obfs_query="&obfs=salamander&obfs-password=${obfs_pass}"
                obfs_info="salamander (${obfs_pass})"
            fi

            cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        { "name": "nexus", "password": "$password" }
      ],
${obfs_block}
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "certificate_path": "$TLS_CERT_FILE",
        "key_path": "$TLS_KEY_FILE"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
            deploy_singbox_config "$port" "udp" || return 1
            local host_addr="$url_ip"
            [[ "$TLS_INSECURE" -eq 0 ]] && host_addr="$TLS_DOMAIN"
            local pin_query=""
            [[ "$TLS_INSECURE" -eq 1 && -n "${TLS_CERT_SHA256:-}" ]] && pin_query="&pinSHA256=${TLS_CERT_SHA256}"
            local link="hysteria2://$password@$host_addr:$port/?sni=$TLS_DOMAIN&insecure=$TLS_INSECURE${pin_query}${obfs_query}#NexusNode-Singbox-Hy2"
            print_singbox_result "sing-box Hysteria 2" "$link" \
                "地址 (Address): ${host_addr}" \
                "端口 (Port):    ${port} (UDP)" \
                "密码 (Password): ${password}" \
                "混淆 (Obfs):    ${obfs_info}" \
                "SNI:            ${TLS_DOMAIN}" \
                "自签跳过验证:   ${TLS_INSECURE}"
            ;;
        3)
            echo -e "\n${CYAN}--- 配置 sing-box TUIC v5 ---${NC}"
            prompt_tls_cert "/etc/sing-box/certs" "www.bing.com" || return 1
            local uuid password
            uuid="$(cat /proc/sys/kernel/random/uuid)"
            password="$(openssl rand -hex 12)"

            cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        { "name": "nexus", "uuid": "$uuid", "password": "$password" }
      ],
      "congestion_control": "bbr",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "certificate_path": "$TLS_CERT_FILE",
        "key_path": "$TLS_KEY_FILE"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
            deploy_singbox_config "$port" "udp" || return 1
            local host_addr="$url_ip"
            [[ "$TLS_INSECURE" -eq 0 ]] && host_addr="$TLS_DOMAIN"
            local link="tuic://$uuid:$password@$host_addr:$port?congestion_control=bbr&alpn=h3&sni=$TLS_DOMAIN&allow_insecure=$TLS_INSECURE#NexusNode-Singbox-TUIC"
            print_singbox_result "sing-box TUIC v5" "$link" \
                "地址 (Address): ${host_addr}" \
                "端口 (Port):    ${port} (UDP)" \
                "UUID:           ${uuid}" \
                "密码 (Password): ${password}" \
                "SNI:            ${TLS_DOMAIN}"
            ;;
        4)
            echo -e "\n${CYAN}--- 配置 sing-box AnyTLS ---${NC}"
            prompt_tls_cert "/etc/sing-box/certs" "www.bing.com" || return 1
            local password
            password="$(openssl rand -hex 12)"

            cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        { "name": "nexus", "password": "$password" }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$TLS_CERT_FILE",
        "key_path": "$TLS_KEY_FILE"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
            deploy_singbox_config "$port" "tcp" || return 1
            local host_addr="$url_ip"
            [[ "$TLS_INSECURE" -eq 0 ]] && host_addr="$TLS_DOMAIN"
            local link="anytls://${password}@${host_addr}:${port}/?sni=${TLS_DOMAIN}&insecure=${TLS_INSECURE}#NexusNode-Singbox-AnyTLS"
            print_singbox_result "sing-box AnyTLS" "$link" \
                "地址 (Address): ${host_addr}" \
                "端口 (Port):    ${port} (TCP)" \
                "密码 (Password): ${password}" \
                "SNI:            ${TLS_DOMAIN}" \
                "自签跳过验证:   ${TLS_INSECURE}"
            ;;
        5)
            echo -e "\n${CYAN}--- 配置 sing-box Shadowsocks-2022 ---${NC}"
            local method="2022-blake3-aes-128-gcm"
            local password
            password="$(openssl rand -base64 16)"

            cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": $port,
      "method": "$method",
      "password": "$password"
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
            deploy_singbox_config "$port" "tcp" "udp" || return 1
            local creds_b64
            creds_b64="$(base64_encode_oneline "${method}:${password}")"
            local link="ss://${creds_b64}@${url_ip}:${port}#NexusNode-Singbox-SS2022"
            print_singbox_result "sing-box SS-2022" "$link" \
                "地址 (Address): ${pub_ip}" \
                "端口 (Port):    ${port} (TCP/UDP)" \
                "加密 (Method):  ${method}" \
                "密钥 (Password): ${password}"
            ;;
        6)
            echo -e "\n${CYAN}--- 配置 sing-box SOCKS5 / HTTP ---${NC}"
            read -p " └─ 用户名 (留空随机): " input_user
            local username="${input_user:-nexus_$(openssl rand -hex 3)}"
            read -p " └─ 密码 (留空随机): " input_pass
            local password="${input_pass:-$(openssl rand -hex 8)}"

            cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        { "username": "$username", "password": "$password" }
      ]
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
            deploy_singbox_config "$port" "tcp" || return 1
            local link="socks://${username}:${password}@${url_ip}:${port}#NexusNode-Mixed"
            print_singbox_result "sing-box SOCKS5/HTTP" "$link" \
                "地址 (Address): ${pub_ip}" \
                "端口 (Port):    ${port} (SOCKS5 & HTTP 共用)" \
                "用户名 (User):  ${username}" \
                "密码 (Pass):    ${password}"
            ;;
        *)
            echo -e "${RED}无效协议选项。${NC}"
            return 1
            ;;
    esac
}

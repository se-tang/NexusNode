#!/usr/bin/env bash

if [[ -z "${NEXUS_COMMON_LOADED:-}" ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../utils/common.sh"
fi

ensure_xray() {
    if ! command -v xray &>/dev/null; then
        echo -e "${CYAN}[Info]${NC} 正在安装 Xray-core 内核..."
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || true
        if ! command -v xray &>/dev/null; then
            echo -e "${RED}[Error] 未能自动安装 Xray-core 内核，请检查网络。${NC}"
            return 1
        fi
    fi
    XRAY_BIN="$(command -v xray)"
}

deploy_xray_config() {
    local port="$1"
    local fw_proto="${2:-tcp}"

    if ! "$XRAY_BIN" run -test -c /usr/local/etc/xray/config.json; then
        echo -e "${RED}[Error] Xray 配置文件校验失败。${NC}"
        return 1
    fi

    if systemctl is-active --quiet xray.service 2>/dev/null; then
        systemctl disable --now xray.service &>/dev/null || true
    fi

    cat <<EOF > /etc/systemd/system/nexus-xray.service
[Unit]
Description=NexusNode Xray Service
After=network.target

[Service]
ExecStart=${XRAY_BIN} run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    open_firewall_port "$port" "$fw_proto"
    restart_and_verify_service "nexus-xray.service"
}

print_xray_result() {
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

generate_xray_reality_keys() {
    local key_pair
    key_pair="$("$XRAY_BIN" x25519 2>/dev/null)" || {
        echo -e "${RED}[Error] 生成 X25519 密钥对失败。${NC}"
        return 1
    }
    REALITY_PRIV_KEY="$(echo "$key_pair" | awk -F': ' '/Private[[:space:]]*[Kk]ey/ {print $2}' | tr -d ' "\r\n')"
    REALITY_PUB_KEY="$(echo "$key_pair" | awk -F': ' '/(Public[[:space:]]*[Kk]ey|Password)/ {print $2}' | head -n 1 | tr -d ' "\r\n')"
    if [[ -z "$REALITY_PRIV_KEY" || -z "$REALITY_PUB_KEY" ]]; then
        echo -e "${RED}[Error] 解析 Xray X25519 密钥失败。${NC}"
        return 1
    fi
}

configure_xray() {
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}       NexusNode - Xray Protocol Menu     ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo " 1. VLESS - XTLS-Reality  (推荐，免域名/防封锁)"
    echo " 2. VLESS - XHTTP+Reality (新一代抗 DPI，免域名)"
    echo " 3. VLESS - WS + TLS      (需自有域名 / CDN)"
    echo " 4. VLESS - gRPC + TLS    (需自有域名 / CDN)"
    echo " 5. Trojan - gRPC / TLS   (需自有域名 / CDN)"
    echo "------------------------------------------"
    read -p " 请选择协议 [1-5] (默认 1): " proto_choice
    proto_choice=${proto_choice:-1}

    ensure_xray || return 1
    pub_ip="$(get_public_ip)"
    if [[ -z "$pub_ip" ]]; then
        echo -e "${RED}[Error] 无法获取服务器公网 IP。${NC}"
        return 1
    fi
    url_ip="$(format_ip_for_url "$pub_ip")"
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    mkdir -p /usr/local/etc/xray

    local input_port port
    if [[ "$proto_choice" == "3" || "$proto_choice" == "4" || "$proto_choice" == "5" ]]; then
        prompt_required_domain "$pub_ip" || return 1
        if [[ "${DOMAIN_IS_CF:-0}" -eq 1 ]]; then
            read -p " └─ 监听端口 (CF CDN 仅支持 443/2053/2083/2087/2096/8443，留空自动选用): " input_port
            if [[ -z "$(echo "${input_port:-}" | tr -d '[:space:]')" ]]; then
                port="$(get_cf_https_port)"
            else
                port="$(get_valid_port "$input_port")" || return 1
            fi
        else
            read -p " └─ 监听端口 [1-65535] (留空随机): " input_port
            port="$(get_valid_port "$input_port")" || return 1
        fi
        prompt_cert_for_domain "/usr/local/etc/xray/certs" "$TLS_DOMAIN" "$DOMAIN_IS_CF" || return 1
    elif [[ "$proto_choice" == "1" || "$proto_choice" == "2" ]]; then
        read -p " └─ 监听端口 [1-65535] (留空随机): " input_port
        port="$(get_valid_port "$input_port")" || return 1
    fi

    case "$proto_choice" in
        1)
            echo -e "\n${CYAN}--- 配置 VLESS-XTLS-Reality ---${NC}"
            read -p " └─ 伪装域名 SNI (留空自动优选): " input_sni
            local sni short_id
            sni="$(get_target_sni "$input_sni")" || return 1
            short_id="$(openssl rand -hex 4)"
            generate_xray_reality_keys || return 1

            cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$uuid", "flow": "xtls-rprx-vision" } ],
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
          "privateKey": "$REALITY_PRIV_KEY",
          "shortIds": [ "$short_id" ]
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
            deploy_xray_config "$port" "tcp" || return 1
            local link="vless://$uuid@$url_ip:$port?encryption=none&security=reality&sni=$sni&fp=chrome&pbk=$REALITY_PUB_KEY&sid=$short_id&type=tcp&flow=xtls-rprx-vision#NexusNode-Xray-Reality"
            print_xray_result "Xray-Reality" "$link" \
                "地址 (Address): ${pub_ip}" \
                "端口 (Port):    ${port}" \
                "UUID:           ${uuid}" \
                "SNI:            ${sni}" \
                "Public Key:     ${REALITY_PUB_KEY}" \
                "ShortId:        ${short_id}"
            ;;
        2)
            echo -e "\n${CYAN}--- 配置 VLESS-XHTTP+Reality ---${NC}"
            read -p " └─ 伪装域名 SNI (留空自动优选): " input_sni
            local sni short_id xhttp_path
            sni="$(get_target_sni "$input_sni")" || return 1
            read -p " └─ XHTTP 路径 (默认 /xhttp): " xhttp_path
            xhttp_path="${xhttp_path:-/xhttp}"
            [[ "$xhttp_path" != /* ]] && xhttp_path="/$xhttp_path"
            short_id="$(openssl rand -hex 4)"
            generate_xray_reality_keys || return 1

            cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$uuid" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "path": "$xhttp_path",
          "mode": "auto"
        },
        "realitySettings": {
          "show": false,
          "dest": "$sni:443",
          "xver": 0,
          "serverNames": [ "$sni" ],
          "privateKey": "$REALITY_PRIV_KEY",
          "shortIds": [ "$short_id" ]
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
            deploy_xray_config "$port" "tcp" || return 1
            local link="vless://$uuid@$url_ip:$port?encryption=none&security=reality&sni=$sni&fp=chrome&pbk=$REALITY_PUB_KEY&sid=$short_id&type=xhttp&path=$xhttp_path&mode=auto#NexusNode-Xray-XHTTP-Reality"
            print_xray_result "Xray-XHTTP+Reality" "$link" \
                "地址 (Address): ${pub_ip}" \
                "端口 (Port):    ${port}" \
                "UUID:           ${uuid}" \
                "SNI:            ${sni}" \
                "XHTTP Path:     ${xhttp_path}" \
                "Public Key:     ${REALITY_PUB_KEY}" \
                "ShortId:        ${short_id}"
            ;;
        3)
            echo -e "\n${CYAN}--- 配置 VLESS-WS+TLS ---${NC}"
            read -p " └─ WebSocket 路径 (默认 /ws): " ws_path
            ws_path="${ws_path:-/ws}"
            [[ "$ws_path" != /* ]] && ws_path="/$ws_path"

            cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$uuid" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "alpn": [ "http/1.1" ],
          "certificates": [
            { "certificateFile": "$TLS_CERT_FILE", "keyFile": "$TLS_KEY_FILE" }
          ]
        },
        "wsSettings": {
          "path": "$ws_path"
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
            deploy_xray_config "$port" "tcp" || return 1
            local host_addr="$url_ip"
            [[ "$TLS_INSECURE" -eq 0 ]] && host_addr="$TLS_DOMAIN"
            local link="vless://$uuid@$host_addr:$port?encryption=none&security=tls&sni=$TLS_DOMAIN&alpn=http%2F1.1&allowInsecure=$TLS_INSECURE&type=ws&host=$TLS_DOMAIN&path=$ws_path#NexusNode-Xray-VLESS-WS"
            print_xray_result "Xray-VLESS-WS+TLS" "$link" \
                "地址 (Address): ${host_addr}" \
                "端口 (Port):    ${port}" \
                "UUID:           ${uuid}" \
                "SNI:            ${TLS_DOMAIN}" \
                "WS Path:        ${ws_path}" \
                "自签证书跳过验证: ${TLS_INSECURE}"
            ;;
        4)
            echo -e "\n${CYAN}--- 配置 VLESS-gRPC+TLS ---${NC}"
            read -p " └─ gRPC ServiceName (默认 grpc): " grpc_svc
            grpc_svc="${grpc_svc:-grpc}"

            cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$uuid" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "tls",
        "tlsSettings": {
          "alpn": [ "h2" ],
          "certificates": [
            { "certificateFile": "$TLS_CERT_FILE", "keyFile": "$TLS_KEY_FILE" }
          ]
        },
        "grpcSettings": {
          "serviceName": "$grpc_svc"
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
            deploy_xray_config "$port" "tcp" || return 1
            local host_addr="$url_ip"
            [[ "$TLS_INSECURE" -eq 0 ]] && host_addr="$TLS_DOMAIN"
            local link="vless://$uuid@$host_addr:$port?encryption=none&security=tls&sni=$TLS_DOMAIN&allowInsecure=$TLS_INSECURE&type=grpc&serviceName=$grpc_svc&mode=gun#NexusNode-Xray-VLESS-gRPC"
            print_xray_result "Xray-VLESS-gRPC+TLS" "$link" \
                "地址 (Address): ${host_addr}" \
                "端口 (Port):    ${port}" \
                "UUID:           ${uuid}" \
                "SNI:            ${TLS_DOMAIN}" \
                "ServiceName:    ${grpc_svc}"
            echo -e "${YELLOW}[提示] 若开启 Cloudflare 小黄云，请确保在 CF 后台「网络 (Network)」中开启 gRPC 开关。${NC}"
            ;;
        5)
            echo -e "\n${CYAN}--- 配置 Trojan-gRPC/TLS ---${NC}"
            read -p " └─ 传输方式 [1. TLS(TCP)  2. gRPC+TLS] (默认 1): " t_mode
            t_mode="${t_mode:-1}"
            local password
            password="$(openssl rand -hex 12)"

            local net_type="tcp"
            local extra_stream=""
            local extra_link="type=tcp"
            local grpc_svc="trojan-grpc"
            if [[ "$t_mode" == "2" ]]; then
                net_type="grpc"
                read -p " └─ gRPC ServiceName (默认 trojan-grpc): " input_svc
                grpc_svc="${input_svc:-trojan-grpc}"
                extra_stream=", \"grpcSettings\": { \"serviceName\": \"$grpc_svc\" }"
                extra_link="type=grpc&serviceName=$grpc_svc&mode=gun"
            fi

            cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $port,
      "protocol": "trojan",
      "settings": {
        "clients": [ { "password": "$password" } ]
      },
      "streamSettings": {
        "network": "$net_type",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            { "certificateFile": "$TLS_CERT_FILE", "keyFile": "$TLS_KEY_FILE" }
          ]
        }${extra_stream}
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
            deploy_xray_config "$port" "tcp" || return 1
            local host_addr="$url_ip"
            [[ "$TLS_INSECURE" -eq 0 ]] && host_addr="$TLS_DOMAIN"
            local link="trojan://$password@$host_addr:$port?security=tls&sni=$TLS_DOMAIN&allowInsecure=$TLS_INSECURE&$extra_link#NexusNode-Xray-Trojan"
            print_xray_result "Xray-Trojan-${net_type^^}" "$link" \
                "地址 (Address): ${host_addr}" \
                "端口 (Port):    ${port}" \
                "密码 (Password): ${password}" \
                "SNI:            ${TLS_DOMAIN}" \
                "传输 (Network): ${net_type}"
            if [[ "$net_type" == "grpc" ]]; then
                echo -e "${YELLOW}[提示] 若开启 Cloudflare 小黄云，请确保在 CF 后台「网络 (Network)」中开启 gRPC 开关。${NC}"
            else
                echo -e "${YELLOW}[提示] 原生 Trojan (TCP) 不支持 Cloudflare 小黄云代理，请保持灰云直连。${NC}"
            fi
            ;;
        *)
            echo -e "${RED}无效协议选项。${NC}"
            return 1
            ;;
    esac
}

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

configure_xray() {
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}       NexusNode - Xray Protocol Menu     ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo " 1. VLESS - XTLS-Reality (推荐，免域名/防封锁)"
    echo " 2. VLESS - WS + TLS     (支持 CDN / 自签证书)"
    echo " 3. VLESS - gRPC + TLS   (多路复用 / 抗干扰)"
    echo " 4. Trojan - gRPC / TLS  (伪装 HTTPS 流量)"
    echo " 5. VMess - WS           (传统兼容，免域名)"
    echo "------------------------------------------"
    read -p " 请选择协议 [1-5] (默认 1): " proto_choice
    proto_choice=${proto_choice:-1}

    local input_port port pub_ip url_ip uuid
    read -p " └─ 监听端口 [1-65535] (留空随机): " input_port
    port="$(get_valid_port "$input_port")" || return 1

    ensure_xray || return 1
    pub_ip="$(get_public_ip)"
    if [[ -z "$pub_ip" ]]; then
        echo -e "${RED}[Error] 无法获取服务器公网 IP。${NC}"
        return 1
    fi
    url_ip="$(format_ip_for_url "$pub_ip")"
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    mkdir -p /usr/local/etc/xray

    case "$proto_choice" in
        1)
            echo -e "\n${CYAN}--- 配置 VLESS-XTLS-Reality ---${NC}"
            read -p " └─ 伪装域名 SNI (留空自动优选): " input_sni
            local sni short_id key_pair priv_key pub_key
            sni="$(get_target_sni "$input_sni")" || return 1
            short_id="$(openssl rand -hex 4)"

            key_pair="$("$XRAY_BIN" x25519 2>/dev/null)" || {
                echo -e "${RED}[Error] 生成 X25519 密钥对失败。${NC}"
                return 1
            }
            priv_key="$(echo "$key_pair" | awk -F': ' '/Private[[:space:]]*[Kk]ey/ {print $2}' | tr -d ' "\r\n')"
            pub_key="$(echo "$key_pair" | awk -F': ' '/(Public[[:space:]]*[Kk]ey|Password)/ {print $2}' | head -n 1 | tr -d ' "\r\n')"
            if [[ -z "$priv_key" || -z "$pub_key" ]]; then
                echo -e "${RED}[Error] 解析 Xray X25519 密钥失败。${NC}"
                return 1
            fi

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
          "privateKey": "$priv_key",
          "shortIds": [ "$short_id" ]
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
            deploy_xray_config "$port" "tcp" || return 1
            local link="vless://$uuid@$url_ip:$port?encryption=none&security=reality&sni=$sni&fp=chrome&pbk=$pub_key&sid=$short_id&type=tcp&flow=xtls-rprx-vision#NexusNode-Xray-Reality"
            print_xray_result "Xray-Reality" "$link" \
                "地址 (Address): ${pub_ip}" \
                "端口 (Port):    ${port}" \
                "UUID:           ${uuid}" \
                "SNI:            ${sni}" \
                "Public Key:     ${pub_key}" \
                "ShortId:        ${short_id}"
            ;;
        2)
            echo -e "\n${CYAN}--- 配置 VLESS-WS+TLS ---${NC}"
            prompt_tls_cert "/usr/local/etc/xray/certs" "www.bing.com" || return 1
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
          "serverName": "$TLS_DOMAIN",
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
            local link="vless://$uuid@$host_addr:$port?encryption=none&security=tls&sni=$TLS_DOMAIN&allowInsecure=$TLS_INSECURE&type=ws&path=$ws_path#NexusNode-Xray-VLESS-WS"
            print_xray_result "Xray-VLESS-WS+TLS" "$link" \
                "地址 (Address): ${host_addr}" \
                "端口 (Port):    ${port}" \
                "UUID:           ${uuid}" \
                "SNI:            ${TLS_DOMAIN}" \
                "WS Path:        ${ws_path}" \
                "自签证书跳过验证: ${TLS_INSECURE}"
            ;;
        3)
            echo -e "\n${CYAN}--- 配置 VLESS-gRPC+TLS ---${NC}"
            prompt_tls_cert "/usr/local/etc/xray/certs" "www.bing.com" || return 1
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
          "serverName": "$TLS_DOMAIN",
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
            ;;
        4)
            echo -e "\n${CYAN}--- 配置 Trojan-gRPC/TLS ---${NC}"
            prompt_tls_cert "/usr/local/etc/xray/certs" "www.bing.com" || return 1
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
          "serverName": "$TLS_DOMAIN",
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
            ;;
        5)
            echo -e "\n${CYAN}--- 配置 VMess-WS ---${NC}"
            read -p " └─ WebSocket 路径 (默认 /vmess): " ws_path
            ws_path="${ws_path:-/vmess}"
            [[ "$ws_path" != /* ]] && ws_path="/$ws_path"

            cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vmess",
      "settings": {
        "clients": [ { "id": "$uuid", "alterId": 0 } ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
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
            local vmess_json
            vmess_json="{\"v\":\"2\",\"ps\":\"NexusNode-Xray-VMess-WS\",\"add\":\"$pub_ip\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"$ws_path\",\"tls\":\"\"}"
            local link="vmess://$(base64_encode_oneline "$vmess_json")"
            print_xray_result "Xray-VMess-WS" "$link" \
                "地址 (Address): ${pub_ip}" \
                "端口 (Port):    ${port}" \
                "UUID:           ${uuid}" \
                "WS Path:        ${ws_path}"
            ;;
        *)
            echo -e "${RED}无效协议选项。${NC}"
            return 1
            ;;
    esac
}

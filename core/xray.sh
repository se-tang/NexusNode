#!/usr/bin/env bash
# ==============================================================================
# NexusNode Xray-core Engine (Reality Vision/XHTTP, TCP+TLS+Vision, WS, gRPC, Trojan)
# ==============================================================================

ensure_xray_binary() {
    if [[ -x "${NEXUS_BIN}/xray" ]]; then
        return 0
    fi
    local arch wp_arch="64"
    arch=$(uname -m)
    case "$arch" in
        aarch64|arm64) wp_arch="arm64-v8a" ;;
        x86_64|amd64)  wp_arch="64" ;;
    esac

    run_step "下载官方最新 Xray-core 二进制内核" "
        curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${wp_arch}.zip -o /tmp/xray.zip &&
        unzip -qo /tmp/xray.zip xray geoip.dat geosite.dat -d ${NEXUS_BIN}/ &&
        chmod +x ${NEXUS_BIN}/xray &&
        rm -f /tmp/xray.zip
    "
}

build_xray_outbounds() {
    local j
    j=$(build_xray_routing_json)
    j="${j#\{}"
    j="${j%\}}"
    printf '  %s\n' "$j"
}

generate_xray_reality_keys() {
    local keys
    keys=$("${NEXUS_BIN}/xray" x25519 2>/dev/null) || {
        ui_err "生成 X25519 密钥对失败。"
        return 1
    }
    REALITY_PRIV_KEY=$(echo "$keys" | awk -F': ' '/Private[[:space:]]*[Kk]ey/ {print $2}' | tr -d ' "\r\n')
    REALITY_PUB_KEY=$(echo "$keys" | awk -F': ' '/(Public[[:space:]]*[Kk]ey|Password)/ {print $2}' | head -n 1 | tr -d ' "\r\n')
    if [[ -z "$REALITY_PRIV_KEY" || -z "$REALITY_PUB_KEY" ]]; then
        ui_err "解析 Xray X25519 密钥失败。"
        return 1
    fi
}

deploy_xray_service() {
    local port="$1"
    if ! "${NEXUS_BIN}/xray" run -test -c "${NEXUS_DIR}/xray/config.json" >/dev/null 2>&1; then
        ui_err "Xray 配置文件校验失败："
        "${NEXUS_BIN}/xray" run -test -c "${NEXUS_DIR}/xray/config.json" || true
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet xray.service 2>/dev/null; then
        systemctl disable --now xray.service >/dev/null 2>&1 || true
    fi
    open_firewall_port "$port" "tcp"
    create_service "nexus-xray" "${NEXUS_BIN}/xray run -c ${NEXUS_DIR}/xray/config.json" "NexusNode Xray Service"
}

# Usage: deploy_xray_node [vision|xhttp|tcp-tls|ws-tls|grpc-tls|trojan] [port] [sni]
deploy_xray_node() {
    local mode="${1:-vision}"
    local port="${2:-}"
    local sni="${3:-}"

    ensure_xray_binary || return 1

    local pub_ip url_ip uuid outbounds_json
    pub_ip=$(get_public_ip)
    if [[ -z "$pub_ip" ]]; then
        ui_err "无法获取服务器公网 IP。"
        return 1
    fi
    url_ip=$(format_ip_for_url "$pub_ip")
    uuid=$("${NEXUS_BIN}/xray" uuid)
    outbounds_json=$(build_xray_outbounds)
    mkdir -p "${NEXUS_DIR}/xray/certs"

    # Domain-based protocols (tcp-tls, ws-tls, grpc-tls, trojan)
    if [[ "$mode" == "tcp-tls" || "$mode" == "ws-tls" || "$mode" == "grpc-tls" || "$mode" == "trojan" ]]; then
        if [[ -z "$sni" ]]; then
            prompt_required_domain "$pub_ip" || return 1
        else
            TLS_DOMAIN="$(validate_sni "$sni")" || return 1
            DOMAIN_IS_CF=0
            check_domain_direct_status "$TLS_DOMAIN" "$pub_ip" || DOMAIN_IS_CF=$?
        fi

        if [[ -z "$port" ]]; then
            local def_port
            if [[ "$mode" != "tcp-tls" && "${DOMAIN_IS_CF:-0}" -eq 1 ]]; then
                def_port=$(get_cf_https_port)
                if [[ "$NON_INTERACTIVE" == "true" ]]; then
                    port="$def_port"
                else
                    ui_ask "监听端口 (CF 端口)" "$def_port" port
                    port="$(get_valid_port "$port")" || return 1
                fi
            else
                def_port=$(random_high_port) || return 1
                if [[ "$NON_INTERACTIVE" == "true" ]]; then
                    port="$def_port"
                else
                    ui_ask "监听端口" "$def_port" port "随机"
                    port="$(get_valid_port "$port")" || return 1
                fi
            fi
        else
            port="$(get_valid_port "$port")" || return 1
        fi

        prompt_cert_for_domain "${NEXUS_DIR}/xray/certs" "$TLS_DOMAIN" "$DOMAIN_IS_CF" || return 1
    else
        # Reality protocols (vision, xhttp)
        if [[ -z "$port" ]]; then
            local def_port
            def_port=$(random_high_port) || return 1
            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                port="$def_port"
            else
                ui_ask "监听端口" "$def_port" port "随机"
                port="$(get_valid_port "$port")" || return 1
            fi
        else
            port="$(get_valid_port "$port")" || return 1
        fi

        if [[ -z "$sni" ]]; then
            prompt_camouflage_sni sni 1
        elif ! is_allowed_reality_sni "$sni"; then
            ui_err "Reality SNI 格式无效或属于已排除的 Apple/CDN/动态域名: ${sni}"
            return 1
        fi
        sni="$(validate_sni "$sni")" || return 1
    fi

    local share_link title extra=""
    case "$mode" in
        vision)
            generate_xray_reality_keys || return 1
            local short_id
            short_id=$(openssl rand -hex 4)
            cat > "${NEXUS_DIR}/xray/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "::",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${sni}:443",
          "xver": 0,
          "serverNames": ["${sni}"],
          "privateKey": "${REALITY_PRIV_KEY}",
          "shortIds": ["${short_id}"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
${outbounds_json}
}
EOF
            deploy_xray_service "$port" || return 1
            title="Xray VLESS-Reality-Vision"
            extra="SNI: ${sni} | ShortID: ${short_id}"
            share_link="vless://${uuid}@${url_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${REALITY_PUB_KEY}&sid=${short_id}&type=tcp#Nexus-Vision-${pub_ip}"
            ;;
        xhttp)
            generate_xray_reality_keys || return 1
            local short_id xhttp_path
            short_id=$(openssl rand -hex 4)
            xhttp_path="/$(openssl rand -hex 4)"
            if [[ "$NON_INTERACTIVE" != "true" ]]; then
                ui_ask "XHTTP 路径" "$xhttp_path" xhttp_path "随机"
                [[ "$xhttp_path" != /* ]] && xhttp_path="/${xhttp_path}"
            fi
            cat > "${NEXUS_DIR}/xray/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "::",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": { "path": "${xhttp_path}", "mode": "auto" },
        "realitySettings": {
          "show": false,
          "dest": "${sni}:443",
          "xver": 0,
          "serverNames": ["${sni}"],
          "privateKey": "${REALITY_PRIV_KEY}",
          "shortIds": ["${short_id}"]
        }
      }
    }
  ],
${outbounds_json}
}
EOF
            deploy_xray_service "$port" || return 1
            title="Xray VLESS-XHTTP-Reality"
            extra="SNI: ${sni} | Path: ${xhttp_path} | ShortID: ${short_id}"
            share_link="vless://${uuid}@${url_ip}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${REALITY_PUB_KEY}&sid=${short_id}&type=xhttp&path=${xhttp_path}&mode=auto#Nexus-XHTTP-${pub_ip}"
            ;;
        tcp-tls)
            cat > "${NEXUS_DIR}/xray/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "::",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            { "certificateFile": "${TLS_CERT_FILE}", "keyFile": "${TLS_KEY_FILE}" }
          ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
${outbounds_json}
}
EOF
            deploy_xray_service "$port" || return 1
            title="Xray VLESS-TCP+TLS+Vision"
            extra="SNI: ${TLS_DOMAIN} | Flow: xtls-rprx-vision"
            share_link="vless://${uuid}@${TLS_DOMAIN}:${port}?encryption=none&security=tls&sni=${TLS_DOMAIN}&fp=chrome&allowInsecure=${TLS_INSECURE}&type=tcp&flow=xtls-rprx-vision#Nexus-VisionTLS-${TLS_DOMAIN}"
            ui_warn "TCP+TLS+Vision 不支持 Cloudflare 小黄云代理，请保持域名灰云直连。"
            ;;
        ws-tls)
            local ws_path="/ws"
            if [[ "$NON_INTERACTIVE" != "true" ]]; then
                ui_ask "请输入 WebSocket 路径" "/ws" ws_path
                [[ "$ws_path" != /* ]] && ws_path="/${ws_path}"
            fi
            cat > "${NEXUS_DIR}/xray/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "::",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "certificates": [
            { "certificateFile": "${TLS_CERT_FILE}", "keyFile": "${TLS_KEY_FILE}" }
          ]
        },
        "wsSettings": { "path": "${ws_path}" }
      }
    }
  ],
${outbounds_json}
}
EOF
            deploy_xray_service "$port" || return 1
            title="Xray VLESS-WS+TLS"
            extra="SNI: ${TLS_DOMAIN} | Path: ${ws_path}"
            share_link="vless://${uuid}@${TLS_DOMAIN}:${port}?encryption=none&security=tls&sni=${TLS_DOMAIN}&alpn=http%2F1.1&allowInsecure=${TLS_INSECURE}&type=ws&host=${TLS_DOMAIN}&path=${ws_path}#Nexus-WS-${TLS_DOMAIN}"
            ;;
        grpc-tls)
            local grpc_svc="grpc"
            if [[ "$NON_INTERACTIVE" != "true" ]]; then
                ui_ask "请输入 gRPC ServiceName" "grpc" grpc_svc
            fi
            cat > "${NEXUS_DIR}/xray/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "::",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h2"],
          "certificates": [
            { "certificateFile": "${TLS_CERT_FILE}", "keyFile": "${TLS_KEY_FILE}" }
          ]
        },
        "grpcSettings": { "serviceName": "${grpc_svc}" }
      }
    }
  ],
${outbounds_json}
}
EOF
            deploy_xray_service "$port" || return 1
            title="Xray VLESS-gRPC+TLS"
            extra="SNI: ${TLS_DOMAIN} | ServiceName: ${grpc_svc}"
            share_link="vless://${uuid}@${TLS_DOMAIN}:${port}?encryption=none&security=tls&sni=${TLS_DOMAIN}&allowInsecure=${TLS_INSECURE}&type=grpc&serviceName=${grpc_svc}&mode=gun#Nexus-gRPC-${TLS_DOMAIN}"
            ui_warn "若使用 Cloudflare 小黄云，请在 CF 后台「网络 (Network)」开启 gRPC 开关。"
            ;;
        trojan)
            local t_mode="1" password net_type="tcp" extra_stream="" extra_link="type=tcp" grpc_svc="trojan-grpc"
            password=$(openssl rand -hex 12)
            if [[ "$NON_INTERACTIVE" != "true" ]]; then
                ui_ask "传输方式 (1: TLS-TCP, 2: gRPC+TLS)" "1" t_mode
            fi
            if [[ "$t_mode" == "2" ]]; then
                net_type="grpc"
                [[ "$NON_INTERACTIVE" != "true" ]] && ui_ask "请输入 gRPC ServiceName" "trojan-grpc" grpc_svc
                extra_stream=", \"grpcSettings\": { \"serviceName\": \"${grpc_svc}\" }"
                extra_link="type=grpc&serviceName=${grpc_svc}&mode=gun"
            fi
            cat > "${NEXUS_DIR}/xray/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "::",
      "port": ${port},
      "protocol": "trojan",
      "settings": {
        "clients": [{ "password": "${password}" }]
      },
      "streamSettings": {
        "network": "${net_type}",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            { "certificateFile": "${TLS_CERT_FILE}", "keyFile": "${TLS_KEY_FILE}" }
          ]
        }${extra_stream}
      }
    }
  ],
${outbounds_json}
}
EOF
            deploy_xray_service "$port" || return 1
            title="Xray Trojan-${net_type^^}"
            extra="SNI: ${TLS_DOMAIN} | Network: ${net_type}"
            share_link="trojan://${password}@${TLS_DOMAIN}:${port}?security=tls&sni=${TLS_DOMAIN}&allowInsecure=${TLS_INSECURE}&${extra_link}#Nexus-Trojan-${TLS_DOMAIN}"
            if [[ "$net_type" == "grpc" ]]; then
                ui_warn "若使用 Cloudflare 小黄云，请在 CF 后台「网络 (Network)」开启 gRPC 开关。"
            else
                ui_warn "原生 Trojan (TCP) 不支持 Cloudflare 小黄云，请保持灰云直连。"
            fi
            ;;
        *)
            ui_err "未知 Xray 协议模式: ${mode}"
            return 1
            ;;
    esac

    rm -f "${NEXUS_DIR}/links/xray_"*.txt
    echo "$share_link" > "${NEXUS_DIR}/links/xray_${mode}.txt"
    ui_node_card "$title" "${TLS_DOMAIN:-$pub_ip}" "$port" "$extra" "$share_link"
}
